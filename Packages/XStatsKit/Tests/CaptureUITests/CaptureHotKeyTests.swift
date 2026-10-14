// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Carbon
import Testing
import CaptureCore
import Localization
@testable import CaptureUI

// Carbon 快捷键是进程外资源；本套件串行且每个测试都解除自己的注册。
@Suite(.serialized) @MainActor struct CaptureHotKeyTests {
    private func binding(_ code: UInt16) -> CaptureHotKey {
        CaptureHotKey(code: code, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, characters: "")
    }
    private func reserve(_ binding: CaptureHotKey) throws -> EventHotKeyRef {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(binding.code), binding.carbon,
            EventHotKeyID(signature: 0x58545431, id: UInt32(binding.code)), GetApplicationEventTarget(), 0, &reference)
        try #require(status == noErr)
        return try #require(reference)
    }
    @Test func inactiveSettingsRejectDuplicateWithoutReplacingSavedBinding() {
        let name = "capture-shortcuts-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = CaptureController(host: .standalone, defaults: defaults)
        defer { controller.cleanUp() }
        let screenshot = binding(80), recording = binding(90)
        controller.setShortcut(screenshot, for: .screenshot)
        controller.setShortcut(recording, for: .record)
        controller.setShortcut(screenshot, for: .record)
        #expect(controller.recordingKey == recording)
        #expect(controller.shortcutConflict)
        let saved = defaults.data(forKey: "capture.recordingKey")
            .flatMap { try? JSONDecoder().decode(CaptureHotKey.self, from: $0) }
        #expect(saved == recording)
    }
    @Test func duplicateBindingsReleasePreviouslyRegisteredShortcut() throws {
        _ = NSApplication.shared
        let keys = CaptureHotKeys()
        defer { keys.clear() }
        let key = binding(80)
        try #require(keys.apply([.screenshot: key]))
        var alias = key; alias.characters = "different display text"
        #expect(!keys.apply([.screenshot: key, .record: alias]))
        let probe = try reserve(key)
        #expect(UnregisterEventHotKey(probe) == noErr)
    }
    @Test func laterConflictRollsBackEarlierRegistrationAndAllowsRetry() throws {
        _ = NSApplication.shared
        let keys = CaptureHotKeys()
        defer { keys.clear() }
        let screenshot = binding(80), recording = binding(90)
        let blocker = try reserve(recording)
        var blocked = true
        defer { if blocked { UnregisterEventHotKey(blocker) } }
        #expect(!keys.apply([.screenshot: screenshot, .record: recording]))
        let probe = try reserve(screenshot)
        UnregisterEventHotKey(probe)
        UnregisterEventHotKey(blocker); blocked = false
        #expect(keys.apply([.screenshot: screenshot, .record: recording]))
        keys.clear()
        let retry = try reserve(recording)
        #expect(UnregisterEventHotKey(retry) == noErr)
    }
    @Test func activeConflictKeepsBothRegistrationsAndSavedSettings() throws {
        let name = "capture-shortcuts-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureShortcuts(defaults: defaults)
        defer { settings.stop() }
        let screenshot = binding(80), recording = binding(90), occupied = binding(96)
        settings.setShortcut(screenshot, for: .screenshot)
        settings.setShortcut(recording, for: .record)
        settings.setEnabled(true)
        try #require(!settings.conflict)
        let blocker = try reserve(occupied)
        defer { UnregisterEventHotKey(blocker) }
        settings.setShortcut(occupied, for: .record)
        #expect(settings.conflict)
        #expect(settings.recordingKey == recording)
        let restored = CaptureShortcuts(defaults: defaults)
        #expect(restored.recordingKey == recording)
        let competing = CaptureHotKeys()
        defer { competing.clear() }
        #expect(!competing.apply([.screenshot: screenshot]))
        #expect(!competing.apply([.record: recording]))
        settings.setShortcut(nil, for: .record)
        #expect(!settings.conflict)
        let freed = try reserve(recording)
        UnregisterEventHotKey(freed)
        settings.stop()
        let stopped = try reserve(screenshot)
        UnregisterEventHotKey(stopped)
    }
    @Test func inactiveShortcutsPersistWithoutRegisteringAndKeepHostDomainsSeparate() throws {
        let name = "capture-shortcuts-" + UUID().uuidString
        let otherName = name + "-other"
        let defaults = UserDefaults(suiteName: name)!, other = UserDefaults(suiteName: otherName)!
        defer {
            defaults.removePersistentDomain(forName: name)
            other.removePersistentDomain(forName: otherName)
        }
        let settings = CaptureShortcuts(defaults: defaults)
        let key = binding(80)
        settings.setShortcut(key, for: .screenshot)
        #expect(!settings.enabled)
        let probe = try reserve(key)
        UnregisterEventHotKey(probe)
        #expect(CaptureShortcuts(defaults: defaults).screenshotKey == key)
        #expect(CaptureShortcuts(defaults: other).screenshotKey == nil)
        settings.setEnabled(true)
        #expect(!settings.conflict)
        settings.stop()
        #expect(settings.screenshotKey == key)
        let stopped = try reserve(key)
        UnregisterEventHotKey(stopped)
    }
    @Test func startupConflictReleasesPartialGroupAndCanRetry() throws {
        let name = "capture-shortcuts-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureShortcuts(defaults: defaults)
        defer { settings.stop() }
        let screenshot = binding(80), recording = binding(90)
        settings.setShortcut(screenshot, for: .screenshot)
        settings.setShortcut(recording, for: .record)
        let blocker = try reserve(recording)
        settings.setEnabled(true)
        #expect(settings.conflict)
        let probe = try reserve(screenshot)
        UnregisterEventHotKey(probe)
        UnregisterEventHotKey(blocker)
        settings.stop()
        settings.setEnabled(true)
        #expect(!settings.conflict)
    }
    @Test func systemScreenshotAndUnmodifiedKeysAreRejected() {
        let name = "capture-shortcuts-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = CaptureShortcuts(defaults: defaults)
        for code: UInt16 in [20, 21, 22, 23] {
            settings.setShortcut(CaptureHotKey(code: code, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, characters: "3"), for: .screenshot)
            #expect(settings.conflict)
            #expect(settings.screenshotKey == nil)
            settings.setShortcut(CaptureHotKey(code: code, modifiers: NSEvent.ModifierFlags([.command, .shift, .control]).rawValue, characters: "3"), for: .screenshot)
            #expect(settings.conflict)
            #expect(settings.screenshotKey == nil)
        }
        settings.setShortcut(CaptureHotKey(code: 0, modifiers: 0, characters: "a"), for: .record)
        #expect(settings.conflict)
        #expect(settings.recordingKey == nil)
    }
    @Test func recorderCapturesCommandEquivalentAndCancelsOrClears() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let button = ShortcutButton()
        defer { button.onChange = { _ in } }
        window.contentView = button
        var edits = 0
        button.onChange = { button.binding = $0; edits += 1 }
        button.performClick(nil)
        let command = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
        #expect(button.performKeyEquivalent(with: command))
        #expect(edits == 1)
        #expect(button.binding?.code == 40)
        #expect(button.title == "⌥⌘K")
        button.performClick(nil)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        button.keyDown(with: escape)
        #expect(edits == 1)
        #expect(button.title == "⌥⌘K")
        button.performClick(nil)
        let delete = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 51))
        button.keyDown(with: delete)
        #expect(edits == 2)
        #expect(button.binding == nil)
        #expect(!button.recording)
    }
    @Test func shortcutInstructionsAreTranslatedWithoutChangingGlobalLanguage() {
        for language in AppLanguage.allCases where language != .system && language != .chinese {
            for text in ["点击设置快捷键；Delete 清除，Esc 取消。", "快捷键无效或已被占用，原设置已保留。", "快捷键在常驻菜单栏时生效。", "快捷键在 XStats 运行时生效。"] {
                #expect(L10n.translate(text, language: language) != text)
            }
        }
    }
    @Test func anotherProcessCannotShareCaptureShortcut() async throws {
        // A same-process Carbon reservation cannot catch accidental non-exclusive registration.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reply = directory.appendingPathComponent("status")
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["-e", #"""
        // SPDX-License-Identifier: AGPL-3.0-or-later
        import AppKit
        import Carbon
        _ = NSApplication.shared
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(92, UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: 0x58545433, id: 1), GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference)
        try String(status).write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)
        _ = readLine()
        if let reference { UnregisterEventHotKey(reference) }
        """#, reply.path]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: reply.path) || !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let status = try String(contentsOf: reply, encoding: .utf8)
        try #require(status == String(noErr))
        let keys = CaptureHotKeys()
        defer { keys.clear() }
        #expect(!keys.apply([.screenshot: binding(92)]))
    }
}
