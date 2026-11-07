// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit

@MainActor public enum DockIconCanvas {
  public static func drawBackground(in bounds: NSRect) {
    let tile = bounds.insetBy(dx: bounds.width / 16, dy: bounds.height / 16)
    NSColor(srgbRed: 252 / 255, green: 253 / 255, blue: 1, alpha: 1).setFill()
    NSBezierPath(
      roundedRect: tile, xRadius: bounds.width * 100 / 512, yRadius: bounds.height * 100 / 512
    ).fill()
  }

  public static func image(artwork: NSImage, hasPaperBackground: Bool = false) -> NSImage {
    let source = artworkBounds(artwork, hasPaperBackground: hasPaperBackground)
    let scale = 368 / max(source.width, source.height)
    let content = NSRect(
      x: (512 - source.width * scale) / 2, y: (512 - source.height * scale) / 2,
      width: source.width * scale, height: source.height * scale)
    return NSImage(size: NSSize(width: 512, height: 512), flipped: false) { _ in
      drawBackground(in: NSRect(x: 0, y: 0, width: 512, height: 512))
      NSGraphicsContext.current?.imageInterpolation = .high
      artwork.draw(
        in: content, from: source,
        operation: hasPaperBackground ? .multiply : .sourceOver, fraction: 1)
      return true
    }
  }

  private static func artworkBounds(_ image: NSImage, hasPaperBackground: Bool) -> NSRect {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return NSRect(origin: .zero, size: image.size)
    }
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    var minX = width
    var minY = height
    var maxX = -1
    var maxY = -1
    pixels.withUnsafeMutableBytes { buffer in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      let rgba = buffer.bindMemory(to: UInt8.self)
      for row in 0..<height {
        for column in 0..<width {
          let offset = row * bytesPerRow + column * 4
          guard rgba[offset + 3] > 32,
            !hasPaperBackground
              || min(rgba[offset], rgba[offset + 1], rgba[offset + 2]) < 220
          else { continue }
          minX = min(minX, column)
          minY = min(minY, row)
          maxX = max(maxX, column)
          maxY = max(maxY, row)
        }
      }
    }
    guard maxX >= minX, maxY >= minY else { return NSRect(origin: .zero, size: image.size) }
    return NSRect(
      x: CGFloat(minX) * image.size.width / CGFloat(width),
      y: CGFloat(height - maxY - 1) * image.size.height / CGFloat(height),
      width: CGFloat(maxX - minX + 1) * image.size.width / CGFloat(width),
      height: CGFloat(maxY - minY + 1) * image.size.height / CGFloat(height))
  }
}
