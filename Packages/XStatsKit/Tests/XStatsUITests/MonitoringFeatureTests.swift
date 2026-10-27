// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Metrics
import SMC
import Testing
@testable import XStatsUI

/// 每个用例使用独立偏好域，实例释放时删除，避免在本机留下测试 plist。
@MainActor
final class MonitoringFeatureTests {
  private var suites: [String] = []

  deinit {
    for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
  }

  @Test func changingFeatureCategoryKeepsPreferencesAndSamplingDemandUnchanged() {
    let settings = settings()
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    settings.setModuleEnabled(.gpu, false)
    settings.panelTab = .settingsFeatures
    model.isMainWindowVisible = true
    let preferences = settings.exportDocument()
    let demand = model.demand
    for _ in 0..<10 {
      for tab in FeatureSettingsTab.allCases {
        model.featureSettingsTab = tab
      }
    }
    #expect(settings.exportDocument() == preferences)
    #expect(model.demand == demand)
    #expect(!settings.isModuleEnabled(.gpu))
  }

  private func settings() -> AppSettings {
    let suite = "MonitoringFeatureTests.\(UUID())"
    suites.append(suite)
    let defaults = UserDefaults(suiteName: suite)!
    return AppSettings(defaults: defaults)
  }

  @Test func menuEntryEnablesItsModuleButRemovingItDoesNotDisableTheModule() {
    let settings = settings()
    settings.setModuleEnabled(.gpu, false)
    settings.setEnabled(.gpu, true)
    #expect(settings.isModuleEnabled(.gpu))
    #expect(settings.orderedMenuBarItems.contains(.gpu))
    settings.setEnabled(.gpu, false)
    #expect(settings.isModuleEnabled(.gpu))
    settings.setModuleEnabled(.thermal, false)
    settings.menuBarItems.insert(.fan)
    #expect(settings.isModuleEnabled(.thermal))
    settings.setEnabled(.temperature, true)
    settings.setModuleEnabled(.thermal, false)
    #expect(!settings.menuBarItems.contains(.fan) && settings.menuBarItems.contains(.temperature))
    #expect(settings.isModuleEnabled(.battery))
    settings.enabledMonitoringModules = []
    settings.menuBarItems = [.cpu, .gpu, .memory]
    #expect(settings.orderedMenuBarItems == [.cpu, .memory, .gpu])
  }

  @Test func displayMenuShowsInfoWithoutEnablingParameterControls() {
    let settings = settings()
    settings.setModuleEnabled(.display, false)
    settings.setEnabled(.display, true)
    #expect(settings.orderedMenuBarItems.contains(.display))
    #expect(!settings.isModuleEnabled(.display))
    settings.setModuleEnabled(.display, true)
    settings.setModuleEnabled(.display, false)
    #expect(settings.orderedMenuBarItems.contains(.display))
    #expect(settings.exportDocument().enabledMonitoringModules?.contains("display") == false)
  }

  @Test func menuEntriesAlsoEnableExistingOptionalFeatures() {
    let settings = settings()
    settings.setEnabled(.aiUsage, true)
    settings.setEnabled(.audio, true)
    #expect(settings.aiUsageEnabled && settings.audioEnabled)
  }

  @Test func noConsumerMeansNoSamplingEvenWhenModulesAreEnabled() {
    let settings = settings()
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.enabledAlerts = []
    #expect(!model.demand.hasSamples)
    settings.historyEnabled = true
    #expect(model.demand.cpu && model.demand.memory && model.demand.network)
    settings.enabledMonitoringModules = []
    #expect(!model.demand.hasSamples)
  }

  @Test func disabledModulesCannotBeReactivatedByVisiblePagesOrAlerts() {
    let settings = settings()
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    settings.enabledMonitoringModules = []
    settings.enabledAlerts = Set(AlertKind.allCases)
    model.isMainWindowVisible = true
    for tab in [
      PanelTab.overview, .cpu, .gpu, .memory, .network, .disk, .thermal, .battery, .system,
    ] {
      settings.panelTab = tab
      let showsBatteryInfo = [.overview, .battery, .system].contains(tab)
      #expect(model.demand.battery == showsBatteryInfo)
      var otherDemand = model.demand
      otherDemand.battery = false
      #expect(!otherDemand.hasSamples)
      #expect(model.bluetoothDemand == ([.battery, .system].contains(tab) ? .foreground : .off))
      #expect(!model.displayControlsVisible)
    }
    #expect(settings.activeAlerts.isEmpty)
    #expect(settings.enabledAlerts == Set(AlertKind.allCases), "关闭功能保留告警偏好")
  }

  /// 旧版偏好域：只写入模块集合、菜单栏项和告警，按升级后首次启动读取。
  private func legacyDefaults(
    modules: [MonitoringModule]?, items: [MenuBarItem] = [.temperature],
    alerts: [AlertKind] = [.cpuTemperature]
  ) -> UserDefaults {
    let suite = "MonitoringFeatureTests.\(UUID())"
    suites.append(suite)
    let defaults = UserDefaults(suiteName: suite)!
    if let modules { defaults.set(modules.map(\.rawValue), forKey: "enabledMonitoringModules") }
    defaults.set(items.map(\.rawValue), forKey: "menuBarItems")
    defaults.set(alerts.map(\.rawValue), forKey: "enabledAlerts")
    return defaults
  }

  @Test func upgradeWithThermalOnlyEnablesEnergyAndKeepsTemperatureFeatures() {
    let defaults = legacyDefaults(modules: [.cpu, .thermal])
    let settings = AppSettings(defaults: defaults)
    #expect(settings.isModuleEnabled(.battery) && settings.isModuleEnabled(.thermal))
    #expect(settings.isEnabled(.temperature))
    #expect(settings.activeAlerts == [.cpuTemperature])
    // 再次启动不重复迁移：用户随后关闭能耗应被保留。
    settings.setModuleEnabled(.battery, false)
    let reloaded = AppSettings(defaults: defaults)
    #expect(!reloaded.isModuleEnabled(.battery) && reloaded.isModuleEnabled(.thermal))
  }

  @Test func upgradeWithBatteryOnlyKeepsCPUTemperatureAlertOff() {
    let defaults = legacyDefaults(
      modules: [.cpu, .battery], alerts: [.cpuTemperature, .batteryHealth])
    let settings = AppSettings(defaults: defaults)
    #expect(settings.enabledMonitoringModules == [.cpu, .battery])
    #expect(settings.enabledAlerts == [.batteryHealth])
    // 迁移后用户重新开启告警，再次启动不能被重复关闭。
    settings.enabledAlerts.insert(.cpuTemperature)
    let reloaded = AppSettings(defaults: defaults)
    #expect(reloaded.enabledAlerts == [.cpuTemperature, .batteryHealth])
  }

  @Test func freshInstallAndOtherCombinationsOnlyRecordTheMigration() {
    let fresh = legacyDefaults(modules: nil, items: [.cpu], alerts: [])
    let freshSettings = AppSettings(defaults: fresh)
    #expect(freshSettings.enabledMonitoringModules == Set(MonitoringModule.allCases))
    #expect(fresh.bool(forKey: "energyModulesMigrated"))
    // 标记已写入后，即使之后出现旧组合也不再改写。
    freshSettings.enabledMonitoringModules = [.thermal]
    #expect(!AppSettings(defaults: fresh).isModuleEnabled(.battery))
    for modules: [MonitoringModule] in [[.battery, .thermal], [.cpu]] {
      let defaults = legacyDefaults(modules: modules)
      let settings = AppSettings(defaults: defaults)
      #expect(settings.enabledMonitoringModules == Set(modules))
      #expect(settings.enabledAlerts == [.cpuTemperature])
      #expect(defaults.bool(forKey: "energyModulesMigrated"))
    }
  }

  @Test func disabledEnergyPageDoesNotKeepOneSecondSampling() {
    let settings = settings()
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    settings.menuBarItems = []
    settings.panelTab = .battery
    model.isMainWindowVisible = true
    #expect(settings.historyEnabled)
    #expect(model.demand.interval == .seconds(1))
    settings.setModuleEnabled(.battery, false)
    // 历史记录仍需其他模块采样，回到后台间隔而不是实时页的每秒采样。
    #expect(model.demand.interval == .seconds(settings.refreshSeconds))
    settings.enabledMonitoringModules = []
    #expect(model.demand.interval == .seconds(10))
  }

  @Test func processSummaryRequestsEnabledCPUWithoutHistoryOrMenu() {
    let settings = settings()
    settings.historyEnabled = false
    settings.menuBarItems = []
    settings.processesEnabled = true
    settings.panelTab = .processes
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    model.isMainWindowVisible = true
    #expect(model.demand.cpu && model.demand.systemProcesses)
    settings.setModuleEnabled(.cpu, false)
    #expect(!model.demand.cpu && model.demand.systemProcesses)
  }

  @Test func lateSnapshotsCannotRepublishDisabledMetrics() {
    let settings = settings()
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    var snapshot = MetricsSnapshot()
    snapshot.cpu = CPULoad(total: 0.95, user: 0.6, system: 0.35, perCore: [0.95], loadAverage: [])
    model.handle(snapshot)
    #expect(model.store.cpu != nil)
    settings.setModuleEnabled(.cpu, false)
    model.handle(snapshot)
    #expect(model.store.cpu == nil)
    #expect(model.store.cpuTotal.elements.isEmpty)
  }

  @Test func disablingModulesClearsTheirLiveHistories() {
    let store = MetricsStore(readBattery: false)
    var snapshot = MetricsSnapshot()
    snapshot.network = NetworkRate(
      downloadBytesPerSecond: 1_000, uploadBytesPerSecond: 500, totalDownloaded: 0, totalUploaded: 0
    )
    snapshot.gpu = GPUUsage(name: "Fixture GPU", utilization: 0.4)
    snapshot.power = PowerReading(system: 30)
    store.apply(snapshot)
    #expect(
      !store.downloadHistory.elements.isEmpty && !store.gpuHistory.elements.isEmpty
        && !store.powerHistory.elements.isEmpty)
    store.clearDisabledModules([.cpu, .memory, .disk, .battery])
    #expect(
      store.network == nil && store.downloadHistory.elements.isEmpty
        && store.uploadHistory.elements.isEmpty,
      "网络关闭后不能保留旧速率曲线")
    #expect(store.gpu == nil && store.gpuHistory.elements.isEmpty, "GPU 关闭后不能保留旧占用曲线")
    #expect(store.power == nil && store.powerHistory.elements.isEmpty, "没有功耗需求时不能保留旧功耗曲线")
  }

  @Test func closingAndReenablingRejectsSnapshotsAlreadyQueuedBeforeDemandDelivery() {
    let settings = settings()
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    var snapshot = MetricsSnapshot()
    snapshot.samplingGeneration = settings.monitoringGeneration
    snapshot.cpu = CPULoad(total: 0.95, user: 0.6, system: 0.35, perCore: [0.95], loadAverage: [])
    settings.setModuleEnabled(.cpu, false)
    settings.setModuleEnabled(.cpu, true)
    model.handle(snapshot)
    #expect(model.store.cpu == nil)
    snapshot.samplingGeneration = settings.monitoringGeneration
    model.handle(snapshot)
    #expect(model.store.cpu?.total == 0.95)
  }

  @Test func cpuFrequencySurvivesWithoutThermalPowerAndDisabledThermalValuesStayHidden() {
    let settings = settings()
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    settings.setModuleEnabled(.thermal, false)
    var snapshot = MetricsSnapshot()
    snapshot.power = PowerReading(system: 30, gpu: 5, clusterFrequency: [0: 3_000])
    model.handle(snapshot)
    #expect(model.store.power?.clusterFrequency == [0: 3_000])
    #expect(model.store.power?.system == nil && model.store.power?.gpu == nil)
    #expect(model.store.powerHistory.elements.isEmpty)
  }

  @Test func energyIncludesTemperaturesWithoutFansAndStopsWhenThePageCloses() {
    let settings = settings()
    settings.enabledMonitoringModules = [.battery]
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.enabledAlerts = []
    settings.panelTab = .battery
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    var basic = MetricsSnapshot()
    basic.battery = BatteryStatus(
      level: 0.8, isCharging: false, isPluggedIn: true,
      isFullyCharged: false, minutesRemaining: nil, cycleCount: 100, health: 0.9)
    model.store.apply(basic)
    model.isMainWindowVisible = true
    #expect(model.demand.battery && model.demand.power)
    #expect(model.demand.temperatures == Set(TemperatureGroup.allCases))
    #expect(!model.demand.fans && !model.demand.cpuFrequency)
    var snapshot = MetricsSnapshot()
    snapshot.power = PowerReading(system: 30, adapter: 40, battery: -10, gpu: 5)
    model.handle(snapshot)
    #expect(model.store.power?.system == 30 && model.store.powerHistory.elements == [30])
    #expect(!settings.isModuleEnabled(.thermal))
    model.isMainWindowVisible = false
    #expect(!model.demand.hasSamples)
    model.handle(snapshot)
    #expect(model.store.power == nil && model.store.powerHistory.elements.isEmpty)
  }

  @Test func batteryAppEnergyOnlyCollectsWhileItsSectionIsVisible() {
    let settings = settings()
    settings.enabledMonitoringModules = [.battery]
    settings.menuBarItems = [.battery]
    settings.historyEnabled = false
    settings.enabledAlerts = []
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    var basic = MetricsSnapshot()
    basic.battery = BatteryStatus(
      level: 0.8, isCharging: false, isPluggedIn: true,
      isFullyCharged: false, minutesRemaining: nil, cycleCount: 100, health: 0.9)
    model.store.apply(basic)
    #expect(!model.demand.appEnergy)
    model.openPopover = .battery
    #expect(model.demand.appEnergy && !model.demand.processes && !model.demand.systemProcesses)
    settings.customPopoverContentEnabled = true
    settings.hiddenPopoverSections.insert(.batteryApps)
    #expect(!model.demand.appEnergy && model.demand.power)
    settings.panelTab = .battery
    model.isMainWindowVisible = true
    #expect(model.demand.appEnergy)
    var snapshot = MetricsSnapshot()
    snapshot.appEnergy = AppEnergyReading(apps: [], totalWatts: 0.5, interval: 5, isAvailable: true)
    model.handle(snapshot)
    #expect(model.store.appEnergy?.totalWatts == 0.5)
    settings.setModuleEnabled(.battery, false)
    model.applyMonitoringSettings()
    model.handle(snapshot)
    #expect(!model.demand.appEnergy && model.store.appEnergy == nil)
    settings.setModuleEnabled(.battery, true)
    model.handle(snapshot)
    model.isMainWindowVisible = false
    model.applyMonitoringSettings()
    model.handle(snapshot)
    #expect(model.store.appEnergy == nil && !model.demand.appEnergy)
  }

  @Test func energyAndFanReadingsRespectIndependentSwitchesAndKeepHardwareDetection() {
    let settings = settings()
    settings.enabledMonitoringModules = [.battery]
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.enabledAlerts = [.cpuTemperature]
    settings.panelTab = .battery
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    model.isMainWindowVisible = true
    var snapshot = MetricsSnapshot()
    snapshot.sensors = SensorReadings(
      temperatures: [
        TemperatureSummary(group: .cpu, average: 50, maximum: 60, sensorCount: 4)
      ],
      fans: [
        FanState(
          id: 0, current: 2_000, minimum: 1_000, maximum: 5_000,
          target: 2_000, isManual: false)
      ], fanCount: 1)
    model.handle(snapshot)
    #expect(model.store.supportsFans, "温度采样仍应识别风扇硬件，不开启风扇采集")
    #expect(model.store.sensors?.temperature(.cpu)?.maximum == 60)
    #expect(model.store.sensors?.fans.isEmpty == true && !model.demand.fans)
    #expect(model.demand.power && model.demand.appEnergy)
    #expect(settings.activeAlerts.contains(.cpuTemperature))

    settings.setModuleEnabled(.battery, false)
    settings.setModuleEnabled(.thermal, true)
    settings.panelTab = .thermal
    model.applyMonitoringSettings()
    model.handle(snapshot)
    #expect(model.demand.fans && model.demand.temperatures.isEmpty)
    #expect(!model.demand.power && !model.demand.appEnergy)
    #expect(model.store.sensors?.temperatures.isEmpty == true)
    #expect(model.store.sensors?.fans.count == 1)
    #expect(!settings.activeAlerts.contains(.cpuTemperature))
    #expect(PanelTab(item: .temperature) == .battery && PanelTab(item: .fan) == .thermal)
    #expect(MenuBarItem.temperature.monitoringModule == .battery)
    #expect(MenuBarItem.fan.monitoringModule == .thermal)
    model.isMainWindowVisible = false
    #expect(!model.demand.hasSamples)
  }

  @Test func batteryPopoverRequestsPowerOnlyWhenItsSectionIsVisible() {
    let settings = settings()
    settings.enabledMonitoringModules = [.battery]
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.enabledAlerts = []
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    model.openPopover = .battery
    #expect(model.demand.power && model.demand.appEnergy, "能耗不依赖内置电池")
    var basic = MetricsSnapshot()
    basic.battery = BatteryStatus(
      level: 0.8, isCharging: false, isPluggedIn: true,
      isFullyCharged: false, minutesRemaining: nil, cycleCount: 100, health: 0.9)
    model.store.apply(basic)
    #expect(model.demand.power)
    settings.customPopoverContentEnabled = true
    settings.hiddenPopoverSections.insert(.batteryPower)
    #expect(model.demand.battery && !model.demand.power)
    // 详情页始终展示所有分区，不受弹窗分区偏好影响。
    settings.panelTab = .battery
    model.isMainWindowVisible = true
    #expect(model.demand.power)
    settings.setModuleEnabled(.battery, false)
    #expect(!model.demand.power && model.demand.battery)
  }

  @Test func disabledBatteryMonitoringKeepsBasicInformationAndMenuChoice() {
    let settings = settings()
    settings.enabledMonitoringModules = []
    settings.historyEnabled = false
    settings.enabledAlerts = [.batteryHealth]
    settings.menuBarItems = [.battery]
    #expect(!settings.isModuleEnabled(.battery), "添加电池入口不能开启耗电采集")
    settings.panelTab = .battery
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    model.isMainWindowVisible = true
    #expect(settings.isEnabled(.battery) && settings.orderedMenuBarItems.contains(.battery))
    #expect(model.demand.battery && !model.demand.power && !model.demand.processes)
    #expect(model.demand.interval == .seconds(10))
    #expect(model.bluetoothDemand == .foreground && settings.activeAlerts.isEmpty)
    var snapshot = MetricsSnapshot()
    snapshot.battery = BatteryStatus(
      level: 0.8, isCharging: false, isPluggedIn: true,
      isFullyCharged: false, minutesRemaining: nil, cycleCount: 100,
      health: 0.9, adapterWatts: 68)
    snapshot.power = PowerReading(system: 30)
    model.handle(snapshot)
    #expect(model.store.battery?.level == 0.8)
    #expect(model.store.power == nil && model.store.powerHistory.elements.isEmpty)
    settings.setModuleEnabled(.battery, true)
    #expect(model.demand.power)
    settings.setModuleEnabled(.battery, false)
    model.applyMonitoringSettings()
    #expect(model.store.battery?.level == 0.8 && settings.isEnabled(.battery))
    settings.setEnabled(.battery, false)
    settings.setEnabled(.battery, true)
    #expect(!settings.isModuleEnabled(.battery))
    model.isMainWindowVisible = false
    settings.setEnabled(.battery, false)
    #expect(!model.demand.hasSamples && model.bluetoothDemand == .off)
  }

  @Test(arguments: [false, true])
  func disabledMonitoringKeepsHardwareWithoutLiveReadings(_ hasCachedPublicAddress: Bool)
    async throws
  {
    let settings = settings()
    settings.enabledMonitoringModules = []
    settings.historyEnabled = false
    settings.menuBarItems = []
    let defaults = settings.networkObservationDefaults
    if hasCachedPublicAddress {
      settings.publicIPLookup = true
      let data = try JSONSerialization.data(withJSONObject: [
        "results": [IPFamily.v4.rawValue: ["ipv4": "198.51.100.1"]], "geoDates": [:],
      ])
      defaults.set(data, forKey: "publicAddressCache4")
    }
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient(),
      networkCacheDefaults: defaults)
    let initialPublicResults = model.network.publicResults
    #expect(initialPublicResults.isEmpty == !hasCachedPublicAddress)
    let hardware = model.store.system
    var snapshot = MetricsSnapshot()
    snapshot.gpu = GPUUsage(name: "Fixture GPU", utilization: 0.9, coreCount: 16)
    snapshot.disk = DiskUsage(volumeName: "Fixture", total: 1_000, available: 300)
    model.store.apply(snapshot)
    model.applyMonitoringSettings()
    #expect(model.store.gpu == nil && model.store.gpuHistory.elements.isEmpty)
    #expect(model.store.system == hardware && !model.store.topology.brand.isEmpty)
    #expect(model.store.disk?.total == 1_000)
    // 打开基础容量信息只做一次读取，不能开启磁盘活动、进程或健康监控。
    settings.panelTab = .disk
    model.isMainWindowVisible = true
    await model.store.refreshDiskCapacity()
    #expect(model.store.disk?.total ?? 0 > 0)
    #expect(
      !model.demand.hasSamples && model.store.diskActivity == nil && model.store.diskHealth == nil)
    #expect(model.store.diskReadHistory.elements.isEmpty && model.store.processes.isEmpty)
    settings.panelTab = .network
    await model.network.refreshDetails(basicOnly: true)
    #expect(model.network.details != nil)
    #expect(!model.isNetworkDetailVisible && !model.demand.hasSamples)
    #expect(model.network.processes.isEmpty && model.network.probes.elements.isEmpty)
    #expect(model.network.publicResults == initialPublicResults && !model.network.isLookingUpPublic)
    model.isMainWindowVisible = false
    #expect(!model.demand.hasSamples)
  }

  @Test func disabledBatteryMonitoringDoesNotWriteEmptyHistory() async throws {
    let settings = settings()
    settings.enabledMonitoringModules = []
    settings.historyEnabled = true
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "battery-history-\(UUID()).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }
    let recorder = HistoryRecorder(settings: settings, databaseURL: url)
    let database = try #require(recorder.database)
    let base = Date().addingTimeInterval(-600)
    var snapshot = MetricsSnapshot()
    snapshot.battery = BatteryStatus(
      level: 0.8, isCharging: false, isPluggedIn: true,
      isFullyCharged: false, minutesRemaining: nil, cycleCount: 100,
      health: 0.9, adapterWatts: 68)
    for minute in 0..<3 {
      snapshot.date = base.addingTimeInterval(Double(minute) * 60)
      recorder.record(snapshot)
    }
    settings.setModuleEnabled(.battery, true)
    snapshot.date = base.addingTimeInterval(180)
    recorder.record(snapshot)
    recorder.flush()
    // 等待异步写入完成，同时确认重新启用后仍能正常记录。
    for _ in 0..<100 {
      if await database.count() > 0 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await database.count() == 1)
    let points = await database.query(from: base.addingTimeInterval(-60), to: Date(), bucket: 60)
    #expect(points.count == 1 && points.first?.battery == 0.8)
  }

  @Test func disabledThermalShortcutOpensItsEnablePageWithoutStartingControl() {
    let settings = settings()
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    settings.setModuleEnabled(.thermal, false)
    var pages: [PanelTab?] = []
    model.openMainWindow = { pages.append($0) }
    model.requestFanMode(.cooling)
    #expect(pages == [.thermal])
    #expect(model.fans.mode == .automatic && !model.fans.isApplying)
    #expect(!settings.isModuleEnabled(.thermal))
  }

  @Test func backupPreservesDisabledModulesAndConflictingMenuChoicesDoNotOverrideThem() throws {
    let source = settings()
    source.setModuleEnabled(.cpu, false)
    source.setModuleEnabled(.thermal, false)
    var document = source.exportDocument()
    document.menuBarItems = ["cpu", "fan", "memory"]
    let decoded = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(document))
    let target = settings()
    target.apply(decoded)
    #expect(!target.isModuleEnabled(.cpu) && !target.isModuleEnabled(.thermal))
    #expect(
      !target.orderedMenuBarItems.contains(.cpu) && !target.orderedMenuBarItems.contains(.fan))
    target.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(!target.isModuleEnabled(.cpu))
  }
}
