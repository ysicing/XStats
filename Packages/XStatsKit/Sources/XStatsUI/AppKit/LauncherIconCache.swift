// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// 只缓存实际展示的缩略图，淘汰最久未使用项；元数据校验也由读取触发。
@MainActor
final class LauncherIconCache {
  static let shared = LauncherIconCache()

  private struct Key: Hashable {
    let path: String
    let size: Int
  }

  private struct Entry {
    let image: NSImage
    let signature: [Date?]
    var checked: TimeInterval
    var access: UInt64
  }

  private let capacity: Int
  private let clock: () -> TimeInterval
  private let loader: (URL) -> NSImage
  private var entries: [Key: Entry] = [:]
  private var access: UInt64 = 0

  init(
    capacity: Int = 128,
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    loader: @escaping (URL) -> NSImage = { NSWorkspace.shared.icon(forFile: $0.path) }
  ) {
    self.capacity = max(1, capacity)
    self.clock = clock
    self.loader = loader
  }

  func image(for url: URL, size: CGFloat) -> NSImage {
    let dimension = min(128, max(16, Int(size.rounded())))
    let key = Key(path: url.standardizedFileURL.path, size: dimension)
    let now = clock()
    access &+= 1
    var signature: [Date?]?
    if var entry = entries[key] {
      if now - entry.checked < 30 {
        entry.access = access
        entries[key] = entry
        return entry.image
      }
      signature = resourceSignature(url)
      if signature == entry.signature {
        entry.checked = now
        entry.access = access
        entries[key] = entry
        return entry.image
      }
    }
    let source = loader(url)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    let pixels = dimension * 2
    if let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap)
    {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      context.imageInterpolation = .high
      source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
      NSGraphicsContext.restoreGraphicsState()
      bitmap.size = image.size
      image.addRepresentation(bitmap)
    }
    if entries[key] == nil, entries.count >= capacity,
      let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key
    {
      entries.removeValue(forKey: oldest)
    }
    entries[key] = Entry(
      image: image, signature: signature ?? resourceSignature(url), checked: now, access: access)
    return image
  }

  func invalidate() { entries.removeAll(keepingCapacity: true) }

  private func resourceSignature(_ url: URL) -> [Date?] {
    let contents = url.appendingPathComponent("Contents")
    let info = contents.appendingPathComponent("Info.plist")
    let resources = contents.appendingPathComponent("Resources")
    var urls = [url, info, resources, resources.appendingPathComponent("Assets.car")]
    if let attributes = try? info.resourceValues(forKeys: [.fileSizeKey]),
      let size = attributes.fileSize, size <= 1_048_576,
      let data = try? Data(contentsOf: info),
      let dictionary = try? PropertyListSerialization.propertyList(
        from: data, format: nil) as? [String: Any],
      let name = dictionary["CFBundleIconFile"] as? String,
      !name.contains("/"), !name.isEmpty
    {
      urls.append(
        resources.appendingPathComponent(
          (name as NSString).pathExtension.isEmpty ? name + ".icns" : name))
    }
    return urls.map {
      var fresh = $0
      fresh.removeAllCachedResourceValues()
      return try? fresh.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
    }
  }
}
