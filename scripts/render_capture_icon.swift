#!/usr/bin/env swift
// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

// Run from the repository root: swift scripts/render_capture_icon.swift
// Capture shares the canonical XStats wave and adds its own capture frame.
let output = URL(
  fileURLWithPath: "Apps/Capture/App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let branding = URL(fileURLWithPath: "Assets/branding/capture", isDirectory: true)
let waveURL = URL(fileURLWithPath: "Assets/branding/xstats-logo-2048.png")
guard let wave = NSImage(contentsOf: waveURL) else {
  fatalError("缺少 XStats 主标识，请先运行 bash scripts/render_xstats_icon.sh")
}
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: branding, withIntermediateDirectories: true)

func drawCaptureIcon() {
  let blue = NSGradient(
    starting: NSColor(srgbRed: 0, green: 0.31, blue: 1, alpha: 1),
    ending: NSColor(srgbRed: 0, green: 0.81, blue: 0.89, alpha: 1))!
  let corners = CGMutablePath()
  // Each corner is a single rounded path, with open space between brackets.
  for (x, y, dx, dy) in [
    (CGFloat(192), CGFloat(800), CGFloat(1), CGFloat(-1)),
    (832, 800, -1, -1), (192, 224, 1, 1), (832, 224, -1, 1),
  ] {
    corners.move(to: CGPoint(x: x, y: y + dy * 112))
    corners.addLine(to: CGPoint(x: x, y: y + dy * 32))
    corners.addCurve(
      to: CGPoint(x: x + dx * 32, y: y),
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
  blue.draw(in: NSRect(x: 168, y: 200, width: 688, height: 624), angle: 0)
  NSGraphicsContext.restoreGraphicsState()

  let screen = NSBezierPath(
    roundedRect: NSRect(x: 272, y: 344, width: 480, height: 336), xRadius: 28, yRadius: 28)
  screen.append(
    NSBezierPath(
      roundedRect: NSRect(x: 298, y: 370, width: 428, height: 284),
      xRadius: 8, yRadius: 8))
  screen.windingRule = .evenOdd
  blue.draw(in: screen, angle: 0)
  wave.draw(in: NSRect(x: 296, y: 296, width: 432, height: 432))
}

for pixels in [16, 32, 64, 128, 256, 512, 1024, 2048] {
  // Supersampling keeps the frame and wave smooth at menu/Finder sizes.
  let renderSize = max(1024, pixels)
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: renderSize, pixelsHigh: renderSize,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
  NSGraphicsContext.current!.cgContext.scaleBy(
    x: CGFloat(renderSize) / 1024, y: CGFloat(renderSize) / 1024)
  drawCaptureIcon()
  NSGraphicsContext.restoreGraphicsState()

  let resized = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
  NSGraphicsContext.current!.imageInterpolation = .high
  NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: renderSize, height: renderSize))
    .draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
  NSGraphicsContext.restoreGraphicsState()
  let filename = pixels == 1024 ? "xstats-capture-logo.png" : "xstats-capture-logo-\(pixels).png"
  try resized.representation(using: .png, properties: [:])!.write(
    to: branding.appendingPathComponent(filename))
}

let dockRenderer = Process()
dockRenderer.executableURL = URL(fileURLWithPath: "/bin/bash")
dockRenderer.arguments = [
  "scripts/render_dock_icon.sh",
  branding.appendingPathComponent("xstats-capture-logo-2048.png").path, output.path,
]
try dockRenderer.run()
dockRenderer.waitUntilExit()
guard dockRenderer.terminationStatus == 0 else { fatalError("生成 Capture 应用图标失败") }
