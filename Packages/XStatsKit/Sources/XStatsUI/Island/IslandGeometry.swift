// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization

@MainActor
enum IslandFullscreen {
    static func isActive(on screen: NSScreen) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        return windows.contains { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(), pid == frontPID,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"], let height = bounds["Height"] else { return false }
            let frame = CGRect(x: x, y: primaryTop - y - height, width: width, height: height)
            return abs(frame.minX - screen.frame.minX) <= 1 && abs(frame.minY - screen.frame.minY) <= 1
                && abs(frame.width - screen.frame.width) <= 1 && abs(frame.height - screen.frame.height) <= 1
        }
    }
}

enum IslandPresentation: Equatable {
    case collapsed, preview, expanded

    var contentSize: CGSize {
        switch self {
        case .collapsed: CGSize(width: 160, height: 32)
        case .preview: CGSize(width: 360, height: 104)
        case .expanded: CGSize(width: 420, height: 320)
        }
    }
}

/// All coordinates are AppKit screen points, including displays above/left of the main display.
struct IslandGeometry {
    let screen: CGRect
    let visible: CGRect
    var safeTop: CGFloat = 0
    var camera: ClosedRange<CGFloat>?

    var hasNotch: Bool { safeTop > 0 && camera.map { $0.upperBound > $0.lowerBound } == true }

    var topClearance: CGFloat { max(0, safeTop, screen.maxY - visible.maxY) }
    // 贴合模式只避让当前占用的顶部区域；菜单栏自动隐藏时不额外画一段空黑条。
    var attachedTopClearance: CGFloat { max(0, safeTop, screen.maxY - visible.maxY) }

    func frame(for presentation: IslandPresentation, preferences: IslandPreferences = IslandPreferences(), compactWidth: CGFloat = 160) -> CGRect {
        let size: CGSize = switch presentation {
        case .collapsed: CGSize(width: compactWidth, height: 32)
        case .preview: presentation.contentSize
        case .expanded: preferences.expandedSize
        }
        let attached = preferences.placement == .attached
        let cameraWidth = hasNotch ? camera!.upperBound - camera!.lowerBound : 0
        let shoulder = attached ? IslandSilhouette.shoulder : 0
        let desiredWidth = presentation == .collapsed && attached ? max(size.width, cameraWidth) + 2 * shoulder : size.width
        let width = min(desiredWidth, visible.width)
        let center = hasNotch ? (camera!.lowerBound + camera!.upperBound) / 2 : visible.midX
        let x = min(max(center - width / 2, visible.minX), visible.maxX - width)
        // 只避让目标屏幕实际保留的菜单栏和安全区；自动隐藏时保留用户设定的悬浮间距。
        let top = attached ? screen.maxY : screen.maxY - topClearance - preferences.normalized.topInset
        let height = max(0, min(size.height + (attached ? attachedTopClearance : 0), top - visible.minY))
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    @MainActor init(_ display: NSScreen) {
        screen = display.frame
        visible = display.visibleFrame
        safeTop = display.safeAreaInsets.top
        if let left = display.auxiliaryTopLeftArea, let right = display.auxiliaryTopRightArea {
            camera = left.maxX...max(left.maxX, right.minX)
        }
    }

    init(screen: CGRect, visible: CGRect, safeTop: CGFloat = 0, camera: ClosedRange<CGFloat>? = nil) {
        self.screen = screen
        self.visible = visible
        self.safeTop = safeTop
        self.camera = camera
    }
}

/// 首项是系统主屏幕，自动选择优先使用当前连接的内置屏幕；偏好中的 UUID 不受临时回退影响。
struct IslandDisplayChoice: Identifiable, Sendable {
    let id: String
    let name: String
    let isBuiltIn: Bool

    var title: String { isBuiltIn ? tr("\(name)（内置屏幕）") : tr("\(name)（外接屏幕）") }

    static func preferredID(savedID: String, displays: [Self]) -> String? {
        if !savedID.isEmpty, displays.contains(where: { $0.id == savedID }) { return savedID }
        return (displays.first(where: \.isBuiltIn) ?? displays.first)?.id
    }

    @MainActor static var connected: [Self] {
        NSScreen.screens.map { screen in
            let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return Self(id: IslandPreferences.displayKey(screen), name: screen.localizedName, isBuiltIn: CGDisplayIsBuiltin(number) != 0)
        }
    }
}

/// 两种外形的内容区域与裁剪保持一致；贴合模式上方只连接屏幕，不承载读数或按钮。
enum IslandSilhouette {
    static let shoulder: CGFloat = 12

    static func contentFrame(in bounds: CGRect, placement: IslandPlacement, topClearance: CGFloat) -> CGRect {
        guard placement == .attached else { return bounds }
        let inset = min(shoulder, bounds.width / 2)
        return CGRect(x: bounds.minX + inset, y: bounds.minY, width: max(0, bounds.width - 2 * inset),
                      height: max(0, bounds.height - topClearance))
    }

    static func path(in bounds: CGRect, placement: IslandPlacement) -> CGPath {
        guard placement == .attached else {
            let radius = min(24, bounds.height / 2)
            return CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        }
        let s = min(shoulder, bounds.width / 4, bounds.height / 4)
        let radius = min(24, (bounds.width - 2 * s) / 2, bounds.height / 2)
        let left = bounds.minX + s, right = bounds.maxX - s
        let top = bounds.maxY, bottom = bounds.minY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: bounds.minX, y: top))
        path.addLine(to: CGPoint(x: bounds.maxX, y: top))
        path.addCurve(to: CGPoint(x: right, y: top - s), control1: CGPoint(x: right, y: top), control2: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom + radius))
        path.addQuadCurve(to: CGPoint(x: right - radius, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom + radius), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: top - s))
        path.addCurve(to: CGPoint(x: bounds.minX, y: top), control1: CGPoint(x: left, y: top), control2: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }
}

/// A hover ticket is invalidated by every explicit action, including a collapse while still hovered.
struct IslandInteraction {
    private(set) var presentation: IslandPresentation = .collapsed
    private var generation: UInt = 0
    private var pointerInside = false
    private var expandedByHover = false
    var closesOnExit: Bool { expandedByHover }

    mutating func enter() -> UInt {
        pointerInside = true
        generation &+= 1
        return generation
    }

    mutating func finishHover(generation ticket: UInt, opening: IslandOpening = .hoverPreview) {
        guard ticket == generation, pointerInside, presentation == .collapsed else { return }
        guard opening != .click else { return }
        expandedByHover = opening == .hoverExpand
        presentation = expandedByHover ? .expanded : .preview
    }

    @discardableResult mutating func leave() -> UInt {
        pointerInside = false
        generation &+= 1
        if presentation == .preview { presentation = .collapsed }
        return generation
    }

    mutating func finishClose(generation ticket: UInt) {
        guard ticket == generation, !pointerInside, expandedByHover else { return }
        collapse()
    }

    mutating func expand() {
        generation &+= 1
        expandedByHover = false
        presentation = .expanded
    }

    mutating func collapse() {
        generation &+= 1
        expandedByHover = false
        presentation = .collapsed
    }
}
