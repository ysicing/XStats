// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Carbon
import Testing
import CaptureCore
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
}
