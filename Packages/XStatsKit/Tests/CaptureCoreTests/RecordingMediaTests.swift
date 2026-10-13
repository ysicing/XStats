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
            try await exporter.export(segments: [segment], trim: nil, to: media.directory.appendingPathComponent("result.mp4"))
        }
        #expect(FileManager.default.fileExists(atPath: segment.path))
        try media.discard()
        #expect(!FileManager.default.fileExists(atPath: media.directory.path))
    }
    @Test func sourceTimestampIsSharedAcrossAudioAndVideo() {
        #expect(RecordingSampleTime.relative(sample: 103, origin: 100) == 3)
        #expect(RecordingSampleTime.relative(sample: 100.25, origin: 100) == 0.25)
        #expect(RecordingSampleTime.relative(sample: 99, origin: 100) == nil)
        #expect(RecordingSampleTime.relative(sample: .nan, origin: 100) == nil)
    }
}
