// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import Foundation
import Testing
@testable import XStatsUI

struct RestCustomAudioTests {
    private func audioFile(in root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("gentle.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        buffer.frameLength = 4410
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<4410 { samples[0][index] = Float(sin(Double(index) * 0.02)) * 0.05 }
        try file.write(from: buffer)
        return url
    }

    @Test func importedAudioSurvivesOriginalRemovalAndReplacementIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audioFile(in: root.appendingPathComponent("source"))
        let store = RestCustomAudioStore(directory: root.appendingPathComponent("imported"))
        let first = try await store.importAudio(from: source)
        let firstURL = try #require(first.url(in: root.appendingPathComponent("imported")))
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: firstURL.path))
        let nextSource = try audioFile(in: root.appendingPathComponent("next"))
        let replacement = try await store.importAudio(from: nextSource)
        try await store.remove(first)
        #expect(replacement != first && !FileManager.default.fileExists(atPath: firstURL.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("imported").path).count == 1)
    }

    @Test func invalidOversizedAndCancelledImportsPreserveExistingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audioFile(in: root)
        let directory = root.appendingPathComponent("imported")
        let store = RestCustomAudioStore(directory: directory)
        let original = try await store.importAudio(from: source)
        let invalid = root.appendingPathComponent("invalid.wav")
        try Data("invalid".utf8).write(to: invalid)
        await #expect(throws: RestCustomAudioStore.Failure.unreadable) { try await store.importAudio(from: invalid) }
        let oversized = root.appendingPathComponent("large.wav")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(RestCustomAudioStore.maximumBytes + 1)); try handle.close()
        await #expect(throws: RestCustomAudioStore.Failure.tooLarge) { try await store.importAudio(from: oversized) }
        let task = Task { try await store.importAudio(from: source) }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled import unexpectedly succeeded") }
        catch is CancellationError {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [original.filename])
        #expect(RestCustomAudio(filename: "../escape.wav", displayName: "escape").url(in: directory) == nil)
    }

    @MainActor @Test func customPlaybackOwnershipMissingFileAndBackupAreHandled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audioFile(in: root)
        weak var previous: AVAudioPlayer?
        let player = RestSoundPlayer(startEngine: { _ in }, startCustomPlayer: { audio in
            #expect(previous == nil)
            previous = audio
            return audio.prepareToPlay() // 不向扬声器输出声音。
        })
        player.play(.custom, customURL: source)
        #expect(player.playing == .custom && previous?.numberOfLoops == -1)
        player.play(.wind)
        #expect(player.playing == .wind && previous == nil)
        player.play(.custom, customURL: root.appendingPathComponent("missing.wav"))
        #expect(player.playing == .off)
        player.stop()
        let suite = "RestCustomAudioTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.restCustomAudio = RestCustomAudio(filename: UUID().uuidString + ".wav", displayName: "gentle.wav")
        settings.restSound = .custom
        #expect(AppSettings(defaults: defaults).restCustomAudio == settings.restCustomAudio)
        let exported = try JSONEncoder().encode(settings.exportDocument())
        #expect(settings.exportDocument().restSound == RestSound.off.rawValue)
        #expect(!String(decoding: exported, as: UTF8.self).contains("gentle.wav"))
    }

    @MainActor @Test func customAudioRestartsAfterOutputDeviceChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try audioFile(in: root)
        var starts = 0
        let player = RestSoundPlayer(startEngine: { _ in }, startCustomPlayer: { _ in
            starts += 1
            return true
        })
        player.play(.custom, customURL: source)
        #expect(starts == 1 && player.playing == .custom)
        player.handleConfigurationChange()
        #expect(starts == 2 && player.playing == .custom)
        player.play(.custom, customURL: source)
        #expect(starts == 2)
        player.stop()
        #expect(player.playing == .off)
    }
}
