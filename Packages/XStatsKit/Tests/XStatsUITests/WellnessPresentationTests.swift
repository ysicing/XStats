// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor struct WellnessPresentationTests {
    @Test(arguments: [WellnessExerciseKind.rest, .breathing])
    func exerciseRendersWithoutMainWindowEnvironment(kind: WellnessExerciseKind) async throws {
        let name = "WellnessPresentationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        settings.restEnabled = true
        let rest = RestController(settings: settings, localDefaults: defaults, sharedDefaults: nil)
        let wellness = WellnessController(rest: rest, settings: settings,
                                          store: WellnessActivityStore(url: nil), schedulesTimers: false)
        if kind == .rest { wellness.startShortRest() }
        else { wellness.startBreathing() }
        #expect(wellness.activeExercise == kind)

        // 独立休息窗口只持有 WellnessController，不注入主页面的 AppModel。
        let host = NSHostingView(rootView: WellnessExerciseView(wellness: wellness)
            .environment(\.isSnapshot, true).frame(width: 560, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0 && host.fittingSize.height > 0)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)

        wellness.finishExercise(completed: false)
        #expect(wellness.activeExercise == nil)
        rest.stop()
        await wellness.prepareForTermination()
    }
}
