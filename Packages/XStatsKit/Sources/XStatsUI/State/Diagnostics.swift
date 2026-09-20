import AppKit
import Foundation
import HelperShared
import Localization
import Metrics
import Observation
import os

/// 运行日志：写入系统统一日志（子系统 work.12306.xstats.app），导出诊断信息时一并收集
enum Log {
    static let subsystem = "work.12306.xstats.app"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let helper = Logger(subsystem: subsystem, category: "helper")
    static let fans = Logger(subsystem: subsystem, category: "fans")
    static let power = Logger(subsystem: subsystem, category: "power")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let update = Logger(subsystem: subsystem, category: "update")
    static let sync = Logger(subsystem: subsystem, category: "sync")
}

/// 导出诊断信息：版本与系统、辅助工具状态、主要设置、最近 3 天的运行日志、清理记录与崩溃报告，打成一个 zip。
/// 不包含序列号、IP 地址与硬件地址。
@MainActor
@Observable
final class DiagnosticsExporter {
    enum Phase: Equatable {
        case idle
        case collecting
        case finished(URL)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    func export(model: AppModel) {
        guard phase != .collecting else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = tr("XStats-诊断-\(Self.fileDate()).zip")
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        phase = .collecting
        Task {
            let summary = await Self.summary(model: model)
            do {
                try await Task.detached { try Self.writeArchive(summary: summary, to: destination) }.value
                Log.app.notice("已导出诊断信息")
                phase = .finished(destination)
            } catch {
                phase = .failed(tr("导出失败：\(error.localizedDescription)"))
            }
        }
    }

    func reveal() {
        if case .finished(let url) = phase { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: 内容

    private static func summary(model: AppModel) async -> String {
        let bundle = Bundle.main
        let settings = model.settings
        let store = model.store
        let process = ProcessInfo.processInfo
        let remoteVersion = await model.helper.remoteProtocolVersion()
        var lines: [String] = []
        func section(_ title: String) { lines.append(""); lines.append("## \(title)") }
        func row(_ key: String, _ value: Any?) { lines.append("\(key): \(value.map { "\($0)" } ?? "—")") }

        lines.append(tr("# XStats 诊断信息"))
        row(tr("导出时间"), ISO8601DateFormatter().string(from: Date()))

        section(tr("应用"))
        row(tr("版本"), bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString"))
        row(tr("构建"), bundle.object(forInfoDictionaryKey: "CFBundleVersion"))
        row(tr("位置"), bundle.bundleURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        row(tr("签名团队"), CodeSigningInfo.currentTeamIdentifier() ?? tr("未签名（开发构建）"))
        row(tr("已运行"), Format.uptime(since: launchDate))

        section(tr("系统"))
        row(tr("机型"), tr("\(store.system.modelName)（\(store.system.modelIdentifier)）"))
        row("macOS", tr("\(store.system.osVersion)（\(store.system.osBuild)）"))
        row(tr("处理器核心"), process.activeProcessorCount)
        row(tr("内存"), Format.bytes(process.physicalMemory))
        row(tr("开机以来"), Format.uptime(since: Date().addingTimeInterval(-process.systemUptime)))
        row(tr("语言"), Locale.preferredLanguages.prefix(3).joined(separator: ", "))
        row(tr("温度传感器"), store.sensors.map { tr("\($0.temperatures.count) 组") })
        row(tr("风扇"), store.sensors.map { tr("\($0.fans.count) 个") })
        row(tr("电池"), store.battery.map { tr("\(Format.percent($0.level))，\($0.isPluggedIn ? tr("接通电源") : tr("使用电池"))，健康 \($0.health.map(Format.percent) ?? "—")") } ?? tr("无"))

        section(tr("辅助工具"))
        row(tr("状态"), model.helper.status.title)
        if case .unavailable(let reason) = model.helper.status { row(tr("原因"), reason) }
        row(tr("协议版本"), tr("应用 \(HelperConstants.protocolVersion) / 辅助工具 \(remoteVersion.map(String.init) ?? tr("未连接"))"))
        row(tr("最近错误"), model.helper.lastError)

        section(tr("状态"))
        row(tr("风扇模式"), model.fans.mode.title)
        row(tr("防休眠"), model.keepAwake.isActive ? model.keepAwake.mode.title : tr("关闭"))
        row(tr("合盖运行"), model.keepAwake.lidClosedActive ? tr("开启") : tr("关闭"))
        row(tr("登录时启动"), model.launchAtLoginEnabled ? tr("开启") : tr("关闭"))
        row(tr("在线升级"), tr("上次检查 \(model.updates.lastChecked.map { ISO8601DateFormatter().string(from: $0) } ?? tr("从未"))，最新 \(model.updates.release?.version ?? tr("当前版本"))"))

        section(tr("设置"))
        row(tr("菜单栏项目"), settings.orderedMenuBarItems.map(\.rawValue).joined(separator: ", "))
        row(tr("菜单栏布局"), settings.menuBarLayout.rawValue)
        row(tr("菜单栏风格"), settings.menuBarStyle.rawValue)
        row(tr("刷新间隔"), tr("\(settings.refreshSeconds) 秒"))
        row(tr("外观"), settings.appearance.rawValue)
        row(tr("连接探测"), settings.probeEnabled ? tr("\(settings.probeTarget.rawValue)，后台\(settings.probeInBackground ? tr("开启") : tr("关闭"))") : tr("关闭"))
        row(tr("公网 IP 查询"), settings.publicIPLookup ? tr("开启") : tr("关闭"))
        row(tr("风扇安全温度"), "\(settings.fanSafetyTemperature)°C")
        row(tr("合盖电量下限"), "\(settings.lidModeBatteryFloor)%")
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func writeArchive(summary: String, to destination: URL) throws {
        let manager = FileManager.default
        let work = manager.temporaryDirectory.appendingPathComponent("XStats-diagnostics-\(UUID().uuidString)")
        let folder = work.appendingPathComponent(tr("XStats-诊断-\(fileDate())"))
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }

        try summary.write(to: folder.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)

        // 统一日志：应用与辅助工具最近 3 天的记录
        let log = run("/usr/bin/log", ["show", "--style", "compact", "--last", "3d", "--info",
                                       "--predicate", "subsystem == \"\(Log.subsystem)\" OR subsystem == \"work.12306.xstats.helper\""])
        try redact(log).write(to: folder.appendingPathComponent("xstats.log"), atomically: true, encoding: .utf8)

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let cleanup = home.appendingPathComponent("Library/Logs/XStats/cleanup.log")
        if let text = try? String(contentsOf: cleanup, encoding: .utf8) {
            let recent = text.split(separator: "\n").suffix(500).joined(separator: "\n")
            try redact(recent).write(to: folder.appendingPathComponent("cleanup.log"), atomically: true, encoding: .utf8)
        }

        // 最近 5 份崩溃 / 卡死报告
        let reports = home.appendingPathComponent("Library/Logs/DiagnosticReports")
        let crashes = ((try? manager.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("XStats") }
            .sorted { modified($0) > modified($1) }
            .prefix(5)
        if !crashes.isEmpty {
            let crashFolder = folder.appendingPathComponent("crashes")
            try manager.createDirectory(at: crashFolder, withIntermediateDirectories: true)
            for crash in crashes {
                try? manager.copyItem(at: crash, to: crashFolder.appendingPathComponent(crash.lastPathComponent))
            }
        }

        try? manager.removeItem(at: destination)
        let zip = run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, destination.path])
        guard manager.fileExists(atPath: destination.path) else {
            throw NSError(domain: "XStats", code: 1, userInfo: [NSLocalizedDescriptionKey: zip])
        }
    }

    /// 去掉用户目录名、IPv4 / IPv6 地址与硬件地址
    nonisolated static func redact(_ text: String) -> String {
        var result = text.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        // 顺序有关：硬件地址先于 IPv6；IPv6 至少 4 段或含 “::”，避免把 12:30:45 这样的时间当成地址
        let patterns: [(String, String)] = [
            (#"\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b"#, "<MAC>"),
            (#"\b(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}\b"#, "<IPv6>"),
            (#"(?:\b[0-9a-fA-F]{1,4})?(?::[0-9a-fA-F]{1,4})*::(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4})*\b)?"#, "<IPv6>"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<IPv4>"),
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    nonisolated private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    nonisolated private static func fileDate() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return error.localizedDescription }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// AppController 启动时读取一次，记下应用启动时间
    static let launchDate = Date()
}
