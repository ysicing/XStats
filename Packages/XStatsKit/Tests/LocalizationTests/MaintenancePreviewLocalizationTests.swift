// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Localization

struct MaintenancePreviewLocalizationTests {
  // 同时覆盖检查卡片、扫描限制、清理页和仅查看项目复用的文案，防止已有译文被英文回退掩盖。
  private let keys = [
    "优化清理",
    "优化",
    "按需清理缓存与项目产物，预览依赖并执行维护。",
    "在优化清理页查看已安装的 AI 工具及关联数据目录，并管理 worktree。",
    "遇到域名解析异常时手动刷新，不修改 DNS 服务器或代理设置。",
    "手动释放可回收缓存；再次打开应用时可能需要重新加载，不建议频繁执行。",
    "没有可移除的依赖",
    "启动代理目标",
    "仅检查当前用户启动代理的绝对程序路径；不删除或停用。",
    "遗留偏好覆盖",
    "检查用户偏好文件中的 App Nap 和磁盘映像验证覆盖；不修改设置。",
    "用户目录权限",
    "仅检查主目录、Library 和 Preferences 的所有者与可写性。",
    "未安装 Homebrew",
    "Homebrew 依赖预览",
    "预览内容过长，仅显示部分结果。",
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
    "应用保存状态审阅",
    "未找到当前用户的 Saved Application State 目录。",
    "运行中的应用，未计量",
    "只审阅超过 30 天的直接 savedState 目录，跳过运行应用；仅展示完整计量占用，不判断可安全丢弃，不提供清理。",
    "已解析文件：{}",
    "共享文件列表格式",
    "偏好文件格式",
    "仅检查共享列表根目录的 sfl2、sfl3、sfl4 文件格式；跳过最近文档，不解档或解析书签。",
    "仅解析 Preferences 与 ByHost 顶层的非受保护 plist；不判断偏好内容是否正确。",
    "Finder 外置卷元数据偏好",
    "只读用户保存的网络盘与 USB .DS_Store 偏好；默认值或关闭不表示故障，不代表卷上现有文件状态。",
    "Spotlight 索引与有限查询",
    "启动卷 Spotlight 索引已关闭；未发起搜索，也不建议重建。",
    "启动卷报告索引已启用",
    "有限查询超过 3 秒；单次结果不能判断索引故障",
    "只查询声明的应用目录并返回计数；成功或零结果均不能证明索引完整，不执行重建。",
    "索引状态或有限查询证据不足；工具缺失、权限、超时和异常输出均不视为正常。",
    "已找到本地应用",
    "有限范围内未确认归属，不能判定失效",
    "Spotlight 搜索规则归属",
    "保留 System 与 Apple 规则；仅核对应用目录两层内的 bundle 标识，未确认归属不等于孤儿规则。",
    "周期维护记录",
    "当前系统未提供 periodic 工具；不根据系统版本推测维护状态。",
    "只读 daily、weekly、monthly 记录的修改时间；超过 7 天仅供审阅，记录新鲜也不能证明维护成功。",
    "目标未在本次范围内核对",
    "记录目标存在",
    "记录目标不存在，可能已移动",
    "登录项目独立来源",
    "仅在已有自动化权限时只读 System Events 登录项目；不含现代后台项目，不以启动代理替代，不判断应用已卸载。",
    "登录项目来源未授权、未运行或读取失败；不弹出授权，不将未知状态视为空列表。",
    "默认路由",
    "分别读取 IPv4 与 IPv6 默认路由；缺失一种路由不代表网络故障。",
    "DNS 单次探测",
    "仅测试当前 DNS 对 apple.com 的一次解析；代理、过滤或离线均可能影响结果。",
    "已挂载磁盘映像",
    "展示映像来源与挂载位置；未判断是否闲置，不执行卸载。",
    "信息数据库",
    "Safari 历史数据库",
    "Safari 常用网站数据库",
    "下载隔离记录",
    "通知数据库",
    "使用记录数据库",
    "系统缓存与更新",
    "仅审阅系统管理目录占用，不判断过期或可回收；更新状态未知。",
    "Rosetta 数据",
    "仅审阅固定 Rosetta 缓存位置，不判断是否仍被系统使用。",
    "设备备份",
    "备份是用户数据，不是固件或缓存；请在设备管理或空间分析中审阅。",
    "虚拟机与虚拟磁盘",
    "仅审阅固定虚拟机数据目录；使用与挂载状态未知，不判断闲置。请复用空间分析入口。",
    "AI 模型数据",
    "模型数据与虚拟磁盘分开审阅，不判断闲置；其他位置请复用 AI 数据专项或空间分析入口。",
    "Finder 元数据与最近项目",
    "仅审阅主目录及桌面、文稿、下载目录顶层的 Finder 元数据和共享列表占用，不读取最近文档内容。",
    "Time Machine 备份审阅",
    "主库 {} 字节",
    "主库空闲页估算 {} 字节（不代表可回收空间）",
    "附属文件 {} 字节",
    "隔离记录 {} 条",
    "只读估算，不执行数据库维护；不读取下载 URL。",
    "仅有主库或部分证据；日志、并发变化或读取限制使当前数据库状态未知。",
    "邮件索引数据库",
    "占用 {} 字节",
    "大小未知",
    "设备固件",
    "仅审阅 iTunes 固定目录中的 IPSW 固件，与设备备份分开；不判断是否仍有需要。",
    "OrbStack 虚拟机数据",
    "应用数据归属审阅",
    "尚未加载应用清单，未检查应用数据归属；请复用选定应用的残留审阅。",
    "仅列有明确归属的待审阅项目：未在已加载应用清单中匹配，不代表卸载或孤儿；不是垃圾，不提供清理授权。",
    "仅检查旧式本地备份标记，不能证明备份失败或已停止；请复用快照入口或 Time Machine 管理。",
    "权限、路径、格式或扫描预算不足，结果未知；未执行任何修改。",
    "资源与维护",
    "配置审阅",
    "网络检查",
    "存储审阅",
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
      L10n.translate("采样期间换出 128 MB", language: .english)
        == "Swapped out during sampling: 128 MB")
    #expect(
      L10n.translate("交换空间占用 2 GB", language: .english) == "Swap used: 2 GB")
    #expect(
      L10n.translate("仅查看项目占用 512 MB", language: .english) == "View-only items use 512 MB")
    #expect(
      L10n.translate("Microsoft Teams 缓存", language: .english) == "Microsoft Teams Cache")
  }
}
