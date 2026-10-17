// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

/// 刻度只负责选择已有时长，不持有计时状态，也不增加刷新定时器。
struct TimerDurationRuler: NSViewRepresentable {
  @Binding var minutes: Int
  var options: [Int]
  var label: String
  var hasPartialMinute = false
  @Environment(\.isEnabled) private var enabled

  func makeNSView(context: Context) -> TimerRulerControl { TimerRulerControl() }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimerRulerControl, context: Context)
    -> CGSize?
  {
    CGSize(width: proposal.width ?? 240, height: 64)
  }

  func updateNSView(_ view: TimerRulerControl, context: Context) {
    view.options = options
    view.selectedMinutes = max(options.first ?? 1, minutes)
    view.hasPartialMinute = hasPartialMinute
    view.isEnabled = enabled
    view.onSelect = { minutes = $0 }
    view.setAccessibilityLabel(label)
    view.setAccessibilityValueDescription(tr("\(WellnessFormat.number(view.selectedMinutes)) 分钟"))
    view.needsDisplay = true
  }
}

/// 原生滑块保留键盘和辅助功能语义，横向拖动刻度以中央指针选择时长。
final class TimerRulerControl: NSSlider {
  var options: [Int] = Array(1...1439)
  var selectedMinutes = 15
  var hasPartialMinute = false
  var onSelect: ((Int) -> Void)?
  private var dragOrigin: (x: CGFloat, index: Double)?
  private var dragged = false
  private var scrollIndex: Double?
  private var tickSpacing: CGFloat { options.count < 10 ? 44 : 12 }
  // NSSlider 的默认 cell 对齐边距不适用于自绘刻度，会让绘制内容越过 SwiftUI 分配的边界。
  override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
  override var intrinsicContentSize: NSSize { NSSize(width: 240, height: 64) }
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { isEnabled }

  var selectedIndex: Int {
    options.indices.min { abs(options[$0] - selectedMinutes) < abs(options[$1] - selectedMinutes) }
      ?? 0
  }

  func selectIndex(_ index: Double) {
    guard isEnabled, index.isFinite, !options.isEmpty else { return }
    let bounded = Int(min(Double(options.count - 1), max(0, index.rounded())))
    let value = options[bounded]
    guard value != selectedMinutes || hasPartialMinute else { return }
    hasPartialMinute = false
    selectedMinutes = value
    setAccessibilityValueDescription(tr("\(WellnessFormat.number(value)) 分钟"))
    needsDisplay = true
    onSelect?(value)
  }

  override func mouseDown(with event: NSEvent) {
    guard isEnabled else { return }
    window?.makeFirstResponder(self)
    dragOrigin = (convert(event.locationInWindow, from: nil).x, Double(selectedIndex))
    dragged = false
    scrollIndex = nil
  }

  override func mouseDragged(with event: NSEvent) {
    guard let origin = dragOrigin else { return }
    let displacement = convert(event.locationInWindow, from: nil).x - origin.x
    if abs(displacement) > 2 { dragged = true }
    selectIndex(origin.index - Double(displacement / tickSpacing))
  }

  override func mouseUp(with event: NSEvent) {
    if dragOrigin != nil && !dragged {
      let x = convert(event.locationInWindow, from: nil).x
      selectIndex(Double(selectedIndex) + Double((x - bounds.midX) / tickSpacing))
    }
    dragOrigin = nil
  }

  override func scrollWheel(with event: NSEvent) {
    guard isEnabled else { return }
    if event.phase.contains(.began) { scrollIndex = nil }
    let delta =
      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
      ? event.scrollingDeltaX : event.scrollingDeltaY
    let step = event.hasPreciseScrollingDeltas ? Double(delta / tickSpacing) : Double(delta)
    let next = min(
      Double(max(0, options.count - 1)), max(0, (scrollIndex ?? Double(selectedIndex)) - step))
    scrollIndex = next
    selectIndex(next)
    if event.phase.contains(.ended) || event.phase.contains(.cancelled)
      || event.momentumPhase.contains(.ended)
    {
      scrollIndex = nil
    }
  }

  override func keyDown(with event: NSEvent) {
    guard isEnabled, event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
      super.keyDown(with: event)
      return
    }
    scrollIndex = nil
    switch event.keyCode {
    case 123, 125: selectIndex(Double(selectedIndex - 1))
    case 124, 126: selectIndex(Double(selectedIndex + 1))
    case 115: selectIndex(0)
    case 119: selectIndex(Double(options.count - 1))
    default: super.keyDown(with: event)
    }
  }

  override func accessibilityValue() -> Any? { NSNumber(value: selectedMinutes) }
  override func accessibilityMinValue() -> Any? { options.first.map(NSNumber.init(value:)) }
  override func accessibilityMaxValue() -> Any? { options.last.map(NSNumber.init(value:)) }
  override func setAccessibilityValue(_ value: Any?) {
    guard let value = value as? NSNumber, value.doubleValue.isFinite else { return }
    guard
      let index = options.indices.min(by: {
        abs(Double(options[$0]) - value.doubleValue) < abs(Double(options[$1]) - value.doubleValue)
      })
    else { return }
    selectIndex(Double(index))
  }
  override func accessibilityPerformIncrement() -> Bool {
    guard isEnabled else { return false }
    selectIndex(Double(selectedIndex + 1))
    return true
  }
  override func accessibilityPerformDecrement() -> Bool {
    guard isEnabled else { return false }
    selectIndex(Double(selectedIndex - 1))
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard !options.isEmpty else { return }
    let selected = selectedIndex
    let radius = Int(bounds.width / tickSpacing / 2) + 1
    let low = max(0, selected - radius)
    let high = min(options.count - 1, selected + radius)
    for index in low...high {
      let x = bounds.midX + CGFloat(index - selected) * tickSpacing
      let major = options.count < 10 || options[index].isMultiple(of: 5) || index == 0
      let edge = min(1, max(0, min(x, bounds.width - x) / 24))
      let alpha = edge * (index <= selected ? 1 : 0.35) * (isEnabled ? 1 : 0.4)
      let color = NSColor.systemOrange.withAlphaComponent(alpha)
      color.setFill()
      NSBezierPath(
        roundedRect: NSRect(x: x - 1.5, y: major ? 23 : 30, width: 3, height: major ? 27 : 20),
        xRadius: 1.5, yRadius: 1.5
      ).fill()
      if major {
        let title = NSAttributedString(
          string: WellnessFormat.number(options[index]),
          attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color,
          ])
        title.draw(at: NSPoint(x: x - title.size().width / 2, y: 3))
      }
    }
    let marker = NSBezierPath()
    marker.move(to: NSPoint(x: bounds.midX, y: 54))
    marker.line(to: NSPoint(x: bounds.midX - 4, y: 61))
    marker.line(to: NSPoint(x: bounds.midX + 4, y: 61))
    marker.close()
    NSColor.systemOrange.setFill()
    marker.fill()
    if window?.firstResponder === self {
      NSColor.keyboardFocusIndicatorColor.setStroke()
      let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
      ring.lineWidth = 2
      ring.stroke()
    }
  }
}
