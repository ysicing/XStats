// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing

struct CapturePermissionDisclosureTests {
  @Test(arguments: ["ar", "de", "en", "es", "fr", "ja", "ko", "zh-Hans", "zh-Hant"])
  func bothHostsProvideLocalizedCapturePermissionDisclosures(language: String) throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for host in ["XStats", "Capture"] {
      let resource = root.appendingPathComponent("Apps/\(host)/App/\(language).lproj")
      let bundle = try #require(Bundle(url: resource))
      for key in [
        "NSScreenCaptureUsageDescription", "NSMicrophoneUsageDescription",
        "NSAudioCaptureUsageDescription",
      ] {
        let description = bundle.localizedString(forKey: key, value: "", table: "InfoPlist")
        #expect(
          !description.isEmpty && description != key,
          "\(host) / \(language) must describe \(key) without a fallback")
      }
    }
  }
}
