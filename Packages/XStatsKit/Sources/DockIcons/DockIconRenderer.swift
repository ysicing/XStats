// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import UniformTypeIdentifiers

@MainActor public enum DockIconRenderer {
  private static var mascots: [DockIconProduct: NSImage] = [:]
  private static let systemIcon = SystemAppIcon(bundle: .main)
  public static let standardIcon =
    systemIcon.standardImage ?? NSWorkspace.shared.icon(for: .applicationBundle)

  public static func mascot(for product: DockIconProduct) -> NSImage? {
    if let image = mascots[product] { return image }
    guard let url = Bundle.module.url(forResource: product.rawValue, withExtension: "png"),
      let artwork = NSImage(contentsOf: url)
    else { return nil }
    let image = DockIconCanvas.image(artwork: artwork, hasPaperBackground: true)
    mascots[product] = image
    return image
  }

  public static func apply(_ style: DockIconStyle, product: DockIconProduct) {
    synchronizeSystemIcon(style, product: product)
    NSApp.applicationIconImage = style == .mascot ? mascot(for: product) : standardIcon
  }

  public static func synchronizeSystemIcon(_ style: DockIconStyle, product: DockIconProduct) {
    guard Bundle.main.bundleIdentifier == product.bundleIdentifier else { return }
    systemIcon.apply(style, mascot: style == .mascot ? mascot(for: product) : nil)
  }
}
