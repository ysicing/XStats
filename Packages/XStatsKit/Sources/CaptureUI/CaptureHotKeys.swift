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
}

@MainActor final class CaptureHotKeys {
    private var keys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static weak var current: CaptureHotKeys?
    var onAction: (CaptureRequest.Action) -> Void = { _ in }
    func apply(_ bindings: [CaptureRequest.Action: CaptureHotKey]) -> Bool {
        clear()
        guard !bindings.isEmpty else { return true }
        Self.current = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x58434150 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { CaptureHotKeys.current?.onAction(id.id == 1 ? .screenshot : .record) }
            return noErr
        }, 1, &spec, nil, &handler)
        var success = true
        for (action, binding) in bindings {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x58434150, id: action == .screenshot ? 1 : 2)
            if RegisterEventHotKey(UInt32(binding.code), binding.carbon, id, GetApplicationEventTarget(), 0, &reference) == noErr, let reference { keys.append(reference) }
            else { success = false }
        }
        return success
    }
    func clear() {
        for key in keys { UnregisterEventHotKey(key) }; keys.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
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
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = binding?.display ?? tr("设置快捷键"); return }
        if event.keyCode == 51 { onChange(nil); recording = false; return }
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.intersection([.control, .option, .command]).isEmpty else { return }
        let key = CaptureHotKey(code: event.keyCode, modifiers: flags.rawValue, characters: event.charactersIgnoringModifiers ?? "")
        recording = false; title = key.display; onChange(key)
    }
    override func resignFirstResponder() -> Bool {
        recording = false; title = binding?.display ?? tr("设置快捷键")
        return super.resignFirstResponder()
    }
}
