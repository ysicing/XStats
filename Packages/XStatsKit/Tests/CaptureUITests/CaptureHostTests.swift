// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Carbon
import Testing
import CaptureCore
import Localization
@testable import CaptureUI

@Suite @MainActor struct CaptureHostTests {
    @Test func embeddedShortcutsStayRegisteredAfterClosingAndLazilyReopen() async throws {
        _ = NSApplication.shared
        let name = "capture-host-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let workspace = CaptureWorkspace(host: .embedded, defaults: defaults)
        defer { workspace.shortcuts.stop(); workspace.cleanUp() }
        let key = CaptureHotKey(code: 91, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, characters: "8")
        workspace.shortcuts.setShortcut(key, for: .record)
        workspace.startShortcuts()
        #expect(workspace.controller == nil)
        #expect(!workspace.shortcuts.conflict)
        workspace.shortcuts.onAction(.record)
        let controller = try #require(workspace.controller)
        #expect(controller.captureAction == .record)
        #expect(!controller.busy) // Audio choices are confirmed before recording starts.
        let home = try #require(NSApp.windows.first { $0.delegate === controller && $0.isVisible })
        home.close()
        for _ in 0..<20 { await Task.yield() }
        #expect(workspace.controller == nil)
        var competitor: EventHotKeyRef?
        #expect(RegisterEventHotKey(UInt32(key.code), key.carbon, EventHotKeyID(signature: 0x58545432, id: 1),
            GetApplicationEventTarget(), 0, &competitor) != noErr)
        if let competitor { UnregisterEventHotKey(competitor) }
        workspace.shortcuts.onAction(.record)
        #expect(workspace.controller != nil)
        #expect(workspace.controller !== controller)
        await workspace.prepareForTermination()
    }
    @Test func embeddedIgnoresStandaloneSettingsAndPreservesHostIdentity() async {
        _ = NSApplication.shared
        let name = "capture-host-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "capture.resident")
        defaults.set("ar", forKey: "capture.language")
        let language = L10n.language
        let menu = NSApp.mainMenu
        let delegate = NSApp.delegate
        let workspace = CaptureWorkspace(host: .embedded, defaults: defaults)
        #expect(workspace.controller == nil)
        workspace.open(.open)
        let controller = workspace.controller
        #expect(controller?.resident == false)
        #expect(controller?.language == language)
        controller?.applyLanguage()
        controller?.applyResidentMode()
        #expect(L10n.language == language)
        #expect(NSApp.mainMenu === menu)
        #expect(NSApp.delegate === delegate)
        #expect(defaults.bool(forKey: "capture.resident"))
        #expect(defaults.string(forKey: "capture.language") == "ar")
        await workspace.prepareForTermination()
        workspace.cleanUp()
    }

    @Test func repeatedOpenReusesHomeAndCloseReleasesEmbeddedController() async throws {
        _ = NSApplication.shared
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let workspace = CaptureWorkspace(host: .embedded)
        workspace.open(.open)
        weak var controller = workspace.controller
        workspace.open(.open)
        let windows = NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) && $0.isVisible }
        #expect(windows.count == 1)
        #expect(workspace.hasOpenWindows)
        #expect(workspace.controller === controller)
        let home = try #require(windows.first)
        home.close()
        for _ in 0..<20 { await Task.yield() }
        #expect(!workspace.hasOpenWindows)
        #expect(workspace.controller == nil)
        #expect(controller == nil)
        // Closing Capture releases it without stopping the embedding application.
        workspace.open(.open)
        #expect(workspace.hasOpenWindows)
        await workspace.prepareForTermination()
        workspace.cleanUp()
        #expect(!workspace.hasOpenWindows)
    }

    @Test func embeddedExcludesOnlyCaptureWindowsWhileStandaloneExcludesItsProcess() {
        let embedded = CaptureWindowExclusion(excludesApplication: false, windowIDs: [42, 43])
        #expect(embedded.excludes(windowID: 42, processID: 10, currentProcessID: 10))
        #expect(!embedded.excludes(windowID: 44, processID: 10, currentProcessID: 10))
        #expect(!embedded.excludes(windowID: 45, processID: 20, currentProcessID: 10))
        let standalone = CaptureWindowExclusion(excludesApplication: true, windowIDs: [])
        #expect(standalone.excludes(windowID: 44, processID: 10, currentProcessID: 10))
        #expect(!standalone.excludes(windowID: 45, processID: 20, currentProcessID: 10))
    }
    @Test func pendingPinDoesNotCreateAWindowAfterRecordingDisablesPinning() async throws {
        let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let model = ImageEditorModel(image: try #require(context.makeImage()))
        var pins = 0
        model.onPin = { _ in pins += 1 }
        model.pin()
        model.canPin = false
        for _ in 0..<20 { await Task.yield() }
        #expect(pins == 0)
        model.canPin = true
        model.pin()
        for _ in 0..<20 { await Task.yield() }
        #expect(pins == 1)
    }

}
