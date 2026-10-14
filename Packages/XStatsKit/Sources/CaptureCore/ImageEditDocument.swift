// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import ImageIO
import UniformTypeIdentifiers

public enum ImageTool: String, CaseIterable, Identifiable, Sendable {
    case crop, arrow, rectangle, pen, text, redact
    public var id: String { rawValue }
}

public struct ImageAnnotation: Sendable {
    public var tool: ImageTool
    /// Original-image pixel coordinates, top-left origin.
    public var points: [CGPoint]
    public var text: String
    public var color: CGColor
    public var lineWidth: CGFloat
    public init(tool: ImageTool, points: [CGPoint], text: String = "", color: CGColor = CGColor(red: 1, green: 0.2, blue: 0.15, alpha: 1), lineWidth: CGFloat = 4) {
        self.tool = tool; self.points = points; self.text = text; self.color = color; self.lineWidth = lineWidth
    }
}

public struct ImageEditDocument: Sendable {
    public let original: CGImage
    public private(set) var annotations: [ImageAnnotation] = []
    public private(set) var cropRect: CGRect
    private struct Revision: Sendable { var count: Int; var crop: CGRect }
    private var history: [Revision] = []
    private var future: [(Revision, [ImageAnnotation])] = []
    public init(image: CGImage) {
        original = image
        cropRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    }
    public var canUndo: Bool { !history.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    private mutating func checkpoint() {
        history.append(Revision(count: annotations.count, crop: cropRect))
        if history.count > 100 { history.removeFirst() }
        future.removeAll()
    }
    public mutating func add(_ annotation: ImageAnnotation) {
        guard !annotation.points.isEmpty, annotations.count < 1000 else { return }
        checkpoint(); annotations.append(annotation)
    }
    public mutating func crop(to rect: CGRect) throws {
        let rect = rect.standardized.intersection(cropRect).integral
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { throw CaptureError.invalidRegion }
        checkpoint(); cropRect = rect
    }
    public mutating func undo() {
        guard let previous = history.popLast() else { return }
        future.append((Revision(count: annotations.count, crop: cropRect), Array(annotations.dropFirst(previous.count))))
        annotations = Array(annotations.prefix(previous.count)); cropRect = previous.crop
    }
    public mutating func redo() {
        guard let (revision, additions) = future.popLast() else { return }
        history.append(Revision(count: annotations.count, crop: cropRect))
        annotations.append(contentsOf: additions); cropRect = revision.crop
    }
    public func render() throws -> CGImage {
        try Task.checkCancellation()
        guard let context = CGContext(data: nil, width: Int(cropRect.width), height: Int(cropRect.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureError.captureFailed }
        context.translateBy(x: -cropRect.minX, y: cropRect.height + cropRect.minY)
        context.scaleBy(x: 1, y: -1)
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(original.height)); context.scaleBy(x: 1, y: -1)
        context.draw(original, in: CGRect(x: 0, y: 0, width: original.width, height: original.height))
        context.restoreGState()
        for item in annotations { try Task.checkCancellation(); Self.draw(item, in: context) }
        try Task.checkCancellation()
        guard let result = context.makeImage() else { throw CaptureError.captureFailed }
        return result
    }
    private static func draw(_ item: ImageAnnotation, in context: CGContext) {
        guard let first = item.points.first else { return }
        let last = item.points.last ?? first
        let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
        context.setStrokeColor(item.color); context.setFillColor(item.color)
        context.setLineWidth(item.lineWidth); context.setLineCap(.round); context.setLineJoin(.round)
        switch item.tool {
        case .crop: break
        case .rectangle: context.stroke(rect)
        case .redact:
            context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(rect.integral)
        case .pen, .arrow:
            context.beginPath(); context.move(to: first)
            for point in item.points.dropFirst() { context.addLine(to: point) }
            context.strokePath()
            if item.tool == .arrow {
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = max(14, item.lineWidth * 4)
                context.move(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                context.addLine(to: last)
                context.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
                context.strokePath()
            }
        case .text:
            context.saveGState()
            context.translateBy(x: first.x, y: first.y + 26); context.scaleBy(x: 1, y: -1)
            let attributed = NSAttributedString(string: item.text, attributes: [.font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor(cgColor: item.color) ?? .systemRed])
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = .zero; CTLineDraw(line, context)
            context.restoreGState()
        }
    }
    public func encoded(jpeg: Bool = false) throws -> Data {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { throw CaptureError.exportFailed }
        CGImageDestinationAddImage(destination, try render(), jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil)
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.exportFailed }
        try Task.checkCancellation()
        return data as Data
    }
    /// 只向相邻临时文件分块写入，取消后不提交到用户选择的位置。
    public func save(to url: URL, jpeg: Bool = false) throws {
        let bytes = try encoded(jpeg: jpeg)
        try Task.checkCancellation()
        let staging = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).capture-image")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: nil) else { throw CaptureError.exportFailed }
        let handle = try FileHandle(forWritingTo: staging)
        defer { try? handle.close() }
        for offset in stride(from: 0, to: bytes.count, by: 512 * 1024) {
            try Task.checkCancellation()
            try handle.write(contentsOf: bytes[offset..<min(offset + 512 * 1024, bytes.count)])
        }
        try handle.close()
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: url) }
    }
}
