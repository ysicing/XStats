// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// 拖动只改变草稿；取消会话不写偏好，落下时还要确认原顺序没有被其他入口修改。
struct PopoverSectionDrag {
  let section: PopoverSection
  let originalOrder: [PopoverSection]
  var previewOrder: [PopoverSection]

  init(section: PopoverSection, order: [PopoverSection]) {
    self.section = section
    originalOrder = order
    previewOrder = order
  }

  mutating func move(over target: PopoverSection) {
    guard section != target,
      let source = previewOrder.firstIndex(of: section),
      let destination = previewOrder.firstIndex(of: target)
    else { return }
    previewOrder.remove(at: source)
    previewOrder.insert(section, at: destination)
  }

  func offset(in currentOrder: [PopoverSection]) -> Int? {
    guard currentOrder == originalOrder,
      let source = originalOrder.firstIndex(of: section),
      let destination = previewOrder.firstIndex(of: section)
    else { return nil }
    return destination - source
  }
}

/// SwiftUI 没有旧版 macOS 通用的拖放结束回调；只把手柄交给 AppKit，确保 Esc 和列表外松手也清理草稿。
struct PopoverSectionDragHandle: NSViewRepresentable {
  // 源与 SwiftUI 目标共用系统声明的类型；未注册的自定义名称会在桥接时丢失。
  // 内容只是随机标记，目标仍要求自己的本地草稿，因此外部文本和跨指标拖入不会生效。
  static let pasteboardType = NSPasteboard.PasteboardType.string
  let title: String
  let animateCancellation: Bool
  let begin: () -> Void
  let end: () -> Void

  func makeNSView(context: Context) -> HandleView { HandleView() }

  func updateNSView(_ view: HandleView, context: Context) {
    view.title = title
    view.animateCancellation = animateCancellation
    view.begin = begin
    view.end = end
  }

  final class HandleView: NSView, NSDraggingSource {
    var title = ""
    var animateCancellation = true
    var begin: (() -> Void)?
    var end: (() -> Void)?
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
      NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))?
        .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))?
        .draw(in: NSRect(x: bounds.midX - 6, y: bounds.midY - 6, width: 12, height: 12))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }
    override func mouseUp(with event: NSEvent) { mouseDownEvent = nil }

    override func mouseDragged(with event: NSEvent) {
      guard let initial = mouseDownEvent,
        hypot(
          event.locationInWindow.x - initial.locationInWindow.x,
          event.locationInWindow.y - initial.locationInWindow.y) >= 4
      else { return }
      mouseDownEvent = nil
      let item = NSPasteboardItem()
      item.setString(UUID().uuidString, forType: PopoverSectionDragHandle.pasteboardType)
      let draggingItem = NSDraggingItem(pasteboardWriter: item)
      let text = NSAttributedString(
        string: title,
        attributes: [
          .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
        ])
      let size = NSSize(width: text.size().width + 24, height: 32)
      let preview = NSImage(size: size, flipped: false) { rect in
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        text.draw(at: NSPoint(x: 12, y: (rect.height - text.size().height) / 2))
        return true
      }
      let origin = convert(initial.locationInWindow, from: nil)
      draggingItem.setDraggingFrame(NSRect(origin: origin, size: size), contents: preview)
      begin?()
      let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
      session.animatesToStartingPositionsOnCancelOrFail = animateCancellation
    }

    func draggingSession(
      _ session: NSDraggingSession,
      sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
      context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(
      _ session: NSDraggingSession, endedAt screenPoint: NSPoint,
      operation: NSDragOperation
    ) {
      end?()
    }
  }
}

struct PopoverSectionDropDelegate: DropDelegate {
  let section: PopoverSection
  @Binding var drag: PopoverSectionDrag?
  let commit: (PopoverSectionDrag) -> Bool

  func validateDrop(info: DropInfo) -> Bool { drag?.originalOrder.contains(section) == true }

  func dropEntered(info: DropInfo) { drag?.move(over: section) }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: validateDrop(info: info) ? .move : .cancel)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard let draft = drag else { return false }
    let accepted = commit(draft)
    drag = nil
    return accepted
  }
}
