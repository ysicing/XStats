// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import OSLog
import SwiftUI

@MainActor
final class IslandWindowController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "work.12306.xstats.app", category: "island")
    let model = IslandModel()
    private let appModel: AppModel
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
    private var screenID: CGDirectDisplayID?
    private var locked = false
    private var sleeping = false
    private var displaysSleeping = false

    init(appModel: AppModel) {
        self.appModel = appModel
        super.init()
    }

    var isSuspended: Bool { locked || sleeping || displaysSleeping }

    func start() {
        if isRunning { expand(); return }
        isRunning = true
        interaction.collapse()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.lefthalf.filled", accessibilityDescription: tr("灵动岛"))
        item.button?.toolTip = tr("灵动岛")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        installObservers()
        render(animated: false)
        Self.logger.notice("Island started with shared application services")
    }

    func refreshLanguage() {
        panel?.title = tr("灵动岛")
        statusItem?.button?.toolTip = tr("灵动岛")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        releasePanel()
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        locked = false
        sleeping = false
        displaysSleeping = false
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
        render(animated: true)
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
        stop()
    }

    private func entered() {
        hoverTask?.cancel()
        let ticket = interaction.enter()
        guard interaction.presentation == .collapsed else { return }
        hoverTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.isRunning, !self.isSuspended else { return }
            self.hoverTask = nil
            self.interaction.finishHover(generation: ticket)
            self.render(animated: true)
        }
    }

    private func exited() {
        hoverTask?.cancel()
        hoverTask = nil
        let previous = interaction.presentation
        interaction.leave()
        if previous != interaction.presentation { render(animated: true) }
    }

    private var selectedScreen: NSScreen? {
        if let screenID, let screen = NSScreen.screens.first(where: { displayID($0) == screenID }) { return screen }
        return NSScreen.screens.first(where: { CGDisplayIsBuiltin(displayID($0)) != 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func render(animated: Bool) {
        guard isRunning, !isSuspended else { return }
        guard let screen = selectedScreen else { releasePanel(); return }
        model.presentation = interaction.presentation
        let geometry = IslandGeometry(screen)
        let target = geometry.frame(for: model.presentation)
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
        canvas.layoutSurface(target: target, geometry: geometry, animated: canAnimate)
        panel.orderFrontRegardless()
        updateDemand()
        updateInputMonitors()
        guard canAnimate else { transitionTask = nil; return }
        transitionTask = Task { @MainActor [weak self, weak panel] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, let panel, self.isRunning, !self.isSuspended,
                  self.transitionGeneration == generation, self.panel === panel else { return }
            self.transitionTask = nil
            panel.setFrame(target, display: false)
            (panel.contentView as? IslandCanvas)?.layoutSurface(target: target, geometry: geometry, animated: false)
        }
    }

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
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
        panel.contentView = canvas
        self.panel = panel
        return panel
    }

    private func releasePanel() {
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
        model.scene = scene
        updateDemand()
    }

    private func updateDemand() {
        let visible = isRunning && !isSuspended && panel?.isVisible == true
        appModel.islandScene = visible ? model.scene : nil
        appModel.islandExpanded = visible && model.presentation == .expanded
        appModel.rest.setIslandVisible(visible && model.scene == .focus)
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
                self.render(animated: false)
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
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
        automatic.state = screenID == nil ? .on : .off
        for screen in NSScreen.screens {
            let id = displayID(screen)
            let item = addItem(screen.localizedName, action: #selector(selectScreen(_:)), to: menu)
            item.representedObject = NSNumber(value: id)
            item.state = screenID == id ? .on : .off
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
        screenID = (sender.representedObject as? NSNumber)?.uint32Value
        interaction.collapse()
        hoverTask?.cancel()
        hoverTask = nil
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
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

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

    func layoutSurface(target: CGRect, geometry: IslandGeometry, animated: Bool) {
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
        let path = CGMutablePath()
        let w = local.width
        let h = local.height
        let top = geometry.contentInset
        let r: CGFloat = min(top > 0 ? 20 : 24, (h - top) / 2)
        let neck = geometry.hasNotch ? min(w - 24, geometry.cameraWidth) : w - 2 * r
        let left = (w - neck) / 2
        let right = w - left
        // Same path topology in every state permits an interruptible Core Animation morph.
        path.move(to: CGPoint(x: left, y: 0))
        path.addQuadCurve(to: CGPoint(x: left, y: top), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: r, y: top))
        path.addQuadCurve(to: CGPoint(x: 0, y: top + r), control: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: 0, y: h - r))
        path.addQuadCurve(to: CGPoint(x: r, y: h), control: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: w - r, y: h))
        path.addQuadCurve(to: CGPoint(x: w, y: h - r), control: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: w, y: top + r))
        path.addQuadCurve(to: CGPoint(x: w - r, y: top), control: CGPoint(x: w, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: 0), control: CGPoint(x: right, y: top))
        path.closeSubpath()
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: local.minX, ty: local.maxY)
        let newPath = path.copy(using: &transform)!
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
            // Matches DS.Motion.quick's short ease-out selection feedback.
            animation.duration = 0.15
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            surface.add(animation, forKey: "island-shape")
        }
        hosting.frame = CGRect(x: local.minX, y: local.minY, width: local.width, height: max(0, local.height - top))
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
        let area = NSTrackingArea(rect: hosting.frame, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
