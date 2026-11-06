// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import XStatsUI

@MainActor
struct ApplicationInstanceTests {
  @Test func onlyOneInstanceOwnsTheLockAndExitAllowsRestart() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("instance.lock")
    var first: ApplicationInstance? = try ApplicationInstance(lockURL: url)
    #expect(first?.isPrimary == true)
    let second = try ApplicationInstance(lockURL: url)
    #expect(!second.isPrimary)
    first = nil
    #expect(FileManager.default.fileExists(atPath: url.path))
    let restarted = try ApplicationInstance(lockURL: url)
    #expect(restarted.isPrimary)
    let duplicate = try ApplicationInstance(lockURL: url)
    #expect(!duplicate.isPrimary)
  }

  @Test func symbolicLinkCannotReplaceTheLockFile() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let target = folder.appendingPathComponent("target")
    try Data().write(to: target)
    let url = folder.appendingPathComponent("instance.lock")
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    #expect(throws: (any Error).self) { try ApplicationInstance(lockURL: url) }
  }

  @Test func initializationQueuesAtMostSixteenRequestsInOrder() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let instance = try ApplicationInstance(lockURL: folder.appendingPathComponent("instance.lock"))
    for index in 0..<20 {
      instance.receive(
        Notification(
          name: .init("relaunch"),
          userInfo: [
            "arguments": ["XStats", "--show-panel", "\(index)"],
            "urls": ["xstats://open/ai-usage"], "reopen": false,
          ]))
    }
    var received: [ApplicationInstance.Request] = []
    instance.handleRequests { received.append($0) }
    #expect(received.map { $0.arguments.last } == (0..<16).map { "\($0)" })
    #expect(received.allSatisfy { $0.urls.first?.absoluteString == "xstats://open/ai-usage" })
    #expect(received.allSatisfy { !$0.reopen })
    instance.handleRequests { _ in Issue.record("Queued requests must only be handled once") }
  }

  @Test func invalidOrOversizedRequestsAreIgnored() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let instance = try ApplicationInstance(lockURL: folder.appendingPathComponent("instance.lock"))
    instance.handleRequests { _ in Issue.record("Invalid launch request was accepted") }
    for payload: [AnyHashable: Any] in [
      [:],
      ["arguments": Array(repeating: "XStats", count: 65), "urls": [String](), "reopen": true],
      ["arguments": [String(repeating: "a", count: 16_385)], "urls": [String](), "reopen": true],
      [
        "arguments": [String](), "urls": Array(repeating: "xstats://open", count: 17),
        "reopen": true,
      ],
      ["arguments": [String](), "urls": [String(repeating: "a", count: 2049)], "reopen": true],
    ] {
      instance.receive(Notification(name: .init("relaunch"), userInfo: payload))
    }
  }

  @Test func duplicateForwardsArgumentsAndURLsToTheOwner() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("instance.lock")
    let instance = try ApplicationInstance(lockURL: url)
    let duplicate = try ApplicationInstance(lockURL: url)
    var received: ApplicationInstance.Request?
    instance.handleRequests { received = $0 }
    duplicate.forward(
      .init(
        arguments: ["XStats", "--show-calendar"],
        urls: [try #require(URL(string: "xstats://open/ai-usage"))], reopen: false))
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while received == nil && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let request = try #require(received)
    #expect(request.arguments == ["XStats", "--show-calendar"])
    #expect(request.urls.first?.absoluteString == "xstats://open/ai-usage")
    #expect(!request.reopen)
  }
}
