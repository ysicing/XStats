// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureCore
import Localization

/// The host owns process-wide behavior; capture functionality is shared.
public enum CaptureHost: Sendable { case embedded, standalone }

@MainActor public final class CaptureWorkspace {
    private let host: CaptureHost
    private let defaults: UserDefaults
    private(set) var controller: CaptureController?
    public var onWindowsChanged: () -> Void = {}
    public var hasOpenWindows: Bool { controller?.hasOpenWindows ?? false }
    public var hasUnsavedWork: Bool { controller?.hasUnsavedWork ?? false }
    public var hasActiveWorkspace: Bool { controller != nil }

    public init(host: CaptureHost = .embedded, defaults: UserDefaults = .standard) {
        self.host = host; self.defaults = defaults
    }
    public func open(_ action: CaptureRequest.Action = .open) {
        let controller = activeController()
        if action == .open { controller.showHome() }
        else { controller.begin(action, external: true) }
    }
    public func handle(_ url: URL) { activeController().handle(url) }
    public func refreshLanguage() { controller?.applyLanguage() }

    private func activeController() -> CaptureController {
        if let controller { return controller }
        let controller = CaptureController(host: host, defaults: defaults)
        self.controller = controller
        controller.onWindowsChanged = { [weak self] in self?.onWindowsChanged() }
        controller.onIdle = { [weak self] in
            guard let self else { return }
            if host == .standalone {
                // Idle already means no windows or pending media work. Release
                // the workspace first so the delegate can terminate immediately,
                // without nesting AppKit's terminateLater loop inside this task.
                cleanUp()
                NSApp.terminate(nil)
            } else { cleanUp() }
        }
        // The idle policy is deferred to the next main-actor turn so the
        // initiating action can present its window first.
        controller.installObservers()
        return controller
    }
    public func confirmTermination() -> Bool {
        guard hasUnsavedWork else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = tr("退出并丢弃未保存的内容？")
        alert.addButton(withTitle: tr("丢弃并退出")); alert.addButton(withTitle: tr("取消"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    public func prepareForTermination() async { await controller?.discardAndStop() }
    public func cleanUp() {
        controller?.cleanUp()
        controller = nil
        onWindowsChanged()
    }
}

struct CaptureWindowExclusion {
    let excludesApplication: Bool
    let windowIDs: Set<CGWindowID>
    func excludes(windowID: CGWindowID, processID: pid_t?, currentProcessID: pid_t) -> Bool {
        windowIDs.contains(windowID) || (excludesApplication && processID == currentProcessID)
    }
}
