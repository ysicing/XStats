// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct NetworkPresentationLocalizationTests {
  @Test func wirelessDetailsAndOrderingHaveExplicitTranslations() throws {
    let keys = [
      "自定义弹窗内容", "选择各指标弹窗显示的内容，并调整排列顺序。", "弹窗内容", "恢复默认顺序", "拖动以调整顺序", "已显示 {} / {} 项", "链路速率",
      "频段 / 信道", "无线详情", "接入点地址",
      "信道宽度", "无线协议", "安全方式", "噪声", "信噪比", "开放网络", "已展开", "已收起",
      "系统未提供网络名称或接入点地址，可能受定位权限限制。", "无线链路协商速率，不代表实际下载速度。",
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
