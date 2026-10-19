// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AIUsage
import AudioControl
import AppKit
import Cleaner
import Darwin
import Localization
import Metrics
import NetworkObservation
import SMC
import SwiftUI
import Updates

/// `XStats --snapshot <目录>`：用本机实时数据渲染各页面 PNG，用于设计走查
@MainActor
enum SnapshotRenderer {
  private(set) static var didFail = false

  static func run(outputDirectory: URL) async {
    didFail = false
    do {
      try FileManager.default.createDirectory(
        at: outputDirectory, withIntermediateDirectories: true)
    } catch {
      reportFailure(outputDirectory, error: error)
      return
    }

    if CommandLine.arguments.contains("--metric-summary-only") {
      let suite = "XStats.metricSummarySnapshot.\(UUID())"
      guard let defaults = UserDefaults(suiteName: suite) else { return }
      defer { defaults.removePersistentDomain(forName: suite) }
      let settings = AppSettings(defaults: defaults)
      settings.language = L10n.language
      settings.menuBarItems = []
      settings.historyEnabled = false
      settings.enabledAlerts = []
      settings.publicIPLookup = false
      settings.probeEnabled = false
      settings.hiddenPopoverSections.formUnion(
        MenuBarItem.network.popoverSections.filter { $0 != .networkHistory })
      let model = AppModel(
        settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [],
        networkCacheDefaults: defaults)
      var demand = MetricsDemand()
      demand.cpu = true
      demand.memory = true
      demand.network = true
      var snapshot = MetricsSnapshot()
      await model.hub.update(demand)
      await model.hub.start(primeAllMetrics: false) { snapshot = $0 }
      try? await Task.sleep(for: .seconds(3))
      await model.hub.stop()
      // 演示数据：确定性数值与匿名应用名，截图不包含本机进程及地址。
      snapshot.processes = [
        ProcessUsage(
          pid: 42, name: "Demo", executablePath: nil,
          appBundlePath: nil, cpu: 2, memory: 1_073_741_824)
      ]
      snapshot.thermalState = .serious
      snapshot.networkInterface = nil
      snapshot.memory?.swapUsed = 2_147_483_648
      snapshot.network?.downloadBytesPerSecond = 4_000_000
      snapshot.network?.uploadBytesPerSecond = 1_000_000
      snapshot.disk = DiskUsage(
        volumeName: "Macintosh HD", total: 1_000_000_000_000,
        available: 400_000_000_000, purgeable: 20_000_000_000)
      // 曲线使用匿名演示历史；系统读取已停止，不增加截图期间的采样。
      for index in 0..<60 {
        snapshot.memory?.app = UInt64(4_000_000_000 + 1_000_000_000 * (1 + sin(Double(index) / 8)))
        model.store.apply(snapshot)
      }
      await model.network.refreshDetails(basicOnly: true)
      model.network.maskForSnapshot()
      model.diskTools.showPreview(volumes: [
        MountedVolume(
          url: URL(fileURLWithPath: "/Volumes/Demo"),
          name: "Demo External SSD", total: 2_000_000_000_000, available: 800_000_000_000,
          isInternal: false, isRemovable: true, isEjectable: true, isLocal: true)
      ])
      for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        guard let appearance = NSAppearance(named: name) else { continue }
        NSApp.appearance = appearance
        for perCore in [false, true] {
          settings.cpuSharePerCore = perCore
          let scale = perCore ? "core" : "machine"
          write(
            VStack(spacing: DS.Space.s3) { CPUPopover() }
              .appLanguageEnvironment().padding(DS.Space.s3).frame(width: DS.Size.popoverWidth),
            model: model, appearance: appearance,
            to: outputDirectory.appendingPathComponent("cpu-\(scale)-\(suffix).png"))
          write(
            OverviewPage().appLanguageEnvironment().frame(width: 640, height: 760),
            model: model, appearance: appearance,
            to: outputDirectory.appendingPathComponent("overview-\(scale)-\(suffix).png"))
        }
        write(
          VStack(spacing: DS.Space.s3) {
            MemoryPopover()
            ThermalPopover(item: .temperature)
            NetworkPopover()
          }
          .appLanguageEnvironment().padding(DS.Space.s3).frame(width: DS.Size.popoverWidth),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("summaries-\(suffix).png"))
        write(
          VStack(spacing: DS.Space.s3) { DiskPopover() }
            .appLanguageEnvironment().padding(DS.Space.s3).frame(width: DS.Size.popoverWidth),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("disk-volumes-\(suffix).png"))
        write(
          TemperatureCard().appLanguageEnvironment().padding(DS.Space.s3).frame(width: 600),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("temperature-\(suffix).png"))
      }
      return
    }

    if CommandLine.arguments.contains("--hardware-details-only") {
      let suite = "XStats.hardwareDetailsSnapshot.\(UUID())"
      guard let defaults = UserDefaults(suiteName: suite) else { return }
      defer { defaults.removePersistentDomain(forName: suite) }
      let settings = AppSettings(defaults: defaults)
      settings.language = L10n.language
      settings.menuBarItems = []
      settings.historyEnabled = false
      settings.enabledAlerts = []
      settings.panelTab = .gpu
      let model = AppModel(
        settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
      model.isMainWindowVisible = true
      var demand = model.demand
      demand.disk = true
      demand.diskDetail = true
      demand.battery = true
      await model.hub.update(demand)
      // 只读当前硬件，不启动其他功能或进程采样。截图写入前停止循环。
      await model.hub.start(primeAllMetrics: false) { snapshot in model.store.apply(snapshot) }
      try? await Task.sleep(for: .seconds(5))
      await model.hub.stop()
      for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        guard let appearance = NSAppearance(named: name) else { continue }
        NSApp.appearance = appearance
        for (width, detail) in [(DS.Size.popoverWidth, false), (CGFloat(600), true)] {
          for item in [MenuBarItem.gpu, .battery, .disk] {
            let content = VStack(spacing: DS.Space.s3) {
              switch item {
              case .gpu: GPUPopover()
              case .battery: BatteryPopover()
              default: DiskPopover()
              }
            }
            .environment(\.isDetailPage, detail).appLanguageEnvironment()
            .padding(DS.Space.s3).frame(width: width)
            write(
              content, model: model, appearance: appearance,
              to: outputDirectory.appendingPathComponent(
                "hardware-\(item.rawValue)-\(Int(width))-\(suffix).png"))
          }
        }
      }
      return
    }

    if CommandLine.arguments.contains("--app-management-only") {
      let suite = "XStats.appManagementSnapshot.\(UUID())"
      guard let defaults = UserDefaults(suiteName: suite) else { return }
      defer { defaults.removePersistentDomain(forName: suite) }
      let settings = AppSettings(defaults: defaults)
      settings.language = L10n.language
      settings.uninstallerEnabled = true
      let model = AppModel(
        settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
      let apps = ["Atlas", "Boreal", "Editor", "Studio", "Terminal", "Weather"].map {
        InstalledApp(
          url: URL(fileURLWithPath: "/Applications/\($0).app"), name: $0,
          bundleIdentifier: "demo.\($0.lowercased())", version: "2.4.1", teamIdentifier: nil)
      }
      let metadata = Dictionary(
        uniqueKeysWithValues: apps.enumerated().map { index, app in
          (
            app.id,
            ApplicationMetadata(
              architecture: index.isMultiple(of: 2) ? .appleSilicon : .universal,
              lastOpened: index < 4 ? Date(timeIntervalSince1970: 1_790_000_000) : nil,
              isAppStore: index == 1)
          )
        })
      let json =
        #"{"formulae":[{"name":"tool","full_name":"vendor/tap/tool","desc":"Command-line development tool with a detailed description for layout review","installed":[{"version":"1.1","time":1790000000,"installed_on_request":true}],"versions":{"stable":"2.0"},"outdated":true},{"name":"runtime","full_name":"runtime","desc":"Runtime dependency for command-line tools","installed":[{"version":"24.0","time":1790000000,"installed_on_request":false}],"versions":{"stable":"24.0"},"pinned":true}],"casks":[{"full_token":"editor","name":["Editor"],"installed":"2.4.1","installed_time":1790000000,"desc":"Native code editor","version":"2.5.0","outdated":true,"artifacts":[{"app":["Editor.app"],"target":"/Applications/Editor.app"}]}]}"#
      // 演示包同样走生产解析器，不构造可能绕过身份检查的操作对象。
      let packages =
        (try? HomebrewManagement.parse(json, prefix: URL(fileURLWithPath: "/opt/homebrew"))) ?? []
      model.appManagement.showPreview(
        apps: apps, metadata: metadata,
        sizes: Dictionary(
          uniqueKeysWithValues: apps.enumerated().map {
            ($0.element.id, UInt64(($0.offset + 1) * 128_000_000))
          }), packages: packages,
        storeUpdates: [
          apps[1].id: .init(
            bundleIdentifier: apps[1].bundleIdentifier, version: "2.5.0",
            minimumSystemVersion: "14.0", storeID: "123")
        ])
      for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        guard let appearance = NSAppearance(named: name) else { continue }
        NSApp.appearance = appearance
        for tab in AppManagementController.Tab.allCases {
          // 覆盖宽窗口的列分配和窄窗口的工具栏换行；保持原有截图文件名。
          for (width, sizeSuffix) in [(CGFloat(1050), ""), (1240, "-wide"), (760, "-compact")] {
            write(
              AppManagementPage(tab: tab).appLanguageEnvironment().frame(width: width, height: 560),
              model: model, appearance: appearance,
              to: outputDirectory.appendingPathComponent(
                "apps-\(tab.rawValue)-\(suffix)\(sizeSuffix).png"))
          }
        }
      }
      return
    }

    // 定向诊断不启动指标采样或 AI 日志扫描；demo 仅用于布局走查。
    if CommandLine.arguments.contains("--apple-intelligence-only") {
      let demo = CommandLine.arguments.contains("--demo")
      let report =
        demo
        ? AppleIntelligenceDiagnostics.Report.example
        : ((try? await AppleIntelligenceDiagnostics.load()) ?? .unreadable)
      if !demo {
        let path = outputDirectory.appendingPathComponent("report.json")
        do { try JSONEncoder().encode(report).write(to: path) } catch {
          reportFailure(path, error: error)
          return
        }
      }
      let suite = "XStats.appleIntelligenceSnapshot.\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite)!
      defer { defaults.removePersistentDomain(forName: suite) }
      let settings = AppSettings(defaults: defaults)
      settings.language = L10n.language
      let model = AppModel(
        settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
      for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        guard let appearance = NSAppearance(named: name) else { continue }
        NSApp.appearance = appearance
        write(
          AppleIntelligenceDetailsPopover(report: report), model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("apple-intelligence-\(suffix).png"))
        write(
          AppleIntelligenceStatusRow(status: .unavailable).padding(DS.Space.s3).frame(width: 600),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("apple-intelligence-row-\(suffix).png"))
      }
      return
    }

    if CommandLine.arguments.contains("--cleaner-review-only") {
      let suite = "XStats.cleanerReviewSnapshot.\(UUID())"
      guard let defaults = UserDefaults(suiteName: suite) else { return }
      defer { defaults.removePersistentDomain(forName: suite) }
      let settings = AppSettings(defaults: defaults)
      settings.language = L10n.language
      settings.cleanerEnabled = true
      settings.cleanExcludedPaths = ["/Users/demo/Library/Caches/com.example.kept"]
      let model = AppModel(
        settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
      guard let rule = RuleCatalog.rules().first(where: { $0.id == "system.caches" }) else {
        return
      }
      let items = (1...12).map { index in
        CleanItem(
          url: URL(fileURLWithPath: "/Users/demo/Library/Caches/com.example.application\(index)"),
          size: UInt64(index * 1_000_000))
      }
      let scan = RuleScan(
        rule: rule, items: items, skippedCount: 2, blocked: nil,
        skippedReasons: [.recentlyModified: 1, .excluded: 1], unreadableCount: 1)
      let emptyScans = RuleCatalog.rules().filter { $0.id != rule.id }.map {
        RuleScan(rule: $0, items: [], skippedCount: 0, blocked: nil)
      }
      // 产物演示只扫描临时夹具；使用真实扫描结果保证选择契约与生产一致。
      let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
        "XStats-cleaner-demo-\(UUID())")
      defer { try? FileManager.default.removeItem(at: fixture) }
      do {
        for project in ["Atlas", "Boreal", "Studio"] {
          for path in ["package.json", "node_modules/example/index.js", "build/output.bin"] {
            let url = fixture.appendingPathComponent("Projects/\(project)/\(path)")
            try FileManager.default.createDirectory(
              at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: path == "package.json" ? 2 : 256_000).write(to: url)
          }
        }
      } catch {
        reportFailure(fixture, error: error)
        return
      }
      settings.projectPurgeConfiguredPaths = [fixture.appendingPathComponent("Projects").path]
      let projectScan = await ProjectPurge.scan(home: fixture.path)
      model.projectPurge.showPreview(projectScan)
      if let first = projectScan.items.first { model.projectPurge.toggle(first) }
      model.cleaner.showPreview([scan] + emptyScans)
      model.cleaner.toggle(items[0], in: scan)
      for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        guard let appearance = NSAppearance(named: name) else { continue }
        NSApp.appearance = appearance
        write(
          CleanerPage().appLanguageEnvironment().frame(width: 900, height: 700), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("cleaner-partial-\(suffix).png"))
        write(
          ProjectPurgeWindowView().frame(width: 720, height: 680), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("project-purge-\(suffix).png"))
        write(
          CleanerReviewSheet(scan: scan, cleaner: model.cleaner), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("cleaner-review-\(suffix).png"))
        write(
          CleanerExclusionsSheet(cleaner: model.cleaner), model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("cleaner-exclusions-\(suffix).png"))
        let originalExclusions = settings.cleanExcludedPaths
        settings.cleanExcludedPaths = (0..<50).map { "/Users/demo/kept/\($0)" }
        write(
          CleanerReviewSheet(scan: scan, cleaner: model.cleaner), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("cleaner-review-limit-\(suffix).png"))
        write(
          CleanerExclusionsSheet(cleaner: model.cleaner), model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("cleaner-exclusions-limit-\(suffix).png"))
        settings.cleanExcludedPaths = originalExclusions
      }
      if CommandLine.arguments.contains("--native-preview") {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
          contentRect: NSRect(x: 100, y: 100, width: 720, height: 680),
          styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered,
          defer: false)
        window.title = "XStats · UI Preview"
        window.isReleasedWhenClosed = false
        WindowChrome.apply(to: window)
        window.contentView = NSHostingView(rootView: ProjectPurgeWindowView().environment(model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        try? await Task.sleep(for: .seconds(120))
        window.orderOut(nil)
      }
      // 清单截图使用演示候选，覆盖应用缓存、开发者项目与长译文，不查询本机工具。
      model.cleaner.showPreview(
        RuleCatalog.rules().enumerated().map { index, rule in
          let path =
            switch rule.id {
            case "app.claude": "/Users/demo/Library/Application Support/Claude/Cache"
            case "app.antigravity": "/Users/demo/Library/Application Support/Antigravity/Cache"
            case "app.qoder": "/Users/demo/Library/Application Support/Qoder/CachedData"
            case "app.codebuddy": "/Users/demo/Library/Application Support/CodeBuddy/Cache"
            case "app.codex": "/Users/demo/Library/Caches/Codex/Default/Cache"
            case "app.slack": "/Users/demo/Library/Application Support/Slack/Cache"
            case "app.discord": "/Users/demo/Library/Application Support/discord/Cache"
            case "app.teamsClassic": "/Users/demo/Library/Application Support/Microsoft/Teams/Cache"
            default: "/Users/demo/Library/Caches/" + rule.id
            }
          let items =
            rule.category == .developer || rule.id.hasPrefix("app.")
            ? [
              CleanItem(
                url: URL(fileURLWithPath: path),
                size: UInt64(index + 1) * 1_000_000)
            ]
            : []
          return RuleScan(rule: rule, items: items, skippedCount: 0, blocked: nil)
        })
      for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        guard let appearance = NSAppearance(named: name) else { continue }
        NSApp.appearance = appearance
        write(
          CleanerPage().appLanguageEnvironment().frame(width: 1000, height: 1650), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("developer-cleanup-catalog-\(suffix).png"))
      }
      return
    }

    if CommandLine.arguments.contains("--uninstaller-only") {
      let suite = "XStats.uninstallerSnapshot.\(UUID())"
      guard let defaults = UserDefaults(suiteName: suite) else { return }
      defer { defaults.removePersistentDomain(forName: suite) }
      let settings = AppSettings(defaults: defaults)
      settings.language = L10n.language
      let model = AppModel(
        settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
      let app = InstalledApp(
        url: URL(fileURLWithPath: "/Applications/Demo.app"), name: "Demo",
        bundleIdentifier: "com.example.demo", version: "1.0", teamIdentifier: nil)
      let items = [
        AppLeftover(url: app.url, kind: .application, size: 20_000_000),
        AppLeftover(
          url: URL(fileURLWithPath: "/Users/demo/Library/Caches/com.example.demo"), kind: .caches,
          size: 2_000_000),
        AppLeftover(
          url: URL(
            fileURLWithPath: "/Users/demo/Library/Group Containers/group.com.example.shared"),
          kind: .containers, size: 1_000_000, requiresReview: true),
      ]
      for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        guard let appearance = NSAppearance(named: name) else { continue }
        NSApp.appearance = appearance
        for removed in [false, true] {
          model.uninstaller.showPreview(
            app: app, items: removed ? Array(items.dropFirst()) : items, applicationRemoved: removed
          )
          let state = removed ? "retry" : "selected"
          write(
            UninstallerPage().appLanguageEnvironment().frame(width: 900, height: 660), model: model,
            appearance: appearance,
            to: outputDirectory.appendingPathComponent("uninstaller-\(state)-\(suffix).png"))
          write(
            UninstallConfirmationSheet(app: app, uninstaller: model.uninstaller), model: model,
            appearance: appearance,
            to: outputDirectory.appendingPathComponent("uninstaller-confirm-\(state)-\(suffix).png")
          )
        }
        model.uninstaller.showPreview(
          app: app, items: items, applicationRemoved: false, scanIncomplete: true)
        write(
          UninstallerPage().appLanguageEnvironment().frame(width: 900, height: 660), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("uninstaller-incomplete-\(suffix).png"))
        write(
          UninstallConfirmationSheet(app: app, uninstaller: model.uninstaller), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("uninstaller-confirm-incomplete-\(suffix).png")
        )
        for uncertain in [false, true] {
          model.uninstaller.showPreview(
            app: app, items: [items[0]], applicationRemoved: false,
            copies: uncertain ? [] : [URL(fileURLWithPath: "/Applications/Other Copy/Demo.app")],
            installationCheckIncomplete: uncertain)
          write(
            UninstallerPage().appLanguageEnvironment().frame(width: 900, height: 660), model: model,
            appearance: appearance,
            to: outputDirectory.appendingPathComponent(
              "uninstaller-\(uncertain ? "unknown-copies" : "copies")-\(suffix).png"))
        }

      }
      return
    }

    if CommandLine.arguments.contains("--timer-only") {
      renderTimers(outputDirectory: outputDirectory)
      if CommandLine.arguments.contains("--verify-runtime") {
        do { try await verifyTimerRuntime(outputDirectory: outputDirectory) } catch {
          reportFailure(outputDirectory.appendingPathComponent("timer-runtime.json"), error: error)
        }
      }
      return
    }

    if CommandLine.arguments.contains("--rest-hud-only") {
      renderRestHUD(outputDirectory: outputDirectory)
      return
    }

    if CommandLine.arguments.contains("--wellness-only") {
      renderWellness(outputDirectory: outputDirectory)
      if CommandLine.arguments.contains("--verify-runtime") {
        do { try await verifyWellnessRuntime(outputDirectory: outputDirectory) } catch {
          reportFailure(outputDirectory.appendingPathComponent("runtime.json"), error: error)
        }
      }
      return
    }

    if CommandLine.arguments.contains("--features-only") {
      await renderFeatures(outputDirectory: outputDirectory)
      await renderAudio(outputDirectory: outputDirectory, demo: true)
      renderCalendar(outputDirectory: outputDirectory, gallery: true)
      return
    }

    // 日历快照只渲染固定日期，不启动系统采样、AI 扫描或磁盘扫描。
    if CommandLine.arguments.contains("--calendar-only") {
      renderCalendar(outputDirectory: outputDirectory)
      return
    }
    if CommandLine.arguments.contains("--audio-only") {
      await renderAudio(outputDirectory: outputDirectory)
      return
    }
    if CommandLine.arguments.contains("--connections-only") {
      await renderConnections(outputDirectory: outputDirectory)
      return
    }
    if CommandLine.arguments.contains("--display-only") {
      await renderDisplays(outputDirectory: outputDirectory)
      return
    }
    if CommandLine.arguments.contains("--menubar-only") {
      await renderMenuBar(outputDirectory: outputDirectory)
      return
    }

    let defaults = UserDefaults(suiteName: "XStats.snapshot") ?? .standard
    let settings = AppSettings(defaults: defaults)
    settings.language = L10n.language
    settings.enabledMonitoringModules = Set(MonitoringModule.allCases)
    settings.menuBarItems = [
      .cpu, .gpu, .memory, .network, .disk, .temperature, .battery, .aiUsage,
    ]
    settings.aiUsageEnabled = true
    settings.cleanerEnabled = true
    settings.uninstallerEnabled = true
    settings.processesEnabled = true
    // 历史页用示例数据：最近 24 小时每分钟一条，中间留一段“睡眠”空档
    let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "xstats-snapshot-history.sqlite")
    try? FileManager.default.removeItem(at: historyURL)
    if let database = try? HistoryDatabase(url: historyURL) {
      let now = Int(Date().timeIntervalSince1970) / 60 * 60
      for index in 0..<(24 * 60) where !(600..<780).contains(index) {
        let t = Double(index)
        let wave = (sin(t / 90) + 1) / 2
        await database.insert(
          HistoryRecord(
            minute: now - (24 * 60 - index) * 60,
            cpu: 0.08 + wave * 0.3, cpuMax: min(1, 0.2 + wave * 0.6),
            memory: 0.55 + wave * 0.2, pressure: index % 400 == 0 ? 4 : 1,
            download: 200_000 + wave * 3_000_000, upload: 40_000 + wave * 400_000,
            gpu: index % 3 == 0 ? wave * 0.4 : nil, temperature: 45 + wave * 30,
            power: index > 1200 ? 20 + wave * 25 : nil))
      }
    }
    let model = AppModel(
      settings: settings, historyURL: historyURL,
      aiUsageProviders: [SnapshotAIUsageProvider()])
    await model.aiUsage.refresh()
    model.displays.refreshCatalog()
    model.isMainWindowVisible = true
    model.network.setVisibility(inMenuBar: true, detailVisible: true)

    // 采集约 12 秒的真实数据，让历史曲线有内容
    var demand = MetricsDemand()
    demand.cpu = true
    demand.generation = settings.monitoringGeneration
    demand.interval = .milliseconds(250)
    demand.memory = true
    demand.network = true
    demand.gpu = true
    demand.disk = true
    demand.battery = true
    demand.processes = true
    demand.temperatures = Set(TemperatureGroup.allCases)
    demand.fans = true
    demand.power = true
    demand.cpuFrequency = true
    demand.diskDetail = true
    await model.hub.update(demand)
    await model.hub.start { snapshot in model.handle(snapshot) }
    try? await Task.sleep(for: .seconds(12))
    await model.hub.stop()
    model.network.setVisibility(inMenuBar: false, detailVisible: false)
    model.network.maskForSnapshot()
    // 清理页展示真实扫描结果（只读，不删除任何文件）
    model.cleaner.scan()
    while model.cleaner.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
    model.history.load(.day)
    model.startupItems.refresh()
    model.uninstaller.loadApps()
    try? await Task.sleep(for: .seconds(2))
    // 固定的虚构更新仅用于离屏截图，不随正式发布版本推进，也不执行检查或安装。
    // .invalid 是演示地址；中英文摘要沿用真实更新的语言选择规则。
    model.updates.showPreview(
      UpdateRelease(
        version: "9.9.9", build: "9999", date: "2026-10-01", minimumSystem: "14.0",
        url: URL(string: "https://example.invalid/XStats-9.9.9-AppleSilicon.zip")!,
        sha256: String(repeating: "0", count: 64),
        size: 9_600_000, dmg: URL(string: "https://example.invalid/XStats-9.9.9-AppleSilicon.dmg"),
        notes: ["优化菜单栏弹窗的显示与交互", "改善日历布局与农历显示", "减少后台重复计算，保持原有采样频率"],
        changelog: URL(string: "https://github.com/ysicing/XStats/blob/main/CHANGELOG.md"),
        englishNotes: [
          "Improve menu bar popover display and interaction",
          "Improve calendar layout and lunar date display",
          "Reduce repeated background work while preserving sampling rates",
        ]))

    for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      guard let appearance = NSAppearance(named: appearanceName) else { continue }
      NSApp.appearance = appearance
      for tab in PanelTab.allCases where tab != .settingsAccount {
        settings.panelTab = tab
        write(
          MainWindowView(), model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("window-\(tab.rawValue)-\(suffix).png"))
      }
      write(
        UpdatePromptView {}, model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("update-prompt-\(suffix).png"))
      write(
        LanguagePickerList(selection: settings.language) { _ in }.appLanguageEnvironment(),
        model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("language-picker-\(suffix).png"))
      for item in MenuBarItem.allCases where item != .fan {
        write(
          PopoverRootView(item: item), model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("popover-\(item.rawValue)-\(suffix).png"))
      }
      // 合并模式的面板：状态总览
      model.combinedPopoverTab = nil
      write(
        CombinedPopoverView(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("popover-combined-\(suffix).png"))
    }

    let menuBar = MenuBarRenderer.image(for: model)
    for dark in [false, true] {
      let preview = MenuBarRenderer.preview(menuBar, dark: dark)
      // 垫上菜单栏底色，便于查看
      let padded = NSImage(
        size: NSSize(width: preview.size.width + DS.Space.s4, height: preview.size.height),
        flipped: false
      ) { rect in
        NSColor(hex: dark ? 0x1F2937 : 0xE5E7EB).setFill()
        rect.fill()
        preview.draw(
          in: NSRect(x: DS.Space.s2, y: 0, width: preview.size.width, height: preview.size.height))
        return true
      }
      writePNG(
        padded, scale: 2,
        to: outputDirectory.appendingPathComponent("menubar-\(dark ? "dark" : "light").png"))
    }
    await renderConnections(outputDirectory: outputDirectory)
    print(tr("截图已输出到 \(outputDirectory.path)"))
  }

  /// 固定的虚构连接只用于布局走查；不激活系统扩展，不读取本机连接。
  private static func renderConnections(outputDirectory: URL) async {
    guard NetworkMonitorSupport.isAvailable else { return }
    let suite = "XStats.connectionsSnapshot.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { return }
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.language = L10n.language
    settings.networkConnectionsEnabled = true
    settings.panelTab = .connections
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    let demo: [(String, String?, String?, UInt16, ConnectionTransport)] = [
      (
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
        "192.0.2.10", "example.invalid", 443, .tcp
      ),
      (
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
        "2001:db8::10", "static.example.invalid", 443, .udp
      ),
      (
        "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", "198.51.100.20",
        "server.example.invalid", 22, .tcp
      ),
      (
        "/System/Applications/Mail.app/Contents/MacOS/Mail", "203.0.113.30", "mail.example.invalid",
        993, .tcp
      ),
      ("/usr/bin/z-demo-process", nil, nil, 443, .tcp),
    ]
    model.connectionMonitor.showPreview(
      demo.enumerated().map { index, value in
        ObservedConnection(
          id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
          timestamp: Date(timeIntervalSince1970: 1_791_244_800 - Double(index * 5)),
          processID: Int32(100 + index), executablePath: value.0,
          address: value.1, hostname: value.2, port: value.3, transport: value.4,
          direction: .outbound)
      })
    model.connectionMonitor.previewWorld = await OfflineGeography.shared.world()
    // 文档地址及归属地均为演示值；截图不发送连接数据，也不访问地理数据库下载入口。
    model.connectionMonitor.previewCountries = [
      "192.0.2.10": "AU", "2001:db8::10": "US", "198.51.100.20": "JP", "203.0.113.30": "HK",
    ]
    for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      guard let appearance = NSAppearance(named: name) else { continue }
      NSApp.appearance = appearance
      model.connectionMonitor.setObservationPaused(false)
      write(
        MainWindowView(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("connections-window-\(suffix).png"))
      write(
        NetworkConnectionsPage().frame(width: 900).background(DS.Palette.background)
          .appLanguageEnvironment(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("connections-page-wide-\(suffix).png"))
      model.connectionMonitor.setObservationPaused(true)
      write(
        NetworkConnectionsPage().frame(width: 900).background(DS.Palette.background)
          .appLanguageEnvironment(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("connections-paused-\(suffix).png"))
      model.featureSettingsTab = .optional
      write(
        FeatureSettings().frame(width: 680).appLanguageEnvironment(), model: model,
        appearance: appearance,
        to: outputDirectory.appendingPathComponent("connections-settings-\(suffix).png"))
      model.networkComponent.showPreview(nil)
      write(
        NetworkComponentManagementView().appLanguageEnvironment(), model: model,
        appearance: appearance,
        to: outputDirectory.appendingPathComponent("component-install-\(suffix).png"))
      // 9.9.9/9999 明确标记为虚构版本，避免截图冒充实际已安装或已发布的组件。
      var component = NetworkComponentStatus(
        componentVersion: "9.9.9", componentBuild: "9999",
        extensionVersion: "9.9.9", extensionBuild: "9999",
        observationMachService: "example.invalid",
        registration: .enabled, filterEnabled: true)
      model.networkComponent.showPreview(component)
      write(
        NetworkComponentManagementView().appLanguageEnvironment(), model: model,
        appearance: appearance,
        to: outputDirectory.appendingPathComponent("component-installed-\(suffix).png"))
      component.registration = .requiresApproval
      model.networkComponent.showPreview(component)
      write(
        NetworkComponentManagementView().appLanguageEnvironment(), model: model,
        appearance: appearance,
        to: outputDirectory.appendingPathComponent("component-approval-\(suffix).png"))
      component.registration = .enabled
      component.update = .init(phase: .available, version: "9.9.10")
      model.networkComponent.showPreview(component)
      write(
        NetworkComponentManagementView().appLanguageEnvironment(), model: model,
        appearance: appearance,
        to: outputDirectory.appendingPathComponent("component-update-\(suffix).png"))
    }
  }

  /// 使用隔离偏好只读取设备；不请求权限，不创建 tap，不修改系统音量或路由。
  private static func renderAudio(outputDirectory: URL, demo: Bool = false) async {
    let suite = "XStats.audioSnapshot.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { return }
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.language = L10n.language
    settings.audioEnabled = true
    settings.menuBarItems = [.audio]
    settings.panelTab = .audio
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    if demo || CommandLine.arguments.contains("--audio-demo") {
      let builtIn = AudioDeviceInfo(
        id: 1, uid: "demo.builtin", name: tr("系统默认输出"), hasInput: true, hasOutput: true,
        inputVolume: 0.4, outputVolume: 0.5, inputMuted: true, outputMuted: false,
        canSetInputVolume: true, canSetOutputVolume: true, canSetInputMute: true,
        canSetOutputMute: true)
      let external = AudioDeviceInfo(id: 2, uid: "demo.usb", name: "USB Audio", hasOutput: true)
      let apps = [
        AudioApplication(
          id: "demo.playing", name: "Music",
          bundleURL: URL(fileURLWithPath: "/System/Applications/Music.app"), processObjectIDs: [1],
          isPlaying: true),
        AudioApplication(
          id: "demo.paused", name: "Browser",
          bundleURL: URL(fileURLWithPath: "/Applications/Safari.app"), processObjectIDs: [2],
          isPlaying: false),
        AudioApplication(
          id: "demo.default", name: "Video Player",
          bundleURL: URL(fileURLWithPath: "/System/Applications/QuickTime Player.app"),
          processObjectIDs: [3], isPlaying: true),
        // 注册了音频上下文但从未播放、也未调整的进程不应出现在控制列表。
        AudioApplication(
          id: "com.apple.dock", name: "Dock", processObjectIDs: [4], isPlaying: false),
        AudioApplication(
          id: "com.apple.controlcenter", name: "Control Center", processObjectIDs: [5],
          isPlaying: false),
        AudioApplication(
          id: "com.apple.AppStore", name: "App Store", processObjectIDs: [6], isPlaying: false),
      ]
      model.audio.showPreview(
        AudioHardwareSnapshot(
          devices: [builtIn, external], outputID: 1, inputID: 1, applications: apps),
        volumes: ["demo.playing": AudioAppVolume(level: 1.6)!],
        outputs: ["demo.playing": "demo.usb", "demo.paused": "demo.missing"],
        bluetoothDevices: [
          BluetoothAudioDevice(
            address: "AA-BB-CC-DD-EE-FF", name: "Studio Headphones", hasInput: true, hasOutput: true
          )
        ])
    } else {
      model.audio.setDemand(enabled: true, visible: true, menuVisible: true)
      // HAL 串行队列事件发布到主线程后再离屏测量。
      try? await Task.sleep(for: .milliseconds(300))
    }
    for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      guard let appearance = NSAppearance(named: name) else { continue }
      NSApp.appearance = appearance
      write(
        PopoverRootView(item: .audio), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("audio-\(suffix).png"))
      write(
        MainWindowView(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("audio-window-\(suffix).png"))
    }
    model.audio.stop()
  }

  /// HUD 样式与状态用独立偏好和演示时钟渲染，不启动计时或写入用户统计。
  private static func renderRestHUD(outputDirectory: URL) {
    let suite = "XStats.restHUDSnapshot.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { return }
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.language = L10n.language
    settings.restEnabled = true
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    if CommandLine.arguments.contains("--native-preview") {
      settings.restHUDStyle = .hourglass
      model.rest.showPreview(phase: .work, action: .pause)
      model.wellness.showPreview(activities: [], at: Date(), eyeRest: false)
      let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
      var panels: [RestPanel] = []
      for (index, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
        let panel = RestPanel(
          contentRect: NSRect(
            x: visible.midX - 290 + CGFloat(index) * 304,
            y: visible.midY - 92, width: 276, height: 184),
          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.appearance = NSAppearance(named: name)
        panel.hudDragEnabled = true
        panel.onEscape = { [weak panel] in panel?.orderOut(nil) }
        panel.contentView = NSHostingView(
          rootView: RestHUDView(
            rest: model.rest, close: { [weak panel] in panel?.orderOut(nil) },
            wellness: model.wellness
          )
          .environment(model).environment(\.colorScheme, index == 0 ? .light : .dark))
        panel.orderFrontRegardless()
        panels.append(panel)
      }
      defer { for panel in panels { panel.close() } }
      let path = outputDirectory.appendingPathComponent("native-windows.json")
      do {
        let records = panels.enumerated().map {
          [
            "appearance": $0.offset == 0 ? "light" : "dark",
            "windowNumber": $0.element.windowNumber,
          ] as [String: Any]
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted]).write(
          to: path)
      } catch {
        reportFailure(path, error: error)
        return
      }
      // 真正的玻璃由 WindowServer 合成，离屏 cacheDisplay 无法验证；限时展示且不启动真实计时。
      RunLoop.main.run(until: Date().addingTimeInterval(45))
      return
    }
    for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      guard let appearance = NSAppearance(named: name) else { continue }
      NSApp.appearance = appearance
      for style in RestHUDStyle.allCases {
        settings.restHUDStyle = style
        for (state, phase, action, eyeRest) in [
          ("focus", RestPhase.work, RestPrimaryAction.pause, false),
          ("paused", .work, .resume, false),
          ("break", .rest, .pause, false),
          ("eye-rest", .work, .pause, true),
        ] {
          model.rest.showPreview(phase: phase, action: action)
          model.wellness.showPreview(activities: [], at: Date(), eyeRest: eyeRest)
          write(
            RestHUDView(rest: model.rest, close: {}, wellness: model.wellness), model: model,
            appearance: appearance,
            to: outputDirectory.appendingPathComponent(
              "hud-\(style.rawValue)-\(state)-\(suffix).png"))
        }
      }
    }
  }

  /// 在独立原生窗口中采样短时进程成本；不创建通知管理器，也不访问用户数据库。
  private static func verifyWellnessRuntime(outputDirectory: URL) async throws {
    let suite = "XStats.wellnessRuntime.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else {
      throw CocoaError(.coderInvalidValue)
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.restEnabled = true
    settings.language = L10n.language
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    model.rest.sync()
    model.wellness.sync()
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 580),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "XStats · " + tr("护眼休息")
    window.contentView = NSHostingView(
      rootView: WellnessEyeRestView(wellness: model.wellness).environment(model))
    defer {
      window.orderOut(nil)
      model.rest.stop()
    }
    var observations: [[String: Any]] = []
    for (phase, seconds) in [("idle", 3.0), ("eye_rest_visible", 6.0), ("closed", 3.0)] {
      switch phase {
      case "eye_rest_visible":
        model.wellness.startShortRest()
        window.center()
        window.orderFrontRegardless()
      case "closed":
        model.wellness.finishEyeRest(completed: false)
        window.orderOut(nil)
      default: break
      }
      try await Task.sleep(for: .milliseconds(500))  // 先让首次布局与状态切换完成。
      var before = rusage()
      getrusage(RUSAGE_SELF, &before)
      let started = ProcessInfo.processInfo.systemUptime
      try await Task.sleep(for: .seconds(seconds))
      var after = rusage()
      getrusage(RUSAGE_SELF, &after)
      let cpu =
        Double(
          after.ru_utime.tv_sec - before.ru_utime.tv_sec + after.ru_stime.tv_sec
            - before.ru_stime.tv_sec)
        + Double(
          after.ru_utime.tv_usec - before.ru_utime.tv_usec + after.ru_stime.tv_usec
            - before.ru_stime.tv_usec) / 1e6
      let elapsed = ProcessInfo.processInfo.systemUptime - started
      observations.append([
        "phase": phase, "seconds": elapsed, "cpuPercent": cpu / elapsed * 100,
        "peakResidentBytes": after.ru_maxrss,
        "deadlineTimer": model.wellness.hasDeadlineTimer,
        "displayTimer": model.wellness.hasDisplayTimer,
      ])
    }
    await model.wellness.prepareForTermination()
    let report: [String: Any] = [
      "demo": true, "pid": ProcessInfo.processInfo.processIdentifier,
      "observations": observations,
      "timersReleased": !model.wellness.hasDisplayTimer && !model.wellness.hasDeadlineTimer,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: outputDirectory.appendingPathComponent("runtime.json"))
  }

  /// 使用隔离偏好测量真实计时器的可见、后台、挂起与关闭路径，不发系统通知。
  private static func verifyTimerRuntime(outputDirectory: URL) async throws {
    let suite = "XStats.timerRuntime.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else {
      throw CocoaError(.coderInvalidValue)
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.restEnabled = true
    let rest = RestController(settings: settings, localDefaults: defaults, sharedDefaults: nil)
    let timer = TimerController(rest: rest, settings: settings)
    let wellness = WellnessController(
      rest: rest, settings: settings, store: WellnessActivityStore(url: nil))
    defer {
      wellness.suspend()
      timer.stop()
      rest.stop()
    }
    rest.sync()
    var observations: [[String: Any]] = []
    for phase in [
      "idle", "visible", "hidden", "suspended", "manual-break", "screen-off-break", "break-ended",
      "disabled",
    ] {
      switch phase {
      case "visible":
        timer.select(.countdown)
        timer.setPageVisible(true)
        timer.startPauseCountdown()
        timer.startPauseStopwatch()
      case "hidden": timer.setPageVisible(false)
      case "suspended": timer.suspend()
      case "manual-break":
        timer.resume()
        wellness.startBreak(.short)
      case "screen-off-break": wellness.suspend(preservingRest: true)
      case "break-ended": wellness.finishEyeRest(completed: false)
      case "disabled":
        timer.resume()
        settings.restEnabled = false
        timer.sync()
        wellness.sync()
      default: break
      }
      var before = rusage()
      getrusage(RUSAGE_SELF, &before)
      let started = ProcessInfo.processInfo.systemUptime
      try await Task.sleep(for: .seconds(3))
      var after = rusage()
      getrusage(RUSAGE_SELF, &after)
      let cpu =
        Double(
          after.ru_utime.tv_sec - before.ru_utime.tv_sec + after.ru_stime.tv_sec
            - before.ru_stime.tv_sec)
        + Double(
          after.ru_utime.tv_usec - before.ru_utime.tv_usec + after.ru_stime.tv_usec
            - before.ru_stime.tv_usec) / 1e6
      let elapsed = ProcessInfo.processInfo.systemUptime - started
      observations.append([
        "phase": phase, "seconds": elapsed, "cpuPercent": cpu / elapsed * 100,
        "peakResidentBytes": after.ru_maxrss, "displayTimer": timer.hasDisplayTimer,
        "deadlineTimer": timer.hasDeadlineTimer,
        "breakActive": wellness.isEyeRestActive, "breakDisplayTimer": wellness.hasDisplayTimer,
        "breakDeadlineTimer": wellness.hasDeadlineTimer,
      ])
    }
    try JSONSerialization.data(
      withJSONObject: ["demo": true, "observations": observations],
      options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: outputDirectory.appendingPathComponent("timer-runtime.json"))
  }

  private static func renderTimers(outputDirectory: URL) {
    let suite = "XStats.timerSnapshot.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { return }
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.language = L10n.language
    settings.restEnabled = true
    settings.wellnessPreferences.breakEnabled = true
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    model.rest.showPreview()
    model.wellness.showPreview(activities: [], at: Date())
    for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      guard let appearance = NSAppearance(named: name) else { continue }
      NSApp.appearance = appearance
      for mode in TimerMode.allCases {
        model.rest.showPreview(action: mode == .pomodoro ? .pause : .startFocus)
        model.timer.showPreview(mode)
        write(
          RestPage().frame(width: 900).appLanguageEnvironment(), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("timer-\(mode.rawValue)-\(suffix).png"))
        write(
          TimerPopover(openPage: {}, showHUD: {}, close: {}), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("timer-popover-\(mode.rawValue)-\(suffix).png")
        )
        write(
          RestHUDView(rest: model.rest, close: {}, timer: model.timer), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("timer-hud-\(mode.rawValue)-\(suffix).png"))
        model.rest.showPreview(action: mode == .pomodoro ? .resume : .startFocus)
        model.timer.showPreview(mode, paused: true)
        write(
          TimerPopover(openPage: {}, showHUD: {}, close: {}), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent(
            "timer-popover-\(mode.rawValue)-paused-\(suffix).png"))
      }
      for mode in TimerMode.allCases {
        model.timer.stop()
        model.timer.select(mode)
        model.rest.showPreview(action: .startFocus)
        write(
          TimerPopover(openPage: {}, showHUD: {}, close: {}), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent(
            "timer-popover-\(mode.rawValue)-setup-\(suffix).png"))
      }
      for kind in [ManualBreakKind.short, .long] {
        write(
          TimerPopover(showsRest: true, breakKind: kind, openPage: {}, showHUD: {}, close: {}),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent(
            "timer-popover-break-\(kind)-setup-\(suffix).png"))
      }
      write(
        RestOptionsPopover(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("timer-settings-\(suffix).png"))
      write(
        RestOptionsPopover(forBreaks: true), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("timer-break-settings-\(suffix).png"))
      for kind in ManualBreakKind.allCases {
        model.wellness.showPreview(activities: [], at: Date(), eyeRest: true, kind: kind)
        write(
          TimerPopover(showsRest: true, openPage: {}, showHUD: {}, close: {}),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent(
            "timer-popover-break-\(kind)-active-\(suffix).png"))
        write(
          RestHUDView(rest: model.rest, close: {}, wellness: model.wellness, timer: model.timer),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("timer-break-\(kind)-hud-\(suffix).png"))
      }
      model.wellness.showPreview(activities: [], at: Date())
      for state in ["disabled", "paused", "scheduled"] {
        model.wellness.resume()
        model.wellness.showPreview(activities: [], at: Date())
        settings.wellnessPreferences.breakEnabled = state != "disabled"
        if state == "paused" { model.wellness.suspend() }
        write(
          TimerPopover(showsRest: true, openPage: {}, showHUD: {}, close: {}),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent(
            "timer-popover-reminder-\(state)-\(suffix).png"))
      }
    }
  }

  private static func renderWellness(outputDirectory: URL) {
    let suite = "XStats.wellnessSnapshot.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { return }
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.language = L10n.language
    settings.restEnabled = true
    settings.wellnessPreferences.breakEnabled = true
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    model.rest.showPreview()
    let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(14 * 3600)
    let activities = (0..<7).flatMap { index -> [WellnessActivity] in
      let day = now.addingTimeInterval(-Double(index) * 86400)
      return [
        .init(
          kind: .focus, startedAt: day.addingTimeInterval(-1500), endedAt: day, completed: true),
        .init(kind: .rest, startedAt: day, endedAt: day.addingTimeInterval(300), completed: true),
      ]
    }
    for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      guard let appearance = NSAppearance(named: name) else { continue }
      NSApp.appearance = appearance
      model.wellness.showPreview(activities: activities, at: now)
      write(
        RestPage().frame(width: 900).appLanguageEnvironment(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("wellness-page-\(suffix).png"))
      for (state, phase, action) in [
        ("idle", RestPhase.work, RestPrimaryAction.startFocus),
        ("paused", .work, .resume), ("break", .rest, .pause),
        ("next-round", .work, .startNextRound),
      ] {
        model.rest.showPreview(phase: phase, action: action)
        write(
          RestPage().frame(width: 900).appLanguageEnvironment(), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("wellness-\(state)-\(suffix).png"))
      }
      model.rest.showPreview()
      write(
        RestOptionsPopover(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("focus-settings-\(suffix).png"))
      write(
        WellnessHealthCard().padding(16).frame(width: 560).appLanguageEnvironment(), model: model,
        appearance: appearance,
        to: outputDirectory.appendingPathComponent("wellness-card-\(suffix).png"))
      write(
        WellnessPreferencesSettings().padding(16).frame(width: 480).appLanguageEnvironment(),
        model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("wellness-settings-\(suffix).png"))
      write(
        WellnessStatisticsView(wellness: model.wellness), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("wellness-statistics-\(suffix).png"))
      model.wellness.showPreview(activities: activities, at: now, eyeRest: true)
      write(
        WellnessEyeRestView(wellness: model.wellness).frame(width: 680), model: model,
        appearance: appearance,
        to: outputDirectory.appendingPathComponent("wellness-eye-rest-\(suffix).png"))

    }
  }

  /// README 已有功能使用临时历史库、虚构 AI 数据和设备状态，不调用真实采样/控制后端。
  private static func renderFeatures(outputDirectory: URL) async {
    let suite = "XStats.featuresSnapshot.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { return }
    defer { defaults.removePersistentDomain(forName: suite) }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
      suite, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    do {
      try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
      let historyURL = temporary.appendingPathComponent("history.sqlite")
      let database = try HistoryDatabase(url: historyURL)
      let now = Int(Date().timeIntervalSince1970) / 60 * 60
      for index in 0..<1440 where !(600..<720).contains(index) {
        let wave = (sin(Double(index) / 75) + 1) / 2
        await database.insert(
          HistoryRecord(
            minute: now - (1440 - index) * 60,
            cpu: 0.1 + wave * 0.35, cpuMax: 0.3 + wave * 0.5, memory: 0.5 + wave * 0.15,
            pressure: 1, download: 500_000 + wave * 5_000_000, upload: 100_000 + wave * 500_000,
            gpu: wave * 0.3, temperature: 40 + wave * 25, power: 12 + wave * 20))
      }
      let settings = AppSettings(defaults: defaults)
      settings.language = L10n.language
      settings.aiUsageEnabled = true
      settings.aiUsageSources = [.codex]
      settings.restEnabled = true
      settings.historyEnabled = true
      let model = AppModel(
        settings: settings, historyURL: historyURL,
        aiUsageProviders: [SnapshotAIUsageProvider()], aiQuotaProviders: [SnapshotAIQuotaProvider()]
      )
      await model.aiUsage.refresh()
      // 单价仅用于演示费用估算，不代表模型的当前公开价格或用户账单。
      model.aiUsage.showPreview(
        costReferences: .init(
          catalog: .init(
            prices: [
              "gpt-5.4": .init(input: 2, output: 10, cacheRead: 0.2),
              "gpt-5.4-mini": .init(input: 0.5, output: 2, cacheRead: 0.05),
            ], fetchedAt: Date()), exchangeRate: nil))
      model.history.load(.day)
      while model.history.isQuerying { try await Task.sleep(for: .milliseconds(10)) }
      model.rest.showPreview()
      model.displays.showPreview(
        catalog: [
          DisplayInfo(
            target: .init(id: 1, identity: "demo.display"), name: "Demo Display", isBuiltIn: false,
            isMain: true,
            summary: "27″ · 5120×2880 · 60 Hz")
        ],
        readings: [
          1: [
            .brightness: .value(.init(current: 65, maximum: 100)),
            .contrast: .value(.init(current: 75, maximum: 100)),
            .volume: .value(.init(current: 30, maximum: 100)),
          ]
        ])
      for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        guard let appearance = NSAppearance(named: name) else { continue }
        NSApp.appearance = appearance
        write(
          AIUsagePage(initialActivityMode: .monthly).frame(width: 900).appLanguageEnvironment(),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("ai-usage-\(suffix).png"))
        write(
          HistoryPage().frame(width: 900).appLanguageEnvironment(), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("history-\(suffix).png"))
        write(
          RestPage().frame(width: 900).appLanguageEnvironment(), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("rest-\(suffix).png"))
        settings.setModuleEnabled(.gpu, false)
        model.featureSettingsTab = .basic
        write(
          FeatureSettings().frame(width: 900).appLanguageEnvironment(), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("monitoring-features-\(suffix).png"))
        model.featureSettingsTab = .optional
        write(
          FeatureSettings().frame(width: 900).appLanguageEnvironment(), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("optional-features-\(suffix).png"))
        model.featureSettingsTab = .experimental
        write(
          FeatureSettings().frame(width: 900).appLanguageEnvironment(), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("experimental-features-\(suffix).png"))
        write(
          DisabledMonitoringPage(module: .gpu).frame(width: 900).appLanguageEnvironment(),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("monitoring-disabled-\(suffix).png"))
        settings.setModuleEnabled(.gpu, true)
        write(
          PopoverRootView(item: .display).appLanguageEnvironment(), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("displays-\(suffix).png"))
        settings.setModuleEnabled(.display, false)
        write(
          PopoverRootView(item: .display).appLanguageEnvironment(), model: model,
          appearance: appearance,
          to: outputDirectory.appendingPathComponent("displays-information-only-\(suffix).png"))
        settings.setModuleEnabled(.display, true)
      }
    } catch { reportFailure(outputDirectory, error: error) }
  }

  /// 显示器走查只读信息和 Get VCP 能力，不执行设置写入。
  private static func renderDisplays(outputDirectory: URL) async {
    let suite = "XStats.displaySnapshot.\(UUID())"
    guard let defaults = UserDefaults(suiteName: suite) else { return }
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.language = L10n.language
    settings.menuBarItems = [.display]
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    model.displays.start()
    model.displays.setVisible(true)
    await model.displays.refresh()
    model.displays.setVisible(false)
    model.displays.stop()
    for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      guard let appearance = NSAppearance(named: name) else { continue }
      NSApp.appearance = appearance
      write(
        PopoverRootView(item: .display), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("displays-\(suffix).png"))
      model.combinedPopoverTab = nil
      write(
        CombinedPopoverView(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("overview-\(suffix).png"))
      model.combinedPopoverTab = .display
      write(
        CombinedPopoverView(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("expanded-\(suffix).png"))
    }
  }

  /// 菜单栏走查只启动相关指标采样，不扫描清理目录、不读取 AI 日志或查询更新。
  private static func renderMenuBar(outputDirectory: URL) async {
    let suite = "XStats.menuBarSnapshot.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return }
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.language = L10n.language
    settings.menuBarItems = Set(MenuBarItem.allCases.filter { $0 != .aiUsage })
    settings.setMenuBarOrder([.network, .cpu, .memory, .gpu, .disk])
    settings.processesEnabled = true
    settings.cleanerEnabled = true
    settings.menuBarLayout = .iconOnly
    settings.panelTab = .settingsMenuBar
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    model.isCombinedPopoverOpen = true
    await model.hub.update(model.demand)
    await model.hub.start(primeAllMetrics: false) { snapshot in model.store.apply(snapshot) }
    try? await Task.sleep(for: .seconds(3))
    await model.hub.stop()
    model.displays.refreshCatalog()
    model.isMainWindowVisible = true
    // CPU 详情需要频率数据；显式按详情需求采一次，避免借用全量预采样的副作用。
    model.combinedPopoverTab = .cpu
    await model.hub.update(model.demand)
    await model.hub.start(primeAllMetrics: false) { snapshot in model.store.apply(snapshot) }
    // 频率首次采样只建立计数器基线；等待有效差值，硬件不支持时最多等 4 秒。
    for _ in 0..<16 {
      try? await Task.sleep(for: .milliseconds(250))
      if model.store.power?.clusterFrequency.isEmpty == false { break }
    }
    await model.hub.stop()
    for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      guard let appearance = NSAppearance(named: name) else { continue }
      NSApp.appearance = appearance
      model.combinedPopoverTab = nil
      write(
        CombinedPopoverView(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("overview-\(suffix).png"))
      for item: MenuBarItem in [.cpu, .network] {
        model.combinedPopoverTab = item
        write(
          CombinedPopoverView(), model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("detail-\(item.rawValue)-\(suffix).png"))
      }
      model.combinedPopoverTab = nil
      for layout in MenuBarLayout.allCases {
        settings.menuBarLayout = layout
        write(
          MainWindowView(), model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("settings-\(layout.rawValue)-\(suffix).png"))
        let image = MenuBarRenderer.preview(
          MenuBarRenderer.image(for: model), dark: suffix == "dark")
        writePNG(
          image, scale: 2,
          to: outputDirectory.appendingPathComponent("menubar-\(layout.rawValue)-\(suffix).png"))
      }
    }
  }

  private static func renderCalendar(outputDirectory: URL, gallery: Bool = false) {
    let name = "XStats.calendarSnapshot.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else { return }
    defer { defaults.removePersistentDomain(forName: name) }
    // 固定地区与周起始日，截图不随运行机器的系统设置变化。
    var weekCalendar = Calendar(identifier: .gregorian)
    weekCalendar.firstWeekday = 2
    let settings = AppSettings(
      defaults: defaults, calendarLocale: Locale(identifier: "zh_CN"), calendar: weekCalendar)
    settings.calendarEnabled = true
    settings.language = L10n.language
    let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [])
    guard let september = CalendarEngine.day(year: 2026, month: 9, day: 23)?.date,
      let summer = CalendarEngine.day(year: 2024, month: 6, day: 11)?.date
    else { return }
    for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
      guard let appearance = NSAppearance(named: name) else { continue }
      NSApp.appearance = appearance
      if gallery, !L10n.language.isChinese {
        // 公共外语图库展示通用日历；农历/中国节假日的专项走查仍由 --calendar-only 覆盖。
        settings.calendarFeatures = []
        settings.calendarPreferences.showHolidayOverview = false
        settings.calendarPreferences.showEvents = false
        settings.calendarPreferences.showReminders = false
        write(
          CalendarPopover(referenceDate: september, firstWeekday: settings.calendarFirstWeekday),
          model: model, appearance: appearance,
          to: outputDirectory.appendingPathComponent("calendar-\(suffix).png"))
        continue
      }
      settings.calendarFeatures = CalendarFeature.mainlandChinaDefaults
      write(
        CalendarPopover(referenceDate: september, firstWeekday: settings.calendarFirstWeekday),
        model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("calendar-\(suffix).png"))
      settings.calendarPreferences.largeLunarText = true
      settings.calendarPreferences.strongerLunarText = true
      settings.calendarPreferences.showEvents = true
      settings.calendarPreferences.showReminders = true
      write(
        CalendarPopover(referenceDate: september, firstWeekday: settings.calendarFirstWeekday),
        model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("calendar-agenda-\(suffix).png"))
      write(
        CalendarOptionsPopover(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("calendar-options-\(suffix).png"))
      settings.calendarPreferences.display = .custom
      settings.calendarPreferences.dateFormat = "yyyy-MM-dd"
      write(
        CalendarOptionsPopover(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("calendar-custom-\(suffix).png"))
      settings.calendarPreferences.display = .dateLunar
      write(
        CalendarOptionsPopover(), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("calendar-lunar-\(suffix).png"))
      // 重置呈现偏好；黄历在日期详情中固定显示，其他选项沿用固定的中国大陆默认值。
      settings.calendarPreferences = CalendarPreferences(locale: Locale(identifier: "zh_CN"))
      write(
        CalendarPopover(
          referenceDate: september, showsDayDetails: true,
          firstWeekday: settings.calendarFirstWeekday), model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("calendar-almanac-\(suffix).png"))
      settings.calendarFeatures = Set(CalendarFeature.allCases)
      write(
        CalendarPopover(
          referenceDate: summer, showsDayDetails: true, firstWeekday: settings.calendarFirstWeekday),
        model: model, appearance: appearance,
        to: outputDirectory.appendingPathComponent("calendar-details-\(suffix).png"))
    }
  }

  /// 用真实的 NSHostingView 放进离屏窗口截图，渲染路径与 App 内一致
  private static func write<V: View>(
    _ view: V, model: AppModel, appearance: NSAppearance, to url: URL
  ) {
    let hosting = NSHostingView(
      rootView:
        view
        .environment(model)
        .environment(\.isSnapshot, true)
        .background(DS.Palette.background))
    hosting.appearance = appearance
    let size = hosting.fittingSize
    hosting.frame = CGRect(origin: .zero, size: size)

    let window = NSWindow(
      contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = appearance
    window.backgroundColor = .dsBackground
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    defer { window.orderOut(nil) }
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
      reportFailure(url, error: CocoaError(.coderInvalidValue))
      return
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    do {
      guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.coderInvalidValue)
      }
      try data.write(to: url)
    } catch { reportFailure(url, error: error) }
  }

  private static func writePNG(_ image: NSImage, scale: CGFloat, to url: URL) {
    let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else {
      reportFailure(url, error: CocoaError(.coderInvalidValue))
      return
    }
    bitmap.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(origin: .zero, size: image.size))
    NSGraphicsContext.restoreGraphicsState()
    do {
      guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.coderInvalidValue)
      }
      try data.write(to: url)
    } catch { reportFailure(url, error: error) }
  }

  private static func reportFailure(_ url: URL, error: any Error) {
    didFail = true
    FileHandle.standardError.write(
      Data("Snapshot failed: \(url.path): \(error.localizedDescription)\n".utf8))
  }
}

private struct SnapshotAIUsageProvider: AIUsageProvider {
  let id = AIProviderID.codex

  func fetch() async throws -> AIUsageSnapshot {
    let now = Date()
    var snapshot = AIUsageSnapshot(provider: .codex, fetchedAt: now)
    snapshot.localUsage = LocalUsageReport(
      rows: (0..<30).flatMap { day in
        let date = Calendar.current.date(
          byAdding: .day, value: -day, to: Calendar.current.startOfDay(for: now))!
        return [
          ModelTokenUsage(
            day: date, model: "gpt-5.4", input: 240_000 + day * 3_000,
            cached: 180_000, output: 32_000, records: 18),
          ModelTokenUsage(
            day: date, model: "gpt-5.4-mini", input: 80_000,
            cached: 40_000, output: 12_000, records: 10),
        ]
      }, fileCount: 42)
    return snapshot
  }
}

private struct SnapshotAIQuotaProvider: AIQuotaProvider {
  let id = AIProviderID.codex
  func fetch() async throws -> AIQuotaSnapshot {
    let now = Date()
    let fields: [String: Any] = [
      "provider": "codex", "source": "direct", "fetchedAt": now.timeIntervalSinceReferenceDate,
      "windows": [
        [
          "kind": "session", "usedPercent": 32,
          "resetsAt": now.addingTimeInterval(7200).timeIntervalSinceReferenceDate,
        ],
        [
          "kind": "weekly", "usedPercent": 41,
          "resetsAt": now.addingTimeInterval(4 * 86400).timeIntervalSinceReferenceDate,
        ],
      ],
    ]
    var snapshot = try JSONDecoder().decode(
      AIQuotaSnapshot.self, from: JSONSerialization.data(withJSONObject: fields))
    snapshot.details = .init(plan: "Pro")
    return snapshot
  }
}
