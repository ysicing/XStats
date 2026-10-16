// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import Foundation
import AppKit
import CoreText
@testable import CaptureCore

@Suite struct SensitiveTextTests {
  @Test(arguments: [
    "电话：13812345678", "Phone: +1 202 555 0123", "Email: test.user@example.com",
    "身份证：11010519491231002X", "Card: 4111 1111 1111 1111",
  ]) func findsCommonSensitiveValues(_ text: String) {
    #expect(SensitiveTextDetector.ranges(in: text).count == 1)
  }
  @Test(arguments: [
    "版本 1.3.3", "2026-10-15", "订单号 1234567890123456", "11010519491331002X", "110105194912310021",
    "1111111111111111", "3138123456789", "9876543210987654",
  ])
  func ignoresDatesVersionsAndInvalidChecksums(_ text: String) {
    #expect(SensitiveTextDetector.ranges(in: text).isEmpty)
  }
  @Test func bankCardFollowedBySecurityCodeStillMasksTheCard() {
    let text = "4111 1111" + " 1111 1111 123"
    let values = SensitiveTextDetector.ranges(in: text).map { String(text[$0]) }
    #expect(values.contains { $0.hasPrefix("4111 1111 1111 1111") })
  }
  @Test func preservesRangesWithChineseAndEmojiAndDoesNotMergeAdjacentValues() {
    let text = "🔒 邮箱 test@example.com 电话 13812345678"
    #expect(
      SensitiveTextDetector.ranges(in: text).map { String(text[$0]) } == [
        "test@example.com", "13812345678",
      ])
  }
  @Test func recognizesFourTypesInARealImageAndReturnsOriginalCropCoordinates() async throws {
    let image = try fixture()
    let crop = CGRect(x: 20, y: 20, width: 900, height: 460)
    let regions = try await Task.detached {
      try SensitiveTextDetector().regions(in: image, crop: crop)
    }.value
    #expect(regions.count == 4)
    for y in [80, 180, 280, 380] {
      #expect(regions.contains { $0.contains(CGPoint(x: 150, y: y)) })
    }
    #expect(regions.allSatisfy { crop.contains($0) })
  }
  @Test func cancelledRecognizerDoesNotRunVision() async throws {
    let detector = SensitiveTextDetector()
    detector.cancel()
    let image = try fixture()
    await #expect(throws: CancellationError.self) {
      try await Task.detached {
        try detector.regions(in: image, crop: CGRect(x: 0, y: 0, width: 1000, height: 500))
      }.value
    }
  }
  private func fixture() throws -> CGImage {
    let context = try #require(
      CGContext(
        data: nil, width: 1000, height: 500, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1000, height: 500))
    let values = [
      "138" + "12345678", "test.user@example.com", "110105" + "19491231002X",
      "4111 1111" + " 1111 1111",
    ]
    let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
    for (index, value) in values.enumerated() {
      let string = NSAttributedString(
        string: value,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
            gray: 0, alpha: 1),
        ])
      context.textPosition = CGPoint(x: 60, y: 500 - 90 - index * 100)
      CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    return try #require(context.makeImage())
  }

}
