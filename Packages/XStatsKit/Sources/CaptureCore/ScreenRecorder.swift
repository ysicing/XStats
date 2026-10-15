// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import OSLog

/// AVCaptureSession's blocking lifecycle stays on a dedicated serial queue.
final class MicrophoneCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "work.12306.xstats.capture.microphone")
    private let session = AVCaptureSession()
    private var observers: [NSObjectProtocol] = []
    private let device: @Sendable () -> AVCaptureDevice?
    init(device: @escaping @Sendable () -> AVCaptureDevice? = { AVCaptureDevice.default(for: .audio) }) {
        self.device = device
    }
    func start(writer: RecordingWriter) async throws {
        let clock: CMClock = try await CaptureCallback<CMClock>().wait(onCancel: { self.requestStop() }) { completion in
            queue.async {
                guard !completion.isCancelled else { return }
                do {
                    self.session.beginConfiguration()
                    do {
                        defer { self.session.commitConfiguration() }
                        guard let device = self.device() else { throw CaptureError.microphoneFailed }
                        let input = try AVCaptureDeviceInput(device: device)
                        let output = AVCaptureAudioDataOutput()
                        guard self.session.canAddInput(input), self.session.canAddOutput(output) else { throw CaptureError.microphoneFailed }
                        self.session.addInput(input); self.session.addOutput(output)
                        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                            let token = NotificationCenter.default.addObserver(forName: name, object: self.session, queue: nil) { notification in
                                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                                writer.reportAudioFailure(CaptureError.microphoneFailure(error))
                            }
                            self.observers.append(token)
                        }
                        output.setSampleBufferDelegate(writer, queue: writer.queue)
                    }
                    guard !completion.isCancelled else { self.stopOnQueue(); return }
                    self.session.startRunning()
                    guard self.session.isRunning, let clock = self.session.synchronizationClock else { throw CaptureError.microphoneFailed }
                    // startRunning 无法强制打断。取消先释放等待者，迟到的启动在原队列停止。
                    if !completion.finish(.success(clock)) { self.stopOnQueue() }
                } catch {
                    self.stopOnQueue()
                    completion.finish(.failure((error as? CaptureError) ?? CaptureError.microphoneFailure(error as NSError)))
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
    private var stopStream: @MainActor (SCStream) async throws -> Void = ScreenRecorder.stopStream
    private static let logger = Logger(subsystem: CaptureRequest.bundleIdentifier, category: "recording")
    public init(media: RecordingMedia) { self.media = media; super.init() }
    init(media: RecordingMedia, stream: SCStream, writer: RecordingWriter? = nil, activeURL: URL? = nil,
         stopStream: @escaping @MainActor (SCStream) async throws -> Void) {
        self.media = media; self.stream = stream; self.writer = writer; self.activeURL = activeURL
        self.stopStream = stopStream; super.init()
    }
    public var isCapturing: Bool { stream != nil || microphone != nil }
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
                        if !Self.isWindowAvailable(windowID) { self?.onFailure(.unavailableTarget) }
                    }
                }
                timer.tolerance = 0.25
                targetTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } catch { self.source = nil; throw error }
    }
    static func isWindowAvailable(_ windowID: CGWindowID) -> Bool {
        guard windowID != kCGNullWindowID else { return false }
        // 此 API 接收无 CF 对象回调的窗口 ID 数组，元素是整数值而非 NSNumber。
        // 按 ID 查询包含隐藏窗口，避免使用只对上下层窗口列表有意义的 including 选项。
        var identifier = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let identifiers = CFArrayCreate(kCFAllocatorDefault, &identifier, 1, nil) else { return false }
        let windows = CGWindowListCreateDescriptionFromArray(identifiers) as? [[String: Any]]
        return windows?.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID } == true
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
        guard !transitioning, isCapturing || writer != nil else { throw CaptureError.invalidTransition }
        transitioning = true
        defer { transitioning = false }
        let endTime = CMClockGetTime(CMClockGetHostTimeClock())
        var captureError: (any Error)?
        if let stream {
            do {
                try await stopStream(stream)
                self.stream = nil
            } catch { captureError = error }
        }
        do { try await microphone?.stop(); microphone = nil } catch { if captureError == nil { captureError = error } }
        // 停止失败仍保留生产者供最终停止或退出清理重试，不能把 UI 推进到预览。
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
                } else if await writer.hasCommittedMedia, let url {
                    // A terminal audio failure can still seal playable earlier
                    // media. Keep it while propagating the failure to the host.
                    segments.append(url)
                }
                captureError = error
            }
        }
        if !isCapturing { Self.logger.notice("Recording producer stopped") }
        if let captureError { throw captureError }
    }
    public func stop() async throws {
        targetTimer?.invalidate(); targetTimer = nil
        defer { if !isCapturing { source = nil } }
        if isCapturing || writer != nil { try await pause() }
    }
    private static func stopStream(_ stream: SCStream) async throws {
        try await CaptureCallback<Void>().wait(onCancel: { stream.stopCapture { _ in } }) { completion in
            stream.stopCapture { error in
                if let error { completion.finish(.failure(error)) }
                else { completion.finish(.success(())) }
            }
        }
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
            // delegate 已确认流停止，不再向这条流发停止请求；writer 仍需封口保留片段。
            self.stream = nil
            self.onFailure(CaptureError.recordingFailure(error))
        }
    }
}
