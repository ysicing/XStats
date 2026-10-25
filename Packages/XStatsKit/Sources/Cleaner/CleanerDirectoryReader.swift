// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

/// 目录打开可能阻塞在不可取消的系统调用中；按需子进程隔离读取，取消后先回收再退出扫描。
public enum CleanerDirectoryReader {
  private static let argument = "--cleaner-read-directory"

  /// 必须在应用初始化之前调用；此模式只输出 NUL 分隔的名称，不访问偏好或启动服务。
  public static func runIfRequested() {
    let arguments = CommandLine.arguments
    guard arguments.dropFirst().first == argument else { return }
    guard arguments.count == 3 else { exit(EINVAL) }
    guard let directory = arguments[2].withCString({ opendir($0) }) else { exit(errno) }
    defer { closedir(directory) }
    while true {
      errno = 0
      guard let entry = readdir(directory) else { exit(errno) }
      let length = Int(entry.pointee.d_namlen)
      let written = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: UInt8.self, capacity: length + 1) { bytes in
          var offset = 0
          while offset < length + 1 {
            let count = Darwin.write(STDOUT_FILENO, bytes + offset, length + 1 - offset)
            if count == -1 && errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
          }
          return true
        }
      }
      guard written else { exit(EIO) }
    }
  }

  static func children(of path: String, executable: URL, budget: ScanBudget) throws -> [URL] {
    try budget.check()
    var descriptors: [Int32] = [0, 0]
    guard pipe(&descriptors) == 0 else { throw posixError(errno) }
    defer {
      close(descriptors[0])
      if descriptors[1] >= 0 { close(descriptors[1]) }
    }
    for descriptor in descriptors {
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else { throw posixError(errno) }
    }
    guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) != -1 else { throw posixError(errno) }
    let pid = try spawn(executable: executable, path: path, output: descriptors[1])
    close(descriptors[1])
    descriptors[1] = -1
    // 在 waitpid 前始终持有 PID，避免进程退出后 PID 复用导致误杀。
    defer {
      kill(pid, SIGKILL)
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
    let root = URL(fileURLWithPath: path)
    var children: [URL] = []
    var pending: [UInt8] = []
    var bytes = [UInt8](repeating: 0, count: 16_384)
    let maximumNameBytes = MemoryLayout.size(ofValue: dirent().d_name) - 1
    while true {
      try budget.check()
      let count = bytes.withUnsafeMutableBytes {
        Darwin.read(descriptors[0], $0.baseAddress, $0.count)
      }
      if count > 0 {
        for byte in bytes.prefix(count) {
          if byte != 0 {
            // macOS 单个目录项名称有长度上限，异常协议不能无限累积内存。
            guard pending.count < maximumNameBytes else { throw posixError(EIO) }
            pending.append(byte)
            continue
          }
          let name = String(decoding: pending, as: UTF8.self)
          pending.removeAll(keepingCapacity: true)
          guard name != ".", name != ".." else { continue }
          guard !name.isEmpty, !name.contains("/") else { throw posixError(EIO) }
          try budget.visit()
          guard !name.hasPrefix(".") else { continue }
          let child = root.appendingPathComponent(name)
          try budget.visitCandidate(child.standardizedFileURL.path)
          children.append(child)
        }
        continue
      }
      if count == -1 {
        if errno == EINTR { continue }
        guard errno == EAGAIN else { throw posixError(errno) }
      }
      var info = siginfo_t()
      let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
      if result == -1 && errno != EINTR { throw posixError(errno) }
      if result == 0 && info.si_pid != 0 {
        guard info.si_code == CLD_EXITED, info.si_status == 0 else {
          throw posixError(info.si_code == CLD_EXITED ? info.si_status : EIO)
        }
        // 退出后仍先排空管道；不返回缺少结尾或失败进程的部分清单。
        if count == 0 {
          guard pending.isEmpty else { throw posixError(EIO) }
          try budget.check()
          return children
        }
        continue
      }
      if count == 0 {
        usleep(20_000)
        continue
      }
      var descriptor = pollfd(fd: descriptors[0], events: Int16(POLLIN), revents: 0)
      _ = poll(&descriptor, 1, 20)
    }
  }

  private static func spawn(executable: URL, path: String, output: Int32) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var error = posix_spawn_file_actions_init(&actions)
    guard error == 0 else { throw posixError(error) }
    defer { posix_spawn_file_actions_destroy(&actions) }
    error = posix_spawnattr_init(&attributes)
    guard error == 0 else { throw posixError(error) }
    defer { posix_spawnattr_destroy(&attributes) }
    error = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    if error == 0 {
      error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
    }
    if error == 0 {
      error = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    }
    if error == 0 { error = posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) }
    guard error == 0 else { throw posixError(error) }
    let argv = [executable.path, argument, path].map { strdup($0) }
    let env = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
    defer { for value in argv + env { free(value) } }
    guard (argv + env).allSatisfy({ $0 != nil }) else { throw posixError(ENOMEM) }
    var pid: pid_t = 0
    error = (argv + [nil]).withUnsafeBufferPointer { args in
      (env + [nil]).withUnsafeBufferPointer { values in
        posix_spawn(
          &pid, executable.path, &actions, &attributes, args.baseAddress!, values.baseAddress!)
      }
    }
    guard error == 0 else { throw posixError(error) }
    return pid
  }

  private static func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
  }
}
