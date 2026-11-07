// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
@testable import DockIcons

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

  @Test func paperAndTransparentArtworkHaveTheSameCenteredSizeAndNearWhiteTile() throws {
    for paper in [false, true] {
      let artwork = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { _ in
        if paper {
          NSColor.white.setFill()
          NSRect(x: 0, y: 0, width: 100, height: 100).fill()
        }
        NSColor.blue.setFill()
        NSRect(x: 10, y: 20, width: 80, height: 60).fill()
        return true
      }
      let image = DockIconCanvas.image(artwork: artwork, hasPaperBackground: paper)
      let data = try #require(image.tiffRepresentation)
      let bitmap = try #require(NSBitmapImageRep(data: data))
      #expect(try #require(bitmap.colorAt(x: 32, y: 32)).alphaComponent == 0)
      let background = try #require(
        bitmap.colorAt(x: 256, y: 40)?.usingColorSpace(.deviceRGB))
      #expect(abs(background.redComponent - 252 / 255) < 0.01)
      #expect(abs(background.greenComponent - 253 / 255) < 0.01)
      #expect(background.blueComponent == 1)
      #expect(try #require(bitmap.colorAt(x: 70, y: 256)).redComponent > 0.9)
      #expect(try #require(bitmap.colorAt(x: 80, y: 256)).redComponent < 0.1)
      #expect(try #require(bitmap.colorAt(x: 432, y: 256)).redComponent < 0.1)
      #expect(try #require(bitmap.colorAt(x: 442, y: 256)).redComponent > 0.9)
    }
  }

  @Test func systemIconChangesOnlyWithStaticStyleAndCanRestoreTheDefault() throws {
    var images: [NSImage?] = []
    let icon = SystemAppIcon(bundle: .main) { image, path in
      #expect(path == Bundle.main.bundlePath)
      images.append(image)
      return true
    }
    let mascot = try #require(DockIconRenderer.mascot(for: .xstats))
    #expect(icon.apply(.mascot, mascot: mascot))
    #expect(icon.apply(.mascot, mascot: mascot))
    #expect(images.count == 1)
    #expect(images[0] === mascot)
    #expect(icon.apply(.automatic, mascot: nil))
    #expect(icon.apply(.standard, mascot: nil))
    #expect(images.count == 2)
    #expect(images[1] == nil)
    #expect(icon.apply(.mascot, mascot: mascot))
    #expect(images.count == 3)
  }

  @Test func failedSystemIconWritesDoNotRetryOnEveryMonitoringRefresh() throws {
    var attempts = 0
    let icon = SystemAppIcon(bundle: .main) { _, _ in
      attempts += 1
      return false
    }
    let mascot = try #require(DockIconRenderer.mascot(for: .capture))
    #expect(!icon.apply(.mascot, mascot: nil))
    #expect(attempts == 0)
    #expect(!icon.apply(.mascot, mascot: mascot))
    #expect(!icon.apply(.mascot, mascot: mascot))
    #expect(attempts == 1)
    #expect(!icon.apply(.standard, mascot: nil))
    #expect(attempts == 2)
  }
}
