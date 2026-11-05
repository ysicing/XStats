// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import CoreImage
import ImageIO
import Security

enum LaunchpadWallpaper {
  static func image(at url: URL) throws -> CGImage? {
    try Task.checkCancellation()
    guard url.isFileURL,
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 200_000_000,
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 1536,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    try Task.checkCancellation()
    let original = CIImage(cgImage: thumbnail)
    let blurred = original.clampedToExtent().applyingFilter(
      "CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
    return CIContext(options: [.cacheIntermediates: false]).createCGImage(
      blurred, from: original.extent)
  }
}

enum LaunchpadApplicationRemoval {
  static func isCandidate(_ url: URL) -> Bool {
    let path = url.standardizedFileURL.path
    guard url.isFileURL, url.pathExtension == "app",
      url.resolvingSymlinksInPath().standardizedFileURL.path == path,
      path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"),
      path != Bundle.main.bundleURL.standardizedFileURL.path,
      !path.dropLast(4).contains(".app/")
    else { return false }
    return FileManager.default.fileExists(
      atPath: url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
  }

  static func trash(_ url: URL) throws {
    guard isCandidate(url) else { throw CocoaError(.fileWriteNoPermission) }
    try validateAppStoreSignature(url)
    try Task.checkCancellation()
    guard isCandidate(url) else { throw CocoaError(.fileWriteNoPermission) }
    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
  }

  static func validateAppStoreSignature(_ url: URL) throws {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    let rule = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
      SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
      let code, let requirement,
      SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess
    else { throw CocoaError(.fileWriteNoPermission) }
  }
}
