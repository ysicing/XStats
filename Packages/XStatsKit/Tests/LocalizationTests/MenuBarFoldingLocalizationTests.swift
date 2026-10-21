// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct MenuBarFoldingLocalizationTests {
  @Test func accessAndRecoveryInstructionsHaveExplicitTranslations() throws {
    let keys = [
      "管理应用…", "授权菜单栏应用列表", "授权访问",
      "请选择 group.com.apple.controlcenter.plist，仅授权此文件，用于隐藏和恢复所选应用。",
      "无法读取菜单栏应用列表，请重新授权该文件。",
      "菜单栏应用尚未恢复，请重试恢复后退出。",
      "无法读取或更新菜单栏应用列表，请授权后重试；也可在系统设置中恢复显示。",
      "选择要隐藏的应用，点击菜单栏箭头收起或展开。同一应用的图标会一起变化。",
      "首次使用需授权访问菜单栏应用列表；仅访问选定文件，无需屏幕录制。",
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys {
        #expect(table.sourceKeys.contains(key), "\(language): \(key)")
        #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
      }
    }
  }
}
