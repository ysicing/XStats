// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import XStatsUI

struct DiagnosticsLogTailTests {
  @Test func recentLinesAreLimitedAndUnicodeRemainsIntact() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let lines = (0..<600).map { "记录🙂\($0)" }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: false, encoding: .utf8)
    #expect(
      try DiagnosticsExporter.cleanupLogTail(at: url) == lines.suffix(500).joined(separator: "\n"))
    let tail = try DiagnosticsExporter.cleanupLogTail(at: url, maximumBytes: 43)
    #expect(!tail.contains("�"))
    #expect(tail.hasSuffix(lines.last!))
    #expect(tail.utf8.count <= 43)
  }

  @Test func sparseLargeFileAndOversizedLineHaveBoundedTails() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    try Data().write(to: url)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seek(toOffset: 128 * 1024 * 1024)
    try handle.write(contentsOf: Data("长行🙂".utf8))
    #expect(try DiagnosticsExporter.cleanupLogTail(at: url) == "")
    try handle.write(contentsOf: Data("\n最近记录🙂\n".utf8))
    #expect(try DiagnosticsExporter.cleanupLogTail(at: url) == "最近记录🙂")
  }
}
