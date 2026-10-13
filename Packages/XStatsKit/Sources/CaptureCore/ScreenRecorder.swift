// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit
import OSLog

/// AVCaptureSession's blocking lifecycle stays on a dedicated serial queue.
private final class MicrophoneCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "work.12306.xstats.capture.microphone")
    private let session = AVCaptureSession()
    private var observers: [NSObjectProtocol] = []
    func start(writer: RecordingWriter) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    guard let device = AVCaptureDevice.default(for: .audio) else { throw CaptureError.microphonePermission }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    guard self.session.canAddInput(input), self.session.canAddOutput(output) else { throw CaptureError.captureFailed }
                    self.session.addInput(input); self.session.addOutput(output)
                    for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                        let token = NotificationCenter.default.addObserver(forName: name, object: self.session, queue: nil) { _ in writer.reportAudioFailure() }
                        self.observers.append(token)
                    }
                    output.setSampleBufferDelegate(writer, queue: writer.queue)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
        let clock: CMClock = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.session.startRunning()
                guard self.session.isRunning, let clock = self.session.synchronizationClock else {
                    self.session.stopRunning()
                    continuation.resume(throwing: CaptureError.captureFailed)
                    return
                }
                continuation.resume(returning: clock)
            }
        }
        await writer.setMicrophoneClock(clock)
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                for token in self.observers { NotificationCenter.default.removeObserver(token) }; self.observers.removeAll()
                self.session.stopRunning()
                for output in self.session.outputs { (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil) }
                continuation.resume()
            }
        }
    }
}

@MainActor public final class ScreenRecorder: NSObject, SCStreamDelegate {
    public private(set) var segments: [URL] = []
    public let media: RecordingMedia
    public var onFailure: (CaptureError) -> Void = { _ in }
    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var microphone: MicrophoneCapture?
    private var activeURL: URL?
    private var source: ScreenCaptureSource?
    private var options = RecordingOptions()
    private var transitioning = false
    private var targetTimer: Timer?
    private static let logger = Logger(subsystem: CaptureRequest.bundleIdentifier, category: "recording")
    public init(media: RecordingMedia) { self.media = media; super.init() }
    public static func requestMicrophone() async throws {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else { throw CaptureError.microphonePermission }
    }
    public func start(source: ScreenCaptureSource, options: RecordingOptions) async throws {
        guard self.source == nil else { throw CaptureError.invalidTransition }
        self.source = source; self.options = options
        do {
            try await resume()
            if let windowID = source.windowID {
                // A narrow window-ID lookup runs only while this window recording exists.
                // ScreenCaptureKit can continue sending blank frames after a window closes.
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]]
                        if windows?.isEmpty != false { self?.onFailure(.unavailableTarget) }
                    }
                }
                timer.tolerance = 0.25
                targetTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } catch { self.source = nil; throw error }
    }
    public func resume() async throws {
        guard stream == nil, !transitioning, let source else { throw CaptureError.invalidTransition }
        transitioning = true
        defer { transitioning = false }
        let url = media.newSegmentURL()
        let writer = RecordingWriter { [weak self] error in Task { @MainActor in self?.onFailure(error) } }
        self.writer = writer; activeURL = url
        do {
            try await writer.prepare(url: url, size: CaptureGeometry.recordingSize(source.pixelSize), options: options)
            let configuration = source.configuration(recording: true, systemAudio: options.systemAudio)
            let stream = SCStream(filter: source.filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if options.systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
            self.stream = stream
            if options.microphone {
                let microphone = MicrophoneCapture(); self.microphone = microphone
                try await microphone.start(writer: writer)
            }
            try await stream.startCapture()
            Self.logger.notice("Recording producer started")
        } catch {
            try? await stream?.stopCapture(); await microphone?.stop()
            _ = try? await writer.finish()
            self.stream = nil; self.writer = nil; microphone = nil; activeURL = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
    public func pause() async throws {
        guard !transitioning, stream != nil else { throw CaptureError.invalidTransition }
        transitioning = true
        defer { transitioning = false }
        let endTime = CMClockGetTime(CMClockGetHostTimeClock())
        var captureError: (any Error)?
        do { try await stream?.stopCapture() } catch { captureError = error }
        await microphone?.stop()
        stream = nil; microphone = nil
        let writer = self.writer; self.writer = nil
        let url = activeURL; activeURL = nil
        if let writer {
            do {
                if try await writer.finish(endTime: endTime), let url { segments.append(url) }
                else if let url { try? FileManager.default.removeItem(at: url) }
            } catch { captureError = error }
        }
        Self.logger.notice("Recording producer stopped")
        if let captureError { throw captureError }
    }
    public func stop() async throws {
        targetTimer?.invalidate(); targetTimer = nil
        defer { source = nil }
        if stream != nil { try await pause() }
    }
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in self?.onFailure(.unavailableTarget) }
    }
}
