// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct PortsLocalizationTests {
  @Test func portsPageStringsHaveExplicitTranslations() throws {
    let keys = [
      "端口", "显示位置", "工具侧栏", "网络页面", "两处显示",
      "端口号", "监听", "已建立", "对端", "冲突", "拷贝本地地址", "拷贝对端地址",
      "按进程统计，同一进程的各行速率相同", "搜索端口、进程、服务或地址", "暂时无法读取端口",
      "查看监听端口、已建立的连接及占用进程，可结束占用端口的进程。", "正在读取端口…", "没有匹配的端口",
      "监听 {} · 连接 {}", "端口 {} 同时被多个进程监听", "连接过多，只显示前 {} 项",
      "仅列出当前用户的进程，系统服务占用的端口不会显示",
      "会断开它占用的端口与连接，未保存的内容可能会丢失。强制退出会立即结束，不给应用保存的机会。",
      "结束“{}”（PID {}）？", "进程已退出或不再占用该端口，请刷新后重试", "国际",
      "查看所属进程", "查看应用", "查看运行进程", "拷贝路径", "清除筛选",
      "未找到目标进程，它可能已退出",
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys {
        #expect(table.sourceKeys.contains(key), "\(language): \(key)")
        #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
      }
    }
  }

  /// 运行时拼接的数值通过模板匹配，使用显式语言，不修改全局语言。
  @Test func interpolatedPortMessagesTranslateWithoutChangingGlobalLanguage() {
    #expect(
      L10n.translate("监听 4 · 连接 12", language: .english) == "Listening 4 · Connections 12")
    #expect(
      L10n.translate("端口 3000 同时被多个进程监听", language: .english)
        == "Multiple processes are listening on port 3000")
    #expect(
      L10n.translate("连接过多，只显示前 4096 项", language: .english)
        == "Too many connections; showing the first 4096")
    #expect(
      L10n.translate("结束“node”（PID 42）？", language: .english) == "End “node” (PID 42)?")
  }
}
