// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct TrioIconTests {
  @Test func dockImageUsesLiveContentOnAReadableTile() throws {
    var reading = TrioReading()
    reading.values[.battery] = 0.8
    reading.connection = .wifi(bars: 3)
    let configuration = TrioConfiguration()
    let image = TrioIconRenderer.dockImage(reading: reading, configuration: configuration)
    #expect(image.size == NSSize(width: 256, height: 256))
    #expect(!image.isTemplate)
    #expect(image.accessibilityDescription == reading.tooltip(configuration))
    let data = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
    let background = try #require(
      bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 8))
    #expect(background.alphaComponent == 1)
    #expect(try #require(background.usingColorSpace(.deviceRGB)).redComponent > 0.95)
    reading.values[.battery] = 0.1
    #expect(
      try #require(
        TrioIconRenderer.dockImage(reading: reading, configuration: configuration)
          .tiffRepresentation)
        != data)
  }

  @Test func dockIconFollowsLayoutVisibilityAndSettings() throws {
    let app = NSApplication.shared
    let previousPolicy = app.activationPolicy()
    let originalIcon = app.applicationIconImage?.copy() as? NSImage
    defer {
      app.applicationIconImage = originalIcon
      _ = app.setActivationPolicy(previousPolicy)
    }
    let suite = "TrioDockIcon.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarLayout = .iconOnly
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    let controller = MenuBarController(model: model)
    #expect(app.setActivationPolicy(.regular))
    controller.refreshDockIcon()
    let firstIcon = app.applicationIconImage
    #expect(firstIcon?.size == NSSize(width: 256, height: 256))
    let firstData = try #require(firstIcon?.tiffRepresentation)
    controller.refreshDockIcon()
    #expect(app.applicationIconImage?.tiffRepresentation == firstData)
    settings.trio.showsValue.toggle()
    controller.refreshDockIcon()
    #expect(app.applicationIconImage?.tiffRepresentation != firstData)
    var reading = TrioReading()
    reading.values[.battery] = 0.8
    controller.refreshDockIcon(reading: reading)
    let chargedData = try #require(app.applicationIconImage?.tiffRepresentation)
    reading.values[.battery] = 0.1
    controller.refreshDockIcon(reading: reading)
    #expect(app.applicationIconImage?.tiffRepresentation != chargedData)
    settings.menuBarLayout = .combined
    controller.refreshDockIcon()
    let restoredIcon = app.applicationIconImage
    #expect(restoredIcon?.size != NSSize(width: 256, height: 256))
    settings.menuBarLayout = .iconOnly
    #expect(app.setActivationPolicy(.accessory))
    controller.refreshDockIcon()
    #expect(app.applicationIconImage === restoredIcon)
    #expect(app.setActivationPolicy(.regular))
    controller.refreshDockIcon()
    #expect(app.applicationIconImage?.size == NSSize(width: 256, height: 256))
    #expect(app.setActivationPolicy(.accessory))
    controller.refreshDockIcon()
    #expect(app.applicationIconImage?.size != NSSize(width: 256, height: 256))
  }

  @Test func configurationPersistsWithoutChangingPanelItems() throws {
    let suite = "TrioIconTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let panelItems = settings.menuBarItems
    settings.trio.outer = .cpu
    settings.trio.center = .network
    settings.trio.footer = .aiUsage
    settings.trio.bluetoothDeviceID = "aabbccddeeff"
    settings.trio.bluetoothIconScale = 1.15
    settings.trio.wifiIconScale = 0.85
    settings.trio.temporaryAsWiFi = true
    settings.trio.sharingAsWiFi = false
    settings.trio.batteryDisplay = .chargingSymbol
    settings.trio.batteryTopScale = 1.1
    settings.menuBarLayout = .iconOnly
    #expect(settings.menuBarItems == panelItems)
    #expect(AppSettings(defaults: defaults).trio == settings.trio)
    let saved = settings.exportDocument()
    settings.trio.outer = .battery
    settings.apply(saved)
    #expect(settings.trio.outer == .cpu)
    #expect(settings.trio.bluetoothDeviceID == "aabbccddeeff")
    #expect(settings.trio.effectiveBluetoothIconScale == 1.15)
    #expect(settings.trio.effectiveWiFiIconScale == 0.85)
    #expect(settings.trio.temporaryAsWiFi == true)
    #expect(settings.trio.sharingAsWiFi == false)
    #expect(settings.trio.effectiveBatteryDisplay == .chargingSymbol)
    #expect(settings.trio.effectiveBatteryTopScale == 1.1)
  }

  @Test func legacyBatteryOptionsPreserveDisplayAndNormalizeNewValues() throws {
    let suite = "TrioBatteryMigration.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for showsValue in [false, true] {
      var legacy = TrioConfiguration(outer: .memory, footer: .aiUsage)
      legacy.showsValueWhenPluggedIn = showsValue
      legacy.wifiIconScale = 1.15
      legacy.bluetoothDeviceID = "aabbccddeeff"
      let data = try JSONEncoder().encode(legacy)
      var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      #expect(object["batteryDisplay"] == nil && object["batteryTopScale"] == nil)
      #expect(object["batteryLowThreshold"] == nil)
      // 本地预览保存过的独立阈值应被忽略，不能导致其他图标配置丢失。
      object["batteryLowThreshold"] = 0.5
      defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "menuBarTrio")
      let settings = AppSettings(defaults: defaults)
      #expect(settings.trio == legacy)
      #expect(settings.trio.effectiveBatteryDisplay == (showsValue ? .value : .powerSymbol))
      #expect(settings.trio.effectiveBatteryTopScale == 1)
      for (input, scale): (Double, Double) in [
        (0, 0.8), (2, 1.2), (.nan, 1), (.infinity, 1),
      ] {
        settings.trio.batteryTopScale = input
        let reloaded = AppSettings(defaults: defaults).trio
        #expect(reloaded.batteryTopScale == scale)
        #expect(reloaded.wifiIconScale == 1.15 && reloaded.bluetoothDeviceID == "aabbccddeeff")
      }
    }
  }

  @Test func batteryDisplayDistinguishesChargingExternalPowerAndHiddenContent() {
    var reading = TrioReading()
    reading.values[.battery] = 0.8
    var config = TrioConfiguration()
    for mode in TrioBatteryDisplay.allCases {
      config.batteryDisplay = mode
      for (charging, pluggedIn, fullyCharged): (Bool, Bool, Bool) in [
        (false, false, false), (true, true, false), (false, true, false), (false, true, true),
      ] {
        reading.charging = charging
        reading.pluggedIn = pluggedIn
        reading.fullyCharged = fullyCharged
        let symbol = reading.batteryPowerSymbol(config)
        switch mode {
        case .value: #expect(symbol == nil)
        case .chargingSymbol: #expect(symbol == (charging ? "bolt.fill" : nil))
        case .powerSymbol:
          #expect(symbol == (charging ? "bolt.fill" : pluggedIn ? "powerplug.fill" : nil))
        }
        config.showsValue = false
        #expect(reading.batteryPowerSymbol(config) == nil)
        config.showsValue = true
      }
    }
    config.batteryDisplay = .powerSymbol
    reading.charging = true
    reading.values[.battery] = nil
    #expect(reading.batteryPowerSymbol(config) == nil)
    reading.values[.battery] = .nan
    #expect(reading.batteryPowerSymbol(config) == nil)
    reading.values[.battery] = 0.8
    config.outer = .cpu
    #expect(reading.batteryPowerSymbol(config) == nil)
  }

  @Test func batteryTopScaleAffectsOnlyVisibleBatteryContentAndKeepsFixedCanvas() throws {
    var reading = TrioReading()
    reading.connection = .wifi(bars: 3)
    reading.values = [.battery: 1, .cpu: 0.4]
    var config = TrioConfiguration()
    for dark in [false, true] {
      for mode in TrioBatteryDisplay.allCases {
        config.batteryDisplay = mode
        for charging in [false, true] {
          reading.charging = charging
          reading.pluggedIn = true
          for source: TrioSource in [.battery, .cpu] {
            config.outer = source
            for showsValue in [false, true] {
              config.showsValue = showsValue
              config.batteryTopScale = 0.8
              let small = TrioIconRenderer.image(
                reading: reading, configuration: config, dark: dark)
              config.batteryTopScale = 1.2
              let large = TrioIconRenderer.image(
                reading: reading, configuration: config, dark: dark)
              #expect(small.size == NSSize(width: 24, height: 22) && small.size == large.size)
              let differs =
                try #require(small.tiffRepresentation) != #require(large.tiffRepresentation)
              #expect(differs == (source == .battery && showsValue))
            }
          }
        }
      }
    }
  }

  @Test func sharedBatteryLevelsKeepTemplateAndStatusColorsConsistent() {
    var config = TrioConfiguration()
    var reading = TrioReading()
    for level in [0, 0.1, 0.1001, 0.2, 0.2001, 1] {
      reading.values[.battery] = level
      #expect(
        TrioIconRenderer.image(reading: reading, configuration: config, dark: true).isTemplate
          == (LoadLevel.remaining(level) == .normal))
      config.statusColors = false
      #expect(
        TrioIconRenderer.image(reading: reading, configuration: config, dark: true).isTemplate)
      config.statusColors = true
    }
  }

  @Test func legacyNetworkOptionsKeepExistingChoicesAndClampScale() throws {
    var config = TrioConfiguration(outer: .memory, footer: .aiUsage)
    config.ethernetAsWiFi = true
    config.hotspotAsWiFi = true
    config.showsValue = false
    config.bluetoothDeviceID = "aabbccddeeff"
    config.bluetoothIconScale = 1.15
    let data = try JSONEncoder().encode(config)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["wifiIconScale"] == nil)
    #expect(object["temporaryAsWiFi"] == nil && object["sharingAsWiFi"] == nil)
    let suite = "TrioNetworkMigration.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(data, forKey: "menuBarTrio")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.trio == config)
    #expect(settings.trio.effectiveWiFiIconScale == 1)
    for (input, expected) in [(0.1, 0.8), (5.0, 1.2), (Double.nan, 1), (.infinity, 1)] {
      config.wifiIconScale = input
      settings.trio = config
      #expect(settings.trio.wifiIconScale == expected)
      #expect(AppSettings(defaults: defaults).trio.wifiIconScale == expected)
    }
  }

  @Test func networkStyleOptionsPreserveErrorsAndConnectionState() {
    var config = TrioConfiguration()
    let connectionStyles: [(NetworkIconState, String)] = [
      (.ethernet, "network"), (.hotspot, "personalhotspot"),
      (.temporary, "point.3.connected.trianglepath.dotted"), (.sharing, "arrow.up.forward.app"),
    ]
    for (state, symbol) in connectionStyles {
      var reading = TrioReading()
      reading.connection = state
      #expect(reading.centerSymbol(config) == symbol)
      let title = reading.networkTitle
      config.ethernetAsWiFi = true
      config.hotspotAsWiFi = true
      config.temporaryAsWiFi = true
      config.sharingAsWiFi = true
      #expect(reading.centerSymbol(config) == "wifi")
      #expect(reading.connection == state && reading.networkTitle == title)
      for (error, errorSymbol): (NetworkIconState, String) in [
        (.off, "wifi.slash"), (.unavailable, "wifi.slash"),
        (.unassociated, "wifi"), (.noInternet, "wifi.exclamationmark"),
      ] {
        reading.connection = error
        #expect(reading.connection.isError)
        #expect(reading.centerSymbol(config) == errorSymbol)
      }
      config = TrioConfiguration()
    }
    var reading = TrioReading()
    config.temporaryAsWiFi = true
    reading.connection = .sharing
    #expect(reading.centerSymbol(config) == "arrow.up.forward.app")
    config.temporaryAsWiFi = false
    config.sharingAsWiFi = true
    reading.connection = .temporary
    #expect(reading.centerSymbol(config) == "point.3.connected.trianglepath.dotted")
  }

  @Test func wifiScaleChangesOnlyVisibleWiFiSymbolsAndKeepsFixedCanvas() throws {
    var reading = TrioReading()
    reading.values[.battery] = 0.76
    reading.values[.audio] = 0.5
    reading.audioSymbol = "headphones"
    var config = TrioConfiguration()
    for dark in [false, true] {
      for state in NetworkIconState.samples {
        reading.connection = state
        config.wifiIconScale = 0.8
        let small = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
        config.wifiIconScale = 1.2
        let large = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
        #expect(small.size == large.size && large.size == NSSize(width: 24, height: 22))
        let differs = try #require(small.tiffRepresentation) != #require(large.tiffRepresentation)
        #expect(differs == reading.networkSymbol(config).hasPrefix("wifi"))
      }
      reading.connection = .wifi(bars: 3)
      reading.bluetoothOutput = true
      reading.selectedBluetoothSymbol = "computermouse"
      for id: String? in [nil, "aabbccddeeff"] {
        config.bluetoothDeviceID = id
        config.wifiIconScale = 0.8
        let small = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
        config.wifiIconScale = 1.2
        let large = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
        #expect(try #require(small.tiffRepresentation) == #require(large.tiffRepresentation))
      }
      reading.bluetoothOutput = false
      reading.selectedBluetoothSymbol = nil
      config.bluetoothDeviceID = nil
    }
  }

  @Test func legacyBluetoothOptionsDecodeWithoutResettingOtherChoices() throws {
    var config = TrioConfiguration(outer: .memory, footer: .fan)
    config.bluetoothReplacesNetwork = false
    config.showsValue = false
    let data = try JSONEncoder().encode(config)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["bluetoothDeviceID"] == nil && object["bluetoothIconScale"] == nil)
    let decoded = try JSONDecoder().decode(TrioConfiguration.self, from: data)
    #expect(decoded == config)
    #expect(decoded.bluetoothDeviceID == nil)
    #expect(decoded.effectiveBluetoothIconScale == 1)
    for (input, expected) in [(0.1, 0.8), (5.0, 1.2), (Double.nan, 1), (.infinity, 1)] {
      config.bluetoothIconScale = input
      #expect(config.normalized.bluetoothIconScale == expected)
    }
  }

  @Test func selectedBluetoothDeviceNeverFallsBackToAnotherDevice() async throws {
    let suite = "TrioBluetooth.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.trio = TrioConfiguration(outer: .cpu, footer: .aiUsage)
    settings.trio.bluetoothDeviceID = "aabbccddeeff"
    settings.menuBarLayout = .iconOnly
    settings.audioEnabled = false
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    defer { model.bluetooth.stop() }
    model.bluetooth.readDevices = {
      [
        BluetoothDevice(
          name: "Trackpad", address: "AA:BB:CC:DD:EE:FF", kind: .trackpad, batteries: []),
        BluetoothDevice(
          name: "Other", address: "11:22:33:44:55:66", kind: .mouse, batteries: []),
      ]
    }
    _ = await model.bluetooth.recentDevices(maxAge: 0)
    var reading = TrioReading(model: model)
    #expect(reading.centerSymbol(settings.trio) == BluetoothDevice.Kind.trackpad.symbol)
    #expect(reading.tooltip(settings.trio).contains("Trackpad"))
    #expect(!model.drawnMenuBarItems.contains(.audio))
    #expect(!settings.audioEnabled)
    model.bluetooth.readDevices = {
      [
        BluetoothDevice(
          name: "Trackpad", address: "AA:BB:CC:DD:EE:FF", kind: .trackpad, batteries: [],
          isConnected: false),
        BluetoothDevice(
          name: "Other", address: "11:22:33:44:55:66", kind: .mouse, batteries: []),
      ]
    }
    _ = await model.bluetooth.recentDevices(maxAge: 0)
    reading = TrioReading(model: model)
    reading.bluetoothOutput = true
    reading.audioSymbol = "headphones"
    reading.connection = .wifi(bars: 3)
    #expect(reading.centerSymbol(settings.trio) == "wifi")
    #expect(!reading.tooltip(settings.trio).contains("Trackpad"))
    #expect(settings.trio.bluetoothDeviceID == "aabbccddeeff")
    model.bluetooth.readDevices = {
      [
        BluetoothDevice(
          name: "Trackpad", address: "AA-BB-CC-DD-EE-FF", kind: .trackpad, batteries: [])
      ]
    }
    _ = await model.bluetooth.recentDevices(maxAge: 0)
    #expect(
      TrioReading(model: model).selectedBluetoothSymbol == BluetoothDevice.Kind.trackpad.symbol)
    settings.trio.bluetoothDeviceID = "invalid"
    #expect(TrioReading(model: model).selectedBluetoothSymbol == nil)
    settings.trio.bluetoothDeviceID = nil
    #expect(settings.audioEnabled)
    #expect(reading.centerSymbol(settings.trio) == "headphones")
  }

  @Test func manualBluetoothDemandStopsWhenReplacementIsNotVisible() throws {
    let suite = "TrioBluetoothDemand.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.trio = TrioConfiguration(outer: .cpu, footer: .aiUsage)
    settings.trio.bluetoothDeviceID = "aabbccddeeff"
    settings.menuBarItems = []
    settings.menuBarLayout = .iconOnly
    let model = AppModel(
      settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
    for _ in 0..<10 {
      model.isMainWindowVisible = false
      #expect(model.bluetoothDemand == .background)
      settings.panelTab = .settingsMenuBar
      model.isMainWindowVisible = true
      #expect(model.bluetoothDemand == .foreground)
      settings.panelTab = .system
      #expect(model.bluetoothDemand == .foreground)
      settings.panelTab = .battery
      #expect(model.bluetoothDemand == .foreground)
      settings.panelTab = .settingsMenuBar
      settings.trio.bluetoothReplacesNetwork = false
      #expect(model.bluetoothDemand == .off)
      model.isMainWindowVisible = false
      settings.trio.bluetoothReplacesNetwork = true
      settings.menuBarLayout = .combined
      #expect(model.bluetoothDemand == .off)
      settings.menuBarLayout = .iconOnly
      settings.setModuleEnabled(.network, false)
      #expect(model.bluetoothDemand == .off)
      settings.setModuleEnabled(.network, true)
    }
    settings.trio.bluetoothDeviceID = nil
    #expect(model.bluetoothDemand == .off)
  }

  @Test func bluetoothScaleOnlyChangesReplacementAndKeepsFixedCanvas() throws {
    var reading = TrioReading()
    reading.connection = .wifi(bars: 2)
    reading.selectedBluetoothSymbol = "rectangle.and.hand.point.up.left"
    var config = TrioConfiguration()
    config.bluetoothDeviceID = "aabbccddeeff"
    for dark in [false, true] {
      config.bluetoothIconScale = 0.8
      let small = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
      config.bluetoothIconScale = 1.2
      let large = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
      #expect(large.size == small.size && large.size == NSSize(width: 24, height: 22))
      #expect(try #require(small.tiffRepresentation) != #require(large.tiffRepresentation))
      reading.connection = .noInternet
      let errorLarge = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
      config.bluetoothIconScale = 0.8
      let errorSmall = TrioIconRenderer.image(reading: reading, configuration: config, dark: dark)
      #expect(
        try #require(errorLarge.tiffRepresentation) == #require(errorSmall.tiffRepresentation))
      config.networkErrorsFirst = false
      #expect(reading.centerSymbol(config) == reading.selectedBluetoothSymbol)
      config.networkErrorsFirst = true
      reading.connection = .wifi(bars: 2)
    }
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
      (0.1, true, .systemRed), (0.1, false, .systemRed),
      (0.1001, false, .systemOrange), (0.15, true, .systemOrange),
      (0.2, true, .systemOrange), (0.2, false, .systemOrange),
      (0.2001, false, .systemGreen), (0.55, true, .systemYellow),
      (0.55, false, .systemGreen),
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
