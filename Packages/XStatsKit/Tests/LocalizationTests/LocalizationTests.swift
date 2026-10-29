import Testing
@testable import Localization

// 不切换全局语言：其他测试套件并行运行，依赖中文原文
@Suite struct LocalizationTests {
  @Test func preferredAccountLabelsHaveTranslationsInEveryCatalog() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in ["订阅账号", "默认", "设为默认", "用于菜单栏与小组件", "跟随 Magpie"] {
        #expect(table.translate(source)?.isEmpty == false, "\(language): \(source)")
      }
    }
  }

  @Test func magpieConnectionGuidanceHasTranslationsInEveryCatalog() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in [
        "AI 功能需要安装并运行 Magpie。",
        "无法连接 Magpie，请确认它已运行并开启本地接口。",
        "无法打开 Magpie，请手动启动后重试。",
        "安装 Magpie", "打开 Magpie", "重新检测", "AI", "启用 AI",
      ] {
        #expect(table.translate(source)?.isEmpty == false, "\(language): \(source)")
      }
    }
  }

  @Test func aiWidgetSummaryLabelsAreTranslatedInEveryCatalog() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in [
        "累计 Token", "最近 365 天", "Magpie 全部记录", "以四个圆环查看订阅额度",
        "查看累计 Token、输入输出与今日用量", "上次数据", "订阅额度", "暂无额度数据",
      ] {
        #expect(table.translate(source)?.isEmpty == false, "\(language): \(source)")
      }
    }
  }

  @Test func reviewedInterfaceKeysHaveTranslationsInEveryLanguage() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for key in ["未启用", "正在启用…", "重试", "输入", "输出", "磁盘可用 1.2 TB"] {
        let translated = try #require(table.translate(key), "\(language): \(key)")
        #expect(translated != key)
        if key.contains("1.2 TB") { #expect(translated.contains("1.2 TB")) }
      }
    }
  }

  @Test func menuBarPresentationHasExplicitTranslations() throws {
    for language in AppLanguage.allCases where language != .system && language != .chinese {
      let table = try #require(Translations.catalog(for: language))
      for source in [
        "数值位置", "适用于双行文字及图形旁的双行文字", "上方", "下方",
        "点击指标打开详情", "右键菜单可打开状态总览",
        "实验性功能", "折叠菜单栏图标",
        "实验性功能仍在探索中，可能存在兼容性或稳定性问题，后续更新中可能调整或移除。",
        "点击系统双箭头可能出现空白或图标错位。请用 XStats 箭头展开；无法恢复时关闭此功能。",
        "占用偏高或电量偏低时用橙色、红色提示；电量 ≤20% 为橙色，≤10% 为红色",
        "占用着色灵敏度", "标准", "灵敏", "外环状态颜色",
        "占用 ≥80% 为橙色，≥90% 为红色", "占用 ≥60% 为橙色，≥85% 为红色",
        "此刻各核心的占用；偏高时变橙色或红色",
        "开启高负载着色后，圆点提示占用偏高或电量偏低",
        "小标签与数值分两行，靠右对齐，数值的右边不会跳",
      ] {
        #expect(table.translate(source)?.isEmpty == false, "\(language): \(source)")
      }
    }
  }

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
    #expect(table.translate("AI") == "AI")
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
