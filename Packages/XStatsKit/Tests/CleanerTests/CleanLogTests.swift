// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import Cleaner

struct CleanLogTests {
  @Test func legacyLargeLogRetainsCompleteRecentRecordsAndBoundsNewEntries() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let row = Data("{\"detail\":\"清理记录🙂\"}\n".utf8)
    var original = Data()
    while original.count <= CleanLog.maximumBytes * 2 { original.append(row) }
    try original.write(to: url)
    let log = CleanLog(url: url)
    log.record(
      url: URL(fileURLWithPath: "/fixture"), ruleID: "fixture", bytes: 1,
      action: "remove", detail: "a" + String(repeating: "\u{0301}", count: 500_000))
    let result = try Data(contentsOf: url)
    #expect(result.count <= CleanLog.maximumBytes)
    let text = try #require(String(data: result, encoding: .utf8))
    let lines = text.split(separator: "\n")
    #expect(lines.count > 1)
    for line in lines {
      #expect(try JSONSerialization.jsonObject(with: Data(line.utf8)) is [String: Any])
    }
    let lastLine = try #require(lines.last)
    let last = try #require(
      JSONSerialization.jsonObject(with: Data(lastLine.utf8)) as? [String: Any])
    #expect(last["action"] as? String == "remove")
  }

  @Test func oversizedLegacyLineIsDiscardedWithoutReadingTheWholeFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data().write(to: url)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 128 * 1024 * 1024)
    try handle.close()
    CleanLog(url: url).record(
      url: URL(fileURLWithPath: "/fixture"), ruleID: "fixture", bytes: 0,
      action: "skip", detail: nil)
    let result = try Data(contentsOf: url)
    #expect(result.count < 1024)
    #expect(try JSONSerialization.jsonObject(with: result) is [String: Any])
  }
}
