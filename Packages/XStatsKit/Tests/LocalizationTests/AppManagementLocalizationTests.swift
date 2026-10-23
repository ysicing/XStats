// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct AppManagementLocalizationTests {
  @Test func uninstallScanStagesAndMeasuredCountsHaveExplicitTranslations() throws {
    let sources = [
      "正在核对应用身份…", "正在核对其他安装副本…", "正在统计大小（2 / 12）…", "待统计",
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in sources {
        let translated = try #require(table.translate(source), "\(language): \(source)")
        #expect(translated != source && !translated.isEmpty)
        if source.contains("12") {
          #expect(translated.contains("2") && translated.contains("12"))
          #expect(!translated.contains("{}"))
        }
      }
    }
  }

  @Test func appManagementTextExistsInEverySupportedCatalog() throws {
    let sources =
      (Translations.applicationManagementEnglish + "\n" + Translations.appServicesEnglish).split(
        separator: "\n"
      ).compactMap {
        line -> String? in
        guard let separator = line.firstIndex(of: "\t") else { return nil }
        return String(line[..<separator])
      }
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in sources { #expect(table.translate(source) != nil, "\(language): \(source)") }
    }
  }
  @Test func cleanupConfirmationHasExplicitTranslations() throws {
    let keys = [
      "永久删除所选项目？", "将所选项目移到废纸篓？", "确认清理所选项目？", "永久删除", "移到废纸篓",
      "将永久删除 4 个所选项目，共 714 MB。此操作无法撤销。",
      "将把 4 个所选项目移到废纸篓，共 714 MB。需要时可从废纸篓放回。",
      "将永久删除废纸篓中选中的 4 个项目，共 714 MB。此操作无法撤销。",
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys {
        let text = try #require(table.translate(key), "\(language): \(key)")
        #expect(!text.isEmpty && text != key)
        if key.contains("714 MB") { #expect(text.contains("714 MB") && text.contains("4")) }
      }
    }
  }

}
