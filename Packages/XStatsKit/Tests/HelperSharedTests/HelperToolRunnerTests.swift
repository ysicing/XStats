// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import HelperShared
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HelperToolRunnerTests {
  @Test func capturesBothStreamsAndExitStatus() async {
    let result = await run(
      path: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 7"])
    #expect(result.status == 7)
    #expect(result.output == "outerr")
    #expect(!result.timedOut)
  }

  @Test func drainsOutputBeyondRetentionLimit() async {
    let result = await run(
      path: "/bin/sh", arguments: ["-c", "head -c 262144 /dev/zero"], maximumOutputBytes: 1024)
    #expect(result.status == 0 && !result.timedOut)
    #expect(result.output.utf8.count == 1024)
  }

  @Test func timesOutEvenWhenChildIgnoresTermination() async {
    let start = ContinuousClock.now
    let result = await run(
      path: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
    #expect(result.timedOut && result.status != 0)
    #expect(start.duration(to: .now) < .seconds(3))
    // 超时后仍能处理后续恢复命令。
    let recovery = await run(path: "/usr/bin/true", arguments: [])
    #expect(recovery.status == 0 && !recovery.timedOut)
  }

  @Test func boundsWaitForInheritedPipeAfterParentExit() async {
    let start = ContinuousClock.now
    let result = await run(
      path: "/bin/sh", arguments: ["-c", "sleep 2 & exit 0"], timeout: 0.1)
    #expect(result.timedOut && result.status != 0)
    #expect(start.duration(to: .now) < .seconds(1.5))
  }

  @Test func timesOutAfterOutputClosesBeforeProcessExit() async {
    let result = await run(
      path: "/bin/sh", arguments: ["-c", "exec 1>&- 2>&-; exec sleep 2"], timeout: 0.1)
    #expect(result.timedOut)
  }

  @Test func reportsLaunchFailureWithoutWaiting() async {
    let result = await run(path: "/nonexistent/xstats-test-tool", arguments: [])
    #expect(result.status != 0 && !result.timedOut)
  }

  /// 子进程已退出但管道仍被孙进程持有；超时升级信号前 PID 必须仍由本执行器占有。
  @Test func exitedChildRemainsUnreapedUntilSignallingIsFinished() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pidFile = directory.appendingPathComponent("pid")
    async let runner = run(
      path: "/bin/sh",
      arguments: ["-c", "echo $$ > \"$1\"; sleep 2 & exit 0", "fixture", pidFile.path],
      timeout: 1)
    // 用 WNOWAIT 观察而不争抢回收权，也不向任何 PID 发信号。
    var observedExit = false
    var observedPID: pid_t?
    var observationError: Int32 = 0
    let deadline = ContinuousClock.now + .milliseconds(800)
    while ContinuousClock.now < deadline {
      if let value = try? String(contentsOf: pidFile, encoding: .utf8),
        let pid = pid_t(value.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        observedPID = pid
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG)
        if result == -1 {
          observationError = errno
          break
        }
        if info.si_pid == pid {
          observedExit = true
          break
        }
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    if observedExit, let pid = observedPID {
      // 跨过最初的退出通知调度，确保不是偶然看到了尚未来得及被 Foundation 回收的瞬间。
      try await Task.sleep(for: .milliseconds(100))
      var info = siginfo_t()
      observedExit =
        waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) == 0
        && info.si_pid == pid
    }
    let result = await runner
    #expect(observedExit, "退出进程必须保留到发送信号结束，观察错误：\(observationError)")
    #expect(result.timedOut)
    let pid = try #require(observedPID)
    try await expectReaped(pid)
  }

  @Test func forcedTimeoutEventuallyReapsTheChild() async throws {
    let result = await run(
      path: "/bin/sh", arguments: ["-c", "trap '' TERM; echo $$; while :; do :; done"], timeout: 0.2
    )
    #expect(result.timedOut)
    let pid = try #require(pid_t(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    try await expectReaped(pid)
  }

  @Test func preservesLiteralArgumentsAndSignalStatus() async {
    let literal = "value with spaces; $(not-a-command)"
    let arguments = await run(path: "/usr/bin/printf", arguments: ["%s", literal])
    #expect(arguments.status == 0 && arguments.output == literal && !arguments.timedOut)
    let signalled = await run(path: "/bin/sh", arguments: ["-c", "kill -TERM $$"])
    #expect(signalled.status == SIGTERM && !signalled.timedOut)
  }

  @Test func doesNotInheritUnrelatedDescriptors() async throws {
    let descriptor = open("/dev/null", O_RDONLY)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    #expect(fcntl(descriptor, F_SETFD, 0) == 0)
    let result = await run(
      path: "/bin/sh", arguments: ["-c", "test ! -e /dev/fd/\(descriptor)"])
    #expect(result.status == 0 && !result.timedOut)
  }

  @Test func concurrentCommandsCompleteWithoutStarvingExitObservers() async {
    await withTaskGroup(of: HelperToolRunner.Result.self) { group in
      for _ in 0..<8 {
        group.addTask { await run(path: "/usr/bin/true", arguments: [], timeout: 2) }
      }
      for await result in group {
        #expect(result.status == 0 && !result.timedOut)
      }
    }
  }

  // 与生产 Helper 一样从 Dispatch 队列调用阻塞 API，让测试协作线程池能够继续调度。
  private func run(
    path: String, arguments: [String], timeout: TimeInterval = 30,
    maximumOutputBytes: Int = 64 * 1024
  ) async -> HelperToolRunner.Result {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(
          returning: HelperToolRunner.run(
            path: path, arguments: arguments, timeout: timeout,
            maximumOutputBytes: maximumOutputBytes))
      }
    }
  }

  private func expectReaped(_ pid: pid_t) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      var info = siginfo_t()
      if waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) == -1, errno == ECHILD {
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("子进程未被回收")
  }

}
