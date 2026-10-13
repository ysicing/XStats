// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

/// 登录、服务与显式后台启动不抢占桌面；手动启动提供主窗口。
@MainActor
enum ApplicationLaunch {
    static func showsMainWindow(event: NSAppleEventDescriptor?, arguments: [String], hasPendingDeepLink: Bool) -> Bool {
        guard !hasPendingDeepLink, !arguments.contains("--background") else { return false }
        let presentationArguments: Set<String> = ["--show-window", "--show-panel", "--show-calendar", "--show-speedtest",
                                                   "--show-egress", "--probe", "--explain-process"]
        guard !arguments.contains(where: presentationArguments.contains) else { return false }
        guard let event else { return true }
        if event.eventClass == AEEventClass(kInternetEventClass), event.eventID == AEEventID(kAEGetURL) { return false }
        guard event.eventID == AEEventID(kAEOpenApplication) else { return true }
        let reason = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        return reason != keyAELaunchedAsLogInItem && reason != keyAELaunchedAsServiceItem
    }
}
