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
    (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
      + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + keyName
  }
  private var keyName: String {
    switch Int(code) {
    case kVK_UpArrow: "↑"
    case kVK_DownArrow: "↓"
    case kVK_LeftArrow: "←"
    case kVK_RightArrow: "→"
    case kVK_Return: "↩"
    case kVK_ANSI_KeypadEnter: "⌤"
    case kVK_ANSI_KeypadClear: "⌧"
    case kVK_Tab: "⇥"
    case kVK_Space: tr("空格")
    case kVK_Delete: "⌫"
    case kVK_ForwardDelete: "⌦"
    case kVK_Escape: "⎋"
    case kVK_Help: tr("帮助")
    case kVK_Home: "↖"
    case kVK_End: "↘"
    case kVK_PageUp: "⇞"
    case kVK_PageDown: "⇟"
    default: Self.functionKeys[Int(code)].map { "F\($0)" } ?? characters.uppercased()
    }
  }
  // Function-key virtual codes are not contiguous. Persisted private-use
  // characters are event tokens, so render their names from the key code.
  private static let functionKeys: [Int: Int] = [
    kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5,
    kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
    kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15,
    kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
  ]
  var carbon: UInt32 {
    (flags.contains(.command) ? UInt32(cmdKey) : 0)
      | (flags.contains(.option) ? UInt32(optionKey) : 0)
      | (flags.contains(.control) ? UInt32(controlKey) : 0)
      | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
  }
  var isUsable: Bool {
    guard !flags.intersection([.control, .option, .command]).isEmpty,
      modifiers == flags.intersection([.control, .option, .shift, .command]).rawValue,
      ![51, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(code)
    else { return false }
    // Preserve macOS's default screenshot/recording shortcuts even if Carbon allows overriding them.
    let screenshotModifiers: [NSEvent.ModifierFlags] = [
      [.command, .shift], [.command, .shift, .control],
    ]
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
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        var id = EventHotKeyID()
        guard let context,
          GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.signature == 0x5843_4150
        else { return OSStatus(eventNotHandledErr) }
        return MainActor.assumeIsolated {
          let owner = Unmanaged<CaptureHotKeys>.fromOpaque(context).takeUnretainedValue()
          guard let action = owner.actions[id.id] else { return OSStatus(eventNotHandledErr) }
          owner.onAction(action)
          return noErr
        }
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    guard status == noErr else {
      clear()
      return false
    }
    for action in CaptureRequest.Action.allCases {
      guard let binding = bindings[action] else { continue }
      var reference: EventHotKeyRef?
      Self.nextID &+= 1
      let id = EventHotKeyID(signature: 0x5843_4150, id: Self.nextID)
      actions[id.id] = action
      if RegisterEventHotKey(
        UInt32(binding.code), binding.carbon, id, GetApplicationEventTarget(),
        UInt32(kEventHotKeyExclusive), &reference) == noErr, let reference
      {
        keys.append(reference)
      } else {
        clear()
        return false
      }
    }
    return true
  }
  func clear() {
    for key in keys { UnregisterEventHotKey(key) }
    keys.removeAll()
    if let handler { RemoveEventHandler(handler) }
    handler = nil
    actions.removeAll()
  }
  isolated deinit { clear() }
}

struct CaptureShortcutRecorder: NSViewRepresentable {
  let value: CaptureHotKey?
  var onChange: (CaptureHotKey?) -> Void
  var onRecordingChanged: (Bool) -> Void = { _ in }
  func makeNSView(context: Context) -> ShortcutButton { ShortcutButton() }
  func updateNSView(_ view: ShortcutButton, context: Context) {
    view.binding = value
    view.onChange = onChange
    view.onRecordingChanged = onRecordingChanged
    if !view.recording { view.title = value?.display ?? tr("设置快捷键") }
  }
  static func dismantleNSView(_ view: ShortcutButton, coordinator: ()) {
    view.finishRecording()
    view.onChange = { _ in }
    view.onRecordingChanged = { _ in }
  }
}

@MainActor final class ShortcutButton: NSButton {
  var binding: CaptureHotKey?
  var onChange: (CaptureHotKey?) -> Void = { _ in }
  var onRecordingChanged: (Bool) -> Void = { _ in }
  var recording = false
  private var windowObserver: NSObjectProtocol?
  override init(frame: NSRect) {
    super.init(frame: frame)
    bezelStyle = .rounded
    target = self
    action = #selector(record)
  }
  convenience init() { self.init(frame: .zero) }
  required init?(coder: NSCoder) { fatalError() }
  override var acceptsFirstResponder: Bool { true }
  @objc private func record() {
    guard !recording, window?.makeFirstResponder(self) == true else { return }
    recording = true
    title = tr("按下快捷键，Esc 取消")
    onRecordingChanged(true)
  }
  func finishRecording() {
    guard recording else { return }
    recording = false
    title = binding?.display ?? tr("设置快捷键")
    onRecordingChanged(false)
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    finishRecording()
    if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    windowObserver = nil
    super.viewWillMove(toWindow: newWindow)
    guard let newWindow else { return }
    windowObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didResignKeyNotification,
      object: newWindow, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.finishRecording() }
    }
  }
  isolated deinit {
    if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard recording, window?.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
    keyDown(with: event)
    return true
  }
  override func keyDown(with event: NSEvent) {
    guard recording else {
      super.keyDown(with: event)
      return
    }
    if event.keyCode == 53 {
      finishRecording()
      return
    }
    if event.keyCode == 51 {
      finishRecording()
      onChange(nil)
      title = binding?.display ?? tr("设置快捷键")
      return
    }
    let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
    guard !flags.intersection([.control, .option, .command]).isEmpty else { return }
    let key = CaptureHotKey(
      code: event.keyCode, modifiers: flags.rawValue,
      characters: event.charactersIgnoringModifiers ?? "")
    finishRecording()
    onChange(key)
    title = binding?.display ?? tr("设置快捷键")
  }
  override func resignFirstResponder() -> Bool {
    finishRecording()
    return super.resignFirstResponder()
  }
}
