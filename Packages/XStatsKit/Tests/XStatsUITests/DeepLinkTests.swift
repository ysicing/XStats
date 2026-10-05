// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import AppKit
import Testing
@testable import XStatsUI

struct DeepLinkTests {
    @MainActor @Test func repeatedCalendarOpensKeepTheSamePanelVisible() throws {
        _ = NSApplication.shared
        let suite = "XStats.DeepLinkCalendarTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.calendarEnabled = true
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        let controller = CalendarMenuBarController(model: model)
        defer { controller.dismiss() }
        #expect(controller.present())
        #expect(controller.present())
    }

    @MainActor @Test func explicitRestCommandsAreIdempotentAndKeepPausedProgress() throws {
        let suite = "XStats.DeepLinkRestTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true; settings.restMode = .single
        var now: UInt64 = 0
        let rest = RestController(settings: settings, localDefaults: defaults, sharedDefaults: nil, clock: { now })
        defer { rest.stop() }
        rest.setRunning(true)
        #expect(rest.isRunning)
        now = 10_000_000_000
        rest.setRunning(true)
        #expect(rest.isRunning)
        #expect(rest.secondsRemaining == Double(settings.restWorkMinutes * 60 - 10))
        rest.setRunning(false)
        let remaining = rest.secondsRemaining
        now = 20_000_000_000
        rest.setRunning(false)
        #expect(!rest.isRunning)
        #expect(rest.secondsRemaining == remaining)
        rest.setRunning(true)
        #expect(rest.isRunning)
        #expect(rest.secondsRemaining == remaining)
    }

    @Test func everyPublishedPageAndPanelHasAStableRoute() throws {
        for (path, page) in AppDeepLink.pages {
            #expect(AppDeepLink(url: try #require(URL(string: "xstats://open/\(path)"))) == .open(page))
        }
        for (path, item) in AppDeepLink.panels {
            #expect(AppDeepLink(url: try #require(URL(string: "xstats://panel/\(path)"))) == .panel(item))
        }
        #expect(AppDeepLink(url: try #require(URL(string: "xstats://open/" + String(repeating: "a", count: 2048)))) == nil)
    }

    @Test(arguments: [
        ("xstats://open", AppDeepLink.open(nil)),
        ("xstats://open/audio", .open(.audio)),
        ("xstats://open/ai-usage", .open(.aiUsage)),
        ("xstats://open/settings/menu-bar", .open(.settingsMenuBar)),
        ("xstats://panel/cpu", .panel(.cpu)),
        ("xstats://panel/overview", .panel(nil)),
        ("xstats://open/calendar", .calendar),
        ("xstats://open/speed-test", .speedTest),
        ("xstats://open/egress", .egress),
        ("xstats://rest/start", .rest(.start)),
        ("xstats://rest/pause", .rest(.pause)),
        ("xstats://rest/reset", .rest(.reset)),
        ("xstats://keep-awake/stop", .keepAwake(.stop))
    ])
    func parsesKnownRoutes(_ example: (String, AppDeepLink)) throws {
        #expect(AppDeepLink(url: try #require(URL(string: example.0))) == example.1)
    }

    @Test(arguments: ["https://open/audio", "xstats://unknown/audio", "xstats://open/unknown", "xstats://open/audio?enabled=true",
                      "xstats://open/audio#fragment", "xstats://user@open/audio", "xstats://open:123/audio", "xstats://open//audio",
                      "xstats://open/%61udio", "xstats://open/settings/account", "xstats://action/uninstall", "xstats://rest/unknown",
                      "xstats://keep-awake/lid-closed", "xstats://panel/audio/extra"])
    func rejectsUnknownOrAmbiguousRoutes(_ text: String) throws {
        #expect(AppDeepLink(url: try #require(URL(string: text))) == nil)
    }

    @MainActor @Test func disabledPagesRouteToSettingsWithoutEnablingFeatures() throws {
        let suite = "XStats.DeepLinkTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.audioEnabled = false; settings.restEnabled = false; settings.processesEnabled = false
        #expect(AppDeepLink.page(.audio, settings: settings) == .settingsGeneral)
        #expect(AppDeepLink.page(.rest, settings: settings) == .settingsGeneral)
        #expect(AppDeepLink.page(.processes, settings: settings) == .settingsGeneral)
        #expect(!settings.audioEnabled && !settings.restEnabled && !settings.processesEnabled)
    }
}
