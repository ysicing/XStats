// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Vision
import os

/// One on-demand, cancellable recognition. Recognized text never leaves this operation.
public final class SensitiveTextDetector: Sendable {
  // VNRequest is confined to the worker except for its thread-safe cancellation method.
  private struct State {
    var request: VNRecognizeTextRequest?
    var cancelled = false
  }
  private let state = OSAllocatedUnfairLock(uncheckedState: State())
  public init() {}
  public func cancel() {
    state.withLockUnchecked { state in
      state.cancelled = true
      state.request?.cancel()
    }
  }
  /// Returns original-image pixel coordinates with a top-left origin, limited to the current crop.
  public func regions(in image: CGImage, crop: CGRect) throws -> [CGRect] {
    try Task.checkCancellation()
    let crop = crop.integral.intersection(
      CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard !crop.isNull, let cropped = image.cropping(to: crop) else {
      throw CaptureError.invalidRegion
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let languages = try request.supportedRecognitionLanguages()
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { languages.contains($0) }
    let cancelled = state.withLockUnchecked { state in
      guard !state.cancelled else { return true }
      state.request = request
      return false
    }
    guard !cancelled else { throw CancellationError() }
    defer { state.withLockUnchecked { $0.request = nil } }
    try VNImageRequestHandler(cgImage: cropped).perform([request])
    try Task.checkCancellation()
    guard !state.withLockUnchecked({ $0.cancelled }) else { throw CancellationError() }
    var regions: [CGRect] = []
    for observation in request.results ?? [] {
      try Task.checkCancellation()
      guard let text = observation.topCandidates(1).first else { continue }
      // Do not reject low confidence: a plausible sensitive value still needs covering.
      for range in Self.ranges(in: text.string) {
        let normalized = try text.boundingBox(for: range)?.boundingBox ?? observation.boundingBox
        let rect = CGRect(
          x: crop.minX + normalized.minX * crop.width,
          y: crop.minY + (1 - normalized.maxY) * crop.height,
          width: normalized.width * crop.width, height: normalized.height * crop.height)
        let padding = max(3, rect.height * 0.15)
        let padded = rect.insetBy(dx: -padding, dy: -padding).integral.intersection(crop)
        if !padded.isNull, padded.width >= 2, padded.height >= 2 { regions.append(padded) }
        guard regions.count < 1000 else { throw DetectionError.tooManyMatches }
      }
    }
    return regions
  }
  public enum DetectionError: Error { case tooManyMatches }

  // Fixed patterns have bounded repetition; ranges are kept in the OCR string's UTF-16 coordinates.
  private static let email = try! NSRegularExpression(
    pattern:
      #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?\.[A-Za-z]{2,24}"#
  )
  private static let phone = try! NSRegularExpression(
    pattern:
      #"(?<![A-Za-z0-9])(?:(?:\+?86[ -]?)?1[3-9][0-9](?:[ -]?[0-9]){8}|\+[1-9][0-9]{0,2}(?:[ -]?[0-9]){7,12})(?![A-Za-z0-9])"#
  )
  private static let identity = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9])[1-9][0-9]{16}[0-9Xx](?![A-Za-z0-9])"#)
  private static let card = try! NSRegularExpression(
    pattern: #"(?<![A-Za-z0-9])[0-9](?:[ -]?[0-9]){12,18}(?![A-Za-z0-9])"#)
  static func ranges(in text: String) -> [Range<String.Index>] {
    let full = NSRange(text.startIndex..<text.endIndex, in: text)
    var ranges: [NSRange] = []
    for pattern in [email, phone, identity, card] {
      for match in pattern.matches(in: text, range: full) {
        guard let range = Range(match.range, in: text) else { continue }
        let value = String(text[range])
        if pattern === identity, !validIdentity(value) { continue }
        if pattern === card {
          // OCR often joins a grouped card and a following CVV into one candidate.
          // Retain the entire candidate if it has a valid card prefix, covering the joined digits too.
          if !validCard(value) {
            let groups = value.split(whereSeparator: { $0 == " " || $0 == "-" })
            guard groups.count > 1, let last = groups.last, (3...4).contains(last.count),
              validCard(groups.dropLast().joined())
            else { continue }
          }
        }
        if pattern === phone, value.hasPrefix("+"), value.filter(\.isNumber).count > 15 { continue }
        ranges.append(match.range)
      }
    }
    // A number may match more than one type; cover the union only once.
    let sorted = ranges.sorted {
      $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location
    }
    var merged: [NSRange] = []
    for range in sorted {
      if let last = merged.last, NSMaxRange(last) > range.location {
        merged[merged.count - 1] = NSUnionRange(last, range)
      } else {
        merged.append(range)
      }
    }
    return merged.compactMap { Range($0, in: text) }
  }
  private static func validCard(_ value: String) -> Bool {
    let digits = value.compactMap(\.wholeNumberValue)
    guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
    let sum = digits.reversed().enumerated().reduce(0) { sum, pair in
      let digit = pair.offset.isMultiple(of: 2) ? pair.element : pair.element * 2
      return sum + (digit > 9 ? digit - 9 : digit)
    }
    return sum.isMultiple(of: 10)
  }
  private static func validIdentity(_ value: String) -> Bool {
    let chars = Array(value.uppercased())
    guard chars.count == 18 else { return false }
    let digits = chars.prefix(17).compactMap(\.wholeNumberValue)
    guard digits.count == 17 else { return false }
    let year = digits[6] * 1000 + digits[7] * 100 + digits[8] * 10 + digits[9]
    let month = digits[10] * 10 + digits[11]
    let day = digits[12] * 10 + digits[13]
    let calendar = Calendar(identifier: .gregorian)
    let parts = DateComponents(year: year, month: month, day: day)
    guard (1800...2099).contains(year), let date = calendar.date(from: parts),
      calendar.dateComponents([.year, .month, .day], from: date) == parts
    else { return false }
    let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
    let checksum = zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 } % 11
    return chars[17] == Array("10X98765432")[checksum]
  }
}
