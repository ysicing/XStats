// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import Localization

enum RecordingTimeText {
  static func string(_ seconds: Double, fractional: Bool = false, locale: Locale = L10n.locale)
    -> String
  {
    let value = seconds.isFinite ? max(0, seconds) : 0
    let pattern: Duration.TimeFormatStyle.Pattern =
      value >= 3600
      ? .hourMinuteSecond(
        padHourToLength: 2, fractionalSecondsLength: fractional ? 1 : 0,
        roundFractionalSeconds: fractional ? .toNearestOrEven : .down)
      : .minuteSecond(
        padMinuteToLength: 2, fractionalSecondsLength: fractional ? 1 : 0,
        roundFractionalSeconds: fractional ? .toNearestOrEven : .down)
    return Duration.seconds(value).formatted(.time(pattern: pattern).locale(locale))
  }
}

struct RecordingTrimSlider: NSViewRepresentable {
  let start: Double
  let end: Double
  let duration: Double
  let enabled: Bool
  let onChange: (RecordingTrimRangeView.Handle, Double) -> Void

  func makeNSView(context: Context) -> RecordingTrimRangeView { RecordingTrimRangeView() }
  func updateNSView(_ view: RecordingTrimRangeView, context: Context) {
    view.onChange = onChange
    view.configure(start: start, end: end, duration: duration, enabled: enabled)
  }
}

/// 共用一条轨道，但保留两个原生 NSSlider 的键盘、焦点与辅助功能行为。
final class RecordingTrimRangeView: NSView {
  enum Handle: Equatable { case start, end }
  let startSlider = RecordingHandleSlider()
  let endSlider = RecordingHandleSlider()
  var onChange: (Handle, Double) -> Void = { _, _ in }
  private var duration = 0.0
  // 与显示精度一致；不足 0.1 秒的片段仍允许保留完整原片。
  private var minimumSpan: Double { min(0.1, duration) }

  override init(frame: NSRect) {
    super.init(frame: frame)
    for slider in [startSlider, endSlider] {
      slider.cell = RecordingHandleCell()
      slider.userInterfaceLayoutDirection = .leftToRight
      slider.isContinuous = true
      slider.altIncrementValue = 1
      slider.target = self
      slider.action = #selector(sendAction(_:))
      addSubview(slider)
    }
    startSlider.nextKeyView = endSlider
    setAccessibilityElement(false)
  }
  required init?(coder: NSCoder) { nil }

  func configure(start: Double, end: Double, duration: Double, enabled: Bool) {
    self.duration = duration.isFinite ? max(0, duration) : 0
    for slider in [startSlider, endSlider] {
      slider.minValue = 0
      slider.maxValue = max(self.duration, 0.001)
      slider.isEnabled = enabled && self.duration > 0
    }
    endSlider.doubleValue = min(self.duration, max(minimumSpan, end))
    startSlider.doubleValue = min(max(0, start), endSlider.doubleValue - minimumSpan)
    startSlider.cell?.setAccessibilityLabel(tr("开始时间"))
    endSlider.cell?.setAccessibilityLabel(tr("结束时间"))
    updateAccessibleBounds()
    needsDisplay = true
  }
  override func layout() {
    super.layout()
    startSlider.frame = bounds
    endSlider.frame = bounds
  }
  @objc func sendAction(_ sender: NSSlider) {
    guard sender.isEnabled else { return }
    let handle: Handle = sender === startSlider ? .start : .end
    if handle == .start {
      startSlider.doubleValue = min(max(0, sender.doubleValue), endSlider.doubleValue - minimumSpan)
    } else {
      endSlider.doubleValue = min(
        duration, max(startSlider.doubleValue + minimumSpan, sender.doubleValue))
    }
    updateAccessibleBounds()
    needsDisplay = true
    onChange(handle, sender.doubleValue)
  }
  private func updateAccessibleBounds() {
    let startCell = startSlider.cell as? RecordingHandleCell
    let endCell = endSlider.cell as? RecordingHandleCell
    startCell?.accessibleMinimum = 0
    startCell?.accessibleMaximum = max(0, endSlider.doubleValue - minimumSpan)
    endCell?.accessibleMinimum = startSlider.doubleValue + minimumSpan
    endCell?.accessibleMaximum = duration
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    guard !isHidden, bounds.contains(local), startSlider.isEnabled else { return nil }
    let startX = knobCenter(startSlider)
    let endX = knobCenter(endSlider)
    // 两端非常接近时，仍可从各自一侧点选；重合点优先保留当前焦点。
    if abs(local.x - startX) == abs(local.x - endX), window?.firstResponder === endSlider {
      return endSlider
    }
    return abs(local.x - startX) <= abs(local.x - endX) ? startSlider : endSlider
  }
  private func knobCenter(_ slider: NSSlider) -> CGFloat {
    (slider.cell as? NSSliderCell)?.knobRect(flipped: isFlipped).midX ?? 0
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let cell = startSlider.cell as? NSSliderCell else { return }
    let inset = cell.knobThickness / 2
    let track = NSRect(
      x: inset, y: bounds.midY - 2, width: max(0, bounds.width - 2 * inset), height: 4)
    NSColor.separatorColor.setFill()
    NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
    let span = max(duration, 0.001)
    let left = track.minX + track.width * startSlider.doubleValue / span
    let right = track.minX + track.width * endSlider.doubleValue / span
    (startSlider.isEnabled ? NSColor.controlAccentColor : NSColor.disabledControlTextColor)
      .setFill()
    NSBezierPath(
      roundedRect: NSRect(x: left, y: track.minY, width: max(0, right - left), height: 4),
      xRadius: 2, yRadius: 2
    ).fill()
  }
}

final class RecordingHandleSlider: NSSlider {
  override func mouseDown(with event: NSEvent) {
    // 双手柄共享轨道，点击后明确聚焦当前端点，方向键应继续调整这一端。
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }
}

private final class RecordingHandleCell: NSSliderCell {
  var accessibleMinimum = 0.0
  var accessibleMaximum = 0.0
  override func accessibilityMinValue() -> Any? { accessibleMinimum }
  override func accessibilityMaxValue() -> Any? { accessibleMaximum }
  override func accessibilityValueDescription() -> String? {
    RecordingTimeText.string(doubleValue, fractional: true)
  }
  override func drawBar(inside rect: NSRect, flipped: Bool) {}
}
