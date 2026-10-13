// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import XStatsUI

@MainActor
@Suite(.serialized)
struct AppPresentationTests {
    @Test func manualLaunchOpensTheWindowButLoginAndServiceLaunchesDoNot() {
        #expect(ApplicationLaunch.showsMainWindow(event: nil, arguments: ["XStats"], hasPendingDeepLink: false))
        for reason in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
            let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
            event.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: AEKeyword(keyAEPropData))
            #expect(!ApplicationLaunch.showsMainWindow(event: event, arguments: ["XStats"], hasPendingDeepLink: false))
        }
    }

    @Test func explicitBackgroundAndDeepLinkLaunchesDoNotOpenAnExtraWindow() {
        #expect(!ApplicationLaunch.showsMainWindow(event: nil, arguments: ["XStats", "--background"], hasPendingDeepLink: false))
        #expect(!ApplicationLaunch.showsMainWindow(event: nil, arguments: ["XStats"], hasPendingDeepLink: true))
        #expect(!ApplicationLaunch.showsMainWindow(event: nil, arguments: ["XStats", "--show-panel", "cpu"], hasPendingDeepLink: false))
    }

    @Test func menusRouteAboutAndWindowCommandsAndRestoreHiddenApplications() throws {
        let app = NSApplication.shared
        let previousWindowsMenu = app.windowsMenu
        let previousHelpMenu = app.helpMenu
        defer { app.windowsMenu = previousWindowsMenu; app.helpMenu = previousHelpMenu }
        let target = MenuCommandTarget()
        let command = #selector(MenuCommandTarget.performCommand)
        let menu = MainMenu.make(target: target, aboutAction: command, settingsAction: command, updateAction: command,
                                 openWindowAction: command, guideAction: command, feedbackAction: command)
        let application = try #require(menu.items.first?.submenu)
        application.performActionForItem(at: 0)
        #expect(target.commands == 1)
        let hideOthers = try #require(application.items.first { $0.action == #selector(NSApplication.hideOtherApplications(_:)) })
        #expect(hideOthers.keyEquivalent == "h")
        #expect(hideOthers.keyEquivalentModifierMask == [.command, .option])
        #expect(application.items.contains { $0.action == #selector(NSApplication.unhideAllApplications(_:)) })
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
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        let controller = MainWindowController(model: model)
        controller.show(tab: .settingsAbout)
        defer { controller.close() }
        #expect(controller.isOpen)
        let window = try #require(controller.nsWindow)
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification, object: window))
        #expect(controller.isOpen)
        #expect(!model.isMainWindowVisible)
        controller.windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification, object: window))
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
