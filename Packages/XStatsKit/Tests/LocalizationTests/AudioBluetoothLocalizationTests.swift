// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct AudioBluetoothLocalizationTests {
  @Test func trioBluetoothDeviceOptionsHaveExplicitTranslationsInEveryLanguage() throws {
    let keys = [
      "蓝牙设备替换网络图标", "替换图标使用的设备", "仅改变图标，音量仍跟随当前输出；指定设备断开后显示网络图标。",
      "自动跟随音频输出", "所选设备不可用", "蓝牙图标大小",
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys {
        #expect(table.sourceKeys.contains(key), "\(language): \(key)")
        #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
      }
    }
  }

  @Test func audioControlsHaveExplicitTranslationsInEveryLanguage() throws {
    let keys = Translations.audioEnglish.split(separator: "\n").compactMap {
      $0.split(separator: "\t").first.map(String.init)
    }
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys { #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)") }
    }
  }
}
