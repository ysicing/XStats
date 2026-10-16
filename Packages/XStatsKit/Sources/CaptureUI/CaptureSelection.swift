// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import ScreenCaptureKit
import CaptureCore
import Localization

@MainActor final class CaptureSelection {
  private var panels: [NSPanel] = []
  private var continuation: CheckedContinuation<ScreenCaptureSource?, any Error>?
  private var eventMonitor: Any?
  private var screenObserver: NSObjectProtocol?
  private weak var activeView: SelectionView?
  func select(
    mode: CaptureMode, action: CaptureRequest.Action, content: SCShareableContent,
    exclusion: CaptureWindowExclusion = .init(excludesApplication: true, windowIDs: [])
  ) async throws -> ScreenCaptureSource? {
    try Task.checkCancellation()
    let excluded = content.applications.filter {
      $0.processID == ProcessInfo.processInfo.processIdentifier
    }
    guard !exclusion.excludesApplication || !excluded.isEmpty else {
      throw CaptureError.captureFailed
    }
    let windowsByID = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
    let orderedIDs =
      (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? [])
      .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    let windows = orderedIDs.compactMap { windowsByID[$0] }.filter {
      $0.windowLayer == 0
        && !exclusion.excludes(
          windowID: $0.windowID, processID: $0.owningApplication?.processID,
          currentProcessID: ProcessInfo.processInfo.processIdentifier)
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        for screen in NSScreen.screens {
          guard
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
            let display = content.displays.first(where: { $0.displayID == id })
          else { continue }
          let panel = SelectionPanel(
            contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
          panel.isReleasedWhenClosed = false
          panel.acceptsMouseMovedEvents = true
          panel.level = .screenSaver
          panel.isOpaque = false
          panel.backgroundColor = .clear
          panel.hidesOnDeactivate = false
          panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
          let view = SelectionView(
            frame: CGRect(origin: .zero, size: screen.frame.size), mode: mode, action: action,
            screenFrame: screen.frame, scale: screen.backingScaleFactor, windows: windows)
          view.onActivate = { [weak self] view in self?.activate(view) }
          view.onReset = { [weak self] in self?.resetSelection() }
          view.onCancel = { [weak self] in self?.finish(nil) }
          view.onSelection = { [weak self] region, window in
            guard let self else { return }
            if let window {
              self.finish(ScreenCaptureSource(window: window, displayID: id))
            } else if let region {
              do {
                let converted = try CaptureGeometry.region(
                  region, in: screen.frame, scale: screen.backingScaleFactor)
                self.finish(
                  ScreenCaptureSource(
                    display: display, excludedApps: exclusion.excludesApplication ? excluded : [],
                    excludedWindows: content.windows.filter {
                      exclusion.windowIDs.contains($0.windowID)
                    }, region: converted))
              } catch { self.finish(nil) }
            } else {
              self.finish(
                ScreenCaptureSource(
                  display: display, excludedApps: exclusion.excludesApplication ? excluded : [],
                  excludedWindows: content.windows.filter {
                    exclusion.windowIDs.contains($0.windowID)
                  }))
            }
          }
          panel.contentView = view
          panel.makeFirstResponder(view)
          panel.orderFrontRegardless()
          self.panels.append(panel)
        }
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
          [weak self] event in
          if event.keyCode == 53 {
            self?.finish(nil)
            return nil
          }
          if event.keyCode == 36 || event.keyCode == 76 {
            self?.activeView?.confirmSelection()
            return nil
          }
          return event
        }
        self.screenObserver = NotificationCenter.default.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification,
          object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.finish(nil) }
        }
        NSApp.activate(ignoringOtherApps: true)
        self.panels.first?.makeKey()
        if self.panels.isEmpty { self.finish(nil) }
      }
    } onCancel: {
      Task { @MainActor in self.finish(nil) }
    }
  }
  private func activate(_ view: SelectionView) {
    for panel in panels {
      guard let other = panel.contentView as? SelectionView, other !== view else { continue }
      other.resetSelection()
    }
    activeView = view
  }
  private func resetSelection() {
    for panel in panels { (panel.contentView as? SelectionView)?.resetSelection() }
    activeView = nil
  }
  func cancel() { finish(nil) }
  private func finish(_ source: ScreenCaptureSource?) {
    if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    eventMonitor = nil
    if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    screenObserver = nil
    activeView = nil
    for panel in panels {
      (panel.contentView as? SelectionView)?.resetSelection()
      panel.orderOut(nil)
      panel.close()
    }
    panels.removeAll()
    let continuation = self.continuation
    self.continuation = nil
    continuation?.resume(returning: source)
  }
}

@MainActor private final class SelectionPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// 原生选区视图：鼠标操作只修改草稿，按钮或 Return 才提交捕获请求。
@MainActor final class SelectionView: NSView {
  let mode: CaptureMode
  let action: CaptureRequest.Action
  let screenFrame: CGRect
  let scale: CGFloat
  let windows: [SCWindow]
  let language: AppLanguage
  var onSelection: (CGRect?, SCWindow?) -> Void = { _, _ in }
  var onActivate: (SelectionView) -> Void = { _ in }
  var onReset: () -> Void = {}
  var onCancel: () -> Void = {}
  private var region = RegionSelection()
  private var hovered: SCWindow?
  private var selectedWindow: SCWindow?
  private var selectedDisplay = false
  private var completed = false
  private let toolbar = NSVisualEffectView()
  private let controls = NSStackView()
  private let dimensions = NSTextField(labelWithString: "")
  private let confirm = NSButton()
  private let windowPreview = SelectionWindowPreview()
  private let targetName = NSTextField(labelWithString: "")
  var isReady: Bool {
    guard !completed else { return false }
    return switch mode {
    case .region: region.isReady
    case .window: selectedWindow != nil && windowPreview.image != nil
    case .display: selectedDisplay
    }
  }
  override var acceptsFirstResponder: Bool { true }

  init(
    frame: CGRect, mode: CaptureMode, action: CaptureRequest.Action, screenFrame: CGRect,
    scale: CGFloat, windows: [SCWindow], language: AppLanguage = L10n.language
  ) {
    self.mode = mode
    self.action = action
    self.screenFrame = screenFrame
    self.scale = scale
    self.windows = windows
    self.language = language.resolved
    super.init(frame: frame)
    toolbar.material = .popover
    toolbar.blendingMode = .withinWindow
    toolbar.state = .active
    toolbar.wantsLayer = true
    toolbar.layer?.cornerRadius = 14
    toolbar.layer?.masksToBounds = true
    toolbar.isHidden = true
    addSubview(toolbar)
    controls.orientation = .horizontal
    controls.spacing = 12
    controls.alignment = .centerY
    controls.userInterfaceLayoutDirection = language == .arabic ? .rightToLeft : .leftToRight
    controls.translatesAutoresizingMaskIntoConstraints = false
    toolbar.addSubview(controls)
    NSLayoutConstraint.activate([
      controls.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
      controls.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
      controls.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
    ])
    dimensions.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    dimensions.textColor = .secondaryLabelColor
    // 宽 × 高是数学表达式；RTL 界面也保持这一顺序，避免尺寸被读反。
    dimensions.cell?.baseWritingDirection = .leftToRight
    dimensions.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    dimensions.lineBreakMode = .byTruncatingTail
    controls.addArrangedSubview(dimensions)
    if mode == .window {
      targetName.font = .systemFont(ofSize: 12, weight: .medium)
      targetName.lineBreakMode = .byTruncatingMiddle
      targetName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      targetName.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
      controls.addArrangedSubview(targetName)
    }
    windowPreview.onChange = { [weak self] in self?.updatePresentation() }
    confirm.title = action == .record ? localized("开始录屏") : localized("截图")
    confirm.bezelStyle = .rounded
    confirm.controlSize = .large
    confirm.target = self
    confirm.action = #selector(confirmSelection)
    confirm.keyEquivalent = "\r"
    confirm.setAccessibilityLabel(confirm.title)
    controls.addArrangedSubview(confirm)
    let reset = NSButton(
      image: NSImage(
        systemSymbolName: "arrow.counterclockwise", accessibilityDescription: localized("重新选择"))!,
      target: self, action: #selector(reselect))
    reset.bezelStyle = .rounded
    reset.toolTip = localized("重新选择")
    reset.setAccessibilityLabel(localized("重新选择"))
    controls.addArrangedSubview(reset)
    let cancel = NSButton(
      image: NSImage(systemSymbolName: "xmark", accessibilityDescription: localized("取消"))!,
      target: self, action: #selector(cancelSelection))
    cancel.bezelStyle = .rounded
    cancel.toolTip = localized("取消")
    cancel.setAccessibilityLabel(localized("取消"))
    controls.addArrangedSubview(cancel)
  }
  private func localized(_ text: String) -> String { L10n.translate(text, language: language) }
  required init?(coder: NSCoder) { fatalError() }
  override func updateTrackingAreas() {
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    super.updateTrackingAreas()
  }
  private func quartzPoint(_ event: NSEvent) -> CGPoint {
    let global = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    let height = NSScreen.screens.first?.frame.height ?? 0
    return CGPoint(x: global.x, y: height - global.y)
  }
  override func mouseMoved(with event: NSEvent) {
    if mode == .window, selectedWindow == nil {
      let point = quartzPoint(event)
      let candidate = windows.first { $0.frame.contains(point) }
      if candidate?.windowID != hovered?.windowID {
        hovered = candidate
        needsDisplay = true
      }
    }
    guard mode == .region else {
      NSCursor.arrow.set()
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    if !toolbar.isHidden, toolbar.frame.contains(point) {
      NSCursor.arrow.set()
      return
    }
    if let handle = region.handle(at: point) {
      switch handle {
      case .left, .right: NSCursor.resizeLeftRight.set()
      case .top, .bottom: NSCursor.resizeUpDown.set()
      default: NSCursor.crosshair.set()
      }
    } else if region.rect?.contains(point) == true {
      NSCursor.openHand.set()
    } else {
      NSCursor.crosshair.set()
    }
  }
  override func mouseDown(with event: NSEvent) {
    guard !completed else { return }
    window?.makeKey()
    window?.makeFirstResponder(self)
    switch mode {
    case .display:
      selectedDisplay = true
    case .window:
      guard selectedWindow == nil else { return }
      let point = quartzPoint(event)
      guard let candidate = windows.first(where: { $0.frame.contains(point) }) else { return }
      selectedWindow = candidate
      hovered = nil
    case .region:
      region.begin(at: convert(event.locationInWindow, from: nil), in: bounds)
    }
    onActivate(self)
    updatePresentation()
    if let selectedWindow {
      let source = ScreenCaptureSource(window: selectedWindow, displayID: 0)
      windowPreview.load {
        // The preview has a bounded pixel budget and no live stream.
        try await source.screenshot(maximumDimension: 1600)
      }
    }
  }
  override func mouseDragged(with event: NSEvent) {
    guard mode == .region, !completed else { return }
    region.update(to: convert(event.locationInWindow, from: nil), in: bounds)
    updatePresentation()
  }
  override func mouseUp(with event: NSEvent) {
    guard mode == .region, region.isDragging, !completed else { return }
    region.end(at: convert(event.locationInWindow, from: nil), in: bounds)
    updatePresentation()
  }
  @objc func confirmSelection() {
    guard isReady else { return }
    completed = true
    windowPreview.reset()
    if mode == .window {
      onSelection(nil, selectedWindow)
    } else if mode == .region, let rect = region.rect {
      onSelection(rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY), nil)
    } else {
      onSelection(nil, nil)
    }
  }
  @objc private func reselect() { onReset() }
  @objc private func cancelSelection() { onCancel() }
  func resetSelection() {
    windowPreview.reset()
    region.reset()
    selectedWindow = nil
    hovered = nil
    selectedDisplay = false
    updatePresentation()
  }
  private var highlight: CGRect? {
    if mode == .region { return region.rect }
    if mode == .display { return selectedDisplay ? bounds : nil }
    guard let window = selectedWindow ?? hovered else { return nil }
    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
    let target = CaptureGeometry.appKitFrame(window.frame, primaryHeight: primaryHeight)
      .offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    return selectedWindow != nil
      ? SelectionWindowPreview.fittedFrame(target: target, in: bounds) : target
  }
  private func updatePresentation() {
    needsDisplay = true
    let hasDraft = mode == .window ? selectedWindow != nil && !completed : isReady
    toolbar.isHidden = !hasDraft
    confirm.isEnabled = isReady
    guard hasDraft, let highlight else { return }
    let pixelSize =
      selectedWindow.map { window in
        let source = ScreenCaptureSource(window: window, displayID: 0)
        return source.pixelSize
      } ?? CGSize(width: highlight.width * scale, height: highlight.height * scale)
    targetName.stringValue =
      selectedWindow?.title.flatMap { $0.isEmpty ? nil : $0 } ?? selectedWindow?.owningApplication?
      .applicationName ?? ""
    targetName.toolTip = targetName.stringValue
    let width = Int(pixelSize.width.rounded()).formatted(.number.locale(L10n.locale(for: language)))
    let height = Int(pixelSize.height.rounded()).formatted(
      .number.locale(L10n.locale(for: language)))
    dimensions.stringValue = localized("\(width) × \(height) 像素")
    let size = CGSize(width: min(bounds.width - 32, controls.fittingSize.width + 28), height: 58)
    // 优先放在选框外；贴近屏幕边缘时移到框内，始终留在当前显示器上。
    let y: CGFloat
    if highlight.minY - size.height - 12 >= bounds.minY + 16 {
      y = highlight.minY - size.height - 12
    } else if highlight.maxY + size.height + 12 <= bounds.maxY - 16 {
      y = highlight.maxY + 12
    } else {
      y = max(bounds.minY + 16, min(highlight.minY + 12, bounds.maxY - size.height - 16))
    }
    toolbar.frame = CGRect(
      x: max(bounds.minX + 16, min(highlight.midX - size.width / 2, bounds.maxX - size.width - 16)),
      y: y, width: size.width, height: size.height)
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.28).setFill()
    bounds.fill()
    if let highlight {
      // Fully transparent pixels let WindowServer send clicks to the window
      // below us. Keep the highlight visually clear while retaining its hit area.
      NSColor.black.withAlphaComponent(0.01).setFill()
      highlight.fill(using: .copy)
      if let image = windowPreview.image {
        NSImage(cgImage: image, size: highlight.size).draw(in: highlight)
      }
      let border = NSBezierPath(rect: highlight.insetBy(dx: 0.5, dy: 0.5))
      border.lineWidth = 2
      NSColor.white.setStroke()
      border.stroke()
      if mode == .region, region.isReady {
        for handle in RegionSelection.Handle.allCases {
          let point = handle.point(in: highlight)
          let shape = NSBezierPath(
            roundedRect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 2,
            yRadius: 2)
          NSColor.white.setFill()
          shape.fill()
          NSColor.black.withAlphaComponent(0.6).setStroke()
          shape.stroke()
        }
      }
    }
    let text: String
    if mode == .window, windowPreview.loading {
      text = localized("正在预览窗口…")
    } else if mode == .window, let error = windowPreview.error {
      text = error == .screenPermission ? error.localizedDescription : localized("窗口预览未完成，请重新选择。")
    } else if isReady || region.isAdjusting {
      text = mode == .region ? localized("拖动选框移动，拖动边缘调整，按回车确认") : localized("已选择范围，按回车确认，Esc 取消")
    } else {
      text =
        switch mode {
        case .region: localized("拖动选择区域，按 Esc 取消")
        case .window: localized("点击窗口，按 Esc 取消")
        case .display: localized("点击要捕获的屏幕，按 Esc 取消")
        }
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.baseWritingDirection = language == .arabic ? .rightToLeft : .leftToRight
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 4
    shadow.shadowColor = NSColor.black
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 16, weight: .medium),
      .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
      .shadow: shadow,
    ]
    text.draw(
      in: CGRect(x: 24, y: bounds.height - 110, width: bounds.width - 48, height: 70),
      withAttributes: attributes)
  }
}
