// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import DockIcons
import Testing
@testable import XStatsUI

@MainActor struct DockIconSelectionTests {
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
    let controller = MenuBarController(model: model) { _, _ in
      renders += 1
      return NSImage(size: NSSize(width: 256, height: 256))
    }
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
