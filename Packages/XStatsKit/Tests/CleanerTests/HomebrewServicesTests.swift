// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
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
}
