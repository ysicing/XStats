// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit

@main
struct RenderDockIcon {
  @MainActor static func main() throws {
    guard CommandLine.arguments.count == 3,
      let artwork = NSImage(contentsOfFile: CommandLine.arguments[1])
    else { fatalError("用法：render_dock_icon <透明品牌 PNG> <AppIcon.appiconset>") }
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let icon = DockIconCanvas.image(artwork: artwork)
    for points in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!
          .write(to: directory.appendingPathComponent(filename))
      }
    }
  }
}
