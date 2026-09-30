// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

/// 独立日历入口：按分钟刷新，关闭或休眠时停止。
@MainActor
final class CalendarMenuBarController: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?
    private var panel: StatusPanel?
    private var panelSizing: CalendarPopoverSizing?
    private var timer: Timer?
    private var hoverView: CalendarHoverView?
    private var hoverTask: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func start() {
        model.openCalendar = { [weak self] in self?.show() }
        model.restoreCalendarEntry = { [weak self] in
            self?.item?.isVisible = true
            self?.update()
        }
        update()
        observeSettings()
        for (center, name) in [
            (NotificationCenter.default, Notification.Name.NSCalendarDayChanged),
            (NotificationCenter.default, Notification.Name.NSSystemTimeZoneDidChange),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
        ] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            observers.append((center, token))
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append((center, center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer?.invalidate()
                self?.timer = nil
                self?.hoverTask?.cancel()
                self?.dismiss()
            }
        }))
    }

    func stop() {
        hoverTask?.cancel()
        hoverView?.removeFromSuperview()
        hoverView = nil
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
            _ = model.settings.calendarPreferences
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
            hoverTask?.cancel()
            hoverView?.removeFromSuperview()
            hoverView = nil
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
            item.button?.font = .menuBarFont(ofSize: 0)
            self.item = item
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshTitle() }
            }
            timer?.tolerance = 2
        }
        if model.settings.calendarPreferences.openOnHover, let button = item?.button {
            if hoverView == nil {
                let view = CalendarHoverView(frame: button.bounds)
                view.autoresizingMask = [.width, .height]
                view.entered = { [weak self] in self?.scheduleHover() }
                view.exited = { [weak self] in self?.hoverTask?.cancel() }
                button.addSubview(view)
                hoverView = view
            }
        } else {
            hoverTask?.cancel()
            hoverView?.removeFromSuperview()
            hoverView = nil
        }
        refreshTitle()
        panel?.refreshHeight()
    }

    private func refreshTitle() {
        guard let button = item?.button else { return }
        let preferences = model.settings.calendarPreferences
        let title = preferences.title(at: Date(), locale: L10n.locale,
                                      showsLunar: model.settings.calendarFeatures.contains(.lunar))
        button.title = title.isEmpty ? "" : " " + title
        button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: tr("日历"))
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = CalendarEngine.gregorian()
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .full
        button.toolTip = formatter.string(from: Date())
        button.setAccessibilityLabel(tr("日历") + " · " + formatter.string(from: Date()))
    }

    private func scheduleHover() {
        hoverTask?.cancel()
        guard panel?.isVisible != true else { return }
        hoverTask = Task { @MainActor [weak self] in
            // 略过鼠标经过菜单栏时的瞬时进入；离开图标立即取消。
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.panel?.isVisible != true else { return }
            self.show()
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        hoverTask?.cancel()
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
        // 菜单栏开关只控制常驻入口；全局快捷键仍可按需打开日历。
        let screen = item?.button?.window?.screen ?? NSApp.keyWindow?.screen ?? NSScreen.main
        let sizing = CalendarPopoverSizing.fitting(visibleSize: screen?.visibleFrame.size ?? CGSize(width: 520, height: 900))
        if panel == nil || (panel?.isVisible == false && panelSizing != sizing) {
            let model = self.model
            let panel = StatusPanel(width: sizing.width, minHeight: 380, maxHeight: sizing.maxHeight,
                                    content: { CalendarPopover(sizing: sizing, firstWeekday: model.settings.calendarFirstWeekday).environment(model) },
                                    measuring: { CalendarPopover(sizing: sizing, firstWeekday: model.settings.calendarFirstWeekday).environment(model).environment(\.isSnapshot, true) })
            panel.onVisibilityChange = { [weak self] visible in self?.item?.button?.highlight(visible) }
            self.panel = panel
            panelSizing = sizing
        }
        refreshTitle()
        if let button = item?.button, let window = button.window, item?.isVisible == true {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            panel?.toggle(below: anchor, on: window.screen)
        } else if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            // 菜单栏入口隐藏时，设置页仍可打开日历。
            let visible = screen.visibleFrame
            panel?.toggle(below: NSRect(x: visible.midX, y: visible.maxY, width: 1, height: 1), on: screen)
        }
    }

    func dismiss() { panel?.dismiss() }

    @objc private func openSettings() {
        dismiss()
        model.openMainWindow(.settingsMenuBar)
    }
}

@MainActor
private final class CalendarHoverView: NSView {
    var entered: () -> Void = {}
    var exited: () -> Void = {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { entered() }
    override func mouseExited(with event: NSEvent) { exited() }
}
