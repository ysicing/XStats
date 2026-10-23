// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Testing
@testable import Cleaner

struct InspectionToolOutputTests {
  @Test(arguments: ["route", "scutil"])
  func systemToolResolutionIncludesSbinDirectories(_ name: String) throws {
    let home = try fixture("exit 0")
    defer { try? FileManager.default.removeItem(at: home) }
    // 只解析系统文件的位置，绝不运行 route 或 scutil。
    let executable = try #require(DeveloperToolRunner.executable(named: name, home: home.path))
    #expect(executable.path == (name == "route" ? "/sbin/route" : "/usr/sbin/scutil"))
  }

  @Test(arguments: ["route", "scutil"])
  func fixtureToolsStillTakePrecedenceOverSystemDirectories(_ name: String) throws {
    let home = try fixture("exit 0", name: name)
    defer { try? FileManager.default.removeItem(at: home) }
    let executable = try #require(DeveloperToolRunner.executable(named: name, home: home.path))
    #expect(executable.path == home.appendingPathComponent(".local/bin/" + name).path)
  }

  @Test(arguments: ["", "12345678", "ab\u{00E9}cd"])
  func strictCaptureAcceptsExactlyTheByteLimit(_ payload: String) async throws {
    let home = try fixture("printf '%s' '\(payload)'\n")
    defer { try? FileManager.default.removeItem(at: home) }
    let result = try await DeveloperToolRunner.run(
      tool, arguments: [], home: home.path, timeout: 30,
      outputLimit: payload.utf8.count, requiresCompleteOutput: true)
    #expect(result.status == 0)
    #expect(result.output == payload)
  }

  @Test(arguments: [0, 8, 65_536])
  func strictCaptureRejectsOverflowEvenIfTheToolExitsSuccessfully(_ limit: Int) async throws {
    let payload = String(repeating: "x", count: limit + 1)
    let home = try fixture("printf '%s' '\(payload)'\nexit 0\n")
    defer { try? FileManager.default.removeItem(at: home) }
    do {
      _ = try await DeveloperToolRunner.run(
        tool, arguments: [], home: home.path, timeout: 30,
        outputLimit: limit, requiresCompleteOutput: true)
      Issue.record("Strict capture accepted truncated output")
    } catch ToolExecutionError.outputTooLarge(let name) {
      #expect(name == tool)
    }
  }

  @Test func strictCaptureLimitsBytesRatherThanCharacters() async throws {
    let home = try fixture("printf '%s' 'ab\u{00E9}cd'\n")
    defer { try? FileManager.default.removeItem(at: home) }
    do {
      _ = try await DeveloperToolRunner.run(
        tool, arguments: [], home: home.path, timeout: 30,
        outputLimit: 5, requiresCompleteOutput: true)
      Issue.record("Strict capture counted characters instead of bytes")
    } catch ToolExecutionError.outputTooLarge(let name) {
      #expect(name == tool)
    }
  }

  @Test func inspectionEnvironmentKeepsACompleteFixturePlistLargerThanEightKiB() async throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: [
        "images": [
          ["image-path": "/fixture/disk.dmg", "fixture": String(repeating: "x", count: 16_384)]
        ]
      ], format: .xml, options: 0)
    let plist = String(decoding: data, as: UTF8.self)
    let home = try fixture("printf '%s' '\(plist)'\n", name: "hdiutil")
    defer { try? FileManager.default.removeItem(at: home) }
    let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] })
    let result = try await environment.inspectTool("hdiutil", ["info", "-plist"])
    #expect(result.output.utf8.count > 8192)
    let parsed =
      try PropertyListSerialization.propertyList(
        from: Data(result.output.utf8), format: nil) as? [String: Any]
    let images = try #require(parsed?["images"] as? [[String: String]])
    #expect(images.count == 1)
    #expect(images.first?["image-path"] == "/fixture/disk.dmg")
    #expect(images.first?["fixture"]?.utf8.count == 16_384)
  }

  @Test(.timeLimit(.minutes(1)))
  func overflowStopsTheOwnedProcessWithoutWaitingForItsTimeout() async throws {
    let home = try fixture(
      """
      trap '' TERM
      printf '%s\\n' "$$" > "$HOME/pid"
      while [ ! -f "$HOME/release" ]; do /bin/sleep 0.01; done
      printf '123456789'
      exec /bin/sleep 30
      """)
    defer { try? FileManager.default.removeItem(at: home) }
    let task = Task {
      try await DeveloperToolRunner.run(
        tool, arguments: [], home: home.path, timeout: 30,
        outputLimit: 8, requiresCompleteOutput: true)
    }
    do {
      let pid = try await startedPID(home)
      let started = ContinuousClock.now
      try Data().write(to: home.appendingPathComponent("release"))
      do {
        _ = try await task.value
        Issue.record("Overflowing inspection returned success")
      } catch ToolExecutionError.outputTooLarge(let name) {
        #expect(name == tool)
      }
      #expect(ContinuousClock.now - started < .seconds(5))
      #expect(kill(pid, 0) != 0 && errno == ESRCH)
    } catch {
      task.cancel()
      _ = await task.result
      throw error
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func cancellingStrictCaptureStopsItsOwnedProcess() async throws {
    let home = try fixture(
      """
      printf '%s\\n' "$$" > "$HOME/pid"
      exec /bin/sleep 30
      """)
    defer { try? FileManager.default.removeItem(at: home) }
    let task = Task {
      try await DeveloperToolRunner.run(
        tool, arguments: [], home: home.path, timeout: 30,
        outputLimit: 8192, requiresCompleteOutput: true)
    }
    do {
      let pid = try await startedPID(home)
      let started = ContinuousClock.now
      task.cancel()
      do {
        _ = try await task.value
        Issue.record("Cancelled inspection returned success")
      } catch is CancellationError {
      }
      #expect(ContinuousClock.now - started < .seconds(5))
      #expect(kill(pid, 0) != 0 && errno == ESRCH)
    } catch {
      task.cancel()
      _ = await task.result
      throw error
    }
  }

  @Test(arguments: [Int32(0), Int32(23)])
  func defaultTailCaptureLetsTheFakeMutationFinish(_ status: Int32) async throws {
    let home = try fixture(
      """
      if [ -f /dev/fd/1 ]; then exit 91; fi
      i=0
      while [ "$i" -lt 1000 ]; do
        printf '0123456789'
        i=$((i + 1))
      done
      printf 'TAIL-END'
      : > "$HOME/completed"
      exit \(status)
      """)
    defer { try? FileManager.default.removeItem(at: home) }
    do {
      let result = try await DeveloperToolRunner.run(
        tool, arguments: [], home: home.path, timeout: 30, outputLimit: 8)
      #expect(status == 0)
      #expect(result.status == 0)
      #expect(result.output == "TAIL-END")
      #expect(result.output.utf8.count == 8)
    } catch ToolExecutionError.failed(let name, let actualStatus, let output) {
      #expect(name == tool)
      #expect(status == 23)
      #expect(actualStatus == status)
      #expect(output == "TAIL-END")
    }
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("completed").path))
  }

  @Test(arguments: [["cleanup"], ["upgrade"], ["uninstall"], ["services", "restart", "fixture"]])
  func strictOptionDoesNotChangeHomebrewMutationBranches(_ arguments: [String]) async throws {
    let home = try fixture(
      """
      printf 'Warning: fixture output exceeds the inspection limit\\n'
      : > "$HOME/completed"
      """, name: "brew")
    defer { try? FileManager.default.removeItem(at: home) }
    let result = try await DeveloperToolRunner.run(
      "brew", arguments: arguments, home: home.path, timeout: 30,
      outputLimit: 1, requiresCompleteOutput: true)
    #expect(result.status == 0)
    #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("completed").path))
  }

  private var tool: String { "xstats-inspection-fixture" }

  private func fixture(_ body: String, name: String = "xstats-inspection-fixture") throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "xstats-inspection-test-\(UUID())")
    let executable = home.appendingPathComponent(".local/bin/" + name)
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ("#!/bin/sh\n" + body + "\n").write(
      to: executable, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return home
  }

  private func startedPID(_ home: URL) async throws -> Int32 {
    let file = home.appendingPathComponent("pid")
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n"),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
      {
        return pid
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CocoaError(.fileReadNoSuchFile)
  }
}
