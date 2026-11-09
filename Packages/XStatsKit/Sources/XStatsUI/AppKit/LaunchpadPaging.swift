// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import QuartzCore

struct LaunchpadPageSwipe {
  var offset: CGFloat = 0
  var velocity: CGFloat = 0
  private var timestamp: TimeInterval?
  var isActive: Bool { timestamp != nil }

  init(offset: CGFloat = 0) { self.offset = offset }

  mutating func update(delta: CGFloat, timestamp: TimeInterval) {
    if let previous = self.timestamp, timestamp > previous {
      let interval = timestamp - previous
      velocity = interval < 0.1 ? velocity * 0.4 + delta / interval * 0.6 : 0
    }
    offset += delta
    self.timestamp = timestamp
  }

  func translation(width: CGFloat, page: Int, count: Int) -> CGFloat {
    let value = min(width, max(-width, offset))
    guard (page == 0 && value > 0) || (page == count - 1 && value < 0) else {
      return value
    }
    return value * 0.55 * width / (width + 0.55 * abs(value))
  }

  func destination(width: CGFloat, page: Int, count: Int, timestamp: TimeInterval) -> Int {
    let releaseVelocity = timestamp - (self.timestamp ?? timestamp) < 0.1 ? velocity : 0
    let projected = offset + releaseVelocity * 0.18
    let threshold = width * 0.2
    let delta = projected < -threshold ? 1 : projected > threshold ? -1 : 0
    return min(max(0, page + delta), max(0, count - 1))
  }
}

@MainActor
final class LaunchpadPagePreview: NSView {
  let strip = CALayer()

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.addSublayer(strip)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { nil }

  func add(_ image: CGImage, delta: Int, size: NSSize) {
    let tile = CALayer()
    tile.frame = NSRect(
      x: CGFloat(delta) * bounds.width, y: bounds.maxY - size.height,
      width: size.width, height: size.height)
    tile.contents = image
    tile.contentsGravity = .resize
    strip.addSublayer(tile)
  }

  var translation: CGFloat {
    if let presentation = strip.presentation() { return presentation.affineTransform().tx }
    if let spring = strip.animation(forKey: "paging") as? CASpringAnimation,
      let start = spring.fromValue as? CGFloat
    {
      return start
    }
    return strip.affineTransform().tx
  }

  func track(_ offset: CGFloat) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    strip.removeAllAnimations()
    strip.setAffineTransform(CGAffineTransform(translationX: offset, y: 0))
    CATransaction.commit()
  }

  func settle(at offset: CGFloat, velocity: CGFloat) {
    let start = translation
    track(offset)
    let spring = CASpringAnimation(keyPath: "transform.translation.x")
    let frequency = 2 * CGFloat.pi / DS.Motion.launchpadResponse
    spring.mass = 1
    spring.stiffness = frequency * frequency
    spring.damping = 2 * frequency
    spring.initialVelocity = velocity
    spring.fromValue = start
    spring.toValue = offset
    spring.duration = spring.settlingDuration
    strip.add(spring, forKey: "paging")
  }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  static func snapshot(_ view: NSView) -> CGImage? {
    view.layoutSubtreeIfNeeded()
    let scale = min(1, 1600 / max(1, max(view.bounds.width, view.bounds.height)))
    guard view.bounds.width > 0, view.bounds.height > 0,
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(ceil(view.bounds.width * scale)),
        pixelsHigh: Int(ceil(view.bounds.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
        bitsPerPixel: 0)
    else { return nil }
    bitmap.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap.cgImage
  }
}

@MainActor
final class LaunchpadFolderBackdrop: NSView {
  var onClose: () -> Void = {}
  override func mouseDown(with event: NSEvent) { onClose() }
}

@MainActor
final class LaunchpadFolderTransition: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
