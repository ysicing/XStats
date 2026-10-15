// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

enum IslandPresentation: Equatable {
    case collapsed, preview, expanded

    var contentSize: CGSize {
        switch self {
        case .collapsed: CGSize(width: 272, height: 38)
        case .preview: CGSize(width: 360, height: 104)
        case .expanded: CGSize(width: 420, height: 300)
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
    var contentInset: CGFloat { hasNotch ? safeTop : 0 }
    var cameraWidth: CGFloat { hasNotch ? camera!.upperBound - camera!.lowerBound : 0 }

    func frame(for presentation: IslandPresentation) -> CGRect {
        let size = presentation.contentSize
        let width = min(max(size.width, cameraWidth + 24), visible.width)
        let center = hasNotch ? (camera!.lowerBound + camera!.upperBound) / 2 : visible.midX
        let x = min(max(center - width / 2, visible.minX), visible.maxX - width)
        let top = hasNotch ? screen.maxY : visible.maxY - 8
        let height = min(size.height + contentInset, top - visible.minY)
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

/// A hover ticket is invalidated by every explicit action, including a collapse while still hovered.
struct IslandInteraction {
    private(set) var presentation: IslandPresentation = .collapsed
    private var generation: UInt = 0
    private var pointerInside = false

    mutating func enter() -> UInt {
        pointerInside = true
        generation &+= 1
        return generation
    }

    mutating func finishHover(generation ticket: UInt) {
        guard ticket == generation, pointerInside, presentation == .collapsed else { return }
        presentation = .preview
    }

    mutating func leave() {
        pointerInside = false
        generation &+= 1
        if presentation == .preview { presentation = .collapsed }
    }

    mutating func expand() {
        generation &+= 1
        presentation = .expanded
    }

    mutating func collapse() {
        generation &+= 1
        presentation = .collapsed
    }
}
