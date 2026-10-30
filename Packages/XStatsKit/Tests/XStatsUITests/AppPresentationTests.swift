// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
@testable import Localization
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
@Suite(.serialized)
struct AppPresentationTests {
  @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
  func launchWindowSettingFitsEveryLanguage(language: AppLanguage) throws {
    let catalog = Translations.catalog(for: language)
    let title =
      language == .chinese
      ? "启动时显示主窗口" : try #require(catalog?.translate("启动时显示主窗口"))
    let host = NSHostingView(
      rootView: SettingsGroup {
        GroupRow(showsDivider: false) {
          SettingRow(title: title) {
            DSToggle(isOn: .constant(true), label: title)
          }
        }
      }
      .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
      .environment(\.isSnapshot, true)
      .frame(width: 480))
    let size = host.fittingSize
    #expect(size.width == 480 && size.height >= 40 && size.height < 160)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    if let path = ProcessInfo.processInfo.environment["XSTATS_LAUNCH_SETTINGS_PREVIEW_DIR"] {
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: path).appendingPathComponent("\(language.rawValue).png"))
    }
  }

  @Test(arguments: [false, true])
  func manualLaunchFollowsPreferenceButLoginAndServiceLaunchesDoNot(showWindow: Bool) {
    #expect(
      ApplicationLaunch.showsMainWindow(
        event: nil, arguments: ["XStats"], hasPendingDeepLink: false,
        showMainWindowOnLaunch: showWindow) == showWindow)
    let manualEvent = NSAppleEventDescriptor(
      eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    #expect(
      ApplicationLaunch.showsMainWindow(
        event: manualEvent, arguments: ["XStats"], hasPendingDeepLink: false,
        showMainWindowOnLaunch: showWindow) == showWindow)
    for reason in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
      let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID))
      event.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: AEKeyword(keyAEPropData))
      #expect(
        !ApplicationLaunch.showsMainWindow(
          event: event, arguments: ["XStats"], hasPendingDeepLink: false,
          showMainWindowOnLaunch: showWindow))
    }
  }

  @Test(arguments: [false, true])
  func explicitBackgroundAndDeepLinkLaunchesDoNotOpenAnExtraWindow(showWindow: Bool) {
    #expect(
      !ApplicationLaunch.showsMainWindow(
        event: nil, arguments: ["XStats", "--background"], hasPendingDeepLink: false,
        showMainWindowOnLaunch: showWindow))
    #expect(
      !ApplicationLaunch.showsMainWindow(
        event: nil, arguments: ["XStats"], hasPendingDeepLink: true,
        showMainWindowOnLaunch: showWindow))
    let urlEvent = NSAppleEventDescriptor(
      eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
      targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    #expect(
      !ApplicationLaunch.showsMainWindow(
        event: urlEvent, arguments: ["XStats"], hasPendingDeepLink: false,
        showMainWindowOnLaunch: showWindow))
    for argument in [
      "--show-window", "--show-panel", "--show-calendar", "--show-timer", "--show-speedtest",
      "--show-egress", "--probe", "--explain-process",
    ] {
      #expect(
        !ApplicationLaunch.showsMainWindow(
          event: nil, arguments: ["XStats", argument], hasPendingDeepLink: false,
          showMainWindowOnLaunch: showWindow))
    }
  }

  @Test func launchWindowPreferencePersistsAndSupportsOptionalBackups() throws {
    let suite = "AppPresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.showMainWindowOnLaunch)
    settings.showMainWindowOnLaunch = false
    let restored = AppSettings(defaults: defaults)
    #expect(!restored.showMainWindowOnLaunch)
    #expect(restored.exportDocument().showMainWindowOnLaunch == false)
    var document = SettingsDocument()
    document.showMainWindowOnLaunch = restored.exportDocument().showMainWindowOnLaunch
    let decoded = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(document))
    settings.showMainWindowOnLaunch = true
    settings.apply(decoded)
    #expect(!settings.showMainWindowOnLaunch)
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(!settings.showMainWindowOnLaunch)
    settings.showMainWindowOnLaunch = true
    #expect(AppSettings(defaults: defaults).showMainWindowOnLaunch)
  }

  @Test func menusRouteAboutAndWindowCommandsAndRestoreHiddenApplications() throws {
    let app = NSApplication.shared
    let previousWindowsMenu = app.windowsMenu
    let previousHelpMenu = app.helpMenu
    defer {
      app.windowsMenu = previousWindowsMenu
      app.helpMenu = previousHelpMenu
    }
    let target = MenuCommandTarget()
    let command = #selector(MenuCommandTarget.performCommand)
    let menu = MainMenu.make(
      target: target, aboutAction: command, settingsAction: command, updateAction: command,
      openWindowAction: command, guideAction: command, feedbackAction: command)
    let application = try #require(menu.items.first?.submenu)
    application.performActionForItem(at: 0)
    #expect(target.commands == 1)
    let hideOthers = try #require(
      application.items.first { $0.action == #selector(NSApplication.hideOtherApplications(_:)) })
    #expect(hideOthers.keyEquivalent == "h")
    #expect(hideOthers.keyEquivalentModifierMask == [.command, .option])
    #expect(
      application.items.contains { $0.action == #selector(NSApplication.unhideAllApplications(_:)) }
    )
    let windows = try #require(app.windowsMenu)
    windows.performActionForItem(at: 0)
    #expect(target.commands == 2)
    #expect(windows.items.contains { $0.action == #selector(NSWindow.performMiniaturize(_:)) })
    #expect(app.helpMenu?.items.count == 2)
  }

  @Test func closedWindowDoesNotKeepTheApplicationInTheDock() throws {
    _ = NSApplication.shared
    let suite = "XStats.AppPresentationTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.panelTab = .settingsAbout
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    let controller = MainWindowController(model: model)
    controller.show(tab: .settingsAbout)
    defer { controller.close() }
    #expect(controller.isOpen)
    let window = try #require(controller.nsWindow)
    controller.windowDidMiniaturize(
      Notification(name: NSWindow.didMiniaturizeNotification, object: window))
    #expect(controller.isOpen)
    #expect(!model.isMainWindowVisible)
    controller.windowDidDeminiaturize(
      Notification(name: NSWindow.didDeminiaturizeNotification, object: window))
    #expect(model.isMainWindowVisible)
    var openWhenClosing: Bool?
    controller.onVisibilityChange = { [weak controller] _ in openWhenClosing = controller?.isOpen }
    controller.close()
    #expect(openWhenClosing == false)
    #expect(!controller.isOpen && !model.isMainWindowVisible)
  }
}

@MainActor
private final class MenuCommandTarget: NSObject {
  private(set) var commands = 0
  @objc func performCommand() { commands += 1 }
}
