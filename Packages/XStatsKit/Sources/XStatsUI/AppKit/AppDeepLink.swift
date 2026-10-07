// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 启动器可用的固定路由；协议名称独立于偏好设置枚举，不接受任意命令或文件路径。
enum AppDeepLink: Equatable, Sendable {
    enum RestAction: String, Sendable { case start, pause, toggle, reset, skip, hud }
    enum KeepAwakeAction: String, Sendable { case start, stop, toggle }
    case open(PanelTab?)
    case panel(MenuBarItem?)
    case calendar, speedTest, egress
    case rest(RestAction)
    case keepAwake(KeepAwakeAction)

    static let pages: [String: PanelTab] = [
        "overview": .overview, "system": .system, "history": .history, "ai-usage": .aiUsage,
        "cpu": .cpu, "gpu": .gpu, "memory": .memory, "disk": .disk, "network": .network,
        "thermal": .thermal, "battery": .battery, "processes": .processes, "audio": .audio,
        "connections": .connections,
        "keep-awake": .keepAwake, "rest": .rest, "cleaner": .cleaner, "uninstaller": .uninstaller,
        "startup-items": .startupItems, "settings": .settingsGeneral, "settings/general": .settingsGeneral,
        "settings/features": .settingsFeatures, "settings/menu-bar": .settingsMenuBar, "settings/notifications": .settingsNotifications,
        "settings/helper": .settingsHelper, "settings/about": .settingsAbout
    ]
    static let panels: [String: MenuBarItem] = [
        "cpu": .cpu, "gpu": .gpu, "memory": .memory, "network": .network, "disk": .disk,
        "temperature": .temperature, "fan": .fan, "battery": .battery,
        "ai-usage": .aiUsage, "display": .display, "audio": .audio
    ]

    init?(url: URL) {
        guard url.absoluteString.utf8.count <= 2048,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "xstats",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.query == nil, parts.fragment == nil,
              !parts.percentEncodedPath.contains("%"), let host = parts.host?.lowercased() else { return nil }
        let path = parts.path.hasPrefix("/") ? String(parts.path.dropFirst()) : parts.path
        switch host {
        case "open":
            if path.isEmpty { self = .open(nil) }
            else if let page = Self.pages[path] { self = .open(page) }
            else if path == "calendar" { self = .calendar }
            else if path == "speed-test" { self = .speedTest }
            else if path == "egress" { self = .egress }
            else { return nil }
        case "panel":
            if path == "overview" { self = .panel(nil) }
            else if let item = Self.panels[path] { self = .panel(item) }
            else { return nil }
        case "rest":
            guard let action = RestAction(rawValue: path) else { return nil }
            self = .rest(action)
        case "keep-awake":
            guard let action = KeepAwakeAction(rawValue: path) else { return nil }
            self = .keepAwake(action)
        default: return nil
        }
    }

    @MainActor static func page(_ requested: PanelTab, settings: AppSettings) -> PanelTab {
        switch requested {
        case .audio where !settings.audioEnabled, .rest where !settings.restEnabled,
             .connections where !settings.canViewNetworkConnections,
             .processes where !settings.processesEnabled, .cleaner where !settings.cleanerEnabled,
             .uninstaller where !settings.uninstallerEnabled,
             .aiUsage where !settings.aiUsageEnabled: .settingsFeatures
        default: requested
        }
    }
}
