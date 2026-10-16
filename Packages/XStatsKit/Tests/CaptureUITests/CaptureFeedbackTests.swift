// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureCore
import Testing
@testable import CaptureUI

@MainActor struct CaptureFeedbackTests {
  @Test func fullWindowPreviewFitsWithoutCroppingOffscreenWindows() {
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
    #expect(
      SelectionWindowPreview.fittedFrame(
        target: CGRect(x: -200, y: -100, width: 1200, height: 800), in: bounds)
        == CGRect(x: 94, y: 96, width: 312, height: 208))
    #expect(
      SelectionWindowPreview.fittedFrame(
        target: CGRect(x: 100, y: 120, width: 200, height: 100), in: bounds)
        == CGRect(x: 100, y: 120, width: 200, height: 100))
  }
  @Test func reselectingDiscardsLateWindowPreview() async throws {
    let preview = SelectionWindowPreview()
    let oldImage = try image(width: 20)
    let newImage = try image(width: 30)
    let (started, signal) = AsyncStream<Void>.makeStream()
    var continuation: CheckedContinuation<CGImage, Never>?
    let oldTask = preview.load {
      await withCheckedContinuation {
        continuation = $0
        signal.yield(())
        signal.finish()
      }
    }
    for await _ in started { break }
    preview.reset()
    let newTask = preview.load { newImage }
    await newTask.value
    continuation?.resume(returning: oldImage)
    await oldTask.value
    #expect(preview.image === newImage)
    #expect(preview.loading == false)
    preview.reset()
    #expect(preview.image == nil)
  }
  @Test func failedWindowPreviewPreservesPermissionRecovery() async {
    let preview = SelectionWindowPreview()
    await preview.load { throw CaptureError.screenPermission }.value
    #expect(preview.image == nil)
    #expect(preview.error == .screenPermission)
    #expect(preview.loading == false)
    preview.reset()
    #expect(preview.error == nil)
  }
  @Test func recordingControlsPreferSpaceOutsideTheCapture() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let target = CGRect(x: 200, y: 250, width: 500, height: 300)
    let frame = RecordingRangeIndicator.controlFrame(
      size: CGSize(width: 260, height: 130), target: target, screens: [screen])
    #expect(frame == CGRect(x: 320, y: 108, width: 260, height: 130))
    #expect(frame.intersects(target) == false)
    let fallback = RecordingRangeIndicator.controlFrame(
      size: CGSize(width: 260, height: 130), target: screen, screens: [screen])
    #expect(screen.contains(fallback))
  }
  @Test func recordingOutlineTracksBoundsAndReleasesItsWindow() throws {
    _ = NSApplication.shared
    let indicator = RecordingRangeIndicator()
    defer { indicator.close() }
    indicator.update(
      frame: CGRect(x: -400, y: 200, width: 300, height: 150), paused: false, visible: true)
    let panel = try #require(indicator.panel)
    #expect(panel.frame == CGRect(x: -403, y: 197, width: 306, height: 156))
    #expect(panel.ignoresMouseEvents)
    #expect(panel.canBecomeKey == false)
    #expect(indicator.windowIDs.contains(CGWindowID(panel.windowNumber)))
    indicator.update(
      frame: CGRect(x: 40, y: 80, width: 500, height: 300), paused: true, visible: true)
    #expect(panel.frame == CGRect(x: 37, y: 77, width: 506, height: 306))
    #expect(indicator.paused)
    indicator.update(
      frame: CGRect(x: 40, y: 80, width: 500, height: 300), paused: true, visible: false)
    #expect(panel.isVisible == false)
    // Hidden indicator IDs stay excluded so reappearing never enters video.
    #expect(indicator.windowIDs.contains(CGWindowID(panel.windowNumber)))
    indicator.close()
    #expect(indicator.panel == nil)
    #expect(indicator.windowIDs.isEmpty)
  }
  @Test func invalidRecordingBoundsCannotLeaveAnOldOutlineVisible() throws {
    let indicator = RecordingRangeIndicator()
    defer { indicator.close() }
    indicator.update(
      frame: CGRect(x: 10, y: 10, width: 300, height: 200), paused: false, visible: true)
    let panel = try #require(indicator.panel)
    indicator.update(frame: .null, paused: false, visible: true)
    #expect(panel.isVisible == false)
  }
  private func image(width: Int) throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
  }
}
