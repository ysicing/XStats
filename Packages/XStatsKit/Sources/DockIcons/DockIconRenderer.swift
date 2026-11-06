// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit

@MainActor public enum DockIconRenderer {
  private static var mascots: [DockIconProduct: NSImage] = [:]
  public static let standardIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

  public static func mascot(for product: DockIconProduct) -> NSImage? {
    if let image = mascots[product] { return image }
    guard let url = Bundle.module.url(forResource: product.rawValue, withExtension: "png"),
      let artwork = NSImage(contentsOf: url)
    else { return nil }
    let image = NSImage(size: NSSize(width: 512, height: 512), flipped: false) { _ in
      let tile = NSRect(x: 32, y: 32, width: 448, height: 448)
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(roundedRect: tile, xRadius: 100, yRadius: 100).addClip()
      NSColor.white.setFill()
      tile.fill()
      NSGraphicsContext.current?.imageInterpolation = .high
      artwork.draw(in: tile)
      NSGraphicsContext.restoreGraphicsState()
      return true
    }
    mascots[product] = image
    return image
  }

  public static func apply(_ style: DockIconStyle, product: DockIconProduct) {
    NSApp.applicationIconImage = style == .mascot ? mascot(for: product) : nil
  }
}
