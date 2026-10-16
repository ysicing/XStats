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
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
    do { try process.run() } catch {
      return Result(status: -1, output: error.localizedDescription, timedOut: false)
    }
    try? pipe.fileHandleForWriting.close()
    var output = Data()
    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
    var eof = false
    while ContinuousClock.now < deadline {
      if !eof {
        var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = poll(&event, 1, 20)
        if ready > 0 {
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
      } else if process.isRunning {
        // 输出提前关闭时仍须等待退出，但不能忙等占满 Helper 的工作线程。
        Thread.sleep(forTimeInterval: 0.02)
      }
      if eof && !process.isRunning {
        return Result(
          status: process.terminationStatus, output: String(decoding: output, as: UTF8.self),
          timedOut: false)
      }
    }

    // 只终止本次启动的进程。SIGTERM 无效时升级为 SIGKILL，绝不再次无界 waitUntilExit。
    if process.isRunning {
      process.terminate()
      let grace = ContinuousClock.now.advanced(by: .milliseconds(200))
      while process.isRunning && ContinuousClock.now < grace {
        Thread.sleep(forTimeInterval: 0.01)
      }
      if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
    return Result(status: -1, output: String(decoding: output, as: UTF8.self), timedOut: true)
  }
}
