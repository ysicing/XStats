// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

/// Helper 的有限时子进程执行器；超时包含进程退出后等待继承管道 EOF 的时间。
public enum HelperToolRunner {
  public struct Result: Sendable {
    public let status: Int32
    public let output: String
    public let timedOut: Bool
  }

  /// 持续排空 stdout/stderr，但只保留有界诊断；不等待持有管道的孙进程。
  public static func run(
    path: String, arguments: [String], timeout: TimeInterval = 30,
    maximumOutputBytes: Int = 64 * 1024
  ) -> Result {
    guard timeout.isFinite, timeout > 0, maximumOutputBytes >= 0 else {
      return Result(status: -1, output: "Invalid process limits", timedOut: false)
    }
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    let descriptor = pipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      return Result(status: -1, output: "Cannot configure process output", timedOut: false)
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    let pid: pid_t
    do {
      pid = try spawn(
        path: path, arguments: arguments, output: pipe.fileHandleForWriting.fileDescriptor)
    } catch {
      return Result(status: -1, output: error.localizedDescription, timedOut: false)
    }
    let exited = DispatchSemaphore(value: 0)
    let allowReaping = DispatchSemaphore(value: 0)
    // 必须由本执行器独占回收权：WNOWAIT 只观察退出，僵尸仍占有 PID。
    // 最后一次信号发送结束后才允许 waitpid 回收，避免检查与 kill 之间 PID 被复用。
    DispatchQueue.global(qos: .utility).async {
      var info = siginfo_t()
      while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
      exited.signal()
      allowReaping.wait()
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
    // 极端情况下内核尚未完成退出，也不能让 Helper 的维护队列无限等待。
    // 回收线程会继续持有子进程；从此调用线程不得再向 pid 发送信号。
    defer { allowReaping.signal() }
    try? pipe.fileHandleForWriting.close()
    var output = Data()
    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
    var eof = false
    // poll 直接等到有输出、管道关闭或截止时间，不再以短超时空转。
    while !eof {
      let remaining = ContinuousClock.now.duration(to: deadline) / .milliseconds(1)
      guard remaining > 0 else { break }
      var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      let ready = poll(&event, 1, Int32(min(remaining.rounded(.up), Double(Int32.max))))
      if ready < 0 {
        // poll 自身失败时无法继续读取；按输出结束处理，避免立即重试形成忙等。
        if errno != EINTR { eof = true }
        continue
      }
      guard ready > 0 else { continue }
      let count = bytes.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count == 0 {
        eof = true
      } else if count > 0 {
        output.append(contentsOf: bytes.prefix(min(count, maximumOutputBytes - output.count)))
      } else if errno != EINTR && errno != EAGAIN {
        eof = true
      }
    }
    // 输出提前关闭时仍须等待退出，但只等到原截止时间。
    let remaining = max(0, ContinuousClock.now.duration(to: deadline) / .seconds(1))
    if eof, exited.wait(timeout: .now() + remaining) == .success {
      var info = siginfo_t()
      var result: Int32
      repeat {
        result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
      } while result == -1 && errno == EINTR
      return Result(
        status: result == 0 ? info.si_status : -1,
        output: String(decoding: output, as: UTF8.self), timedOut: false)
    }

    // PID 在 allowReaping 释放前不会复用；即使此刻刚退出，信号也只会命中原来的子进程。
    if exited.wait(timeout: .now()) == .timedOut {
      _ = kill(pid, SIGTERM)
      if exited.wait(timeout: .now() + 0.2) == .timedOut {
        _ = kill(pid, SIGKILL)
        _ = exited.wait(timeout: .now() + 0.2)
      }
    }
    return Result(status: -1, output: String(decoding: output, as: UTF8.self), timedOut: true)
  }

  /// 直接启动目标程序，不经 shell；只向子进程传递标准输入输出。
  private static func spawn(path: String, arguments: [String], output: Int32) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var error = posix_spawn_file_actions_init(&actions)
    guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    error = posix_spawnattr_init(&attributes)
    guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL) }
    defer { posix_spawnattr_destroy(&attributes) }
    var signals = sigset_t()
    sigemptyset(&signals)
    error = posix_spawnattr_setsigmask(&attributes, &signals)
    if error == 0 {
      sigfillset(&signals)
      error = posix_spawnattr_setsigdefault(&attributes, &signals)
    }
    if error == 0 {
      error = posix_spawnattr_setflags(
        &attributes,
        Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
    }
    if error == 0 {
      error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    }
    if error == 0 { error = posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) }
    if error == 0 { error = posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO) }
    guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL) }
    let argv = ([path] + arguments).map { strdup($0) }
    let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
    defer {
      for value in argv + environment { free(value) }
    }
    guard (argv + environment).allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
    var pid: pid_t = 0
    error = (argv + [nil]).withUnsafeBufferPointer { args in
      (environment + [nil]).withUnsafeBufferPointer { env in
        posix_spawn(&pid, path, &actions, &attributes, args.baseAddress!, env.baseAddress!)
      }
    }
    guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL) }
    return pid
  }
}
