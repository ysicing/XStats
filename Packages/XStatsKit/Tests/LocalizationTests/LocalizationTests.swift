import Testing
@testable import Localization

// 不切换全局语言：其他测试套件并行运行，依赖中文原文
@Suite struct LocalizationTests {
  @Test func diagnosticsProgressIsTranslatedInEveryCatalog() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in [
        "正在汇总系统信息…", "正在收集运行日志…", "正在收集清理记录…",
        "正在处理崩溃报告…", "正在压缩打包…",
      ] {
        #expect(table.translate(source)?.isEmpty == false)
      }
      let step = try #require(table.translate("第 2/5 步"))
      #expect(step.contains("2") && step.contains("5"))
    }
  }

  @Test func translatesExactAndTemplates() {
    let table = Translations.shared
    #expect(table.translate("内存") == "Memory")
    #expect(table.translate("AI 用量") == "AI Usage")
    #expect(table.translate("每日") == "Daily")
    #expect(table.translate("每周") == "Weekly")
    #expect(table.translate("累计") == "Cumulative")
    #expect(table.translate("上次额度") == "Previous quota")
    #expect(table.translate("上次成功：20:45") == "Last successful: 20:45")
    #expect(table.translate("最近刷新：20:53") == "Last refresh: 20:53")
    #expect(table.translate("12 个进程") == "12 processes")
    #expect(table.translate("1 个进程") == "1 process")
    #expect(table.translate("节气与时令") == "Solar terms and seasons")
    #expect(table.translate("一九第2天") == "Nine 1, day 2")
    #expect(table.translate("不存在的文案") == nil)
  }

  @Test func homebrewCompletionPreservesPackageNamesInEveryCatalog() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in ["已更新“Example Tool”", "已卸载“Example Tool”"] {
        let translated = try #require(table.translate(source))
        #expect(translated.contains("Example Tool"))
        #expect(translated != source)
      }
    }
  }

  @Test func translatesCapturedChinese() {
    // 插进来的中文也会再翻一次
    #expect(Translations.shared.translate("设置 · 关于") == "Settings · About")
  }

  @Test func menuEnhancementTextExistsAndPreservesTemplateValuesInEveryCatalog() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in ["4 小时", "8 小时", "12 小时", "项目间距", "调整合并菜单栏中各项目之间的距离", "丢包"] {
        #expect(table.translate(source) != nil)
      }
      #expect(try #require(table.translate("结束时间：20:45")).contains("20:45"))
      #expect(try #require(table.translate("最近 37 次探测")).contains("37"))
    }
  }

  @Test func defaultsToChinese() {
    #expect(tr("内存") == "内存")
    #expect(AppLanguage.english.resolved == .english)
  }

  @Test func translatesWebDAVControlsAndErrors() {
    #expect(Translations.shared.translate("设置同步") == "Settings Sync")
    #expect(Translations.shared.translate("下载并应用") == "Download and Apply")
    #expect(Translations.shared.translate("WebDAV 返回错误：503") == "WebDAV returned an error: 503")
  }

  @Test func appEnergyTextExistsInEverySupportedCatalog() throws {
    let sources = [
      "App 能耗", "CPU 能耗", "暂时无法读取 App 能耗", "当前没有明显的 CPU 耗电活动",
      "每 5 秒更新，合并应用及辅助进程。仅含可读取的 CPU 能耗，不含 GPU、屏幕等耗电。",
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in sources { #expect(table.translate(source) != nil) }
    }
  }

  @Test func energyAndFanGroupingTextExistsInEverySupportedCatalog() throws {
    let sources = [
      "阻止睡眠", "没有 App 阻止 Mac 进入睡眠", "{} 个系统服务正在阻止睡眠",
      "暂时无法读取睡眠阻止信息", "阻止系统闲置睡眠", "阻止屏幕闲置关闭", "屏幕", "能耗", "风扇", "采集温度、功耗、App 能耗和电量历史；关闭后仍显示电池基础信息",
      "只在显示功耗时记录", "只在显示温度或开启过热通知时记录", "只在显示电池信息时记录",
    ]
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in sources { #expect(table.translate(source) != nil) }
    }
  }

  @Test func translatesCardExpiryInEverySupportedCatalog() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      let translated = try #require(table.translate("到期：Demo"))
      #expect(translated.contains("Demo"))
    }
  }
}
