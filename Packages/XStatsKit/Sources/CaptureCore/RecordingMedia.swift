// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Darwin
import OSLog
@preconcurrency import AVFoundation

public struct RecordingMedia: Sendable {
    public let directory: URL
    private let lease: RecordingSessionLease
    static var recordingsRoot: URL { CaptureCache.recordingsDirectory }
    public init() throws { try self.init(root: Self.recordingsRoot) }
    init(root: URL) throws {
        directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do { lease = try RecordingSessionLease(directory: directory) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    /// One utility sweep when Capture is opened; no idle timer or background polling.
    public static func cleanStaleSessions() async throws {
        try await cleanStaleSessions(root: recordingsRoot)
    }
    static func cleanStaleSessions(root: URL, now: Date = Date(), maximumAge: TimeInterval = 7 * 86400,
                                   maximumBytes: Int64 = 10 * 1024 * 1024 * 1024, maximumSessions: Int = 20) async throws {
        _ = try await CaptureCache.manage(root: root, now: now,
                                         policy: .retention(age: maximumAge, bytes: maximumBytes, sessions: maximumSessions))
    }
    public func newSegmentURL() -> URL { directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov") }
    public func discard() async throws {
        let directory = directory
        // 丢弃必须完成清理，即使调用任务因退出而已取消；递归 I/O 不在主线程执行。
        try await Task.detached(priority: .utility) {
            do { try FileManager.default.removeItem(at: directory) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }.value
    }
    static func validateExportDestination(_ destination: URL, outside directory: URL) throws {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        // 尚不存在的目标文件不会解析父目录中的符号链接，先解析已存在的祖先。
        var ancestor = destination.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var destination = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix.reversed() { destination.appendPathComponent(component) }
        let sensitive = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? true
        let root = directory.pathComponents, target = destination.pathComponents
        let options: String.CompareOptions = sensitive ? [] : [.caseInsensitive]
        let inside = target.count >= root.count && zip(root, target).allSatisfy { $0.compare($1, options: options) == .orderedSame }
        guard !inside else { throw CaptureError.invalidExportDestination }
    }
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
    private let commit: @Sendable (URL, URL) throws -> Void
    public init() { commit = Self.commitStagedFile }
    init(commit: @escaping @Sendable (URL, URL) throws -> Void) { self.commit = commit }
    private nonisolated static func commitStagedFile(_ staging: URL, _ destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
    }
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
        try await Task.detached(priority: .utility) {
            for directory in Set(segments.map { $0.deletingLastPathComponent() }) {
                try RecordingMedia.validateExportDestination(destination, outside: directory)
            }
        }.value
        try Task.checkCancellation()
        let composed = try await buildComposition(segments: segments)
        let composition = composed.composition
        let tracks = composed.audio
        try Task.checkCancellation()
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw CaptureError.exportFailed }
        session = exporter
        // Export beside the destination and move only on success. Never damage an existing destination on failure.
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        defer { session = nil }
        do {
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
            let commit = commit
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                try commit(staging, destination)
            }
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
        } catch {
            // Cleanup can block on the same volume; it must also stay off the main actor.
            await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: staging) }.value
            throw error
        }
    }
    public func cancel() { session?.cancelExport() }
}

/// AVAssetExportSession explicitly supports cancelling while export runs.
private final class ExportCancellation: @unchecked Sendable {
    let session: AVAssetExportSession
    init(session: AVAssetExportSession) { self.session = session }
    func cancel() { session.cancelExport() }
}

/// Kernel-backed leases also protect recordings owned by the other Capture host.
final class RecordingSessionLease: Sendable {
    private let descriptor: Int32
    init(directory: URL) throws {
        let descriptor = open(directory.appendingPathComponent(".session.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CaptureError.exportFailed }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw CaptureError.invalidTransition
        }
        self.descriptor = descriptor
    }
    deinit { close(descriptor) }
}
