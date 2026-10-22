// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import CaptureCore
import Localization

struct ImageCanvas: NSViewRepresentable {
  let model: ImageEditorModel
  func makeNSView(context: Context) -> ImageCanvasView { ImageCanvasView(model: model) }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: ImageCanvasView, context: Context)
    -> CGSize?
  {
    // The canvas fills its proposal; its current AppKit frame is not an intrinsic size.
    CGSize(
      width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0,
      height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0)
  }
  func updateNSView(_ view: ImageCanvasView, context: Context) {
    // Register the model dependencies read by AppKit drawing and the inline field.
    _ = model.mosaics
    _ = model.document
    _ = model.selectedID
    _ = model.color
    _ = model.fontSize
    view.synchronize()
  }
}

@MainActor final class ImageCanvasView: NSView, NSTextFieldDelegate {
  let model: ImageEditorModel
  private let originalImage: NSImage
  private enum Gesture {
    case draw(ImageAnnotation)
    case move(original: ImageAnnotation, anchor: CGPoint, preview: ImageAnnotation)
    case resize(original: ImageAnnotation, handle: Int, preview: ImageAnnotation)
    var preview: ImageAnnotation {
      switch self {
      case .draw(let item), .move(_, _, let item), .resize(_, _, let item): item
      }
    }
  }
  private var gesture: Gesture?
  private var textField: NSTextField?
  private var editingText: ImageAnnotation?
  private var lastTool: ImageTool?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  init(model: ImageEditorModel) {
    self.model = model
    originalImage = NSImage(
      cgImage: model.document.original,
      size: CGSize(width: model.document.original.width, height: model.document.original.height))
    super.init(frame: .zero)
    model.finishEditing = { [weak self] in self?.finishText() }
    setAccessibilityLabel(tr("标注画布"))
  }
  required init?(coder: NSCoder) { fatalError() }
  var imageRect: CGRect {
    let crop = model.document.cropRect
    let scale = max(
      0.001, min((bounds.width - 32) / crop.width, (bounds.height - 32) / crop.height))
    let size = CGSize(width: crop.width * scale, height: crop.height * scale)
    return CGRect(
      x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
      height: size.height)
  }
  private var imageScale: CGFloat { imageRect.width / model.document.cropRect.width }
  func synchronize() {
    if lastTool != model.tool {
      finishText()
      gesture = nil
      lastTool = model.tool
    }
    if model.terminating {
      cancelText()
      gesture = nil
    }
    if let field = textField {
      field.font = .systemFont(ofSize: max(8, model.fontSize * imageScale))
      field.textColor = model.color
      field.setFrameSize(
        CGSize(width: field.frame.width, height: max(26, model.fontSize * imageScale + 10)))
    }
    window?.invalidateCursorRects(for: self)
    needsDisplay = true
  }
  override func resetCursorRects() {
    addCursorRect(
      imageRect, cursor: model.tool == nil ? .arrow : (model.tool == .text ? .iBeam : .crosshair))
  }
  private func imagePoint(_ event: NSEvent) -> CGPoint {
    let point = convert(event.locationInWindow, from: nil)
    let rect = imageRect
    let crop = model.document.cropRect
    return CGPoint(
      x: crop.minX + min(max(0, (point.x - rect.minX) / rect.width), 1) * crop.width,
      y: crop.minY + min(max(0, (point.y - rect.minY) / rect.height), 1) * crop.height)
  }
  private func viewPoint(_ point: CGPoint) -> CGPoint {
    let crop = model.document.cropRect
    let rect = imageRect
    return CGPoint(
      x: rect.minX + (point.x - crop.minX) * imageScale,
      y: rect.minY + (point.y - crop.minY) * imageScale)
  }
  private func handles(_ item: ImageAnnotation) -> [CGPoint] {
    if item.tool == .text { return [] }
    if item.tool == .arrow { return [item.points.first, item.points.last].compactMap { $0 } }
    let rect = item.bounds
    return [
      CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
    ]
  }
  override func mouseDown(with event: NSEvent) {
    finishText()
    guard !model.rendering, !model.detecting, !model.terminating else { return }
    let location = convert(event.locationInWindow, from: nil)
    guard imageRect.insetBy(dx: -8, dy: -8).contains(location) else {
      model.select(nil)
      needsDisplay = true
      return
    }
    window?.makeFirstResponder(self)
    let point = imagePoint(event)
    lastTool = model.tool
    if model.tool == nil {
      if let selected = model.selected,
        let handle = handles(selected).firstIndex(where: {
          let position = viewPoint($0)
          return hypot(location.x - position.x, location.y - position.y) <= 7
        })
      {
        gesture = .resize(original: selected, handle: handle, preview: selected)
      } else if let hit = model.document.annotation(at: point, tolerance: 6 / imageScale) {
        model.select(hit.id)
        if event.clickCount == 2, hit.tool == .text {
          beginText(hit)
        } else {
          gesture = .move(original: hit, anchor: point, preview: hit)
        }
      } else if let selected = model.selected, selected.bounds.contains(point) {
        gesture = .move(original: selected, anchor: point, preview: selected)
      } else {
        model.select(nil)
      }
    } else if model.tool == .text {
      if let hit = model.document.annotation(at: point, tolerance: 6 / imageScale),
        hit.tool == .text
      {
        model.select(hit.id)
        beginText(hit)
      } else {
        model.select(nil)
        beginText(model.annotation(tool: .text, points: [point]))
      }
    } else if let tool = model.tool, imageRect.contains(location) {
      model.select(nil)
      gesture = .draw(model.annotation(tool: tool, points: [point, point]))
    }
    needsDisplay = true
  }
  override func mouseDragged(with event: NSEvent) {
    guard !model.detecting, !model.terminating else { return }
    guard let gesture else { return }
    let point = imagePoint(event)
    switch gesture {
    case .draw(var item):
      if item.tool == .pen {
        if item.points.count < 4096 { item.points.append(point) }
      } else {
        item.points = [item.points[0], point]
      }
      self.gesture = .draw(item)
    case .move(let original, let anchor, _):
      var dx = point.x - anchor.x
      var dy = point.y - anchor.y
      let rect = original.bounds
      let crop = model.document.cropRect
      if rect.minX >= crop.minX, rect.maxX <= crop.maxX {
        dx = min(max(dx, crop.minX - rect.minX), crop.maxX - rect.maxX)
      }
      if rect.minY >= crop.minY, rect.maxY <= crop.maxY {
        dy = min(max(dy, crop.minY - rect.minY), crop.maxY - rect.maxY)
      }
      self.gesture = .move(
        original: original, anchor: anchor,
        preview: original.translated(by: CGSize(width: dx, height: dy)))
    case .resize(let original, let handle, _):
      var item = original
      if original.tool == .arrow {
        item.points[handle == 0 ? 0 : item.points.count - 1] = point
      } else {
        let anchor = handles(original)[(handle + 2) % 4]
        let rect = CGRect(
          x: min(anchor.x, point.x), y: min(anchor.y, point.y),
          width: max(1, abs(anchor.x - point.x)), height: max(1, abs(anchor.y - point.y)))
        item = original.resized(to: rect)
      }
      self.gesture = .resize(original: original, handle: handle, preview: item)
    }
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    guard let gesture else { return }
    mouseDragged(with: event)
    let result = self.gesture?.preview ?? gesture.preview
    self.gesture = nil
    if result.tool == .crop || result.tool == .rectangle || result.tool == .redact {
      guard result.bounds.width >= 2, result.bounds.height >= 2 else {
        needsDisplay = true
        return
      }
    }
    model.commit(result)
    needsDisplay = true
  }
  override func keyDown(with event: NSEvent) {
    guard !model.rendering, !model.detecting, !model.terminating else { return }
    if event.keyCode == 53 {
      gesture = nil
      cancelText()
      model.select(nil)
      needsDisplay = true
      return
    }
    if event.keyCode == 51 || event.keyCode == 117 {
      model.deleteSelected()
      needsDisplay = true
      return
    }
    if event.keyCode == 36, let item = model.selected, item.tool == .text {
      beginText(item)
      return
    }
    if !event.modifierFlags.contains(.command),
      let key = event.charactersIgnoringModifiers?.lowercased()
    {
      let tools: [String: ImageTool] = [
        "c": .crop, "a": .arrow, "r": .rectangle, "p": .pen, "t": .text, "x": .redact,
      ]
      if key == "v" || tools[key] != nil {
        model.select(nil)
        model.tool = tools[key]
        synchronize()
        return
      }
    }
    super.keyDown(with: event)
  }
  private func beginText(_ item: ImageAnnotation) {
    guard let point = item.points.first else { return }
    editingText = item
    model.editingText = true
    let origin = viewPoint(point)
    let field = NSTextField(
      frame: CGRect(
        x: origin.x, y: origin.y, width: max(100, min(360, imageRect.maxX - origin.x)),
        height: max(26, item.fontSize * imageScale + 10)))
    field.stringValue = item.text
    field.placeholderString = tr("标注文字")
    field.font = .systemFont(ofSize: max(8, item.fontSize * imageScale))
    field.textColor = NSColor(cgColor: item.color)
    field.isBezeled = true
    field.bezelStyle = .roundedBezel
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.delegate = self
    field.setAccessibilityLabel(tr("标注文字"))
    textField = field
    addSubview(field)
    window?.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
    needsDisplay = true
  }
  func finishText() {
    guard let field = textField, var item = editingText else { return }
    item.text = field.stringValue
    item.color = model.color.cgColor
    item.fontSize = model.fontSize
    textField = nil
    editingText = nil
    model.editingText = false
    field.delegate = nil
    field.removeFromSuperview()
    if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.commit(item) }
    needsDisplay = true
  }
  private func cancelText() {
    textField?.delegate = nil
    textField?.removeFromSuperview()
    textField = nil
    editingText = nil
    model.editingText = false
    window?.makeFirstResponder(self)
    needsDisplay = true
  }
  func controlTextDidEndEditing(_ notification: Notification) { finishText() }
  func controlTextDidChange(_ notification: Notification) { model.dirty = true }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      cancelText()
      return true
    }
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      finishText()
      window?.makeFirstResponder(self)
      return true
    }
    return false
  }
  override func draw(_ dirtyRect: NSRect) {
    let rect = imageRect
    let crop = model.document.cropRect
    let source = CGRect(
      x: crop.minX, y: CGFloat(model.document.original.height) - crop.maxY, width: crop.width,
      height: crop.height)
    originalImage.draw(
      in: rect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.clip(to: rect)
    context.translateBy(x: rect.minX, y: rect.minY)
    context.scaleBy(x: imageScale, y: imageScale)
    context.translateBy(x: -crop.minX, y: -crop.minY)
    let preview = gesture?.preview
    for item in model.document.annotations {
      if item.id == editingText?.id { continue }
      if let preview, preview.id == item.id {
        preview.draw(in: context, mosaics: model.mosaics)
      } else {
        item.draw(in: context, mosaics: model.mosaics)
      }
    }
    if let preview, case .draw = gesture, preview.tool != .crop {
      preview.draw(in: context, mosaics: model.mosaics)
    }
    context.restoreGState()
    if let preview, preview.tool == .crop {
      let first = viewPoint(CGPoint(x: preview.bounds.minX, y: preview.bounds.minY))
      let selection = CGRect(
        origin: first,
        size: CGSize(
          width: preview.bounds.width * imageScale, height: preview.bounds.height * imageScale))
      let shade = NSBezierPath(rect: rect)
      shade.append(NSBezierPath(rect: selection))
      shade.windingRule = .evenOdd
      NSColor.black.withAlphaComponent(0.4).setFill()
      shade.fill()
      NSColor.white.setStroke()
      NSBezierPath(rect: selection).stroke()
    } else if let selected = preview ?? model.selected, selected.tool != .crop, textField == nil {
      let box = selected.bounds
      let position = viewPoint(box.origin)
      let outline = NSBezierPath(
        rect: CGRect(
          origin: position,
          size: CGSize(
            width: max(1, box.width * imageScale), height: max(1, box.height * imageScale))
        ).insetBy(dx: -3, dy: -3))
      NSColor.controlAccentColor.setStroke()
      outline.lineWidth = 1
      outline.setLineDash([4, 3], count: 2, phase: 0)
      outline.stroke()
      for point in handles(selected) {
        let position = viewPoint(point)
        let dot = NSBezierPath(
          ovalIn: CGRect(x: position.x - 4, y: position.y - 4, width: 8, height: 8))
        NSColor.white.setFill()
        dot.fill()
        NSColor.controlAccentColor.setStroke()
        dot.stroke()
      }
    }
  }
}
