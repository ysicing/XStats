// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
@preconcurrency import AVFoundation

public struct RecordingMedia: Sendable {
    public let directory: URL
    public init() throws {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("XStatsCapture/Recordings", isDirectory: true)
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    public func newSegmentURL() -> URL { directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov") }
    public func discard() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
}

public enum RecordingSampleTime {
    public static func relative(sample: Double, origin: Double) -> Double? {
        guard sample.isFinite, origin.isFinite, sample >= origin else { return nil }
        return sample - origin
    }
}

/// Main-actor ownership prevents two exports sharing a session. AVFoundation performs media work off the UI thread.
@MainActor public final class RecordingExporter {
    private var session: AVAssetExportSession?
    private var exporting = false
    public init() {}
    public func composition(segments: [URL]) async throws -> AVMutableComposition {
        try await buildComposition(segments: segments).composition
    }
    private struct ComposedMedia {
        var composition: AVMutableComposition
        var audio: [AVMutableCompositionTrack]
    }
    private func buildComposition(segments: [URL]) async throws -> ComposedMedia {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CaptureError.exportFailed }
        var audio: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero
        for url in segments {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw CaptureError.exportFailed }
            let range = try await source.load(.timeRange)
            guard range.duration.seconds.isFinite, range.duration.seconds > 0 else { continue }
            try video.insertTimeRange(range, of: source, at: cursor)
            let sources = try await asset.loadTracks(withMediaType: .audio)
            for (index, track) in sources.enumerated() {
                if audio.count <= index {
                    guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CaptureError.exportFailed }
                    audio.append(destination)
                }
                let available = try await track.load(.timeRange).intersection(range)
                if available.duration > .zero { try audio[index].insertTimeRange(available, of: track, at: cursor + (available.start - range.start)) }
            }
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw CaptureError.exportFailed }
        return ComposedMedia(composition: composition, audio: audio)
    }
    public func export(segments: [URL], trim: RecordingTrim?, to destination: URL) async throws {
        guard !exporting else { throw CaptureError.invalidTransition }
        exporting = true
        defer { exporting = false }
        let composed = try await buildComposition(segments: segments)
        let composition = composed.composition
        let tracks = composed.audio
        try Task.checkCancellation()
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw CaptureError.exportFailed }
        session = exporter
        // Export beside the destination and move only on success. Never damage an existing destination on failure.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { session = nil; try? FileManager.default.removeItem(at: staging) }
        exporter.outputURL = staging; exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        if let trim {
            exporter.timeRange = CMTimeRange(start: CMTime(seconds: trim.start, preferredTimescale: 600), duration: CMTime(seconds: trim.duration, preferredTimescale: 600))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = tracks.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(tracks.count > 1 ? 0.5 : 1, at: .zero)
            return parameters
        }
        exporter.audioMix = mix
        let cancellation = ExportCancellation(session: exporter)
        await withTaskCancellationHandler { @MainActor in
            await withCheckedContinuation { continuation in
                exporter.exportAsynchronously { continuation.resume() }
            }
        } onCancel: { cancellation.cancel() }
        try Task.checkCancellation()
        guard exporter.status == .completed else { throw CaptureError.exportFailed }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
    }
    public func cancel() { session?.cancelExport() }
}

/// AVAssetExportSession explicitly supports cancelling while export runs.
private final class ExportCancellation: @unchecked Sendable {
    let session: AVAssetExportSession
    init(session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}
