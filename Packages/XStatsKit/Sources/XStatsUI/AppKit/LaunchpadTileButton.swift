// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit

@MainActor
final class LaunchpadTileButton: NSButton, NSDraggingSource {
  static let pasteboardType = NSPasteboard.PasteboardType("com.xstats.launchpad.item")
  var itemID = ""
  var dragToken = ""
  var canDrag = true
  var onHold: () -> Void = {}
  var onDrop: (String, Bool) -> Void = { _, _ in }
  private var holdTask: Task<Void, Never>?
  private var pressedAt: NSPoint?
  private var didHold = false
  private var enteredAt: TimeInterval = 0

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([Self.pasteboardType])
  }
  required init?(coder: NSCoder) { nil }

  override func mouseDown(with event: NSEvent) {
    pressedAt = event.locationInWindow
    didHold = false
    holdTask?.cancel()
    holdTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
      guard let self, self.window?.isVisible == true else { return }
      self.didHold = true
      self.onHold()
    }
  }

  override func mouseUp(with event: NSEvent) {
    holdTask?.cancel()
    holdTask = nil
    defer { pressedAt = nil }
    guard pressedAt != nil, !didHold, bounds.contains(convert(event.locationInWindow, from: nil))
    else {
      return
    }
    _ = sendAction(action, to: target)
  }

  override func mouseDragged(with event: NSEvent) {
    guard canDrag, let start = pressedAt,
      hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 6
    else { return }
    holdTask?.cancel()
    holdTask = nil
    pressedAt = nil
    let payload = NSPasteboardItem()
    payload.setString(itemID, forType: Self.pasteboardType)
    payload.setString(dragToken, forType: .string)
    let item = NSDraggingItem(pasteboardWriter: payload)
    item.setDraggingFrame(bounds, contents: image)
    beginDraggingSession(with: [item], event: event, source: self)
  }

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  )
    -> NSDragOperation
  { context == .withinApplication ? .move : [] }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    enteredAt = ProcessInfo.processInfo.systemUptime
    return draggingUpdated(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard canDrag, sender.draggingPasteboard.string(forType: .string) == dragToken,
      sender.draggingPasteboard.string(forType: Self.pasteboardType) != itemID
    else { return [] }
    layer?.borderWidth = 2
    layer?.borderColor = (groups(sender) ? NSColor.systemGreen : NSColor.controlAccentColor).cgColor
    return .move
  }

  override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard draggingUpdated(sender) == .move,
      let id = sender.draggingPasteboard.string(forType: Self.pasteboardType)
    else { return false }
    onDrop(id, groups(sender))
    return true
  }

  private func groups(_ sender: NSDraggingInfo) -> Bool {
    bounds.insetBy(dx: 24, dy: 20).contains(convert(sender.draggingLocation, from: nil))
      && ProcessInfo.processInfo.systemUptime - enteredAt >= 0.5
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      holdTask?.cancel()
      holdTask = nil
      pressedAt = nil
      layer?.removeAllAnimations()
    }
    super.viewWillMove(toWindow: newWindow)
  }
}

@MainActor
final class LaunchpadDropView: NSView {
  var dragToken = ""
  var onDrop: (String) -> Void = { _ in }
  var onHover: () -> Bool = { false }
  private(set) var didNavigate = false
  private var hoverTask: Task<Void, Never>?
  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([LaunchpadTileButton.pasteboardType])
  }
  required init?(coder: NSCoder) { nil }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard sender.draggingPasteboard.string(forType: .string) == dragToken else { return [] }
    didNavigate = false
    hoverTask?.cancel()
    hoverTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
      guard let self, self.window != nil else { return }
      self.didNavigate = self.onHover()
    }
    return .move
  }
  override func draggingExited(_ sender: NSDraggingInfo?) {
    hoverTask?.cancel()
    hoverTask = nil
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    hoverTask?.cancel()
    hoverTask = nil
    guard sender.draggingPasteboard.string(forType: .string) == dragToken,
      let id = sender.draggingPasteboard.string(forType: LaunchpadTileButton.pasteboardType)
    else { return false }
    onDrop(id)
    return true
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      hoverTask?.cancel()
      hoverTask = nil
    }
    super.viewWillMove(toWindow: newWindow)
  }
}
