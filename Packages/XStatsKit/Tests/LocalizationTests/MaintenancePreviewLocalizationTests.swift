// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Localization

struct MaintenancePreviewLocalizationTests {
  // 同时覆盖检查卡片、扫描限制、清理页和预览规则复用的文案，防止已有译文被英文回退掩盖。
  private let keys = [
    "启动代理目标",
    "仅检查当前用户启动代理的绝对程序路径；不删除或停用。",
    "遗留偏好覆盖",
    "检查用户偏好文件中的 App Nap 和磁盘映像验证覆盖；不修改设置。",
    "用户目录权限",
    "仅检查主目录、Library 和 Preferences 的所有者与可写性。",
    "未安装 Homebrew",
    "Homebrew 依赖预览",
    "由 Homebrew 列出不再需要的依赖，仅供审阅。",
    "无法完成检查，请稍后重试。",
    "已达到扫描条目上限",
    "已达到扫描时间上限",
    "扫描已取消",
    "系统检查",
    "CPU 短时检查",
    "仅报告连续两个采样区间均占用至少 25% 单核 CPU 的进程；不代表长期故障。",
    "内存压力",
    "累计交换空间占用不单独视为异常。",
    "采样期间换出 {}",
    "交换空间占用 {}",
    "DNS 维护",
    "检测到代理或隧道环境；DNS 维护可能影响现有连接，请先排查代理设置。",
    "刷新 DNS 仅是可选维护；当前检查不执行刷新，也不据此判断网络故障。",
    "取消",
    "开始检查",
    "按需检查资源、配置和维护建议，仅预览，不执行修复。",
    "部分完成",
    "正常",
    "需关注",
    "可选维护",
    "不适用",
    "未检查",
    "部分项目需要“完全磁盘访问权限”才能扫描（Safari 缓存、废纸篓）。",
    "去授权",
    "部分项目未能读取，大小仅包含已完整扫描的项目。请检查权限后重新扫描。",
    "磁盘清理",
    "扫描于 ",
    "{} 可用 {} · 共 {}",
    "仅预览占用 {}",
    "尚未扫描",
    "释放量未确认",
    "扫描中",
    "点击重新扫描以计算可清理空间",
    "正在计算可清理空间",
    "正在清理…",
    "可清理",
    "已停止，已清理部分不会恢复",
    "部分结果未确认",
    "已释放",
    "另有 {} 移到废纸篓",
    "跳过 {} 项",
    "{} 项失败",
    "刚刚",
    "{}前",
    "已选 {} 项",
    "扫描中…",
    "重新扫描",
    "清理中…",
    "清理所选 {}",
    "系统维护",
    "刷新 DNS 缓存",
    "释放内存",
    "由辅助工具执行",
    "需要管理员授权",
    "执行中",
    "无需清理（{}）",
    "查看包含的项目",
    "由对应工具整体清理，不支持逐项勾选；保留其中任一项目会跳过整条规则。",
    "在访达中显示",
    "始终保留此项目",
    "保留项目已达 50 项上限，请先移除不再需要的保留项。",
    "查看全部项目",
    "扫描不完整 · {} 项未能读取",
    "已跳过 {} 项",
    "无需清理",
    "已选 {}/{} 项",
    "{} 项",
    " · 已跳过 {} 项",
    " · 移到废纸篓",
    "仅预览",
    "工具缓存容量单独列出，不计入文件合计。",
    "所选工具缓存将由对应工具永久清理，此操作无法撤销。",
    "缓存也先移到废纸篓",
    "支持的缓存可以恢复；工具缓存始终由对应命令直接清理",
    "保留项目",
    "查看清理日志",
    "{} 缓存",
    "仅清理已确认的缓存目录，保留账号、设置和本地数据",
  ]

  @Test func maintenancePreviewStringsHaveExplicitTranslationsInEveryLanguage() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in keys {
        #expect(table.sourceKeys.contains(key), "\(language): \(key)")
        let translated = L10n.translate(key, language: language)
        #expect(!translated.isEmpty, "\(language): \(key)")
        #expect(
          translated.components(separatedBy: "{}").count
            == key.components(separatedBy: "{}").count,
          "\(language): \(key)")
      }
    }
  }

  @Test func maintenancePreviewTemplatesPreserveEveryValueExactlyOnce() {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      for key in keys where key.contains("{}") {
        let fragments = key.components(separatedBy: "{}")
        let values = (1..<fragments.count).map { "XSTATS_VALUE_\($0)" }
        var source = fragments[0]
        for (index, value) in values.enumerated() {
          source += value + fragments[index + 1]
        }
        let translated = L10n.translate(source, language: language)
        #expect(!translated.contains("{}"), "\(language): \(key)")
        for value in values {
          #expect(
            translated.components(separatedBy: value).count == 2,
            "\(language): \(key): \(value)")
          if language.isRightToLeft {
            #expect(translated.contains("\u{2068}\(value)\u{2069}"), "\(language): \(key)")
          }
        }
      }
    }
  }

  @Test func maintenancePreviewMessagesTranslateUsingExplicitLanguage() {
    #expect(
      L10n.translate("采样期间换出 128 MB", language: .english)
        == "Swapped out during sampling: 128 MB")
    #expect(
      L10n.translate("交换空间占用 2 GB", language: .english) == "Swap used: 2 GB")
    #expect(
      L10n.translate("仅预览占用 512 MB", language: .english) == "Preview-only usage: 512 MB")
    #expect(
      L10n.translate("Microsoft Teams 缓存", language: .english) == "Microsoft Teams Cache")
  }
}
