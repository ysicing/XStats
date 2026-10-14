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
    @Published var captureAction: CaptureRequest.Action = .screenshot
    @Published var systemAudio = true
    @Published var microphone = false
    @Published var resident: Bool
    @Published var language: AppLanguage
    @Published var screenshotKey: CaptureHotKey?
    @Published var recordingKey: CaptureHotKey?
    @Published var shortcutConflict = false
    @Published var error: String?
    @Published var permissionError: CaptureError?
    @Published var busy = false {
        didSet {
            guard host == .embedded else { return }
            for editor in editors { editor.model.canPin = !busy }
        }
    }
    @Published var paused = false
    @Published var countdown = 0
    @Published var transitioning = false
    @Published var exporting = false
    @Published var player: AVPlayer?
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var duration = 0.0
    let host: CaptureHost
    private let defaults: UserDefaults
    var onIdle: () -> Void = {}
    var onWindowsChanged: () -> Void = {}
    private var observersInstalled = false
    private var state = CaptureSessionState()
    private var home: NSWindow?
    private var control: NSWindow?
    private var preview: NSWindow?
    private var editors: [ImageEditorWindow] = []
    private var pins: [(window: NSWindow, image: CGImage)] = []
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

    init(host: CaptureHost, defaults: UserDefaults = .standard) {
        self.host = host; self.defaults = defaults
        resident = host == .standalone && defaults.bool(forKey: "capture.resident")
        language = host == .standalone
            ? AppLanguage(rawValue: defaults.string(forKey: "capture.language") ?? "") ?? .system
            : L10n.language
        super.init()
        screenshotKey = readKey("capture.screenshotKey")
        recordingKey = readKey("capture.recordingKey")
        hotKeys.onAction = { [weak self] in self?.begin($0, external: $0 == .record) }
    }
    func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        if host == .standalone { L10n.configure(language) }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interruptRecording() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let source = self.selectedSource else { return }
                let displays = Set(NSScreen.screens.compactMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 })
                if Self.shouldInterruptForDisplayChange(displayID: source.displayID, windowID: source.windowID, availableDisplays: displays) {
                    self.interruptRecording()
                }
            }
        })
        distributedObserver = DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptRecording() }
        }
        applyResidentMode()
    }
    static func shouldInterruptForDisplayChange(displayID: CGDirectDisplayID, windowID: CGWindowID?, availableDisplays: Set<CGDirectDisplayID>) -> Bool {
        // 独立窗口过滤器跟随窗口移动，由窗口 ID 检查决定结束，不能绑定最初点击的显示器。
        windowID == nil && !availableDisplays.contains(displayID)
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
        observersInstalled = false
        removeStatusItem()
    }
    private func readKey(_ name: String) -> CaptureHotKey? {
        guard let data = defaults.data(forKey: name) else { return nil }
        return try? JSONDecoder().decode(CaptureHotKey.self, from: data)
    }
    func setShortcut(_ key: CaptureHotKey?, for action: CaptureRequest.Action) {
        guard host == .standalone else { return }
        let name = action == .screenshot ? "capture.screenshotKey" : "capture.recordingKey"
        if action == .screenshot { screenshotKey = key } else { recordingKey = key }
        defaults.set(key.flatMap { try? JSONEncoder().encode($0) }, forKey: name)
        applyResidentMode()
    }
    func applyLanguage() {
        if host == .standalone {
            defaults.set(language.rawValue, forKey: "capture.language")
            L10n.configure(language)
        } else { language = L10n.language }
        home?.contentView = NSHostingView(rootView: CaptureHomeView(controller: self))
        home?.title = "XStats Capture"
        control?.title = tr("录屏")
        control?.contentView = NSHostingView(rootView: RecordingControlView(controller: self).environment(\.layoutDirection, L10n.language.isRightToLeft ? .rightToLeft : .leftToRight).environment(\.locale, L10n.locale))
        preview?.title = tr("录屏预览")
        preview?.contentView = NSHostingView(rootView: RecordingPreviewView(controller: self).environment(\.layoutDirection, L10n.language.isRightToLeft ? .rightToLeft : .leftToRight).environment(\.locale, L10n.locale))
        for editor in editors { editor.applyLanguage(L10n.language) }
        for pin in pins {
            pin.window.title = tr("置顶截图")
            pin.window.contentView = NSHostingView(rootView: Image(nsImage: NSImage(cgImage: pin.image, size: CGSize(width: pin.image.width, height: pin.image.height))).resizable().scaledToFit().environment(\.layoutDirection, L10n.language.isRightToLeft ? .rightToLeft : .leftToRight).environment(\.locale, L10n.locale))
        }
        if host == .standalone { CaptureApplication.updateMenu(); applyResidentMode() }
    }
    private var statusItem: NSStatusItem?
    func applyResidentMode() {
        guard host == .standalone else { return }
        defaults.set(resident, forKey: "capture.resident")
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
            home = makeWindow(title: "XStats Capture", size: CGSize(width: 520, height: 430), content: CaptureHomeView(controller: self), resizable: false)
        }
        systemAudio = true; microphone = false
        home?.makeKeyAndOrderFront(nil); onWindowsChanged(); NSApp.activate(ignoringOtherApps: true)
    }
    /// Measure only after a content change; fixed width makes wrapping deterministic.
    /// Comparing the result avoids a window/layout feedback loop.
    func fitHomeWindow() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let home = self?.home, let content = home.contentView else { return }
            content.layoutSubtreeIfNeeded()
            let size = content.fittingSize
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            let current = home.contentRect(forFrameRect: home.frame).size
            guard abs(current.height - size.height) > 1 || abs(current.width - size.width) > 1 else { return }
            // Keep the title bar in place as the recording controls appear or disappear.
            let top = home.frame.maxY
            home.setContentSize(size)
            home.setFrameOrigin(CGPoint(x: home.frame.minX, y: top - home.frame.height))
        }
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
        captureAction = action
        if external, action == .record {
            showHome()
            error = tr("确认捕获范围和声音设置后，开始录制。")
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
                let content = try await ScreenCaptureSource.content(onScreenWindowsOnly: host == .standalone)
                try Task.checkCancellation()
                home?.orderOut(nil)
                let exclusion = CaptureWindowExclusion(excludesApplication: host == .standalone, windowIDs: captureWindowIDs)
                guard var source = try await selector.select(mode: mode, action: action, content: content, exclusion: exclusion) else { resetOperation(); showHome(); return }
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
                    control?.level = .floating; control?.makeKeyAndOrderFront(nil); onWindowsChanged()
                    for count in stride(from: 3, through: 1, by: -1) {
                        countdown = count
                        try await Task.sleep(for: .seconds(1))
                    }
                    try Task.checkCancellation()
                    if host == .embedded {
                        // The control window was created after target selection. Refresh the
                        // display filter before starting so it never enters the recording.
                        let currentContent = try await ScreenCaptureSource.content(onScreenWindowsOnly: false)
                        try Task.checkCancellation()
                        source = source.excludingWindows(currentContent.windows.filter { captureWindowIDs.contains($0.windowID) })
                    }
                    countdown = 0; transitioning = true
                    try state.transition(to: .starting)
                    let recorder = ScreenRecorder(media: try RecordingMedia())
                    self.recorder = recorder; recordingSaved = false
                    recorder.onFailure = { [weak self, weak recorder] error in
                        guard let self, let recorder, self.recorder === recorder,
                              self.busy, !self.finishing, !self.terminating else { return }
                        self.error = error.localizedDescription
                        self.permissionError = error == .screenPermission || error == .microphonePermission ? error : nil
                        self.stopRecording()
                    }
                    do {
                        try await recorder.start(source: source, options: options)
                        try Task.checkCancellation()
                    } catch {
                        let failure = error is CancellationError ? error : CaptureError.recordingFailure(error)
                        // 初次启动失败没有可恢复的片段，释放占位状态以允许再次录制。
                        self.recorder = nil
                        do { try await recorder.discard() }
                        catch { Self.logger.error("Failed to discard media after recording startup failure") }
                        throw failure
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
        guard !terminating, !transitioning, canPauseRecording, let recorder else { return }
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
                let failure = CaptureError.recordingFailure(error)
                self.error = failure.localizedDescription
                permissionError = failure == .screenPermission || failure == .microphonePermission ? failure : nil
                Self.logger.error("Recording pause or resume failed")
                transitioning = false; stopRecording()
            }
        }
    }
    var canPauseRecording: Bool { state.phase == .recording || state.phase == .paused }
    var needsStopRetry: Bool { state.phase == .finishing && !transitioning }
    private func interruptRecording() {
        guard !terminating, state.shouldInterruptCapture else { return }
        if recorder == nil { cancelCountdown() }
        else if transitioning {
            let task = operation
            Task { await task?.value; interruptRecording() }
        } else { stopRecording() }
    }
    func stopRecording() {
        guard !terminating, !finishing, state.shouldInterruptCapture || state.phase == .finishing, let recorder else { return }
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
                let failure = CaptureError.recordingFailure(error)
                self.error = failure.localizedDescription
                permissionError = failure == .screenPermission || failure == .microphonePermission ? failure : nil
                Self.logger.error("Recording stop failed; keeping completed media")
                if recorder.isCapturing {
                    control?.setContentSize(CGSize(width: 360, height: 260))
                    return
                }
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
        preview?.makeKeyAndOrderFront(nil); onWindowsChanged()
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
        busy = true
        operation = Task {
            do { try await recorder.media.discard(); self.recorder = nil; recordingSaved = false; resetOperation() }
            catch {
                self.error = CaptureError.exportFailed.localizedDescription; busy = false
                Self.logger.error("Failed to discard recording media")
            }
        }
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
                // 保存已提交到目标文件。后续清理失败不能改变保存结果或保留空预览。
                var cleanupFailed = false
                do { try await recorder.media.discard() }
                catch {
                    cleanupFailed = true
                    Self.logger.error("Recording saved, but temporary media cleanup failed")
                }
                Self.logger.notice("Recording export completed")
                // close 直接发送关闭通知，不调用用户关闭保护；保持 exporting 避免重复丢弃。
                preview?.close()
                self.recorder = nil
                try? state.transition(to: .idle)
                if cleanupFailed, !terminating {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = tr("录屏已保存，但临时素材未能完全清理。")
                    alert.informativeText = tr("保存的文件不受影响。可在访达中检查并清理剩余临时素材。")
                    alert.addButton(withTitle: tr("确定")); alert.addButton(withTitle: tr("显示临时素材"))
                    if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(recorder.media.directory) }
                }
                considerExit()
            } catch is CancellationError { Self.logger.notice("Recording export cancelled") }
            catch {
                self.error = (error as? CaptureError)?.localizedDescription ?? CaptureError.exportFailed.localizedDescription
                Self.logger.error("Recording export failed; keeping original media")
            }
        }
    }
    func cancelExport() { operation?.cancel(); exporter.cancel() }
    func revealMedia() { if let recorder { NSWorkspace.shared.open(recorder.media.directory) } }
    private func openEditor(_ image: CGImage) {
        let editor = ImageEditorWindow(image: image)
        editor.model.canPin = host == .standalone || !busy
        editor.model.onPin = { [weak self] in self?.pin($0) }
        editor.onClose = { [weak self, weak editor] in
            guard let self else { return }
            self.editors.removeAll { $0 === editor }; self.onWindowsChanged(); self.considerExit()
        }
        editors.append(editor); editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil)
        onWindowsChanged(); NSApp.activate(ignoringOtherApps: true)
    }
    private func pin(_ image: CGImage) {
        guard host == .standalone || !busy else { return }
        guard pins.count < 5 else {
            let alert = NSAlert(); alert.messageText = tr("最多置顶 5 张截图，请先关闭已有截图。"); alert.runModal(); return
        }
        let scale = min(1, 600 / CGFloat(image.width), 450 / CGFloat(image.height))
        let window = makeWindow(title: tr("置顶截图"), size: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale),
                                content: Image(nsImage: NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))).resizable().scaledToFit(), resizable: true)
        window.level = .floating; pins.append((window, image)); window.makeKeyAndOrderFront(nil); onWindowsChanged()
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
        if window === home { home = nil; window.contentView = nil }
        if window === preview {
            player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
            if !exporting, let recorder {
                busy = true
                operation = Task {
                    do {
                        try await recorder.media.discard()
                        self.recorder = nil; resetOperation(); considerExit()
                    } catch {
                        self.error = CaptureError.exportFailed.localizedDescription
                        resetOperation(); showHome()
                        Self.logger.error("Failed to discard media after preview closed")
                    }
                }
            }
            preview = nil; window.contentView = nil
        }
        pins.removeAll { $0.window === window }
        onWindowsChanged(); considerExit()
    }
    var hasOpenWindows: Bool { windowCount > 0 }
    private var windowCount: Int { [home, control, preview].compactMap { $0 }.count + editors.count + pins.count }
    private var captureWindowIDs: Set<CGWindowID> {
        Set(([home, control, preview].compactMap { $0 } + editors.compactMap(\.window) + pins.map(\.window))
            .map { CGWindowID($0.windowNumber) })
    }
    func considerExit() {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !terminating else { return }
            if CaptureLifetime.shouldExit(resident: resident, windows: windowCount, busy: busy || finishing || (host == .embedded && hasUnsavedWork)) { onIdle() }
        }
    }
    var hasUnsavedWork: Bool { busy || (recorder != nil && !recordingSaved) || editors.contains(where: { $0.model.dirty || $0.model.rendering }) }
    func discardAndStop() async {
        terminating = true
        operation?.cancel(); selector.cancel(); exporter.cancel()
        let models = editors.map(\.model)
        for model in models { model.cancelPendingWork(terminating: true) }
        Self.logger.notice("Cancelling capture operations before termination")
        for model in models { await model.waitForPendingWork() }
        await operation?.value
        do { try await recorder?.discard() }
        catch { Self.logger.error("Failed to discard recording media before termination") }
        recorder = nil; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        let windows = [home, control, preview].compactMap { $0 } + editors.compactMap(\.window) + pins.map(\.window)
        for window in windows { window.close() }
        home = nil; control = nil; preview = nil; editors.removeAll(); pins.removeAll()
        onWindowsChanged()
    }
    func openPrivacySettings() {
        let pane = permissionError == .microphonePermission ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}
