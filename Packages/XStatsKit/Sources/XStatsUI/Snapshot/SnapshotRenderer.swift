// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AIUsage
import AppKit
import Localization
import Metrics
import SMC
import SwiftUI
import Updates

/// `XStats --snapshot <目录>`：用本机实时数据渲染各页面 PNG，用于设计走查
@MainActor
enum SnapshotRenderer {
    static func run(outputDirectory: URL) async {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "XStats.snapshot") ?? .standard
        let settings = AppSettings(defaults: defaults)
        settings.language = L10n.language
        settings.menuBarItems = [.cpu, .gpu, .memory, .network, .disk, .temperature, .battery, .aiUsage]
        settings.aiUsageEnabled = true
        // 历史页用示例数据：最近 24 小时每分钟一条，中间留一段“睡眠”空档
        let historyURL = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-snapshot-history.sqlite")
        try? FileManager.default.removeItem(at: historyURL)
        if let database = try? HistoryDatabase(url: historyURL) {
            let now = Int(Date().timeIntervalSince1970) / 60 * 60
            for index in 0..<(24 * 60) where !(600..<780).contains(index) {
                let t = Double(index)
                let wave = (sin(t / 90) + 1) / 2
                await database.insert(HistoryRecord(minute: now - (24 * 60 - index) * 60,
                                                    cpu: 0.08 + wave * 0.3, cpuMax: min(1, 0.2 + wave * 0.6),
                                                    memory: 0.55 + wave * 0.2, pressure: index % 400 == 0 ? 4 : 1,
                                                    download: 200_000 + wave * 3_000_000, upload: 40_000 + wave * 400_000,
                                                    gpu: index % 3 == 0 ? wave * 0.4 : nil, temperature: 45 + wave * 30,
                                                    power: index > 1200 ? 20 + wave * 25 : nil))
            }
        }
        let model = AppModel(settings: settings, historyURL: historyURL,
                             aiUsageProviders: [SnapshotAIUsageProvider()])
        await model.aiUsage.refresh()
        model.isMainWindowVisible = true
        model.network.setVisibility(inMenuBar: true, detailVisible: true)

        // 采集约 12 秒的真实数据，让历史曲线有内容
        var demand = MetricsDemand()
        demand.interval = .milliseconds(250)
        demand.memory = true
        demand.network = true
        demand.gpu = true
        demand.disk = true
        demand.battery = true
        demand.processes = true
        demand.temperatures = Set(TemperatureGroup.allCases)
        demand.fans = true
        demand.power = true
        demand.cpuFrequency = true
        demand.diskDetail = true
        await model.hub.update(demand)
        await model.hub.start { snapshot in model.handle(snapshot) }
        try? await Task.sleep(for: .seconds(12))
        await model.hub.stop()
        model.network.setVisibility(inMenuBar: false, detailVisible: false)
        model.network.maskForSnapshot()
        // 清理页展示真实扫描结果（只读，不删除任何文件）
        model.cleaner.scan()
        while model.cleaner.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
        model.history.load(.day)
        model.startupItems.refresh()
        model.uninstaller.loadApps()
        try? await Task.sleep(for: .seconds(2))
        model.updates.showPreview(UpdateRelease(
            version: "0.3.0", build: "3", date: "2026-09-20", minimumSystem: "14.0",
            url: URL(string: "https://getopenstats.com/download/OpenStats-0.3.0.zip")!, sha256: String(repeating: "0", count: 64),
            size: 9_600_000, dmg: nil,
            notes: [tr("在线升级：发现新版本时显示更新摘要，一键安装并自动重启"), tr("连接探测只在需要时运行，更省电"), tr("进程页刷新频率调整为每 2 秒")],
            changelog: URL(string: "https://getopenstats.com/#changelog")))

        for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            guard let appearance = NSAppearance(named: appearanceName) else { continue }
            NSApp.appearance = appearance
            for tab in PanelTab.allCases {
                settings.panelTab = tab
                write(MainWindowView(), model: model, appearance: appearance,
                      to: outputDirectory.appendingPathComponent("window-\(tab.rawValue)-\(suffix).png"))
            }
            write(UpdatePromptView {}, model: model, appearance: appearance,
                  to: outputDirectory.appendingPathComponent("update-prompt-\(suffix).png"))
            write(LanguagePickerList(selection: settings.language) { _ in }.appLanguageEnvironment(),
                  model: model, appearance: appearance,
                  to: outputDirectory.appendingPathComponent("language-picker-\(suffix).png"))
            for item in MenuBarItem.allCases where item != .fan {
                write(PopoverRootView(item: item), model: model, appearance: appearance,
                      to: outputDirectory.appendingPathComponent("popover-\(item.rawValue)-\(suffix).png"))
            }
            // 合并模式的面板：状态总览
            model.combinedPopoverTab = nil
            write(CombinedPopoverView(), model: model, appearance: appearance,
                  to: outputDirectory.appendingPathComponent("popover-combined-\(suffix).png"))
        }

        let menuBar = MenuBarRenderer.image(for: model)
        for dark in [false, true] {
            let preview = MenuBarRenderer.preview(menuBar, dark: dark)
            // 垫上菜单栏底色，便于查看
            let padded = NSImage(size: NSSize(width: preview.size.width + DS.Space.s4, height: preview.size.height), flipped: false) { rect in
                NSColor(hex: dark ? 0x1F2937 : 0xE5E7EB).setFill()
                rect.fill()
                preview.draw(in: NSRect(x: DS.Space.s2, y: 0, width: preview.size.width, height: preview.size.height))
                return true
            }
            writePNG(padded, scale: 2, to: outputDirectory.appendingPathComponent("menubar-\(dark ? "dark" : "light").png"))
        }
        print(tr("截图已输出到 \(outputDirectory.path)"))
    }

    /// 用真实的 NSHostingView 放进离屏窗口截图，渲染路径与 App 内一致
    private static func write<V: View>(_ view: V, model: AppModel, appearance: NSAppearance, to url: URL) {
        let hosting = NSHostingView(rootView: view
            .environment(model)
            .environment(\.isSnapshot, true))
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = .dsBackground
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        defer { window.orderOut(nil) }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func writePNG(_ image: NSImage, scale: CGFloat, to url: URL) {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }
}

private struct SnapshotAIUsageProvider: AIUsageProvider {
    let id = AIProviderID.codex

    func fetch() async throws -> AIUsageSnapshot {
        let now = Date()
        return AIUsageSnapshot(
            provider: .codex,
            planName: "Pro 20x",
            windows: [
                AIQuotaWindow(kind: .session, usedPercent: 28, resetsAt: now.addingTimeInterval(95 * 60)),
                AIQuotaWindow(kind: .weekly, usedPercent: 87, resetsAt: now.addingTimeInterval(4.5 * 24 * 60 * 60)),
                AIQuotaWindow(kind: .sparkWeekly, usedPercent: 42, resetsAt: now.addingTimeInterval(6 * 24 * 60 * 60)),
            ],
            remainingCredits: 820,
            fetchedAt: now
        )
    }
}
