// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Observation
import SMC
import Testing
import AIUsage
@testable import Metrics
@testable import XStatsUI

@MainActor
struct MenuBarReadingTests {
    @Test(arguments: [false, true])
    func quotaIconsMatchServicesAndDirectAccounts(dark: Bool) throws {
        let providers = ["grok", "codex", "copilot", "claude", "gemini", "perplexity"]
        let fallback = try #require(quotaIconImage(providers: ["unknown"], dark: dark).tiffRepresentation)
        var rendered: Set<Data> = []
        for provider in providers {
            let data = try #require(quotaIconImage(providers: [provider], dark: dark).tiffRepresentation)
            // 同一百分比下各服务必须有独立标志，不能全部退回通用星形图标。
            #expect(data != fallback)
            #expect(rendered.insert(data).inserted)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            var monochrome = true
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<min(28, bitmap.pixelsWide) {
                    let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    if color.alphaComponent > 0.05 {
                        monochrome = monochrome && abs(color.redComponent - color.greenComponent) < 0.01
                            && abs(color.greenComponent - color.blueComponent) < 0.01
                    }
                }
            }
            #expect(monochrome, "菜单栏标志不应残留 SVG 原色")
            if AIProviderID(rawValue: provider) != nil {
                let direct = try #require(quotaIconImage(providers: [provider], dark: dark, magpie: false).tiffRepresentation)
                #expect(direct == data)
            }
            let otherAppearance = try #require(quotaIconImage(providers: [provider], dark: !dark).tiffRepresentation)
            #expect(otherAppearance != data)
        }
        if let directory = ProcessInfo.processInfo.environment["XSTATS_MAGPIE_PREVIEW_DIR"] {
            // 使用截图中的短百分比验证实际观感，均为演示数据。
            let image = quotaIconImage(providers: ["codex", "claude"], dark: dark, remainingPercents: [4, 32])
            let size = NSSize(width: image.size.width + 20, height: image.size.height + 20)
            let canvas = NSImage(size: size, flipped: false) { _ in
                NSColor(calibratedWhite: dark ? 0.12 : 0.96, alpha: 1).setFill()
                NSRect(origin: .zero, size: size).fill()
                image.draw(at: NSPoint(x: 10, y: 10), from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            let tiff = try #require(canvas.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent(dark ? "magpie-menubar-spacing-dark.png" : "magpie-menubar-spacing-light.png"))
        }
    }

    @Test func shortQuotaValuesStayNearIconsWithoutResizing() throws {
        var widths: Set<CGFloat> = []
        for remaining in [4.0, 32.0, 100.0] {
            let image = quotaIconImage(providers: ["codex"], dark: false, remainingPercents: [remaining])
            widths.insert(image.size.width)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            // 图标为 14pt，间隙为 4pt；数值首个可见像素应在 18–20pt 附近。
            var firstTextPixel: Int?
            for x in 28..<bitmap.pixelsWide {
                if (0..<bitmap.pixelsHigh).contains(where: { (bitmap.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.1 }) {
                    firstTextPixel = x
                    break
                }
            }
            let start = try #require(firstTextPixel)
            #expect((36...40).contains(start))
        }
        #expect(widths.count == 1)
    }

    @Test(arguments: MenuBarStyle.options(for: .aiUsage))
    func quotaServiceGapsFollowItemSpacingWithoutChangingSingleService(style: MenuBarStyle) {
        for providers in [["codex"], ["codex", "claude"], ["codex", "claude", "grok", "gemini"]] {
            let compact = quotaIconImage(providers: providers, dark: false, style: style, itemGap: 4)
            for gap: CGFloat in [6, 8, 12] {
                let expanded = quotaIconImage(providers: providers, dark: false, style: style, itemGap: gap)
                #expect(expanded.size.width - compact.size.width == CGFloat(providers.count - 1) * (gap - 4))
            }
        }
    }

    private func quotaIconImage(providers: [String], dark: Bool, magpie: Bool = true,
                                remainingPercents: [Double] = [], style: MenuBarStyle = .icon, itemGap: CGFloat = 8) -> NSImage {
        var reading = MenuBarReading.sample
        reading.keepAwake = false
        reading.aiQuotas = providers.enumerated().map { index, provider in
            let remaining = remainingPercents.indices.contains(index) ? remainingPercents[index] : 68
            return MenuBarQuota(provider: AIProviderID(rawValue: provider),
                         window: AIQuotaWindow(kind: .weekly, usedPercent: 100 - remaining, resetsAt: nil),
                         fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), isStale: false,
                         magpieName: magpie ? provider : nil)
        }
        let image = MenuBarRenderer.image(reading: reading, items: [.aiUsage], style: { _ in style },
                                          networkStyle: .dots, colorizeHighLoad: false, fahrenheit: false, itemGap: itemGap)
        return MenuBarRenderer.preview(image, dark: dark, backingScale: 2)
    }

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
