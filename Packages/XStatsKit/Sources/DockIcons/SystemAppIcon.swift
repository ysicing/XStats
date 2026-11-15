// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit

@MainActor struct SystemAppIcon {
  let bundle: Bundle

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

}
