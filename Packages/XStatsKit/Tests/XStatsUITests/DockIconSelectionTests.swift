// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import DockIcons
import Testing
@testable import XStatsUI

@MainActor struct DockIconSelectionTests {
  @Test(arguments: DockIconStyle.allCases)
  func applicationIconMigratesOnceAndPersistsIndependently(legacyStyle: DockIconStyle) throws {
    let suite = "ApplicationIconMigration.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(legacyStyle.rawValue, forKey: DockIconStyle.preferenceKey)
    let settings = AppSettings(defaults: defaults)
    let expected: DockIconStyle = legacyStyle == .mascot ? .mascot : .standard
    #expect(settings.applicationIconStyle == expected)
    settings.dockIconStyle = .standard
    #expect(settings.applicationIconStyle == expected)
    #expect(AppSettings(defaults: defaults).applicationIconStyle == expected)
    settings.applicationIconStyle = .standard
    settings.dockIconStyle = .mascot
    #expect(AppSettings(defaults: defaults).applicationIconStyle == .standard)
    #expect(AppSettings(defaults: defaults).dockIconStyle == .mascot)
  }

  @Test func applicationIconRoundTripsAndOlderBackupsPreserveItsSelection() throws {
    let suite = "ApplicationIconBackup.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarLayout = .iconOnly
    #expect(settings.applicationIconStyle == .standard)
    settings.applicationIconStyle = .mascot
    let document = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    settings.applicationIconStyle = .standard
    settings.apply(document)
    #expect(settings.applicationIconStyle == .mascot)
    #expect(settings.dockIconStyle == .automatic)
    var legacy = SettingsDocument()
    legacy.dockIconStyle = DockIconStyle.standard.rawValue
    settings.apply(legacy)
    #expect(settings.applicationIconStyle == .mascot)
    for rawValue in ["future-style", DockIconStyle.automatic.rawValue] {
      var invalid = SettingsDocument()
      invalid.applicationIconStyle = rawValue
      settings.apply(invalid)
      #expect(settings.applicationIconStyle == .mascot)
    }
  }

  @Test func systemIconChangesKeepTheSelectedDockStyleAndUpdateWhileDockIsHidden() throws {
    let app = NSApplication.shared
    let previousPolicy = app.activationPolicy()
    let originalIcon = app.applicationIconImage
    defer {
      app.applicationIconImage = originalIcon
      _ = app.setActivationPolicy(previousPolicy)
    }
    let suite = "ApplicationIconRuntime.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarLayout = .iconOnly
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    var systemStyles: [DockIconStyle] = []
    var renders = 0
    let controller = MenuBarController(
      model: model,
      synchronizeApplicationIcon: {
        systemStyles.append($0)
        app.applicationIconImage = NSImage(size: NSSize(width: 1, height: 1))
      },
      makeDockImage: { _, _ in
        renders += 1
        return NSImage(size: NSSize(width: 256, height: 256))
      })
    #expect(app.setActivationPolicy(.regular))
    controller.refreshDockIcon()
    settings.applicationIconStyle = .mascot
    controller.refreshDockIcon()
    #expect(systemStyles == [.standard, .mascot])
    #expect(renders == 2)
    #expect(app.applicationIconImage?.size == NSSize(width: 256, height: 256))
    settings.dockIconStyle = .standard
    controller.refreshDockIcon()
    let standard = try #require(app.applicationIconImage?.tiffRepresentation)
    controller.refreshDockIcon()
    #expect(systemStyles == [.standard, .mascot])
    settings.applicationIconStyle = .standard
    controller.refreshDockIcon()
    #expect(app.applicationIconImage?.tiffRepresentation == standard)
    #expect(app.setActivationPolicy(.accessory))
    settings.applicationIconStyle = .mascot
    controller.refreshDockIcon()
    #expect(systemStyles == [.standard, .mascot, .standard, .mascot])
    #expect(renders == 2)
    #expect(app.setActivationPolicy(.regular))
    controller.refreshDockIcon()
    #expect(app.applicationIconImage?.tiffRepresentation == standard)
  }

  @Test func selectionPersistsAndRoundTripsWithoutOverwritingOlderBackups() throws {
    let suite = "DockIconSelection.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.dockIconStyle == .standard)
    settings.dockIconStyle = .mascot
    #expect(AppSettings(defaults: defaults).dockIconStyle == .mascot)
    let document = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    settings.dockIconStyle = .standard
    settings.apply(document)
    #expect(settings.dockIconStyle == .mascot)
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(settings.dockIconStyle == .mascot)
    var future = SettingsDocument()
    future.dockIconStyle = "future-style"
    settings.apply(future)
    #expect(settings.dockIconStyle == .mascot)
  }

  @Test(arguments: [MenuBarLayout.separate, .combined])
  func liveIconsAreOnlyAvailableInIconOnlyLayout(layout: MenuBarLayout) throws {
    let suite = "DockIconLayout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarLayout = layout
    #expect(settings.dockIconStyle == .standard)
    settings.menuBarLayout = .iconOnly
    #expect(settings.dockIconStyle == .automatic)
    settings.dockIconStyle = .mascot
    settings.menuBarLayout = layout
    #expect(settings.dockIconStyle == .mascot)
    settings.menuBarLayout = .iconOnly
    #expect(settings.dockIconStyle == .mascot)
    settings.dockIconStyle = .automatic
    settings.menuBarLayout = layout
    #expect(settings.dockIconStyle == .standard)
    #expect(AppSettings(defaults: defaults).dockIconStyle == .standard)
    let document = settings.exportDocument()
    #expect(document.dockIconStyle == DockIconStyle.automatic.rawValue)
    let restored = AppSettings(defaults: defaults)
    restored.dockIconStyle = .standard
    restored.apply(document)
    restored.menuBarLayout = .iconOnly
    #expect(restored.dockIconStyle == .automatic)
    settings.menuBarLayout = .iconOnly
    #expect(settings.dockIconStyle == .automatic)
    settings.menuBarLayout = layout
    var standardDocument = SettingsDocument()
    standardDocument.dockIconStyle = DockIconStyle.standard.rawValue
    settings.apply(standardDocument)
    settings.menuBarLayout = .iconOnly
    #expect(settings.dockIconStyle == .standard)
  }

  @Test func explicitLogosOverrideLiveReadingsAndRestoreAfterHiding() throws {
    let app = NSApplication.shared
    let previousPolicy = app.activationPolicy()
    let originalIcon = app.applicationIconImage
    defer {
      app.applicationIconImage = originalIcon
      _ = app.setActivationPolicy(previousPolicy)
    }
    let suite = "DockIconRuntime.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarLayout = .iconOnly
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    var renders = 0
    let controller = MenuBarController(
      model: model,
      makeDockImage: { _, _ in
        renders += 1
        return NSImage(size: NSSize(width: 256, height: 256))
      })
    #expect(app.setActivationPolicy(.regular))
    controller.refreshDockIcon()
    #expect(renders == 1)
    settings.dockIconStyle = .mascot
    controller.refreshDockIcon()
    let mascot = try #require(app.applicationIconImage?.tiffRepresentation)
    settings.trio.showsValue.toggle()
    controller.refreshDockIcon()
    #expect(renders == 1)
    #expect(app.applicationIconImage?.tiffRepresentation == mascot)
    #expect(app.setActivationPolicy(.accessory))
    controller.refreshDockIcon()
    #expect(app.setActivationPolicy(.regular))
    controller.refreshDockIcon()
    #expect(app.applicationIconImage?.tiffRepresentation == mascot)
    settings.dockIconStyle = .standard
    controller.refreshDockIcon()
    #expect(app.applicationIconImage?.tiffRepresentation != mascot)
    #expect(renders == 1)
    settings.dockIconStyle = .automatic
    controller.refreshDockIcon()
    #expect(renders == 2)
    #expect(app.applicationIconImage?.size == NSSize(width: 256, height: 256))
  }
}
