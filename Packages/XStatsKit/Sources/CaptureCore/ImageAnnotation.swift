// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CoreText

public struct ImageAnnotation: Sendable, Identifiable, Equatable {
    public let id: UUID
    public var tool: ImageTool
    /// Original-image pixel coordinates, top-left origin.
    public var points: [CGPoint]
    public var text: String
    public var color: CGColor
    public var lineWidth: CGFloat
    public var fontSize: CGFloat
    public var mosaicSize: MosaicSize
    public init(id: UUID = UUID(), tool: ImageTool, points: [CGPoint], text: String = "",
                color: CGColor = CGColor(red: 1, green: 0.2, blue: 0.15, alpha: 1), lineWidth: CGFloat = 4, fontSize: CGFloat = 26, mosaicSize: MosaicSize = .medium) {
        self.id = id; self.tool = tool; self.points = points; self.text = text
        self.color = color; self.lineWidth = lineWidth; self.fontSize = fontSize; self.mosaicSize = mosaicSize
    }
    private var textLine: CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor(cgColor: color) ?? .systemRed
        ]))
    }
    public var bounds: CGRect {
        guard let first = points.first else { return .zero }
        if tool == .text {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CTLineGetTypographicBounds(textLine, &ascent, &descent, &leading)
            return CGRect(x: first.x, y: first.y, width: max(1, ceil(width)), height: max(1, ceil(ascent + descent + leading)))
        }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    public func translated(by offset: CGSize) -> Self {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) }
        return copy
    }
    public func resized(to rect: CGRect) -> Self {
        let original = bounds
        var copy = self
        copy.points = points.map { point in
            CGPoint(x: rect.minX + (original.width > 0 ? (point.x - original.minX) / original.width : 0) * rect.width,
                    y: rect.minY + (original.height > 0 ? (point.y - original.minY) / original.height : 0) * rect.height)
        }
        return copy
    }
    public func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        let tolerance = max(tolerance, lineWidth / 2)
        switch tool {
        case .crop: return false
        case .text, .redact: return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .rectangle:
            let outer = bounds.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = bounds.insetBy(dx: tolerance, dy: tolerance)
            return outer.contains(point) && !inner.contains(point)
        case .pen, .arrow:
            for (a, b) in zip(points, points.dropFirst()) {
                if Self.distance(point, to: a, b) <= tolerance { return true }
            }
            if tool == .arrow, let last = points.last {
                for wing in arrowWings where Self.distance(point, to: wing, last) <= tolerance { return true }
            }
            return points.count == 1 && hypot(point.x - points[0].x, point.y - points[0].y) <= tolerance
        }
    }
    private static func distance(_ point: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length))
        return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy)
    }
    private var arrowWings: [CGPoint] {
        guard let first = points.first, let last = points.last else { return [] }
        let angle = atan2(last.y - first.y, last.x - first.x), length = max(14, lineWidth * 4)
        return [-CGFloat.pi / 6, CGFloat.pi / 6].map {
            CGPoint(x: last.x - length * cos(angle + $0), y: last.y - length * sin(angle + $0))
        }
    }
    /// Used by both the interactive canvas and final export, in top-left image coordinates.
    public func draw(in context: CGContext, mosaics: ImageMosaics? = nil) {
        guard let first = points.first else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color); context.setFillColor(color)
        context.setLineWidth(lineWidth); context.setLineCap(.round); context.setLineJoin(.round)
        switch tool {
        case .crop: break
        case .rectangle: context.stroke(bounds)
        case .redact:
            if let mosaics { mosaics.draw(in: context, rect: bounds, size: mosaicSize) }
            else { context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(bounds.integral) }
        case .pen, .arrow:
            context.beginPath(); context.move(to: first)
            for point in points.dropFirst() { context.addLine(to: point) }
            if points.count == 1 { context.addLine(to: first) }
            context.strokePath()
            if tool == .arrow, let last = points.last, arrowWings.count == 2 {
                context.move(to: arrowWings[0]); context.addLine(to: last); context.addLine(to: arrowWings[1]); context.strokePath()
            }
        case .text:
            let line = textLine
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
            context.translateBy(x: first.x, y: first.y + ascent); context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity; context.textPosition = .zero
            CTLineDraw(line, context)
        }
    }
}
