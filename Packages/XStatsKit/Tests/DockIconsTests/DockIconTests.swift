// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
@testable import DockIcons

@MainActor struct DockIconTests {
  @Test func missingHostResourcesDoNotFallBackToSharedArtwork() {
    for product in DockIconProduct.allCases {
      #expect(DockIconRenderer.mascot(for: product) == nil)
    }
  }

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
    let resources = try resourceBundle(products: [product])
    defer { try? FileManager.default.removeItem(at: resources.directory) }
    let image = try #require(DockIconRenderer.mascot(for: product, in: resources.bundle))
    #expect(DockIconRenderer.mascot(for: product, in: resources.bundle) === image)
    for other in DockIconProduct.allCases where other != product {
      #expect(DockIconRenderer.mascot(for: other, in: resources.bundle) == nil)
    }
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
      let resources = try resourceBundle(products: [$0])
      defer { try? FileManager.default.removeItem(at: resources.directory) }
      return try #require(
        DockIconRenderer.mascot(for: $0, in: resources.bundle)?.tiffRepresentation)
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

  @Test func standardIconReadsBundleResourceWithoutCreatingCustomIconMetadata() throws {
    let resources = try resourceBundle(products: [.xstats], iconFile: "xstats.png")
    defer { try? FileManager.default.removeItem(at: resources.directory) }
    let imageURL = resources.directory.appending(path: "Contents/Resources/xstats.png")
    let original = try Data(contentsOf: imageURL)
    let expected = try #require(NSImage(contentsOf: imageURL))
    let image = try #require(SystemAppIcon(bundle: resources.bundle).standardImage)
    #expect(image.size == expected.size)
    #expect(try Data(contentsOf: imageURL) == original)
    #expect(
      !FileManager.default.fileExists(atPath: resources.directory.appending(path: "Icon\r").path))
  }

  @Test func missingStandardIconDoesNotLoadCustomizedWorkspaceArtwork() throws {
    let resources = try resourceBundle(products: [])
    defer { try? FileManager.default.removeItem(at: resources.directory) }
    #expect(SystemAppIcon(bundle: resources.bundle).standardImage == nil)
  }

  private func resourceBundle(products: [DockIconProduct], iconFile: String? = nil) throws -> (
    bundle: Bundle, directory: URL
  ) {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "DockIconTests.\(UUID()).bundle")
    let resources = directory.appending(path: "Contents/Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    do {
      var info = ["CFBundleIdentifier": "DockIconTests.\(UUID())", "CFBundlePackageType": "BNDL"]
      info["CFBundleIconFile"] = iconFile
      let data = try PropertyListSerialization.data(
        fromPropertyList: info, format: .xml, options: 0)
      try data.write(to: directory.appending(path: "Contents/Info.plist"))
      let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources/DockIcons/Resources")
      for product in products {
        let name = "\(product.rawValue).png"
        try FileManager.default.copyItem(
          at: source.appending(path: name), to: resources.appending(path: name))
      }
      return (try #require(Bundle(url: directory)), directory)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }
}
