// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct UpdateNotificationTests {
    private let defaults = UserDefaults(suiteName: "UpdateNotificationTests.\(UUID().uuidString)")!

    @Test func preferenceDefaultsOnAndPreservesAnExplicitOptOut() throws {
        // 已有安装的其他通知偏好不影响新开关的默认值。
        defaults.set([String](), forKey: "enabledAlerts")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.notifyUpdates)
        settings.notifyUpdates = false
        #expect(!AppSettings(defaults: defaults).notifyUpdates)
        let data = try JSONEncoder().encode(settings.exportDocument())
        let restored = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        restored.apply(try JSONDecoder().decode(SettingsDocument.self, from: data))
        #expect(!restored.notifyUpdates)
        restored.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
        #expect(!restored.notifyUpdates)
    }

    @Test func successfulNotificationIsDeduplicatedAcrossRestarts() async {
        let settings = AppSettings(defaults: defaults)
        let first = UpdateController(settings: settings, defaults: defaults)
        var versions: [String] = []
        first.onUpdateAvailable = { versions.append($0); return true }
        await first.announceUpdate(version: "1.0.0", userInitiated: false, suppressPrompt: false)
        await first.announceUpdate(version: "1.0.0", userInitiated: false, suppressPrompt: false)
        let restarted = UpdateController(settings: settings, defaults: defaults)
        restarted.onUpdateAvailable = { versions.append($0); return true }
        await restarted.announceUpdate(version: "1.0.0", userInitiated: false, suppressPrompt: false)
        await restarted.announceUpdate(version: "1.0.1", userInitiated: false, suppressPrompt: false)
        await restarted.announceUpdate(version: "1.0.0", userInitiated: false, suppressPrompt: false)
        #expect(versions == ["1.0.0", "1.0.1"])
    }

    @Test func deniedOrFailedSubmissionCanBeRetried() async {
        let controller = UpdateController(settings: AppSettings(defaults: defaults), defaults: defaults)
        var attempts = 0
        controller.onUpdateAvailable = { _ in attempts += 1; return attempts > 1 }
        for _ in 0..<3 {
            await controller.announceUpdate(version: "1.0.0", userInitiated: false, suppressPrompt: false)
        }
        #expect(attempts == 2)
    }

    @Test func backgroundRespectsOptOutQuietModeAndSkippedVersion() async {
        defaults.set("1.0.0", forKey: "updateSkippedVersion")
        let settings = AppSettings(defaults: defaults)
        let controller = UpdateController(settings: settings, defaults: defaults)
        var versions: [String] = []
        controller.onUpdateAvailable = { versions.append($0); return true }
        settings.notifyUpdates = false
        await controller.announceUpdate(version: "1.0.1", userInitiated: false, suppressPrompt: false)
        settings.notifyUpdates = true
        await controller.announceUpdate(version: "1.0.1", userInitiated: false, suppressPrompt: true)
        await controller.announceUpdate(version: "1.0.0", userInitiated: false, suppressPrompt: false)
        #expect(versions.isEmpty)
        await controller.announceUpdate(version: "1.0.1", userInitiated: false, suppressPrompt: false)
        #expect(versions == ["1.0.1"])
    }

    @Test func manualCheckAlwaysPresentsWithoutSendingNotification() async {
        defaults.set("1.0.0", forKey: "updateSkippedVersion")
        defaults.set("1.0.0", forKey: "updateNotifiedVersion")
        let settings = AppSettings(defaults: defaults)
        settings.notifyUpdates = false
        let controller = UpdateController(settings: settings, defaults: defaults)
        var prompts = 0
        var notifications = 0
        controller.onPrompt = { prompts += 1 }
        controller.onUpdateAvailable = { _ in notifications += 1; return true }
        await controller.announceUpdate(version: "1.0.0", userInitiated: true, suppressPrompt: true)
        #expect(prompts == 1)
        #expect(notifications == 0)
    }

    @Test func pendingAuthorizationDoesNotAllowDuplicateNotifications() async {
        let controller = UpdateController(settings: AppSettings(defaults: defaults), defaults: defaults)
        var notifications = 0
        controller.onUpdateAvailable = { [weak controller] version in
            notifications += 1
            await controller?.announceUpdate(version: version, userInitiated: false, suppressPrompt: false)
            return true
        }
        await controller.announceUpdate(version: "1.0.0", userInitiated: false, suppressPrompt: false)
        #expect(notifications == 1)
    }

    @Test func notificationRoutesToUpdatesAndReplacesPreviousVersion() {
        let first = AlertController.updateNotification(version: "1.0.0")
        let next = AlertController.updateNotification(version: "1.0.1")
        #expect(first.identifier == next.identifier)
        #expect(next.content.title.contains("1.0.1"))
        #expect(next.content.userInfo["updates"] as? Bool == true)
        #expect(next.trigger == nil)
    }
}
