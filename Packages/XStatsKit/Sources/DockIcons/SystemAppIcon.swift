// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import OSLog

@MainActor final class SystemAppIcon {
  private let bundle: Bundle
  private let setIcon: (NSImage?, String) -> Bool
  private var lastAttempt: (style: DockIconStyle, succeeded: Bool)?
  private let logger = Logger(subsystem: "work.12306.xstats", category: "ApplicationIcon")

  init(
    bundle: Bundle,
    setIcon: @escaping (NSImage?, String) -> Bool = {
      NSWorkspace.shared.setIcon($0, forFile: $1, options: [])
    }
  ) {
    self.bundle = bundle
    self.setIcon = setIcon
  }

  var standardImage: NSImage? {
    guard let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else {
      return nil
    }
    let file = name as NSString
    let url = bundle.url(
      forResource: file.deletingPathExtension,
      withExtension: file.pathExtension.isEmpty ? "icns" : file.pathExtension)
    return url.flatMap(NSImage.init(contentsOf:))
  }

  @discardableResult
  func apply(_ style: DockIconStyle, mascot: NSImage?) -> Bool {
    let style: DockIconStyle = style == .mascot ? .mascot : .standard
    if let lastAttempt, lastAttempt.style == style { return lastAttempt.succeeded }
    guard style != .mascot || mascot != nil else { return false }
    let succeeded = setIcon(style == .mascot ? mascot : nil, bundle.bundlePath)
    lastAttempt = (style, succeeded)
    if !succeeded {
      logger.error("Failed to update system application icon: \(style.rawValue, privacy: .public)")
    }
    return succeeded
  }
}
