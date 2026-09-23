// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

/// 独立日历入口：只按分钟刷新日期文本，关闭后移除定时器，不参与 MetricsHub 的秒级采样。
@MainActor
final class CalendarMenuBarController: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?
    private var panel: StatusPanel?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func start() {
        update()
        observeSettings()
        for (center, name) in [
            (NotificationCenter.default, Notification.Name.NSCalendarDayChanged),
            (NotificationCenter.default, Notification.Name.NSSystemTimeZoneDidChange),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTitle() }
            }
            observers.append((center, token))
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        dismiss()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    private func observeSettings() {
        withObservationTracking {
            _ = model.settings.calendarEnabled
            _ = model.settings.calendarFeatures
            _ = model.settings.calendarFirstWeekday
            _ = model.settings.language
            _ = model.settings.appearance
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observeSettings()
            }
        }
    }

    func update() {
        guard model.settings.calendarEnabled else {
            dismiss()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            timer?.invalidate()
            timer = nil
            return
        }
        if item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "XStats.calendar"
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: tr("日历"))
            item.button?.imagePosition = .imageLeading
            item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            self.item = item
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTitle() }
            }
            timer?.tolerance = 2
        }
        refreshTitle()
        panel?.refreshHeight()
    }

    private func refreshTitle() {
        guard let button = item?.button else { return }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = CalendarEngine.gregorian()
        formatter.timeZone = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate(model.settings.calendarFeatures.contains(.weekdays) ? "MdEEE" : "Md")
        button.title = " " + formatter.string(from: Date())
        formatter.dateStyle = .full
        button.toolTip = formatter.string(from: Date())
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp, let item {
            let menu = NSMenu()
            menu.addItem(withTitle: tr("日历设置…"), action: #selector(openSettings), keyEquivalent: "").target = self
            menu.addItem(withTitle: tr("退出 XStats"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            sender.performClick(nil)
            item.menu = nil
        } else {
            show()
        }
    }

    func show() {
        guard let button = item?.button, let window = button.window else { return }
        if panel == nil {
            let model = self.model
            let panel = StatusPanel(width: CalendarPopover.width, minHeight: 380,
                                    content: { CalendarPopover().environment(model) },
                                    measuring: { CalendarPopover().environment(model).environment(\.isSnapshot, true) })
            panel.onVisibilityChange = { [weak self] visible in self?.item?.button?.highlight(visible) }
            self.panel = panel
        }
        refreshTitle()
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        panel?.toggle(below: anchor, on: window.screen)
    }

    func dismiss() { panel?.dismiss() }

    @objc private func openSettings() {
        dismiss()
        model.openMainWindow(.settingsMenuBar)
    }
}
