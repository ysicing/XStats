// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import XStatsUI

private final class VolumeScrollEvent: NSEvent {
  var target: NSWindow?
  var point = NSPoint(x: 100, y: 12)
  var horizontal = 0.0
  var vertical = 1.0
  var momentum: NSEvent.Phase = []
  var flags: NSEvent.ModifierFlags = []
  override var window: NSWindow? { target }
  override var locationInWindow: NSPoint { point }
  override var scrollingDeltaX: CGFloat { horizontal }
  override var scrollingDeltaY: CGFloat { vertical }
  override var hasPreciseScrollingDeltas: Bool { false }
  override var isDirectionInvertedFromDevice: Bool { false }
  override var momentumPhase: NSEvent.Phase { momentum }
  override var modifierFlags: NSEvent.ModifierFlags { flags }
}

@MainActor
struct AudioVolumeScrollTests {
  @Test func mouseAndTrackpadUseDifferentStepsAndNormalizeNaturalScrolling() {
    #expect(AudioVolumeScrollAdjustment.delta(x: 0, y: 1, precise: false, inverted: false) == 0.02)
    #expect(AudioVolumeScrollAdjustment.delta(x: 0, y: 1, precise: true, inverted: false) == 0.002)
    #expect(AudioVolumeScrollAdjustment.delta(x: 0, y: -10, precise: true, inverted: true) == 0.02)
    #expect(
      AudioVolumeScrollAdjustment.delta(x: 0, y: -1, precise: false, inverted: false) == -0.02)
    #expect(AudioVolumeScrollAdjustment.delta(x: 0, y: 1000, precise: true, inverted: false) == 0.1)
  }

  @Test func horizontalEmptyAndInvalidScrollingCannotChangeVolume() {
    #expect(AudioVolumeScrollAdjustment.delta(x: 2, y: 1, precise: true, inverted: false) == nil)
    #expect(AudioVolumeScrollAdjustment.delta(x: 0, y: 0, precise: false, inverted: false) == nil)
    #expect(AudioVolumeScrollAdjustment.delta(x: 0, y: .nan, precise: true, inverted: false) == nil)
    #expect(
      AudioVolumeScrollAdjustment.delta(x: .infinity, y: 1, precise: false, inverted: false) == nil)
  }

  @Test func rapidScrollsKeepTheLatestDraftWhileOldWritesFinish() {
    var draft = AudioDeviceVolumeDraft()
    draft.beginEditing()
    draft.update(0.52)
    let old = draft.endEditing()
    draft.beginEditing()
    draft.update((draft.value ?? 0.5) + 0.02)
    let latest = draft.endEditing()
    draft.readbackChanged()
    let oldCompleted = draft.complete(old)
    #expect(!oldCompleted)
    #expect(draft.value == 0.54)
    let latestCompleted = draft.complete(latest)
    #expect(latestCompleted)
    #expect(draft.value == nil)
  }

  @Test func scrollOverlayLeavesNativeMouseInteractionAvailable() {
    let view = AudioVolumeScroll.ScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    #expect(view.hitTest(NSPoint(x: 100, y: 12)) == nil)
    view.stop()
    view.stop()
  }

  @Test func scrollingIsScopedToTheVisibleSliderAndDropsMomentumAndModifiedGestures() {
    _ = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = AudioVolumeScroll.ScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
    window.contentView?.addSubview(view)
    view.enabled = true
    var changes: [Double] = []
    view.adjust = { changes.append($0) }
    let event = VolumeScrollEvent()
    event.target = window
    #expect(view.isMonitoring)
    #expect(view.handle(event))
    #expect(changes == [0.02])
    event.momentum = .changed
    #expect(view.handle(event))
    #expect(changes == [0.02])
    event.momentum = []
    event.point = NSPoint(x: 250, y: 12)
    let outsideHandled = view.handle(event)
    #expect(!outsideHandled)
    event.point = NSPoint(x: 100, y: 12)
    event.flags = .command
    #expect(!view.handle(event))
    event.flags = []
    event.horizontal = 2
    #expect(!view.handle(event))
    event.horizontal = 0
    view.isHidden = true
    #expect(!view.handle(event))
    view.isHidden = false
    view.enabled = false
    #expect(!view.handle(event))
    view.enabled = true
    event.target = nil
    #expect(!view.handle(event))
    #expect(changes == [0.02])
    view.removeFromSuperview()
    #expect(!view.isMonitoring)
    view.stop()
    #expect(!view.isMonitoring)
  }
}
