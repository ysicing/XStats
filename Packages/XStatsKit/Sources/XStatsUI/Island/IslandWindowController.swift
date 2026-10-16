// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Metrics
import IOKit.ps
import Observation
import OSLog
import SwiftUI

@MainActor
final class IslandWindowController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "work.12306.xstats.app", category: "island")
    let model = IslandModel()
    private let appModel: AppModel
    private let fullscreenDetector: @MainActor (NSScreen) -> Bool
    private(set) var panel: IslandPanel?
    private(set) var isRunning = false
    private var interaction = IslandInteraction()
    private var hoverTask: Task<Void, Never>?
    private var transitionTask: Task<Void, Never>?
    private var transitionGeneration: UInt = 0
    private var statusItem: NSStatusItem?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var fullscreenTask: Task<Void, Never>?
    private var readingGeneration: UInt = 0
    private var quotaExpiryTask: Task<Void, Never>?
    private var quotaExpiry: Date?
    private var powerSource: CFRunLoopSource?
    private var powerRefreshTask: Task<Void, Never>?
    private var powerNoticeTask: Task<Void, Never>?
    private var previousBattery: BatteryStatus?
    private var lastBatteryRevision: UInt = 0
    private let powerNoticeDuration: Duration
    private var compactWidth: CGFloat = 160
    private var appliedPreferences = IslandPreferences()
    private var fullscreen = false
    private var locked = false
    private var sleeping = false
    private var displaysSleeping = false

    init(appModel: AppModel, powerNoticeDuration: Duration = .seconds(4), fullscreenDetector: @escaping @MainActor (NSScreen) -> Bool = IslandFullscreen.isActive) {
        self.appModel = appModel
        self.powerNoticeDuration = powerNoticeDuration
        self.fullscreenDetector = fullscreenDetector
        super.init()
    }

    private var preferences: IslandPreferences { appModel.islandPreferences }
    var isSuspended: Bool { preferences.scenes.isEmpty || locked || sleeping || displaysSleeping || (preferences.hideInFullscreen && fullscreen) }

    func syncWithPreferences() {
        guard preferences.enabled else { stop(); return }
        guard isRunning else { start(); return }
        let previous = appliedPreferences
        appliedPreferences = preferences
        if model.presentation != .expanded || !preferences.scenes.contains(model.scene) || previous.scene != preferences.scene {
            model.scene = preferences.scene
        }
        if previous.opening != preferences.opening || previous.display != preferences.display || previous.placement != preferences.placement {
            hoverTask?.cancel()
            hoverTask = nil
            interaction.collapse()
            panel?.resignKey()
        }
        compactWidth = measuredCompactWidth()
        refreshFullscreenState()
        if isSuspended { releasePanel() }
        else { render(animated: false) }
    }

    func start() {
        if isRunning { expand(); return }
        isRunning = true
        appliedPreferences = preferences
        model.scene = preferences.scene
        interaction.collapse()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.lefthalf.filled", accessibilityDescription: tr("灵动岛"))
        item.button?.toolTip = tr("灵动岛")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        installObservers()
        readingGeneration &+= 1
        observeReading(generation: readingGeneration)
        refreshFullscreenState()
        render(animated: false)
        Self.logger.notice("Island started with shared application services")
    }

    func refreshLanguage() {
        panel?.title = tr("灵动岛")
        statusItem?.button?.toolTip = tr("灵动岛")
        statusItem?.button?.image?.accessibilityDescription = tr("灵动岛")
        compactWidth = measuredCompactWidth()
        if isRunning { render(animated: false) }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        readingGeneration &+= 1
        fullscreenTask?.cancel()
        fullscreenTask = nil
        releasePanel()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        locked = false
        sleeping = false
        displaysSleeping = false
        fullscreen = false
        Self.logger.notice("Island stopped; visibility demand released")
    }

    func setLocked(_ value: Bool) {
        guard locked != value else { return }
        locked = value
        reconcileSuspension()
    }

    func setSleeping(_ value: Bool) {
        guard sleeping != value else { return }
        sleeping = value
        reconcileSuspension()
    }

    private func setDisplaysSleeping(_ value: Bool) {
        guard displaysSleeping != value else { return }
        displaysSleeping = value
        reconcileSuspension()
    }

    private func reconcileSuspension() {
        guard isRunning else { return }
        if isSuspended { releasePanel() }
        else { interaction.collapse(); render(animated: false) }
        Self.logger.info("Island suspension changed: \(self.isSuspended, privacy: .public)")
    }

    @objc func expand() {
        guard isRunning, !isSuspended else { return }
        hoverTask?.cancel()
        hoverTask = nil
        interaction.expand()
        render(animated: NSApp.currentEvent?.type != .keyDown)
        // Only an explicit click/menu action takes keyboard focus. Hover never steals it.
        panel?.makeKey()
    }

    @objc func collapse() {
        guard isRunning, !isSuspended else { return }
        hoverTask?.cancel()
        hoverTask = nil
        interaction.collapse()
        panel?.resignKey()
        render(animated: NSApp.currentEvent?.type != .keyDown)
    }

    @objc private func endPreview() {
        appModel.settings.islandPreferences.enabled = false
        stop()
    }

    func entered() {
        hoverTask?.cancel()
        let ticket = interaction.enter()
        guard interaction.presentation == .collapsed, preferences.opening != .click else { return }
        let delay = preferences.hoverDelay
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.isRunning, !self.isSuspended else { return }
            self.hoverTask = nil
            self.interaction.finishHover(generation: ticket, opening: self.preferences.opening)
            self.render(animated: true)
        }
    }

    func exited() {
        hoverTask?.cancel()
        hoverTask = nil
        let previous = interaction.presentation
        let ticket = interaction.leave()
        if previous != interaction.presentation { render(animated: true) }
        guard interaction.closesOnExit else { return }
        let delay = preferences.closeDelay
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.isRunning, !self.isSuspended else { return }
            self.hoverTask = nil
            self.interaction.finishClose(generation: ticket)
            if self.interaction.presentation != previous { self.render(animated: true) }
        }
    }

    private var selectedScreen: NSScreen? {
        guard let id = IslandDisplayChoice.preferredID(savedID: preferences.display, displays: IslandDisplayChoice.connected) else { return nil }
        return NSScreen.screens.first { IslandPreferences.displayKey($0) == id }
    }

    private func render(animated: Bool) {
        guard isRunning, !isSuspended else { return }
        guard let screen = selectedScreen else { releasePanel(); return }
        model.presentation = interaction.presentation
        if model.presentation != .collapsed { clearPowerNotice() }
        model.date = Date()
        if model.presentation == .collapsed { resolveFocus() }
        let geometry = IslandGeometry(screen)
        let placement = preferences.placement
        let topClearance = geometry.attachedTopClearance
        let target = geometry.frame(for: model.presentation, preferences: preferences, compactWidth: compactWidth)
        let panel = panel ?? makePanel()
        let previous = panel.frame
        let canAnimate = animated && panel.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        transitionTask?.cancel()
        transitionGeneration &+= 1
        let generation = transitionGeneration
        // Keep the top edge fixed. WindowServer gets only the reserved bounds and final bounds,
        // rather than a new NSWindow frame on each animation frame.
        let reserved = canAnimate ? previous.union(target) : target
        panel.setFrame(reserved, display: false)
        let canvas = panel.contentView as! IslandCanvas
        canvas.layoutSurface(target: target, placement: placement, topClearance: topClearance, animated: canAnimate)
        panel.orderFrontRegardless()
        updateDemand()
        updateQuotaExpiry()
        updateInputMonitors()
        guard canAnimate else { transitionTask = nil; return }
        transitionTask = Task { @MainActor [weak self, weak panel] in
            do { try await Task.sleep(for: .seconds(DS.Motion.selectionDuration)) } catch { return }
            guard let self, let panel, self.isRunning, !self.isSuspended,
                  self.transitionGeneration == generation, self.panel === panel else { return }
            self.transitionTask = nil
            panel.setFrame(target, display: false)
            (panel.contentView as? IslandCanvas)?.layoutSurface(target: target, placement: placement, topClearance: topClearance, animated: false)
        }
    }

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        // 浮在普通窗口之上，但系统菜单及状态栏始终优先显示和接收操作。
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.title = tr("灵动岛")
        let content = IslandView(model: model, appModel: appModel,
            selectScene: { [weak self] in self?.selectScene($0) },
            expand: { [weak self] in self?.expand() },
            collapse: { [weak self] in self?.collapse() },
            stop: { [weak self] in self?.endPreview() })
        let canvas = IslandCanvas(content: content)
        canvas.onEnter = { [weak self] in self?.entered() }
        canvas.onExit = { [weak self] in self?.exited() }
        canvas.onPress = { [weak self] in self?.expand() }
        panel.contentView = canvas
        self.panel = panel
        return panel
    }

    private func releasePanel() {
        stopPowerObservation()
        quotaExpiryTask?.cancel()
        quotaExpiryTask = nil
        quotaExpiry = nil
        hoverTask?.cancel()
        hoverTask = nil
        transitionTask?.cancel()
        transitionTask = nil
        transitionGeneration &+= 1
        removeInputMonitors()
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel?.close()
        panel = nil
        interaction.collapse()
        model.presentation = .collapsed
        updateDemand()
    }

    func selectScene(_ scene: IslandScene) {
        guard preferences.scenes.contains(scene) else { return }
        model.scene = scene
        appModel.settings.islandPreferences.scene = scene
        updateDemand()
        updateQuotaExpiry()
    }

    private func resolveFocus() {
        model.scene = preferences.automaticFocus ? IslandFocus.scene(preferences: preferences, battery: appModel.store.battery,
            quota: preferences.scenes.contains(.ai) ? IslandReading(scene: .ai, appModel: appModel).quotaAccount : nil, at: Date()) : preferences.scene
        compactWidth = measuredCompactWidth()
    }

    private func observeReading(generation: UInt) {
        let observedPreferences = preferences
        withObservationTracking {
            _ = preferences
            // 观察真实服务的更新，不另设额度或电量轮询。展开期间仍记录变化但不抢占页面。
            if preferences.scenes.contains(.battery) { _ = appModel.store.batteryRevision }
            if preferences.automaticFocus {
                _ = IslandFocus.scene(preferences: preferences,
                    battery: preferences.scenes.contains(.battery) ? appModel.store.battery : nil,
                    quota: preferences.scenes.contains(.ai) ? IslandReading(scene: .ai, appModel: appModel).quotaAccount : nil, at: Date())
            }
            compactWidth = measuredCompactWidth()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.readingGeneration == generation else { return }
                let previousWidth = self.compactWidth
                let previousScene = self.model.scene
                self.receiveBattery(self.appModel.store.battery, revision: self.appModel.store.batteryRevision)
                let contentChanged = observedPreferences != self.preferences
                if !self.preferences.scenes.contains(self.model.scene) || observedPreferences.scene != self.preferences.scene {
                    self.model.scene = self.preferences.scene
                }
                if self.model.presentation == .collapsed { self.resolveFocus() }
                self.model.date = Date()
                self.observeReading(generation: generation)
                self.updateQuotaExpiry()
                if self.isSuspended { self.releasePanel(); return }
                if contentChanged || previousScene != self.model.scene
                    || (self.model.presentation == .collapsed && previousWidth != self.compactWidth) {
                    self.render(animated: false)
                }
            }
        }
    }

    /// 只为所选账号最近的重置点安排一次性失效，不增加网络请求或周期性唤醒。
    private func updateQuotaExpiry() {
        guard isRunning, !isSuspended, panel?.isVisible == true else { return }
        let date = Date()
        let needsQuota = model.scene == .ai || (preferences.automaticFocus && preferences.scenes.contains(.ai))
        var next = needsQuota ? IslandReading(scene: .ai, appModel: appModel).quotaAccount?.windows
            .compactMap(\.resetsAt).filter { $0 > date }.min() : nil
        // 仅展开且存在可靠刻线时，每分钟更新一次时间位置；复用同一个失效任务。
        if model.scene == .ai, model.presentation == .expanded,
           let account = IslandReading(scene: .ai, appModel: appModel).quotaAccount, !account.stale,
           account.windows.contains(where: { $0.paceFraction(at: date, showsRemaining: true) != nil }) {
            let minute = Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / 60) + 1) * 60)
            next = min(next ?? minute, minute)
        }
        guard next != quotaExpiry else { return }
        quotaExpiryTask?.cancel()
        quotaExpiry = next
        guard let next else { quotaExpiryTask = nil; return }
        quotaExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow))) } catch { return }
            guard let self, !Task.isCancelled, self.isRunning, !self.isSuspended, self.quotaExpiry == next else { return }
            self.quotaExpiry = nil
            self.quotaExpiryTask = nil
            self.render(animated: false)
        }
    }

    func setFullscreen(_ value: Bool) {
        guard fullscreen != value else { return }
        fullscreen = value
        reconcileSuspension()
    }

    /// 只在桌面、前台应用或显示器变化后读取窗口边界，不读取标题，也不轮询。
    private func refreshFullscreenState() {
        guard isRunning, preferences.hideInFullscreen, let screen = selectedScreen else {
            setFullscreen(false)
            return
        }
        setFullscreen(fullscreenDetector(screen))
    }

    private func scheduleFullscreenRefresh() {
        fullscreenTask?.cancel()
        fullscreenTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.isRunning else { return }
            self.fullscreenTask = nil
            let wasSuspended = self.isSuspended
            self.refreshFullscreenState()
            // 切换 Space / 全屏时系统可能移动辅助窗口；布尔状态不变也必须校正位置。
            // 从隐藏恢复的路径已在 reconcileSuspension 中重建并定位，避免重复布局。
            if !wasSuspended, !self.isSuspended { self.render(animated: false) }
        }
    }

    private func updateDemand() {
        let visible = isRunning && !isSuspended && panel?.isVisible == true
        appModel.islandScene = visible ? model.scene : nil
        appModel.islandExpanded = visible && model.presentation == .expanded
        appModel.rest.setIslandVisible(visible && model.scene == .focus)
        if visible && preferences.scenes.contains(.battery) { startPowerObservation() }
        else { stopPowerObservation() }
    }

    private func measuredCompactWidth() -> CGFloat {
        let reading = IslandReading(scene: model.scene, appModel: appModel)
        let value = model.powerNotice.map { $0.title + " " + reading.batteryValue } ?? reading.compactValue
        return IslandCompactLayout.width(for: value)
    }

    private func clearPowerNotice() {
        powerNoticeTask?.cancel()
        powerNoticeTask = nil
        model.powerNotice = nil
    }

    /// 只有真实电源变更才触发一次读取；持续电量变化沿用 MetricsHub 原有低频采样。
    private func startPowerObservation() {
        guard powerSource == nil else { return }
        previousBattery = nil
        lastBatteryRevision = appModel.store.batteryRevision
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<IslandWindowController>.fromOpaque(context).takeUnretainedValue().refreshPowerReading()
            }
        }, context)?.takeRetainedValue() else { return }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        refreshPowerReading()
    }

    private func refreshPowerReading() {
        powerRefreshTask?.cancel()
        let hub = appModel.hub
        powerRefreshTask = Task { @MainActor [weak self] in
            guard let snapshot = await hub.sampleBattery(), !Task.isCancelled, let self,
                  self.isRunning, !self.isSuspended, self.panel?.isVisible == true,
                  self.preferences.scenes.contains(.battery) else { return }
            self.appModel.handle(snapshot)
        }
    }

    private func stopPowerObservation() {
        if let source = powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        powerSource = nil
        powerRefreshTask?.cancel()
        powerRefreshTask = nil
        previousBattery = nil
        clearPowerNotice()
    }

    func receiveBattery(_ battery: BatteryStatus?, revision: UInt) {
        guard isRunning, !isSuspended, panel?.isVisible == true, preferences.scenes.contains(.battery) else { return }
        // 组合观察也会由设置或展示状态触发。恢复前的缓存与已消费快照不能建立新基线。
        guard revision != lastBatteryRevision else { return }
        lastBatteryRevision = revision
        let previous = previousBattery
        previousBattery = battery
        guard let battery, let event = IslandPowerNotice.event(previous: previous, current: battery),
              model.presentation == .collapsed else { return }
        clearPowerNotice()
        model.powerNotice = event
        render(animated: false)
        powerNoticeTask = Task { @MainActor [weak self, powerNoticeDuration] in
            do { try await Task.sleep(for: powerNoticeDuration) } catch { return }
            guard let self, !Task.isCancelled, self.isRunning, !self.isSuspended else { return }
            self.powerNoticeTask = nil
            self.model.powerNotice = nil
            self.render(animated: false)
        }
    }

    private func updateInputMonitors() {
        guard model.presentation != .collapsed else { removeInputMonitors(); return }
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    guard event.keyCode == 53, event.window === self.panel else { return false }
                    self.collapse()
                    return true
                }
                if !self.containsMouse() { self.collapse() }
                return false
            }
            return consumed ? nil : event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.containsMouse() else { return }
                self.collapse()
            }
        }
    }

    private func containsMouse() -> Bool {
        guard let panel, let canvas = panel.contentView as? IslandCanvas else { return false }
        let point = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        return canvas.contains(point)
    }

    private func removeInputMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverTask?.cancel()
                self.hoverTask = nil
                self.interaction.leave()
                self.scheduleFullscreenRefresh()
                self.render(animated: false)
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFullscreenRefresh() }
            }))
        }
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSleeping(true) }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSleeping(false) }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDisplaysSleeping(true) }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setDisplaysSleeping(false) }
        }))
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append((distributed, distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setLocked(locked) }
            }))
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: tr("灵动岛"), action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(.separator())
        addItem(tr("展开"), action: #selector(expand), to: menu)
        addItem(tr("收起"), action: #selector(collapse), to: menu)
        let automatic = addItem(tr("自动选择屏幕"), action: #selector(selectScreen(_:)), to: menu)
        automatic.state = preferences.display.isEmpty ? .on : .off
        for screen in IslandDisplayChoice.connected {
            let id = screen.id
            let item = addItem(screen.title, action: #selector(selectScreen(_:)), to: menu)
            item.representedObject = id
            item.state = preferences.display == id ? .on : .off
        }
        menu.addItem(.separator())
        addItem(tr("关闭灵动岛"), action: #selector(endPreview), to: menu)
    }

    @discardableResult private func addItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func selectScreen(_ sender: NSMenuItem) {
        appModel.settings.islandPreferences.display = sender.representedObject as? String ?? ""
        interaction.collapse()
        panel?.resignKey()
        hoverTask?.cancel()
        hoverTask = nil
        refreshFullscreenState()
        render(animated: false)
    }
}

@MainActor final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The shape is the only opaque surface; the transparent animation reserve does not paint pixels.
@MainActor private final class IslandCanvas: NSView {
    private let surface = CAShapeLayer()
    private let hosting: NSHostingView<IslandView>
    private var tracking: NSTrackingArea?
    private var lastWindowFrame: CGRect?
    private var trackingRect = CGRect.zero
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onPress: (() -> Void)?

    init(content: IslandView) {
        hosting = NSHostingView(rootView: content)
        super.init(frame: .zero)
        wantsLayer = true
        surface.fillColor = NSColor.black.cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = surface
        hosting.sizingOptions = []
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { nil }

    func layoutSurface(target: CGRect, placement: IslandPlacement, topClearance: CGFloat, animated: Bool) {
        guard let window else { return }
        let local = CGRect(x: target.minX - window.frame.minX, y: target.minY - window.frame.minY,
                           width: target.width, height: target.height)
        var oldPath = surface.presentation()?.path ?? surface.path
        if let lastWindowFrame {
            var offset = CGAffineTransform(translationX: lastWindowFrame.minX - window.frame.minX,
                                           y: lastWindowFrame.minY - window.frame.minY)
            oldPath = oldPath?.copy(using: &offset)
        }
        lastWindowFrame = window.frame
        // 同一模式下路径拓扑固定，中断时沿当前呈现形状继续过渡；切换模式即时重新布局。
        let newPath = IslandSilhouette.path(in: local, placement: placement)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        surface.path = newPath
        surface.removeAllAnimations()
        CATransaction.commit()
        if animated, let oldPath {
            let animation = CABasicAnimation(keyPath: "path")
            animation.fromValue = oldPath
            animation.toValue = newPath
            animation.duration = DS.Motion.selectionDuration
            animation.timingFunction = DS.Motion.selectionTimingFunction
            surface.add(animation, forKey: "island-shape")
        }
        hosting.frame = IslandSilhouette.contentFrame(in: local, placement: placement, topClearance: topClearance)
        trackingRect = local
        updateTrackingAreas()
    }

    func contains(_ point: CGPoint) -> Bool {
        (surface.presentation()?.path ?? surface.path)?.contains(point) == true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        contains(point) ? super.hitTest(point) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: trackingRect, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onPress?() }
}
