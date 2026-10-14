// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import AVFoundation
import ScreenCaptureKit
import OSLog
import CaptureCore
import Localization

@MainActor final class CaptureController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var mode: CaptureMode = .region
    @Published var systemAudio = true
    @Published var microphone = false
    @Published var resident = UserDefaults.standard.bool(forKey: "capture.resident")
    @Published var language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: "capture.language") ?? "") ?? .system
    @Published var screenshotKey: CaptureHotKey?
    @Published var recordingKey: CaptureHotKey?
    @Published var shortcutConflict = false
    @Published var error: String?
    @Published var permissionError: CaptureError?
    @Published var busy = false
    @Published var paused = false
    @Published var countdown = 0
    @Published var transitioning = false
    @Published var exporting = false
    @Published var player: AVPlayer?
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var duration = 0.0
    private var state = CaptureSessionState()
    private var home: NSWindow?
    private var control: NSWindow?
    private var preview: NSWindow?
    private var editors: [ImageEditorWindow] = []
    private var pins: [NSWindow] = []
    private let selector = CaptureSelection()
    private let hotKeys = CaptureHotKeys()
    private let exporter = RecordingExporter()
    private var recorder: ScreenRecorder?
    private var operation: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var distributedObserver: NSObjectProtocol?
    private var recordingSaved = false
    private var finishing = false
    private var terminating = false
    private var selectedSource: ScreenCaptureSource?
    private static let logger = Logger(subsystem: CaptureRequest.bundleIdentifier, category: "lifecycle")

    override init() {
        super.init()
        screenshotKey = Self.readKey("capture.screenshotKey")
        recordingKey = Self.readKey("capture.recordingKey")
        hotKeys.onAction = { [weak self] in self?.begin($0, external: $0 == .record) }
        L10n.configure(language)
    }
    func installObservers() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interruptRecording() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let source = self.selectedSource else { return }
                if !NSScreen.screens.contains(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == source.displayID }) { self.interruptRecording() }
            }
        })
        distributedObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptRecording() }
        }
        applyResidentMode()
    }
    func cleanUp() {
        operation?.cancel(); selector.cancel(); hotKeys.clear(); player?.pause()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        if let distributedObserver { DistributedNotificationCenter.default().removeObserver(distributedObserver) }
        distributedObserver = nil
        removeStatusItem()
    }
    private static func readKey(_ name: String) -> CaptureHotKey? {
        guard let data = UserDefaults.standard.data(forKey: name) else { return nil }
        return try? JSONDecoder().decode(CaptureHotKey.self, from: data)
    }
    func setShortcut(_ key: CaptureHotKey?, for action: CaptureRequest.Action) {
        let name = action == .screenshot ? "capture.screenshotKey" : "capture.recordingKey"
        if action == .screenshot { screenshotKey = key } else { recordingKey = key }
        UserDefaults.standard.set(key.flatMap { try? JSONEncoder().encode($0) }, forKey: name)
        applyResidentMode()
    }
    func applyLanguage() {
        UserDefaults.standard.set(language.rawValue, forKey: "capture.language")
        L10n.configure(language)
        home?.contentView = NSHostingView(rootView: CaptureHomeView(controller: self).environment(\.layoutDirection, L10n.language.isRightToLeft ? .rightToLeft : .leftToRight).environment(\.locale, L10n.locale))
        home?.title = "XStats Capture"
        applyResidentMode()
    }
    private var statusItem: NSStatusItem?
    func applyResidentMode() {
        UserDefaults.standard.set(resident, forKey: "capture.resident")
        var bindings: [CaptureRequest.Action: CaptureHotKey] = [:]
        if resident { bindings[.screenshot] = screenshotKey; bindings[.record] = recordingKey }
        shortcutConflict = !hotKeys.apply(bindings)
        if resident {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                statusItem?.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "XStats Capture")
            }
            let menu = NSMenu()
            for (title, selector) in [(tr("截图"), #selector(screenshotFromMenu)), (tr("录屏"), #selector(recordFromMenu)), (tr("打开 XStats Capture"), #selector(openFromMenu))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
            }
            menu.addItem(.separator())
            let quit = NSMenuItem(title: tr("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            menu.addItem(quit); statusItem?.menu = menu
        } else { removeStatusItem() }
        considerExit()
    }
    private func removeStatusItem() { if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil }
    @objc private func screenshotFromMenu() { begin(.screenshot) }
    @objc private func recordFromMenu() { begin(.record, external: true) }
    @objc private func openFromMenu() { showHome() }

    func showHome() {
        guard !terminating else { return }
        if busy { showActiveWindow(); return }
        if home == nil {
            home = makeWindow(title: "XStats Capture", size: CGSize(width: 540, height: 620), content: CaptureHomeView(controller: self), resizable: true)
        }
        systemAudio = true; microphone = false
        home?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showActiveWindow() {
        (control ?? preview ?? home)?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func handle(_ url: URL) {
        do {
            let request = try CaptureRequest(url: url)
            if request.action == .open { showHome() } else { begin(request.action, external: true) }
        } catch { self.error = error.localizedDescription; showHome() }
    }
    func begin(_ action: CaptureRequest.Action, external: Bool = false) {
        guard !terminating else { return }
        guard action != .open else { showHome(); return }
        guard !busy, preview == nil, recorder == nil else { showActiveWindow(); return }
        if external, action == .record {
            showHome()
            error = tr("确认捕获范围和声音设置后，点击录屏。")
            return
        }
        if home == nil { showHome() }
        do { try state.transition(to: .selecting) } catch { return }
        busy = true; error = nil; permissionError = nil
        let mode = mode
        var options = RecordingOptions(); options.systemAudio = systemAudio; options.microphone = microphone
        operation = Task {
            do {
                if action == .record, options.microphone { try await ScreenRecorder.requestMicrophone() }
                let content = try await ScreenCaptureSource.content()
                try Task.checkCancellation()
                home?.orderOut(nil)
                guard let source = try await selector.select(mode: mode, content: content) else { resetOperation(); showHome(); return }
                try Task.checkCancellation()
                selectedSource = source
                if action == .screenshot {
                    let image = try await source.screenshot()
                    try Task.checkCancellation()
                    try state.transition(to: .preview)
                    openEditor(image)
                    try state.transition(to: .idle)
                    busy = false; selectedSource = nil
                    home?.close()
                    Self.logger.notice("Screenshot completed")
                } else {
                    try state.transition(to: .countdown)
                    control = makeWindow(title: tr("录屏"), size: CGSize(width: 260, height: 130), content: RecordingControlView(controller: self), resizable: false)
                    control?.level = .floating; control?.makeKeyAndOrderFront(nil)
                    for count in stride(from: 3, through: 1, by: -1) {
                        countdown = count
                        try await Task.sleep(for: .seconds(1))
                    }
                    try Task.checkCancellation()
                    countdown = 0; transitioning = true
                    try state.transition(to: .starting)
                    let recorder = ScreenRecorder(media: try RecordingMedia())
                    self.recorder = recorder; recordingSaved = false
                    recorder.onFailure = { [weak self, weak recorder] error in
                        guard let self, let recorder, self.recorder === recorder,
                              self.busy, !self.finishing, !self.terminating else { return }
                        self.error = error.localizedDescription; self.stopRecording()
                    }
                    do {
                        try await recorder.start(source: source, options: options)
                        try Task.checkCancellation()
                    } catch {
                        // 初次启动失败没有可恢复的片段，释放占位状态以允许再次录制。
                        self.recorder = nil
                        do { try await recorder.discard() }
                        catch { Self.logger.error("Failed to discard media after recording startup failure") }
                        throw error
                    }
                    try state.transition(to: .recording)
                    transitioning = false; paused = false
                }
            } catch is CancellationError { resetOperation(); showHome() }
            catch {
                self.error = (error as? CaptureError)?.localizedDescription ?? CaptureError.captureFailed.localizedDescription
                permissionError = (error as? CaptureError).flatMap { $0 == .screenPermission || $0 == .microphonePermission ? $0 : nil }
                Self.logger.error("Capture operation failed")
                resetOperation(); showHome()
            }
        }
    }
    private func resetOperation() {
        if state.phase != .idle { try? state.transition(to: .idle) }
        busy = false; countdown = 0; transitioning = false; selectedSource = nil
        control?.close(); control = nil
    }
    func cancelCountdown() { operation?.cancel(); selector.cancel() }
    func togglePause() {
        guard !terminating, !transitioning, let recorder else { return }
        transitioning = true
        operation = Task {
            do {
                if paused {
                    try state.transition(to: .resuming); try await recorder.resume(); try state.transition(to: .recording)
                } else {
                    try state.transition(to: .pausing); try await recorder.pause(); try state.transition(to: .paused)
                }
                paused.toggle(); transitioning = false
            } catch is CancellationError { transitioning = false }
            catch {
                self.error = CaptureError.writerFailed.localizedDescription
                transitioning = false; stopRecording()
            }
        }
    }
    private func interruptRecording() {
        guard !terminating, state.shouldInterruptCapture else { return }
        if recorder == nil { cancelCountdown() }
        else if transitioning {
            let task = operation
            Task { await task?.value; interruptRecording() }
        } else { stopRecording() }
    }
    func stopRecording() {
        guard !terminating, !finishing, state.shouldInterruptCapture, let recorder else { return }
        if transitioning {
            let task = operation
            Task { await task?.value; stopRecording() }
            return
        }
        finishing = true; transitioning = true
        operation = Task {
            defer { finishing = false; transitioning = false }
            try? state.transition(to: .finishing)
            do { try await recorder.stop() } catch {
                self.error = CaptureError.writerFailed.localizedDescription
                Self.logger.error("Recording stop failed; keeping completed media")
            }
            guard !terminating, !Task.isCancelled else { return }
            control?.close(); control = nil; selectedSource = nil
            do {
                try await showRecordingPreview(recorder)
            } catch {
                self.error = CaptureError.captureFailed.localizedDescription
                resetOperation(); showHome()
            }
        }
    }
    private func showRecordingPreview(_ recorder: ScreenRecorder) async throws {
        let composition = try await exporter.composition(segments: recorder.segments)
        duration = try await composition.load(.duration).seconds
        try Task.checkCancellation()
        trimStart = 0; trimEnd = duration; recordingSaved = false
        player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
        try state.transition(to: .preview)
        preview = makeWindow(title: tr("录屏预览"), size: CGSize(width: 800, height: 570), content: RecordingPreviewView(controller: self), resizable: true)
        preview?.makeKeyAndOrderFront(nil)
        busy = false; home?.close()
    }
    func recoverRecordingPreview() {
        guard !terminating, state.phase == .idle, !busy, let recorder else { return }
        busy = true; finishing = true
        operation = Task {
            defer { finishing = false }
            do {
                try state.transition(to: .finishing)
                try await showRecordingPreview(recorder)
            } catch { self.error = CaptureError.captureFailed.localizedDescription; resetOperation(); showHome() }
        }
    }
    var hasRecordingMedia: Bool { recorder != nil && preview == nil && !busy }
    func discardRecording() {
        guard !busy, let recorder else { return }
        let alert = NSAlert(); alert.messageText = tr("丢弃未保存的录屏？")
        alert.addButton(withTitle: tr("丢弃")); alert.addButton(withTitle: tr("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try recorder.media.discard(); self.recorder = nil; recordingSaved = false; resetOperation() }
        catch { self.error = CaptureError.exportFailed.localizedDescription }
    }
    func seekTrim() {
        player?.seek(to: CMTime(seconds: trimStart, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.currentItem?.forwardPlaybackEndTime = CMTime(seconds: trimEnd, preferredTimescale: 600)
    }
    func exportRecording() {
        guard !terminating, !exporting, let recorder else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = "Recording.mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporting = true; busy = true; error = nil; permissionError = nil
        operation = Task {
            defer { exporting = false; busy = false; if state.phase == .exporting { try? state.transition(to: .preview) }; considerExit() }
            do {
                try state.transition(to: .exporting)
                let trim = try RecordingTrim(start: trimStart, end: trimEnd, duration: duration)
                try await exporter.export(segments: recorder.segments, trim: trim, to: url)
                recordingSaved = true
                player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
                try recorder.media.discard()
                Self.logger.notice("Recording export completed")
                preview?.close()
                self.recorder = nil
                try? state.transition(to: .idle)
                considerExit()
            } catch is CancellationError { Self.logger.notice("Recording export cancelled") }
            catch {
                self.error = CaptureError.exportFailed.localizedDescription
                Self.logger.error("Recording export failed; keeping original media")
            }
        }
    }
    func cancelExport() { operation?.cancel(); exporter.cancel() }
    func revealMedia() { if let recorder { NSWorkspace.shared.open(recorder.media.directory) } }
    private func openEditor(_ image: CGImage) {
        let editor = ImageEditorWindow(image: image)
        editor.model.onPin = { [weak self] in self?.pin($0) }
        editor.onClose = { [weak self, weak editor] in
            guard let self else { return }
            self.editors.removeAll { $0 === editor }; self.considerExit()
        }
        editors.append(editor); editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func pin(_ image: CGImage) {
        guard pins.count < 5 else {
            let alert = NSAlert(); alert.messageText = tr("最多置顶 5 张截图，请先关闭已有截图。"); alert.runModal(); return
        }
        let scale = min(1, 600 / CGFloat(image.width), 450 / CGFloat(image.height))
        let window = makeWindow(title: tr("置顶截图"), size: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale),
                                content: Image(nsImage: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))).resizable().scaledToFit(), resizable: true)
        window.level = .floating; pins.append(window); window.makeKeyAndOrderFront(nil)
    }
    private func makeWindow<Content: View>(title: String, size: CGSize, content: Content, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: content.environment(\.layoutDirection, L10n.language.isRightToLeft ? .rightToLeft : .leftToRight).environment(\.locale, L10n.locale))
        window.center(); return window
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === control { return false }
        if sender === preview {
            guard !exporting else { return false }
            if !recordingSaved {
                let alert = NSAlert(); alert.messageText = tr("丢弃未保存的录屏？")
                alert.addButton(withTitle: tr("丢弃")); alert.addButton(withTitle: tr("取消"))
                guard alert.runModal() == .alertFirstButtonReturn else { return false }
            }
        }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === home { home = nil }
        if window === preview {
            player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
            if !exporting { try? recorder?.media.discard(); recorder = nil; try? state.transition(to: .idle) }
            preview = nil
        }
        pins.removeAll { $0 === window }
        considerExit()
    }
    func considerExit() {
        Task { @MainActor in
            await Task.yield()
            guard !terminating else { return }
            let windows = [home, control, preview].compactMap { $0 }.count + editors.count + pins.count
            if CaptureLifetime.shouldExit(resident: resident, windows: windows, busy: busy || finishing) { NSApp.terminate(nil) }
        }
    }
    var hasUnsavedWork: Bool { busy || (recorder != nil && !recordingSaved) || editors.contains(where: { $0.model.dirty || $0.model.rendering }) }
    func discardAndStop() async {
        terminating = true
        operation?.cancel(); selector.cancel(); exporter.cancel()
        Self.logger.notice("Cancelling capture operations before termination")
        await operation?.value
        for editor in editors { await editor.model.finishPendingWork() }
        do { try await recorder?.discard() }
        catch { Self.logger.error("Failed to discard recording media before termination") }
        recorder = nil; player?.pause()
    }
    func openPrivacySettings() {
        let pane = permissionError == .microphonePermission ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}
