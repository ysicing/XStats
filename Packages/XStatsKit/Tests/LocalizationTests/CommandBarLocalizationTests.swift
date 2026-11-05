// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Localization

struct CommandBarLocalizationTests {
  @Test(arguments: AppLanguage.allCases.filter { $0 != .system && $0 != .chinese })
  func newCommandLabelsHaveExplicitTranslations(language: AppLanguage) throws {
    let table = try #require(Translations.catalog(for: language))
    for key in [
      "命令栏", "搜索功能与操作", "暂停专注", "开启防休眠", "停止防休眠", "切换麦克风静音", "切换到下一个音频输出",
      "启动台", "命令栏与启动台", "无法读取应用，请关闭后重试。", "搜索应用", "上一页", "下一页",
      "文件夹", "整理应用", "返回", "重命名", "仅移除应用，保留文稿和个人数据。", "无法移除应用",
      "请先退出应用，并检查安装来源和访问权限。", "启动台手势", "使用私有触控板接口；系统更新后可能不可用。",
      "四指捏合", "五指捏合", "启动台触发角", "停留片刻打开；系统已分配的触发角优先。",
      "左上角", "右上角", "左下角", "右下角",
      "查询端口：{}", "查找软件包：{}",
      "搜索应用、功能与操作", "查找进程：{}", "系统设置：网络", "系统设置：蓝牙", "系统设置：显示器",
      "系统设置：声音", "系统设置：键盘", "系统设置：隐私与安全性", "收藏", "取消收藏", "最近使用",
      "清除最近使用", "清除收藏", "最多收藏 8 项", "正在读取应用…", "port <端口号 1–65535>", "brew <软件包名>",
      "ps <进程名或 PID>", "↑↓ 选择 · ↩ 打开", "无法打开项目", "项目可能已移动或不可用，请重新搜索后再试。",
    ] {
      #expect(table.sourceKeys.contains(key), "\(language): \(key)")
      #expect(table.translate(key)?.isEmpty == false, "\(language): \(key)")
    }
  }
}
