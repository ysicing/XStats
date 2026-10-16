// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics

public enum CaptureGeometry {
  public struct Region: Sendable {
    public let sourceRect: CGRect
    public let pixelSize: CGSize
  }
  /// AppKit global coordinates are bottom-up; ScreenCaptureKit source rectangles are top-down display-local points.
  public static func region(_ selection: CGRect, in display: CGRect, scale: CGFloat) throws
    -> Region
  {
    guard scale.isFinite, scale > 0, !selection.isNull, !selection.isInfinite else {
      throw CaptureError.invalidRegion
    }
    let rect = selection.standardized.intersection(display)
    guard rect.width >= 2, rect.height >= 2 else { throw CaptureError.invalidRegion }
    let source = CGRect(
      x: rect.minX - display.minX, y: display.maxY - rect.maxY, width: rect.width,
      height: rect.height)
    return Region(
      sourceRect: source,
      pixelSize: CGSize(
        width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded()))
  }
  /// Quartz uses a top-left origin anchored to the primary display.
  public static func appKitFrame(_ quartzFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(
      x: quartzFrame.minX, y: primaryHeight - quartzFrame.maxY, width: quartzFrame.width,
      height: quartzFrame.height)
  }
  public static func recordingSize(_ original: CGSize) -> CGSize {
    let ratio = min(1, 3840 / max(2, original.width, original.height))
    return CGSize(
      width: max(2, floor(original.width * ratio / 2) * 2),
      height: max(2, floor(original.height * ratio / 2) * 2))
  }
}
