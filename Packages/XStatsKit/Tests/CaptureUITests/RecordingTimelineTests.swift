// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
import Localization
@testable import CaptureUI

@Suite @MainActor struct RecordingTimelineTests {
  init() { _ = NSApplication.shared }
  @Test func handlesClampWithoutCrossingAndKeepTheOtherEndpoint() {
    let view = RecordingTrimRangeView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
    view.configure(start: 2, end: 8, duration: 10, enabled: true)
    var changes: [(RecordingTrimRangeView.Handle, Double)] = []
    view.onChange = { changes.append(($0, $1)) }
    view.startSlider.doubleValue = 9
    view.sendAction(view.startSlider)
    #expect(abs(view.startSlider.doubleValue - 7.9) < 0.00001)
    #expect(view.endSlider.doubleValue == 8)
    #expect(changes.last?.0 == .start)
    view.endSlider.doubleValue = 0
    view.sendAction(view.endSlider)
    #expect(view.endSlider.doubleValue == 8)
    #expect(changes.last?.0 == .end)
    view.startSlider.doubleValue = -5
    view.sendAction(view.startSlider)
    #expect(view.startSlider.doubleValue == 0)
    view.endSlider.doubleValue = 20
    view.sendAction(view.endSlider)
    #expect(view.endSlider.doubleValue == 10)
  }
  @Test func shortClipsAndDisabledControlsStayValid() {
    let view = RecordingTrimRangeView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
    view.configure(start: 0, end: 0.005, duration: 0.005, enabled: true)
    view.startSlider.doubleValue = 0.005
    view.sendAction(view.startSlider)
    #expect(view.startSlider.doubleValue == 0)
    view.configure(start: 0, end: 1, duration: 1, enabled: false)
    var changed = false
    view.onChange = { _, _ in changed = true }
    view.sendAction(view.startSlider)
    #expect(!changed)
    #expect(!view.startSlider.isEnabled && !view.endSlider.isEnabled)
  }
  @Test func nativeSlidersExposeDistinctAccessibleEndpoints() {
    let view = RecordingTrimRangeView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
    view.configure(start: 0, end: 36.6, duration: 36.6, enabled: true)
    #expect(view.startSlider.cell?.accessibilityRole() == .slider)
    #expect(view.endSlider.cell?.accessibilityRole() == .slider)
    #expect(view.startSlider.cell?.accessibilityLabel() == tr("开始时间"))
    #expect(view.endSlider.cell?.accessibilityLabel() == tr("结束时间"))
    #expect(view.startSlider.cell?.isAccessibilityElement() == true)
    #expect(view.startSlider.cell?.accessibilityMaxValue() as? Double == 36.5)
    #expect(view.endSlider.cell?.accessibilityMinValue() as? Double == 0.1)
    #expect(
      view.endSlider.cell?.accessibilityValueDescription()
        == RecordingTimeText.string(36.6, fractional: true))
    #expect(view.startSlider.nextKeyView === view.endSlider)
  }
  @Test func renderedHandlesCanBeHitIndependentlyInParentCoordinates() throws {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 80))
    let view = RecordingTrimRangeView(frame: NSRect(x: 20, y: 20, width: 600, height: 28))
    container.addSubview(view)
    view.configure(start: 2, end: 8, duration: 10, enabled: true)
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
    container.cacheDisplay(in: container.bounds, to: bitmap)
    let startCell = try #require(view.startSlider.cell as? NSSliderCell)
    let endCell = try #require(view.endSlider.cell as? NSSliderCell)
    let startRect = startCell.knobRect(flipped: false)
    let endRect = endCell.knobRect(flipped: false)
    let start = NSPoint(x: startRect.midX, y: startRect.midY)
    let end = NSPoint(x: endRect.midX, y: endRect.midY)
    #expect(start.x < end.x)
    #expect(view.hitTest(view.convert(start, to: container)) === view.startSlider)
    #expect(view.hitTest(view.convert(end, to: container)) === view.endSlider)
    // 可重复查看的原生渲染工件，避免仅以数值断言代替轨道检查。
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(
      to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
        "xstats-recording-trim-test.png"))
  }
  @Test func timeLabelsKeepMinutesHoursFractionsAndLocale() {
    let english = Locale(identifier: "en")
    #expect(RecordingTimeText.string(0, locale: english) == "00:00")
    #expect(RecordingTimeText.string(65.99, locale: english) == "01:05")
    #expect(RecordingTimeText.string(3661.26, locale: english) == "01:01:01")
    #expect(RecordingTimeText.string(36.69, fractional: true, locale: english) == "00:36.7")
    #expect(
      RecordingTimeText.string(36.6, fractional: true, locale: Locale(identifier: "de")).contains(
        ",6"))
  }
}
