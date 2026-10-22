// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Darwin
import Testing
@testable import Cleaner

struct HomebrewServicesTests {
  @Test func nativeListPreservesStatusesAndDoesNotInventRunningServices() throws {
    let services = try HomebrewServices.parse(
      """
      [
        {"name":"redis","status":"started","user":"alice","file":"/Users/alice/Library/LaunchAgents/homebrew.mxcl.redis.plist","exit_code":0},
        {"name":"postgresql@17","status":"none","user":null,"file":null,"exit_code":null},
        {"name":"nginx","status":"error","user":"root","file":"/Library/LaunchDaemons/homebrew.mxcl.nginx.plist","exit_code":256},
        {"name":"timer","status":"scheduled","user":"alice"}
      ]
      """)
    #expect(services.map(\.name) == ["nginx", "postgresql@17", "redis", "timer"])
    #expect(services.first?.exitCode == 256)
    #expect(services[1].status == "none" && services[1].user == nil)
    #expect(services[2].canManage(currentUser: "alice"))
    #expect(!services[2].canManage(currentUser: "bob"))
    #expect(!services[0].canManage(currentUser: "alice"))
    #expect(try HomebrewServices.parse("[]").isEmpty)
  }

  @Test(arguments: [
    "", "warning: failed", "{}", "[{}]",
    #"[{"name":"--all","status":"none"}]"#,
    #"[{"name":"../redis","status":"none"}]"#,
    #"[{"name":"redis; touch /tmp/unsafe","status":"none"}]"#,
    #"[{"name":"redis","status":"none"},{"name":"redis","status":"started"}]"#,
    #"[{"name":"redis","status":null}]"#,
  ])
  func invalidInventoryCannotBecomeAnEmptySuccessOrActionTarget(_ output: String) {
    #expect(throws: HomebrewServices.ServiceError.self) { try HomebrewServices.parse(output) }
  }

  @Test func actionsRecheckCurrentOwnershipAndNeverEscalate() throws {
    let service = try #require(
      HomebrewServices.parse(
        #"[{"name":"team/tap/redis@7","status":"none"}]"#
      ).first)
    for action in HomebrewServices.Action.allCases {
      #expect(
        try HomebrewServices.arguments(
          for: action, service: service, current: [service], currentUser: "alice")
          == ["services", action.rawValue, "team/tap/redis@7"])
    }
    #expect(throws: HomebrewServices.ServiceError.self) {
      try HomebrewServices.arguments(
        for: .start, service: service, current: [], currentUser: "alice")
    }
    for output in [
      #"[{"name":"team/tap/redis@7","status":"started","user":"root"}]"#,
      #"[{"name":"team/tap/redis@7","status":"started","user":"alice","file":"/Library/LaunchDaemons/redis.plist"}]"#,
      #"[{"name":"team/tap/redis@7","status":"started","user":"bob"}]"#,
    ] {
      let fresh = try HomebrewServices.parse(output)
      #expect(throws: HomebrewServices.ServiceError.self) {
        try HomebrewServices.arguments(
          for: .stop, service: service, current: fresh, currentUser: "alice")
      }
    }
  }

  @Test(arguments: HomebrewServices.Action.allCases)
  func preflightTimeoutStopsReadingWithoutStartingAMutation(
    _ action: HomebrewServices.Action
  ) async throws {
    let home = try stubBrew(
      """
      #!/bin/sh
      if [ "$1" = services ] && [ "$2" = list ]; then
        echo $$ > "$HOME/pid"
        exec /bin/sleep 30
      fi
      echo "$@" > "$HOME/mutation"
      """)
    defer { try? FileManager.default.removeItem(at: home) }
    let service = try #require(HomebrewServices.parse(#"[{"name":"redis","status":"none"}]"#).first)
    do {
      try await HomebrewServices.perform(
        action, service: service,
        readInventory: {
          let result = try await DeveloperToolRunner.run(
            "brew", arguments: ["services", "list", "--json"], home: home.path,
            previewTimeout: 0.5, includesStandardError: false)
          return try HomebrewServices.parse(result.output)
        },
        runOperation: {
          _ = try await DeveloperToolRunner.run("brew", arguments: $0, home: home.path)
        })
      Issue.record("服务清单超时后不应继续执行")
    } catch HomebrewServices.ServiceError.preflightTimedOut {
      // 只有预读取超时才表示启停尚未开始。
    } catch {
      Issue.record("预读取超时未与写超时区分：\(error)")
    }
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("mutation").path))
    let pidText = try String(contentsOf: home.appendingPathComponent("pid"), encoding: .utf8)
    let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, 0) != 0)
  }

  @Test(arguments: HomebrewServices.Action.allCases)
  func writeTimeoutPreservesTheUnknownOutcome(_ action: HomebrewServices.Action) async throws {
    let home = try stubBrew(
      """
      #!/bin/sh
      echo "$@" > "$HOME/mutation"
      echo $$ > "$HOME/pid"
      exec /bin/sleep 30
      """)
    defer {
      if let text = try? String(contentsOf: home.appendingPathComponent("pid"), encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        kill(pid, SIGKILL)
      }
      try? FileManager.default.removeItem(at: home)
    }
    let services = try HomebrewServices.parse(#"[{"name":"redis","status":"none"}]"#)
    let service = try #require(services.first)
    do {
      try await HomebrewServices.perform(
        action, service: service, readInventory: { services },
        runOperation: {
          _ = try await DeveloperToolRunner.run(
            "brew", arguments: $0, home: home.path, timeout: 0.5)
        })
      Issue.record("应停止等待仍在运行的写操作")
    } catch ToolExecutionError.timedOut {
      // 保留执行器的写超时语义，不能转换成“操作尚未执行”。
    } catch {
      Issue.record("写超时被错误转换：\(error)")
    }
    let command = try String(contentsOf: home.appendingPathComponent("mutation"), encoding: .utf8)
    #expect(
      command.trimmingCharacters(in: .whitespacesAndNewlines) == "services \(action.rawValue) redis"
    )
    let pidText = try String(contentsOf: home.appendingPathComponent("pid"), encoding: .utf8)
    let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    #expect(kill(pid, 0) == 0)
  }

  @Test func preflightCancellationAndInvalidInventoryNeverStartAMutation() async throws {
    let service = try #require(HomebrewServices.parse(#"[{"name":"redis","status":"none"}]"#).first)
    await #expect(throws: CancellationError.self) {
      try await HomebrewServices.perform(
        .start, service: service, readInventory: { throw CancellationError() },
        runOperation: { _ in Issue.record("已取消的预检查不能启动写操作") })
    }
    do {
      try await HomebrewServices.perform(
        .start, service: service, readInventory: { try HomebrewServices.parse("invalid") },
        runOperation: { _ in Issue.record("无效清单不能启动写操作") })
      Issue.record("无效清单应报告错误")
    } catch HomebrewServices.ServiceError.invalidOutput {
    } catch {
      Issue.record("清单解析错误被错误转换：\(error)")
    }
  }

  private func stubBrew(_ script: String) throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "xstats-service-timeout-\(UUID())")
    let bin = home.appendingPathComponent(".local/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let brew = bin.appendingPathComponent("brew")
    try script.write(to: brew, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
    return home
  }
}
