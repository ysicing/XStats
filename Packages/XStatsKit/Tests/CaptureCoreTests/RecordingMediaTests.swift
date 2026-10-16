// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
import AVFoundation
@testable import CaptureCore

@Suite struct RecordingMediaTests {
  @Test @MainActor func temporaryMediaStaysOnFailedExportAndDiscardsExplicitly() async throws {
    let media = try RecordingMedia()
    let segment = media.newSegmentURL()
    try Data("invalid media".utf8).write(to: segment)
    #expect(FileManager.default.fileExists(atPath: segment.path))
    let exporter = RecordingExporter()
    await #expect(throws: (any Error).self) {
      try await exporter.export(
        segments: [segment], trim: nil, to: media.directory.appendingPathExtension("mp4"))
    }
    #expect(FileManager.default.fileExists(atPath: segment.path))
    try await media.discard()
    #expect(!FileManager.default.fileExists(atPath: media.directory.path))
  }
  @Test func sourceTimestampIsSharedAcrossAudioAndVideo() {
    #expect(RecordingSampleTime.relative(sample: 103, origin: 100) == 3)
    #expect(RecordingSampleTime.relative(sample: 100.25, origin: 100) == 0.25)
    #expect(RecordingSampleTime.relative(sample: 99, origin: 100) == nil)
    #expect(RecordingSampleTime.relative(sample: .nan, origin: 100) == nil)
  }
  @Test func exportRejectsTemporaryFolderAndSymlinkAliases() async throws {
    let media = try RecordingMedia()
    defer { try? FileManager.default.removeItem(at: media.directory) }
    let child = media.directory.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let alias = media.directory.appendingPathExtension("alias")
    defer { try? FileManager.default.removeItem(at: alias) }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: media.directory)
    for directory in [media.directory, child, alias, alias.appendingPathComponent("nested")] {
      #expect(throws: CaptureError.invalidExportDestination) {
        try RecordingMedia.validateExportDestination(
          directory.appendingPathComponent("result.mp4"), outside: media.directory)
      }
    }
    try RecordingMedia.validateExportDestination(
      media.directory.appendingPathExtension("mp4"), outside: media.directory)
    try await media.discard()
    try await media.discard()
  }
}
