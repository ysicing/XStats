// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// 只处理所属计时窗口的按键，输入控件、弹层和录制中的快捷键保留原生行为。
struct TimerKeyboardShortcuts: NSViewRepresentable {
  let model: AppModel
  var enabled = true
  func makeNSView(context: Context) -> KeyView { KeyView() }
  func updateNSView(_ view: KeyView, context: Context) {
    view.handle = { event in
      guard enabled, model.settings.restEnabled, !model.isRecordingShortcut,
        model.timerShortcutBlockers.isEmpty,
        model.timer.pendingStart == nil, !model.wellness.isEyeRestActive,
        !event.isARepeat
      else { return false }
      switch Self.command(
        keyCode: event.keyCode, modifiers: event.modifierFlags, mode: model.timer.mode)
      {
      case .primary: model.timer.performPrimaryAction()
      case .lap: model.timer.recordLap()
      case nil: return false
      }
      return true
    }
  }
  enum Command { case primary, lap }
  static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, mode: TimerMode)
    -> Command?
  {
    let flags = modifiers.intersection([.command, .option, .control, .shift])
    if keyCode == 49 && flags.isEmpty { return .primary }
    if keyCode == 37 && flags == .command && mode == .stopwatch { return .lap }
    return nil
  }
  static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }

  final class KeyView: NSView {
    var handle: ((NSEvent) -> Bool)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, let window = self.window, event.window === window,
          window.isKeyWindow, window.attachedSheet == nil,
          !(window.firstResponder is NSTextView), !(window.firstResponder is NSControl)
        else { return event }
        return self.handle?(event) == true ? nil : event
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
