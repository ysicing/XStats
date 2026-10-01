// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Observation
import SMC
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct MenuBarReadingTests {
    @Test func batteryPreviewIgnoresCPUAndStillObservesBattery() async throws {
        let suite = "MenuBarReadingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil,
                             aiUsageProviders: [], aiQuotaProviders: [])
        await confirmation(expectedCount: 0) { changed in
            withObservationTracking {
                _ = MenuBarReading(model: model, items: [.battery])
            } onChange: { changed() }
            var snapshot = MetricsSnapshot()
            snapshot.cpu = CPULoad(total: 0.5, user: 0.3, system: 0.2, perCore: [0.5], loadAverage: [1, 1, 1])
            model.store.apply(snapshot)
        }
        await confirmation(expectedCount: 1) { changed in
            withObservationTracking {
                _ = MenuBarReading(model: model, items: [.battery])
            } onChange: { changed() }
            var snapshot = MetricsSnapshot()
            snapshot.battery = BatteryStatus(level: 0.75, isCharging: true, isPluggedIn: true,
                                             isFullyCharged: false, minutesRemaining: 20, cycleCount: 30,
                                             health: 0.98, adapterWatts: 60)
            model.store.apply(snapshot)
        }
    }

    @Test func scopedReadingsPreserveEveryItemImage() throws {
        let suite = "MenuBarReadingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil,
                             aiUsageProviders: [], aiQuotaProviders: [])
        var snapshot = MetricsSnapshot()
        snapshot.cpu = CPULoad(total: 0.83, user: 0.6, system: 0.23, perCore: [0.83], loadAverage: [1, 1, 1])
        snapshot.gpu = GPUUsage(name: "Fixture", utilization: 0.3, coreCount: 8)
        snapshot.memory = MemoryUsage(total: 1_000, app: 300, wired: 100, compressed: 50, cached: 200,
                                      swapUsed: 0, swapTotal: 0, pressure: .normal, uncompressed: 100,
                                      swapInBytes: 0, swapOutBytes: 0)
        snapshot.sensors = SensorReadings(temperatures: [TemperatureSummary(group: .cpu, average: 50,
                                                                           maximum: 60, sensorCount: 4)],
                                          fans: [FanState(id: 0, current: 1_800, minimum: 0, maximum: 6_000,
                                                          target: 1_800, isManual: false)], fanCount: 1)
        snapshot.disk = DiskUsage(volumeName: "Fixture", total: 1_000, available: 350)
        snapshot.network = NetworkRate(downloadBytesPerSecond: 1_500_000, uploadBytesPerSecond: 20_000,
                                       totalDownloaded: 10_000_000, totalUploaded: 100_000)
        snapshot.battery = BatteryStatus(level: 0.15, isCharging: true, isPluggedIn: true,
                                         isFullyCharged: false, minutesRemaining: 20, cycleCount: 30,
                                         health: 0.98, adapterWatts: 60)
        model.store.apply(snapshot)
        for item in MenuBarItem.allCases {
            let complete = MenuBarReading(model: model)
            let scoped = MenuBarReading(model: model, items: [item])
            #expect(scoped.tooltip(items: [item], fahrenheit: false) == complete.tooltip(items: [item], fahrenheit: false))
            for style in MenuBarStyle.options(for: item) {
                #expect(scoped.hasSameImage(as: complete, item: item, style: style))
                let completeImage = MenuBarRenderer.image(reading: complete, items: [item], style: { _ in style },
                                                          networkStyle: .dots, colorizeHighLoad: true, fahrenheit: false)
                let scopedImage = MenuBarRenderer.image(reading: scoped, items: [item], style: { _ in style },
                                                        networkStyle: .dots, colorizeHighLoad: true, fahrenheit: false)
                for dark in [false, true] {
                    let before = try #require(MenuBarRenderer.preview(completeImage, dark: dark).tiffRepresentation)
                    let after = try #require(MenuBarRenderer.preview(scopedImage, dark: dark).tiffRepresentation)
                    #expect(before == after)
                }
            }
        }
    }
}
