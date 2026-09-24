// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
import WidgetData

@Test func snapshotRoundTripAndDisabledModules() throws {
    let suite = "WidgetSnapshotTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = WidgetSnapshotStore(defaults: defaults)
    let now = Date()
    let snapshot = WidgetSnapshot(
        aiEnabled: true,
        quotas: [.init(provider: "codex", kind: "weekly", remainingPercent: 37, resetsAt: now.addingTimeInterval(60),
                       fetchedAt: now, isStale: false)],
        publicIPEnabled: true,
        addresses: [.init(family: "v4", ip: "203.0.113.1", countryCode: "CN", city: nil,
                          organization: nil, purityScore: 82, purityGrade: "A")],
        language: "japanese", calendarFirstWeekday: 1, showsLunar: false)
    #expect(store.save(snapshot))
    #expect(store.load() == snapshot)
    #expect(snapshot.currentQuotas(at: now).count == 1)
    #expect(snapshot.currentQuotas(at: now.addingTimeInterval(61)).isEmpty)

    var disabled = snapshot
    disabled.aiEnabled = false
    disabled.publicIPEnabled = false
    #expect(disabled.currentQuotas(at: now).isEmpty)
    #expect(disabled.visibleAddresses.isEmpty)
}
