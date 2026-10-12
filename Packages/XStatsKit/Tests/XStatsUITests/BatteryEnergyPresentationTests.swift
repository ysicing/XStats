// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI
import Testing
@testable import Metrics
@testable import XStatsUI

@MainActor
struct BatteryEnergyPresentationTests {
    @Test(arguments: [(DS.Size.popoverWidth, false), (CGFloat(600), true), (CGFloat(960), true)])
    func energyRowsFitAvailableWidthInBothDirections(width: CGFloat, detail: Bool) throws {
        let suite = "BatteryEnergyPresentationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.enabledMonitoringModules = [.battery]
        settings.hiddenPopoverSections = Set(MenuBarItem.battery.popoverSections).subtracting([.batteryApps, .thermalSensors])
        let model = AppModel(settings: settings, historyURL: nil, aiUsageProviders: [], aiQuotaProviders: [])
        var snapshot = MetricsSnapshot()
        snapshot.battery = BatteryStatus(level: 0.8, isCharging: false, isPluggedIn: true,
                                        isFullyCharged: false, minutesRemaining: nil, cycleCount: 100, health: 0.9)
        snapshot.sensors = SensorReadings(temperatures: [
            TemperatureSummary(group: .cpu, average: 48, maximum: 62, sensorCount: 8),
            TemperatureSummary(group: .battery, average: 30, maximum: 32, sensorCount: 2)
        ], fans: [], fanCount: 0)
        snapshot.appEnergy = AppEnergyReading(apps: [
            AppEnergyUsage(id: "long-name", name: String(repeating: "Long Application Name ", count: 4), bundlePath: nil, watts: 1.234),
            AppEnergyUsage(id: "rtl-name", name: "تطبيق تجريبي طويل الاسم", bundlePath: nil, watts: 0.092)
        ], totalWatts: 1.326, interval: 5, isAvailable: true)
        model.store.apply(snapshot)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let host = NSHostingView(rootView: VStack { BatteryPopover() }
                .environment(model).environment(\.isSnapshot, true)
                .environment(\.isDetailPage, detail)
                .environment(\.layoutDirection, direction).frame(width: width))
            let size = host.fittingSize
            #expect(abs(size.width - width) < 1 && size.height > 0 && size.height < 1600)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            if let directory = ProcessInfo.processInfo.environment["XSTATS_APP_ENERGY_PREVIEW_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("battery-energy-\(Int(width))-\(direction == .leftToRight ? "ltr" : "rtl").png"))
            }
            window.close()
        }
    }
}
