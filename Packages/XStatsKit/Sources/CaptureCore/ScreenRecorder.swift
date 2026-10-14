// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import OSLog

/// AVCaptureSession's blocking lifecycle stays on a dedicated serial queue.
private final class MicrophoneCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "work.12306.xstats.capture.microphone")
    private let session = AVCaptureSession()
    private var observers: [NSObjectProtocol] = []
    func start(writer: RecordingWriter) async throws {
        let clock: CMClock = try await CaptureCallback<CMClock>().wait(onCancel: { self.requestStop() }) { completion in
            queue.async {
                guard !completion.isCancelled else { return }
                do {
                    self.session.beginConfiguration()
                    do {
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
                    }
                    guard !completion.isCancelled else { self.stopOnQueue(); return }
                    self.session.startRunning()
                    guard self.session.isRunning, let clock = self.session.synchronizationClock else { throw CaptureError.captureFailed }
                    // startRunning 无法强制打断。取消先释放等待者，迟到的启动在原队列停止。
                    if !completion.finish(.success(clock)) { self.stopOnQueue() }
                } catch {
                    self.stopOnQueue()
                    completion.finish(.failure(error))
                }
            }
        }
        try Task.checkCancellation()
        await writer.setMicrophoneClock(clock)
    }
    func requestStop() { queue.async { self.stopOnQueue() } }
    func stop() async throws {
        try await CaptureCallback<Void>().wait(onCancel: { self.requestStop() }) { completion in
            queue.async { self.stopOnQueue(); completion.finish(.success(())) }
        }
    }
    private func stopOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        for output in session.outputs { (output as? AVCaptureAudioDataOutput)?.setSampleBufferDelegate(nil, queue: nil) }
        if session.isRunning { session.stopRunning() }
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
        let granted = try await CaptureCallback<Bool>().wait { completion in
            AVCaptureDevice.requestAccess(for: .audio) { completion.finish(.success($0)) }
        }
        try Task.checkCancellation()
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
            try Task.checkCancellation()
            let configuration = source.configuration(recording: true, systemAudio: options.systemAudio)
            let stream = SCStream(filter: source.filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
            if options.systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
            self.stream = stream
            if options.microphone {
                let microphone = MicrophoneCapture(); self.microphone = microphone
                try await microphone.start(writer: writer)
            }
            try await CaptureCallback<Void>().wait(onCancel: { stream.stopCapture { _ in } }) { completion in
                stream.startCapture { error in
                    if let error { completion.finish(.failure(error)) }
                    else if !completion.finish(.success(())), completion.isCancelled { stream.stopCapture { _ in } }
                }
            }
            try Task.checkCancellation()
            Self.logger.notice("Recording producer started")
        } catch {
            // 启动失败不等待可能卡住的生产者；先解除写入，再异步停止系统资源。
            let stream = self.stream; let microphone = self.microphone
            self.stream = nil; self.writer = nil; self.microphone = nil; activeURL = nil
            stream?.stopCapture { _ in }; microphone?.requestStop()
            await writer.abort()
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
        if let stream {
            do {
                try await CaptureCallback<Void>().wait(onCancel: { stream.stopCapture { _ in } }) { completion in
                    stream.stopCapture { error in
                        if let error { completion.finish(.failure(error)) }
                        else { completion.finish(.success(())) }
                    }
                }
            } catch { captureError = error }
        }
        do { try await microphone?.stop() } catch { captureError = error }
        stream = nil; microphone = nil
        let writer = self.writer; self.writer = nil
        let url = activeURL; activeURL = nil
        if let writer {
            do {
                try Task.checkCancellation()
                if try await writer.finish(endTime: endTime), let url { segments.append(url) }
                else if let url { try? FileManager.default.removeItem(at: url) }
            } catch {
                if error is CancellationError {
                    await writer.abort()
                    if let url { try? FileManager.default.removeItem(at: url) }
                }
                captureError = error
            }
        }
        Self.logger.notice("Recording producer stopped")
        if let captureError { throw captureError }
    }
    public func stop() async throws {
        targetTimer?.invalidate(); targetTimer = nil
        defer { source = nil }
        if stream != nil { try await pause() }
    }
    /// 丢弃时无需产出可播放片段，也不等待系统设备的阻塞生命周期。
    public func discard() async throws {
        targetTimer?.invalidate(); targetTimer = nil
        let stream = stream; let microphone = microphone; let writer = writer
        self.stream = nil; self.microphone = nil; self.writer = nil; activeURL = nil; source = nil
        stream?.stopCapture { _ in }; microphone?.requestStop()
        await writer?.abort()
        try await media.discard()
    }
    nonisolated public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.onFailure(.unavailableTarget)
        }
    }
}
