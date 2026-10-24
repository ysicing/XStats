// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Localization

struct MaintenancePreviewLocalizationTests {
  // 同时覆盖检查卡片、扫描限制、清理页和仅查看项目复用的文案，防止已有译文被英文回退掩盖。
  private let keys = [
    "重置缩略图",
    "预览缩略图空白或未更新时重置，文件内容不受影响。",
    "缩略图缓存已重置，缩略图将在浏览文件时重新生成。",
    "修复 Spotlight 搜索",
    "查看修复步骤",
    "搜索找不到文件时，在系统设置中重建指定位置的索引。",
    "在系统设置中打开 Spotlight 的“搜索隐私”或“Spotlight 隐私”。",
    "将需要重建索引的文件夹或磁盘加入列表，等待几秒，再从列表中移除。",
    "macOS 随后会重新建立索引，完成前搜索结果可能不完整。",
    "无法打开系统设置，请手动前往 Spotlight 设置。",
    "查看 Apple 修复步骤",
    "打开 Spotlight 设置",

    "清理优化",
    "优化",
    "按需清理缓存与项目产物，预览依赖并执行维护。",
    "在清理优化页查看已安装的 AI 工具及关联数据目录，并管理 worktree。",
    "遇到域名解析异常时手动刷新，不修改 DNS 服务器或代理设置。",
    "手动释放可回收缓存；再次打开应用时可能需要重新加载，不建议频繁执行。",
    "没有可移除的依赖",
    "未安装 Homebrew",
    "Homebrew 依赖预览",
    "预览内容过长，仅显示部分结果。",
    "由 Homebrew 列出不再需要的依赖，仅供审阅。",
    "无法完成检查，请稍后重试。",
    "已达到扫描条目上限",
    "已达到扫描时间上限",
    "扫描已取消",
    "系统检查",
    "内存压力",
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
    "仅查看项目占用 {}",
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
    "仅查看",
    "仅查看 · {}",
    "未发现缓存",
    "工具预览超时，暂不可清理",
    "{} 个文件或目录无法读取",
    "占用 {}",
    "不支持清理 · {}",
    "未发现内容（{}）",
    "工具缓存容量单独列出，不计入文件合计。",
    "所选工具缓存将由对应工具永久清理，此操作无法撤销。",
    "缓存也先移到废纸篓",
    "支持的缓存可以恢复；工具缓存始终由对应命令直接清理",
    "保留项目",
    "查看清理日志",
    "{} 缓存",
    "仅清理已确认的缓存目录，保留账号、设置和本地数据",
    // P4-P6：独立列出源键，防止英文回退掩盖缺译；不修改全局语言。
    "默认路由",
    "占用 {} 字节",
    "配置审阅",
    "检查范围",
    "本次检查会向当前 DNS 查询 apple.com。",
    "仅查看占用，不提供清理。",
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
      L10n.translate("仅查看项目占用 512 MB", language: .english) == "View-only items use 512 MB")
    #expect(
      L10n.translate("Microsoft Teams 缓存", language: .english) == "Microsoft Teams Cache")
  }
}
