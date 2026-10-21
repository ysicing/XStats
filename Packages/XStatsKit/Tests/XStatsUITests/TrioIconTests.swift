// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct TrioIconTests {
  @Test func configurationPersistsWithoutChangingPanelItems() throws {
    let suite = "TrioIconTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let panelItems = settings.menuBarItems
    settings.trio.outer = .cpu
    settings.trio.center = .network
    settings.trio.footer = .aiUsage
    settings.menuBarLayout = .iconOnly
    #expect(settings.menuBarItems == panelItems)
    #expect(AppSettings(defaults: defaults).trio == settings.trio)
    let saved = settings.exportDocument()
    settings.trio.outer = .battery
    settings.apply(saved)
    #expect(settings.trio.outer == .cpu)
  }

  @Test func aiFooterSelectionRoundTripsAcrossDefaultsAndPreservesLegacyChoice() throws {
    let sourceSuite = "TrioExport.\(UUID())"
    let targetSuite = "TrioImport.\(UUID())"
    let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuite))
    let targetDefaults = try #require(UserDefaults(suiteName: targetSuite))
    defer {
      sourceDefaults.removePersistentDomain(forName: sourceSuite)
      targetDefaults.removePersistentDomain(forName: targetSuite)
    }
    let source = AppSettings(defaults: sourceDefaults)
    source.trio.footer = .aiUsage
    source.aiMenuBarProviders = ["claude", "gemini"]
    let document = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(source.exportDocument()))
    let target = AppSettings(defaults: targetDefaults)
    target.apply(document)
    #expect(target.trio.footer == .aiUsage)
    #expect(target.aiMenuBarProviders == ["claude", "gemini"])
    target.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(target.aiMenuBarProviders == ["claude", "gemini"])
    var excessive = SettingsDocument()
    excessive.aiMenuBarProviders = ["codex", "claude", "gemini", "grok", "copilot"]
    target.apply(excessive)
    #expect(target.aiMenuBarProviders == ["codex", "claude", "gemini", "grok"])
    excessive.aiMenuBarProviders = []
    target.apply(excessive)
    #expect(target.aiMenuBarProviders.isEmpty)
  }

  @Test(arguments: ["memory", "network", "none", "cpu"])
  func legacyFooterFallsBackToAudioWithoutLosingOtherSettings(legacy: String) throws {
    let configuration = TrioConfiguration(outer: .cpu, center: .network, footer: .aiUsage)
    let encoded = try JSONEncoder().encode(configuration)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["footer"] = legacy
    let legacyData = try JSONSerialization.data(withJSONObject: object)
    let migrated = try JSONDecoder().decode(TrioConfiguration.self, from: legacyData)
    let suite = "TrioMigration.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(legacyData, forKey: "menuBarTrio")
    defaults.set("iconOnly", forKey: "menuBarLayout")
    defaults.set(false, forKey: "audioEnabled")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.trio == migrated)
    #expect(settings.audioEnabled)
    #expect(AppSettings(defaults: defaults).trio == migrated)
    #expect(migrated.outer == .cpu && migrated.center == .network)
    #expect(migrated.footer == .audio)
    #expect(TrioFooterSource.allCases == [.audio, .fan, .aiUsage])
  }

  @Test func aiDotsKeepIndependentProgressAndIgnoreAudioStyle() throws {
    var reading = TrioReading()
    reading.aiDots = [
      TrioReading.AIDot(name: "codex", fraction: 1),
      TrioReading.AIDot(name: "claude", fraction: 0.5),
      TrioReading.AIDot(name: "gemini", fraction: 0),
      TrioReading.AIDot(name: "grok", fraction: nil),
    ]
    var config = TrioConfiguration(outer: .none, center: .none, footer: .aiUsage)
    for dark in [false, true] {
      let dots = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
      #expect(!dots.isTemplate)
      #expect(dots.size == NSSize(width: 24, height: 22))
      config.footerStyle = .arc
      let arc = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
      #expect(try #require(dots.tiffRepresentation) == #require(arc.tiffRepresentation))
      config.footerStyle = .dots
      var changed = reading
      changed.aiDots[1].fraction = 0.9
      #expect(changed != reading)
      let updated = TrioIconRenderer.image(reading: changed, configuration: config, dark: dark)
      #expect(try #require(dots.tiffRepresentation) != #require(updated.tiffRepresentation))
    }
    let tooltip = reading.tooltip(config)
    for dot in reading.aiDots { #expect(tooltip.contains(AIServiceBrand.title(dot.name))) }
  }

  @Test func slotsDriveOnlySelectedEnabledMetrics() throws {
    let suite = "TrioIconTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.historyEnabled = false
    settings.enabledAlerts = []
    settings.menuBarLayout = .iconOnly
    settings.trio = TrioConfiguration(outer: .cpu, center: .network, footer: .audio)
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    #expect(model.demand.cpu && !model.demand.memory && model.demand.network)
    #expect(model.demand.networkConnection)
    #expect(!model.demand.gpu && !model.demand.battery && !model.demand.processes)
    settings.setModuleEnabled(.cpu, false)
    #expect(!model.demand.cpu)
    #expect(settings.trio.outer == .cpu)
    settings.trio = TrioConfiguration(outer: .memory, center: .network, footer: .audio)
    settings.setModuleEnabled(.network, false)
    #expect(!model.demand.networkConnection)
    #expect(model.demand.memory && !model.demand.power)
  }

  @Test func bluetoothReplacementRespectsErrorsAndColorOption() {
    var reading = TrioReading()
    reading.connection = .wifi(bars: 3)
    reading.bluetoothOutput = true
    reading.audioPlaying = true
    reading.audioSymbol = "airpodspro"
    var config = TrioConfiguration()
    #expect(reading.centerSymbol(config) == "airpodspro")
    #expect(reading.usesBlueVolume(config))
    reading.connection = .noInternet
    #expect(reading.centerSymbol(config) == "wifi.exclamationmark")
    config.networkErrorsFirst = false
    #expect(reading.centerSymbol(config) == "airpodspro")
    config.bluetoothReplacesNetwork = false
    #expect(reading.centerSymbol(config) == "wifi.exclamationmark")
    config.bluetoothVolumeColor = false
    #expect(!reading.usesBlueVolume(config))
    config.bluetoothVolumeColor = true
    reading.audioPlaying = false
    #expect(!reading.usesBlueVolume(config))
    config.bluetoothReplacesNetwork = true
    #expect(reading.centerSymbol(config) == "airpodspro")
    reading.bluetoothOutput = false
    #expect(reading.centerSymbol(config) == "wifi.exclamationmark")
  }

  @Test func enablingCenterReplacementStartsAudioWithoutChangingPanelSelection() throws {
    let suite = "TrioIconTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarLayout = .iconOnly
    settings.trio = TrioConfiguration(outer: .cpu, center: .network, footer: .aiUsage)
    settings.trio.bluetoothReplacesNetwork = false
    settings.audioEnabled = false
    settings.trio.bluetoothReplacesNetwork = true
    #expect(settings.audioEnabled)
    settings.audioEnabled = false
    settings.trio.footerStyle = .arc
    #expect(!settings.audioEnabled)
    #expect(!AppSettings(defaults: defaults).audioEnabled)
  }

  @Test func disabledSourceIgnoresPreviouslyCollectedValues() throws {
    let suite = "TrioIconTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.trio = TrioConfiguration(outer: .cpu, center: .network, footer: .audio)
    settings.menuBarLayout = .iconOnly
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    var snapshot = MetricsSnapshot()
    snapshot.cpu = CPULoad(total: 0.8, user: 0.5, system: 0.3, perCore: [], loadAverage: [])
    model.store.apply(snapshot)
    #expect(TrioReading(model: model).values[.cpu] == 0.8)
    settings.setModuleEnabled(.cpu, false)
    #expect(TrioReading(model: model).values[.cpu] == nil)
  }

  @Test func allStatesRenderAtFixedSize() throws {
    for state in NetworkIconState.samples {
      var reading = TrioReading()
      reading.connection = state
      reading.values[.battery] = 0.76
      reading.values[.audio] = 0.6
      for dark in [false, true] {
        for style in TrioFooterStyle.allCases {
          var config = TrioConfiguration()
          config.footerStyle = style
          let image = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
          #expect(image.size == NSSize(width: 24, height: 22))
          #expect(try #require(image.tiffRepresentation).count > 0)
        }
      }
    }
  }

  @Test(arguments: TrioFooterSource.allCases) func hiddenUpperSlotsKeepAVisibleFooter(
    footer: TrioFooterSource
  ) throws {
    let image = TrioIconRenderer.image(
      reading: TrioReading(),
      configuration: TrioConfiguration(outer: .none, center: .none, footer: footer), dark: false)
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    let hasVisiblePixel = (0..<bitmap.pixelsWide).contains { x in
      (0..<bitmap.pixelsHigh).contains { y in
        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
      }
    }
    #expect(hasVisiblePixel)
  }
  @Test(arguments: [
    TrioSource.gpu, .temperature, .audio, .fan, .aiUsage, .display, .network, .none,
  ])
  func legacyUpperSourcesNormalizeAndPersist(source: TrioSource) throws {
    let suite = "TrioUpperMigration.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var legacy = TrioConfiguration(outer: source, center: source, footer: .fan)
    legacy.footerStyle = .arc
    defaults.set(try JSONEncoder().encode(legacy), forKey: "menuBarTrio")
    defaults.set("iconOnly", forKey: "menuBarLayout")
    defaults.set(false, forKey: "audioEnabled")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.trio.outer == .cpu)
    #expect(settings.trio.center == .network)
    #expect(settings.trio.footer == .fan && settings.trio.footerStyle == .arc)
    #expect(settings.audioEnabled == (source != .network))
    #expect(AppSettings(defaults: defaults).trio == settings.trio)
    settings.trio.outer = source
    settings.trio.center = source
    #expect(settings.trio.outer == .cpu && settings.trio.center == .network)
  }

  @Test func fanFooterUsesHardwareMaximumAndDoesNotDependOnMute() throws {
    let suite = "TrioFans.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.historyEnabled = false
    settings.enabledAlerts = []
    settings.menuBarItems = []
    settings.trio = TrioConfiguration(outer: .cpu, center: .network, footer: .fan)
    settings.menuBarLayout = .iconOnly
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    #expect(model.store.fanCount == nil && model.demand.fans)
    var snapshot = MetricsSnapshot()
    snapshot.sensors = SensorReadings(
      temperatures: [],
      fans: [
        .init(id: 0, current: 2400, minimum: 1200, maximum: 4800, target: 2400, isManual: false)
      ], fanCount: 1)
    model.store.apply(snapshot)
    #expect(model.demand.fans && model.demand.temperatures.isEmpty && !model.demand.power)
    var reading = TrioReading(model: model)
    #expect(reading.fanFraction == 0.5)
    #expect(reading.tooltip(settings.trio).contains("RPM"))
    var config = settings.trio
    for style in TrioFooterStyle.allCases {
      config.footerStyle = style
      let normal = TrioIconRenderer.image(reading: reading, configuration: config, dark: false)
      reading.muted = true
      let muted = TrioIconRenderer.image(reading: reading, configuration: config, dark: false)
      #expect(try #require(normal.tiffRepresentation) == #require(muted.tiffRepresentation))
      reading.fanFraction = 0
      let stopped = TrioIconRenderer.image(reading: reading, configuration: config, dark: false)
      #expect(try #require(normal.tiffRepresentation) != #require(stopped.tiffRepresentation))
      reading.fanFraction = 0.5
      reading.muted = false
    }
    settings.trio.footer = .audio
    #expect(!model.demand.fans)
    settings.trio.footer = .fan
    settings.setModuleEnabled(.thermal, false)
    #expect(!model.demand.fans)
    #expect(TrioReading(model: model).fanFraction == nil)
    snapshot.sensors = SensorReadings(temperatures: [], fans: [], fanCount: 0)
    model.store.apply(snapshot)
    #expect(!model.drawnMenuBarItems.contains(.fan))
  }

  @Test func lowBatteryTakesColorPriorityOverPowerAndLowPowerMode() throws {
    var reading = TrioReading()
    reading.charging = true
    reading.pluggedIn = true
    let configuration = TrioConfiguration()
    for (level, lowPower, expected): (Double, Bool, NSColor) in [
      (0.15, true, .systemRed), (0.55, true, .systemYellow), (0.55, false, .systemGreen),
    ] {
      reading.values[.battery] = level
      reading.lowPower = lowPower
      let image = TrioIconRenderer.image(
        reading: reading, configuration: configuration, dark: false)
      // 按 Retina 以上分辨率采样，避免低电量短圆弧在 1x 下只有抗锯齿边缘。
      let bitmap = try #require(
        NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 88, bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0))
      let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
      let appearance = try #require(NSAppearance(named: .aqua))
      var expectedColor: NSColor?
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      appearance.performAsCurrentDrawingAppearance {
        image.draw(in: NSRect(x: 0, y: 0, width: 96, height: 88))
        expectedColor = expected.usingColorSpace(.deviceRGB)
      }
      NSGraphicsContext.restoreGraphicsState()
      let reference = try #require(expectedColor)
      let containsExpectedColor = (0..<bitmap.pixelsWide).contains { x in
        (0..<bitmap.pixelsHigh).contains { y in
          guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
            pixel.alphaComponent > 0.8
          else { return false }
          return abs(pixel.redComponent - reference.redComponent) < 0.08
            && abs(pixel.greenComponent - reference.greenComponent) < 0.08
            && abs(pixel.blueComponent - reference.blueComponent) < 0.08
        }
      }
      #expect(containsExpectedColor, "level=\(level), lowPower=\(lowPower), expected=\(reference)")
    }
  }

  @Test func normalizedAssignmentEnablesOnlyNewSourcesAndNoFansFallbackPersists() throws {
    let suite = "TrioAssignment.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.trio = TrioConfiguration(outer: .cpu, center: .network, footer: .audio)
    settings.menuBarLayout = .iconOnly
    settings.audioEnabled = false
    settings.trio.outer = .memory
    #expect(!settings.audioEnabled)
    settings.setModuleEnabled(.thermal, false)
    settings.setModuleEnabled(.cpu, false)
    settings.trio = TrioConfiguration(outer: .gpu, center: .network, footer: .fan)
    #expect(settings.trio.outer == .cpu && settings.trio.footer == .fan)
    #expect(settings.isModuleEnabled(.thermal) && settings.isModuleEnabled(.cpu))
    #expect(!settings.audioEnabled)
    settings.setModuleEnabled(.cpu, false)
    settings.setModuleEnabled(.network, false)
    settings.updateTrioFanAvailability(nil)
    #expect(settings.trio.footer == .fan)
    settings.updateTrioFanAvailability(0)
    #expect(settings.trio.footer == .audio && settings.audioEnabled)
    #expect(!settings.isModuleEnabled(.cpu) && !settings.isModuleEnabled(.network))
    #expect(AppSettings(defaults: defaults).trio.footer == .audio)
    settings.trio.footer = .fan
    #expect(settings.trio.footer == .audio)
  }

}
