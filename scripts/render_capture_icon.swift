#!/usr/bin/env swift
// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

// Run from the repository root: swift scripts/render_capture_icon.swift
// Draw the original Capture mark from paths; no fonts or external artwork.
let output = URL(fileURLWithPath: "Apps/Capture/App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawCaptureIcon() {
    let plate = NSBezierPath(roundedRect: NSRect(x: 104, y: 104, width: 816, height: 816), xRadius: 202, yRadius: 202)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    NSColor.white.setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: .white, ending: NSColor(srgbRed: 0.92, green: 0.94, blue: 0.96, alpha: 1))!
        .draw(in: plate, angle: -90)
    NSColor.white.withAlphaComponent(0.9).setStroke()
    plate.lineWidth = 4
    plate.stroke()

    let blue = NSGradient(starting: NSColor(srgbRed: 0, green: 0.31, blue: 1, alpha: 1),
                          ending: NSColor(srgbRed: 0, green: 0.61, blue: 1, alpha: 1))!
    let corners = CGMutablePath()
    // Each corner is a single rounded path, with open space between brackets.
    for (x, y, dx, dy) in [(CGFloat(258), CGFloat(736), CGFloat(1), CGFloat(-1)),
                            (766, 736, -1, -1), (258, 288, 1, 1), (766, 288, -1, 1)] {
        corners.move(to: CGPoint(x: x, y: y + dy * 112))
        corners.addLine(to: CGPoint(x: x, y: y + dy * 32))
        corners.addCurve(to: CGPoint(x: x + dx * 32, y: y),
                         control1: CGPoint(x: x, y: y + dy * 10),
                         control2: CGPoint(x: x + dx * 10, y: y))
        corners.addLine(to: CGPoint(x: x + dx * 112, y: y))
    }
    // Clip the gradient to the stroked path so all four corners share one light direction.
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext.current!.cgContext
    context.addPath(corners)
    context.setLineWidth(48)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    blue.draw(in: NSRect(x: 224, y: 256, width: 576, height: 512), angle: 0)
    NSGraphicsContext.restoreGraphicsState()

    let screen = NSBezierPath(roundedRect: NSRect(x: 342, y: 382, width: 340, height: 260), xRadius: 28, yRadius: 28)
    blue.draw(in: screen, angle: 0)
    let glass = NSBezierPath(roundedRect: NSRect(x: 370, y: 410, width: 284, height: 204), xRadius: 8, yRadius: 8)
    NSGradient(starting: NSColor(srgbRed: 0.90, green: 0.96, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0.72, green: 0.87, blue: 1, alpha: 1))!
        .draw(in: glass, angle: -70)
}

var entries: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        // Supersampling keeps both the plate and mark smooth at menu/Finder sizes.
        let renderSize = max(1024, pixels)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: renderSize, pixelsHigh: renderSize,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(renderSize) / 1024, y: CGFloat(renderSize) / 1024)
        drawCaptureIcon()
        NSGraphicsContext.restoreGraphicsState()

        let resized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        NSGraphicsContext.current!.imageInterpolation = .high
        NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: renderSize, height: renderSize))
            .draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try resized.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(filename))
        entries.append(["filename": filename, "idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x"])
    }
}
let catalog: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
