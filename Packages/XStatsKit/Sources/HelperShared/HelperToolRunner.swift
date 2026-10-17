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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    let descriptor = pipe.fileHandleForReading.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      return Result(status: -1, output: "Cannot configure process output", timedOut: false)
    }
    // 退出由 terminationHandler 通知，等待期间不按固定间隔唤醒；purge、tmutil 可能静默运行数十秒。
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    do { try process.run() } catch {
      return Result(status: -1, output: error.localizedDescription, timedOut: false)
    }
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
      return Result(
        status: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
        timedOut: false)
    }

    // 只终止本次启动的进程。SIGTERM 无效时升级为 SIGKILL，绝不再次无界 waitUntilExit。
    if process.isRunning {
      process.terminate()
      // 通知可能晚于实际退出；升级信号前重新确认，避免向已退出进程的旧 PID 发信号。
      if exited.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
        _ = kill(process.processIdentifier, SIGKILL)
      }
    }
    return Result(status: -1, output: String(decoding: output, as: UTF8.self), timedOut: true)
  }
}
