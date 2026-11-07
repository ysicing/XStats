// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import UniformTypeIdentifiers

@MainActor public enum DockIconRenderer {
  private static var mascots: [DockIconProduct: (url: URL, image: NSImage)] = [:]
  private static let systemIcon = SystemAppIcon(bundle: .main)
  public static let standardIcon =
    systemIcon.standardImage ?? NSWorkspace.shared.icon(for: .applicationBundle)

  public static func mascot(for product: DockIconProduct, in bundle: Bundle = .main) -> NSImage? {
    guard let url = bundle.url(forResource: product.rawValue, withExtension: "png") else {
      return nil
    }
    if let cached = mascots[product], cached.url == url { return cached.image }
    guard let artwork = NSImage(contentsOf: url) else { return nil }
    let image = DockIconCanvas.image(artwork: artwork, hasPaperBackground: true)
    mascots[product] = (url, image)
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
