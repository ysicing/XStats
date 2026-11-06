// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
import DockIcons

@MainActor struct DockIconTests {
  @Test func preferencesUseProductDefaultsAndIgnoreUnknownValues() throws {
    let suite = "DockIconTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(DockIconStyle.load(from: defaults) == .standard)
    #expect(DockIconStyle.load(from: defaults, fallback: .automatic) == .automatic)
    defaults.set(DockIconStyle.mascot.rawValue, forKey: DockIconStyle.preferenceKey)
    #expect(DockIconStyle.load(from: defaults) == .mascot)
    defaults.set("future-style", forKey: DockIconStyle.preferenceKey)
    #expect(DockIconStyle.load(from: defaults) == .standard)
  }

  @Test(arguments: DockIconProduct.allCases)
  func mascotResourcesHaveTransparentMarginsAndReadableWhiteTiles(product: DockIconProduct) throws {
    let image = try #require(DockIconRenderer.mascot(for: product))
    #expect(DockIconRenderer.mascot(for: product) === image)
    #expect(image.size == NSSize(width: 512, height: 512))
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
    let middle = try #require(
      bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
    #expect(middle.alphaComponent == 1)
    let tile = try #require(
      bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh * 7 / 100)?
        .usingColorSpace(.deviceRGB))
    #expect(tile.alphaComponent == 1)
    #expect(tile.redComponent > 0.9 && tile.greenComponent > 0.9 && tile.blueComponent > 0.9)
  }

  @Test func eachProductUsesDifferentArtwork() throws {
    let images = try DockIconProduct.allCases.map {
      try #require(DockIconRenderer.mascot(for: $0)?.tiffRepresentation)
    }
    #expect(Set(images).count == DockIconProduct.allCases.count)
  }
}
