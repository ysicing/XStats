// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct ThumbnailCacheTests {
  @Test func resetsOnlyTheThumbnailCache() async throws {
    try await ThumbnailCache.reset { arguments in
      #expect(arguments == ["-r", "cache"])
      return ToolRunResult(status: 0, output: "")
    }
  }

  @Test func nonzeroExitIsNotReportedAsSuccess() async {
    do {
      try await ThumbnailCache.reset { _ in
        ToolRunResult(status: 7, output: "fixture failure")
      }
      Issue.record("A failed thumbnail reset was accepted")
    } catch ToolExecutionError.failed(let tool, let status, let output) {
      #expect(tool == "qlmanage" && status == 7 && output == "fixture failure")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test func cancellationAfterCommandExitDoesNotPublishSuccess() async {
    let task = Task {
      try await ThumbnailCache.reset { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return ToolRunResult(status: 0, output: "")
      }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  @Test func explicitExecutableBypassesToolLookup() async throws {
    // 不执行真实 qlmanage；证明系统维护入口可以固定绝对路径，不使用用户 PATH 中的同名工具。
    let result = try await DeveloperToolRunner.run(
      "qlmanage", arguments: ["fixture"], home: "/nonexistent",
      timeout: 1, executableURL: URL(fileURLWithPath: "/bin/echo"))
    #expect(result.status == 0 && result.output == "fixture")
  }

  @Test func explicitExecutableRetainsTimeout() async {
    do {
      _ = try await DeveloperToolRunner.run(
        "qlmanage", arguments: ["5"], home: "/nonexistent",
        timeout: 0.05, executableURL: URL(fileURLWithPath: "/bin/sleep"))
      Issue.record("The command exceeded its timeout")
    } catch ToolExecutionError.timedOut(let tool) {
      #expect(tool == "qlmanage")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
