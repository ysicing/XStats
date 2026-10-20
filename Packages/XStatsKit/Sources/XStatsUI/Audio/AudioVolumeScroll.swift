// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

enum AudioVolumeScrollAdjustment {
  static func delta(x: Double, y: Double, precise: Bool, inverted: Bool) -> Double? {
    guard x.isFinite, y.isFinite, abs(y) > abs(x) else { return nil }
    let amount = y * (inverted ? -1 : 1) * (precise ? 0.002 : 0.02)
    return min(0.1, max(-0.1, amount))
  }
}

/// 透明视图只界定滑杆的滚轮区域；点击和拖动继续交给原生 Slider。
struct AudioVolumeScroll: NSViewRepresentable {
  var enabled: Bool
  let adjust: (Double) -> Void

  func makeNSView(context: Context) -> ScrollView { ScrollView() }
  func updateNSView(_ view: ScrollView, context: Context) {
    view.enabled = enabled
    view.adjust = adjust
  }
  static func dismantleNSView(_ view: ScrollView, coordinator: ()) { view.stop() }

  final class ScrollView: NSView {
    var enabled = false
    var adjust: ((Double) -> Void)?
    private var monitor: Any?
    var isMonitoring: Bool { monitor != nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stop()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        self?.handle(event) == true ? nil : event
      }
    }

    func handle(_ event: NSEvent) -> Bool {
      guard enabled, let window, event.window === window, window.attachedSheet == nil,
        !isHiddenOrHasHiddenAncestor,
        event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
        // AppKit 在不裁剪子视图时可能返回超出 bounds 的 visibleRect。
        bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil))
      else { return false }
      guard
        let delta = AudioVolumeScrollAdjustment.delta(
          x: event.scrollingDeltaX, y: event.scrollingDeltaY,
          precise: event.hasPreciseScrollingDeltas, inverted: event.isDirectionInvertedFromDevice)
      else { return false }
      // 惯性事件仍留在滑杆区域内消耗，但不继续改变音量或转而滚动整页。
      if event.momentumPhase.isEmpty { adjust?(delta) }
      return true
    }

    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
