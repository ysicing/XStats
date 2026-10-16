// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import CoreGraphics

public enum MosaicSize: Int, CaseIterable, Sendable, Identifiable {
  case fine = 12
  case medium = 24
  case coarse = 48
  public var id: Int { rawValue }
}

/// Small, immutable source images shared by all masks and the interactive canvas.
/// The grid is anchored to the original image, so cropping and overlapping masks stay consistent.
public struct ImageMosaics: Sendable {
  private let images: [MosaicSize: CGImage]
  private let imageSize: CGSize
  public init(image: CGImage) throws {
    imageSize = CGSize(width: image.width, height: image.height)
    var images: [MosaicSize: CGImage] = [:]
    for size in MosaicSize.allCases {
      try Task.checkCancellation()
      let block = size.rawValue
      let width = max(1, (image.width + block - 1) / block)
      let height = max(1, (image.height + block - 1) / block)
      guard
        let context = CGContext(
          data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else {
        throw CaptureError.captureFailed
      }
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      guard let result = context.makeImage() else { throw CaptureError.captureFailed }
      images[size] = result
    }
    self.images = images
  }
  func draw(in context: CGContext, rect: CGRect, size: MosaicSize) {
    guard let image = images[size] else { return }
    context.clip(to: rect.integral)
    context.interpolationQuality = .none
    context.translateBy(x: 0, y: imageSize.height)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: imageSize))
  }
}
