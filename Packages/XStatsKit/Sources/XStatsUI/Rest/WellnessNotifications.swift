// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import UserNotifications

/// 共用现有通知代理；每次只保留一个健康提示，不改变系统勿扰行为。
@MainActor final class WellnessNotifications {
    private static let requestID = "XStats.wellness"
    private let wellness: WellnessController
    private let open: () -> Void
    private let center = UNUserNotificationCenter.current()
    private var handled: [String] = []
    private var permissionTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?
    private var enabled = false
    private var generation = 0
    private var categoryLanguage: AppLanguage?

    init(wellness: WellnessController, open: @escaping () -> Void) {
        self.wellness = wellness
        self.open = open
        wellness.onReminder = { [weak self] kinds in self?.post(kinds) }
        wellness.onDismissReminder = { [weak self] in self?.dismiss() }
    }

    func sync() {
        let preferences = wellness.settings.wellnessPreferences
        let newlyEnabled = wellness.settings.restEnabled && (preferences.breakEnabled || preferences.waterEnabled)
        if !newlyEnabled {
            permissionTask?.cancel()
            permissionTask = nil
            dismiss()
        } else if !enabled || categoryLanguage != wellness.settings.language {
            permissionTask?.cancel()
            categoryLanguage = wellness.settings.language
            let shouldRequestPermission = !enabled
            permissionTask = Task { [weak self] in
                guard let self else { return }
                let categories = await self.center.notificationCategories()
                guard !Task.isCancelled, self.enabled else { return }
                let water = UNNotificationCategory(identifier: "XStats.wellness.water", actions: [
                    UNNotificationAction(identifier: "water", title: tr("已喝水")),
                    UNNotificationAction(identifier: "later", title: tr("稍后 10 分钟"))
                ], intentIdentifiers: [])
                let rest = UNNotificationCategory(identifier: "XStats.wellness.rest", actions: [
                    UNNotificationAction(identifier: "rest", title: tr("开始短休"), options: [.foreground]),
                    UNNotificationAction(identifier: "later", title: tr("稍后 10 分钟"))
                ], intentIdentifiers: [])
                let combined = UNNotificationCategory(identifier: "XStats.wellness.combined", actions: [
                    UNNotificationAction(identifier: "water", title: tr("已喝水")),
                    UNNotificationAction(identifier: "rest", title: tr("开始短休"), options: [.foreground]),
                    UNNotificationAction(identifier: "later", title: tr("稍后 10 分钟"))
                ], intentIdentifiers: [])
                self.center.setNotificationCategories(Set(categories.filter { !$0.identifier.hasPrefix("XStats.wellness.") }).union([water, rest, combined]))
                let settings = await self.center.notificationSettings()
                guard !Task.isCancelled, self.enabled else { return }
                if shouldRequestPermission && settings.authorizationStatus == .notDetermined {
                    _ = try? await self.center.requestAuthorization(options: [.alert, .sound])
                }
            }
        }
        enabled = newlyEnabled
    }

    func handle(action: String, kinds: [String], nonce: String) {
        guard enabled, !handled.contains(nonce) else { return }
        handled.append(nonce)
        if handled.count > 32 { handled.removeFirst(handled.count - 32) }
        let requested = Set(kinds.compactMap(HealthReminderKind.init(rawValue:)))
        let current = requested.intersection(wellness.pending)
        switch action {
        case "water": if current.contains(.water) { wellness.recordWater() }
        case "rest": if current.contains(.rest) { wellness.startShortRest() }
        case "later": for kind in current { wellness.postpone(kind) }
        default: open()
        }
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestID])
    }

    func dismiss() {
        generation += 1
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestID])
    }

    private func post(_ kinds: Set<HealthReminderKind>) {
        guard enabled else { return }
        generation += 1
        let postedGeneration = generation
        let content = UNMutableNotificationContent()
        content.title = tr("专注与健康")
        if kinds == [.rest, .water] {
            content.body = tr("休息一下，也别忘了喝水。")
        } else {
            content.body = tr(kinds.contains(.water) ? "喝点水，按自己的需要记录。" : "看看远处，活动一下肩颈。")
        }
        content.categoryIdentifier = kinds.count > 1 ? "XStats.wellness.combined" : kinds.contains(.water) ? "XStats.wellness.water" : "XStats.wellness.rest"
        content.userInfo = ["wellness": true, "wellness_kinds": kinds.map(\.rawValue).sorted(), "wellness_id": UUID().uuidString]
        // 提醒是建议而非告警，不使用 critical/time-sensitive 级别绕过勿扰。
        let previous = deliveryTask
        // 同一通知 ID 串行投递，旧请求完成清理后新请求才提交，避免误删较新的通知。
        deliveryTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            let settings = await self.center.notificationSettings()
            guard self.enabled, self.generation == postedGeneration, kinds.isSubset(of: self.wellness.pending),
                  settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            try? await self.center.add(UNNotificationRequest(identifier: Self.requestID, content: content, trigger: nil))
            if self.generation != postedGeneration { self.center.removeDeliveredNotifications(withIdentifiers: [Self.requestID]) }
        }
    }
}
