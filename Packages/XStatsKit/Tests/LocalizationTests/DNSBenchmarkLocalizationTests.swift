// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct DNSBenchmarkLocalizationTests {
  @Test(arguments: AppLanguage.allCases.filter { $0 != .system && $0 != .chinese })
  func labelsAndWarningsHaveExplicitTranslations(language: AppLanguage) throws {
    let table = try #require(Translations.catalog(for: language))
    for key in [
      "DNS 测试", "测试协议", "测试轮数", "自定义 DNS", "最多添加 8 个自定义 DNS", "系统 DNS",
      "P90 延迟", "失败率", "握手耗时", "解析结果", "疑似 DNS 拦截",
      "普通 DNS 应答可能被沿途接管，相关结果不参与推荐。",
      "检测到代理或 VPN，测试结果受当前路由影响；DoH 也可能经过系统代理。",
      "点击开始测试，比较当前系统与公共 DNS。",
      "先预热，再交错查询；握手单独计时，结果仅保留在窗口中。",
      "开始测试", "测试中 {}/{}", "测试已取消", "测试完成", "没有有效应答",
      "查询超时", "连接失败", "应答无效", "按延迟排序", "按失败率排序", "本次推荐",
      "移除自定义 DNS", "测试未完成，请重试。",
      "首次查询", "普通 DNS 推荐", "点击开始测试，并发比较各家 DNS 的四种协议。",
      "四种协议并发实测；握手单独计时，结果仅保留在窗口中。",
    ] {
      #expect(table.sourceKeys.contains(key), "\(language): \(key)")
      #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
    }
  }
}
