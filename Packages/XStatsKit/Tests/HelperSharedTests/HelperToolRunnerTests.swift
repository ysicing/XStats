// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import HelperShared
import Testing

@Suite(.timeLimit(.minutes(1)))
struct HelperToolRunnerTests {
  @Test func capturesBothStreamsAndExitStatus() {
    let result = HelperToolRunner.run(
      path: "/bin/sh", arguments: ["-c", "printf out; printf err >&2; exit 7"])
    #expect(result.status == 7)
    #expect(result.output == "outerr")
    #expect(!result.timedOut)
  }

  @Test func drainsOutputBeyondRetentionLimit() {
    let result = HelperToolRunner.run(
      path: "/bin/sh", arguments: ["-c", "head -c 262144 /dev/zero"], maximumOutputBytes: 1024)
    #expect(result.status == 0 && !result.timedOut)
    #expect(result.output.utf8.count == 1024)
  }

  @Test func timesOutEvenWhenChildIgnoresTermination() {
    let start = ContinuousClock.now
    let result = HelperToolRunner.run(
      path: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
    #expect(result.timedOut && result.status != 0)
    #expect(start.duration(to: .now) < .seconds(3))
    // 同一执行线程能继续处理后续恢复命令。
    let recovery = HelperToolRunner.run(path: "/usr/bin/true", arguments: [])
    #expect(recovery.status == 0 && !recovery.timedOut)
  }

  @Test func boundsWaitForInheritedPipeAfterParentExit() {
    let start = ContinuousClock.now
    let result = HelperToolRunner.run(
      path: "/bin/sh", arguments: ["-c", "sleep 2 & exit 0"], timeout: 0.1)
    #expect(result.timedOut && result.status != 0)
    #expect(start.duration(to: .now) < .seconds(1.5))
  }

  @Test func timesOutAfterOutputClosesBeforeProcessExit() {
    let result = HelperToolRunner.run(
      path: "/bin/sh", arguments: ["-c", "exec 1>&- 2>&-; exec sleep 2"], timeout: 0.1)
    #expect(result.timedOut)
  }

  @Test func reportsLaunchFailureWithoutWaiting() {
    let result = HelperToolRunner.run(path: "/nonexistent/xstats-test-tool", arguments: [])
    #expect(result.status != 0 && !result.timedOut)
  }
}
