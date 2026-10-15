// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// 选框使用屏幕内的 AppKit 坐标；拖动期间只更新草稿，确认由选择界面负责。
struct RegionSelection {
    enum Handle: CaseIterable {
        case bottomLeft, bottomRight, topLeft, topRight, left, right, bottom, top

        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .topLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.maxY)
            case .left: CGPoint(x: rect.minX, y: rect.midY)
            case .right: CGPoint(x: rect.maxX, y: rect.midY)
            case .bottom: CGPoint(x: rect.midX, y: rect.minY)
            case .top: CGPoint(x: rect.midX, y: rect.maxY)
            }
        }
    }
    private enum Drag {
        case create(CGPoint)
        case move(CGRect, CGPoint)
        case resize(CGRect, Handle, CGPoint)
    }
    private(set) var rect: CGRect?
    private var drag: Drag?
    var isDragging: Bool { drag != nil }
    var isReady: Bool { !isDragging && rect != nil }
    var isAdjusting: Bool {
        switch drag {
        case .move, .resize: true
        case .create, nil: false
        }
    }

    func handle(at point: CGPoint) -> Handle? {
        guard let rect, !isDragging else { return nil }
        // 四角优先，实际命中范围大于可见手柄，便于精确选取。
        if let handle = Handle.allCases.first(where: {
            let center = $0.point(in: rect)
            return abs(point.x - center.x) <= 8 && abs(point.y - center.y) <= 8
        }) { return handle }
        if point.y >= rect.minY, point.y <= rect.maxY {
            if abs(point.x - rect.minX) <= 8 { return .left }
            if abs(point.x - rect.maxX) <= 8 { return .right }
        }
        if point.x >= rect.minX, point.x <= rect.maxX {
            if abs(point.y - rect.minY) <= 8 { return .bottom }
            if abs(point.y - rect.maxY) <= 8 { return .top }
        }
        return nil
    }
    mutating func begin(at point: CGPoint, in bounds: CGRect) {
        let point = clamped(point, in: bounds)
        if let rect, let handle = handle(at: point) {
            drag = .resize(rect, handle, point)
        } else if let rect, rect.contains(point) {
            drag = .move(rect, point)
        } else {
            rect = CGRect(origin: point, size: .zero)
            drag = .create(point)
        }
    }
    mutating func update(to point: CGPoint, in bounds: CGRect) {
        let point = clamped(point, in: bounds)
        switch drag {
        case .create(let origin):
            rect = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                          width: abs(origin.x - point.x), height: abs(origin.y - point.y))
        case .move(let initial, let origin):
            rect = CGRect(x: min(max(bounds.minX, initial.minX + point.x - origin.x), bounds.maxX - initial.width),
                          y: min(max(bounds.minY, initial.minY + point.y - origin.y), bounds.maxY - initial.height),
                          width: initial.width, height: initial.height)
        case .resize(let initial, let handle, let origin):
            var left = initial.minX, right = initial.maxX, bottom = initial.minY, top = initial.maxY
            let dx = point.x - origin.x, dy = point.y - origin.y
            // 拉过对侧边缘时保持最小范围，避免手柄跳到另一边或生成负尺寸。
            if [.left, .bottomLeft, .topLeft].contains(handle) { left = min(initial.maxX - 2, max(bounds.minX, initial.minX + dx)) }
            if [.right, .bottomRight, .topRight].contains(handle) { right = max(initial.minX + 2, min(bounds.maxX, initial.maxX + dx)) }
            if [.bottom, .bottomLeft, .bottomRight].contains(handle) { bottom = min(initial.maxY - 2, max(bounds.minY, initial.minY + dy)) }
            if [.top, .topLeft, .topRight].contains(handle) { top = max(initial.minY + 2, min(bounds.maxY, initial.maxY + dy)) }
            rect = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        case nil: break
        }
    }
    mutating func end(at point: CGPoint, in bounds: CGRect) {
        update(to: point, in: bounds)
        drag = nil
        if let rect, rect.width < 2 || rect.height < 2 { self.rect = nil }
    }
    mutating func reset() { rect = nil; drag = nil }
    private func clamped(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(bounds.minX, point.x), bounds.maxX), y: min(max(bounds.minY, point.y), bounds.maxY))
    }
}
