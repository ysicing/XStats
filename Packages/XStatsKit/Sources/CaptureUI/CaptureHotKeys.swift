// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Carbon
import SwiftUI
import CaptureCore
import Localization

struct CaptureHotKey: Codable, Equatable {
    var code: UInt16
    var modifiers: UInt
    var characters: String
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }
    var display: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "") + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + characters.uppercased()
    }
    var carbon: UInt32 {
        (flags.contains(.command) ? UInt32(cmdKey) : 0) | (flags.contains(.option) ? UInt32(optionKey) : 0) |
        (flags.contains(.control) ? UInt32(controlKey) : 0) | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
    }
    var isUsable: Bool {
        guard !flags.intersection([.control, .option, .command]).isEmpty,
              modifiers == flags.intersection([.control, .option, .shift, .command]).rawValue,
              ![51, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(code) else { return false }
        // Preserve macOS's default screenshot/recording shortcuts even if Carbon allows overriding them.
        let screenshotModifiers: [NSEvent.ModifierFlags] = [[.command, .shift], [.command, .shift, .control]]
        return !(screenshotModifiers.contains(flags) && [20, 21, 22, 23].contains(code))
    }
}

@MainActor final class CaptureHotKeys {
    private var keys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static var nextID: UInt32 = 0
    private var actions: [UInt32: CaptureRequest.Action] = [:]
    var onAction: (CaptureRequest.Action) -> Void = { _ in }
    func apply(_ bindings: [CaptureRequest.Action: CaptureHotKey]) -> Bool {
        clear()
        guard !bindings.isEmpty else { return true }
        // Carbon 注册是逐项执行的；重复组合提前拒绝，任何失败都回滚整组。
        let combinations = Set(bindings.values.map { UInt64($0.code) << 32 | UInt64($0.carbon) })
        guard combinations.count == bindings.count else { return false }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            guard let context, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x58434150 else { return OSStatus(eventNotHandledErr) }
            return MainActor.assumeIsolated {
                let owner = Unmanaged<CaptureHotKeys>.fromOpaque(context).takeUnretainedValue()
                guard let action = owner.actions[id.id] else { return OSStatus(eventNotHandledErr) }
                owner.onAction(action)
                return noErr
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { clear(); return false }
        for action in CaptureRequest.Action.allCases {
            guard let binding = bindings[action] else { continue }
            var reference: EventHotKeyRef?
            Self.nextID &+= 1
            let id = EventHotKeyID(signature: 0x58434150, id: Self.nextID)
            actions[id.id] = action
            if RegisterEventHotKey(UInt32(binding.code), binding.carbon, id, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &reference) == noErr, let reference { keys.append(reference) }
            else { clear(); return false }
        }
        return true
    }
    func clear() {
        for key in keys { UnregisterEventHotKey(key) }; keys.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
        actions.removeAll()
    }
    isolated deinit { clear() }
}

struct CaptureShortcutRecorder: NSViewRepresentable {
    let value: CaptureHotKey?
    var onChange: (CaptureHotKey?) -> Void
    func makeNSView(context: Context) -> ShortcutButton { ShortcutButton() }
    func updateNSView(_ view: ShortcutButton, context: Context) {
        view.binding = value; view.onChange = onChange
        if !view.recording { view.title = value?.display ?? tr("设置快捷键") }
    }
}

@MainActor final class ShortcutButton: NSButton {
    var binding: CaptureHotKey?
    var onChange: (CaptureHotKey?) -> Void = { _ in }
    var recording = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        bezelStyle = .rounded; target = self; action = #selector(record)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    @objc private func record() { recording = true; title = tr("按下快捷键，Esc 取消"); window?.makeFirstResponder(self) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = binding?.display ?? tr("设置快捷键"); return }
        if event.keyCode == 51 { recording = false; onChange(nil); title = binding?.display ?? tr("设置快捷键"); return }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return }
        let key = CaptureHotKey(code: event.keyCode, modifiers: flags.rawValue, characters: event.charactersIgnoringModifiers ?? "")
        recording = false; onChange(key); title = binding?.display ?? tr("设置快捷键")
    }
    override func resignFirstResponder() -> Bool {
        recording = false; title = binding?.display ?? tr("设置快捷键")
        return super.resignFirstResponder()
    }
}
