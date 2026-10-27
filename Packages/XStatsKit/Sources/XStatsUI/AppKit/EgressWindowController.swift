// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import Localization
import SwiftUI

/// 出口与分流窗口。打开期间检测器盯着网络环境，关闭后停止
@MainActor
final class EgressWindowController: NSObject, NSWindowDelegate {
  private let model: AppModel
  private let session: EgressWindowSession
  private var window: NSWindow?
  func refreshLanguage() { window?.title = tr("出口与分流") }
  var onVisibilityChange: ((Bool) -> Void)?

  init(model: AppModel) {
    self.model = model
    session = EgressWindowSession(egress: model.egress)
    super.init()
  }

  /// windowWillClose 时窗口还算可见，所以自己记开关状态
  private(set) var isVisible = false

  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    if !isVisible {
      isVisible = true
      session.open()
      onVisibilityChange?(true)
    }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(
        x: 0, y: 0, width: DS.Size.egressWindowWidth, height: DS.Size.egressWindowHeight),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = tr("出口与分流")
    WindowChrome.apply(to: window)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentMinSize = NSSize(
      width: DS.Size.panelWidth - DS.Space.s16, height: DS.Size.panelMinHeight * 1.5)
    window.contentView = NSHostingView(
      rootView: EgressWindowView(session: session).environment(model))
    // 第一次打开居中，之后沿用用户调整过的位置与大小
    if !window.setFrameUsingName("XStatsEgressWindow") { window.center() }
    window.setFrameAutosaveName("XStatsEgressWindow")
    return window
  }

  func windowWillClose(_ notification: Notification) {
    isVisible = false
    session.close()
    onVisibilityChange?(false)
  }

  func windowDidMiniaturize(_ notification: Notification) { session.setSuspended(true) }

  func windowDidDeminiaturize(_ notification: Notification) { session.setSuspended(false) }

  func windowWillUseStandardFrame(_ sender: NSWindow, defaultFrame: NSRect) -> NSRect {
    fittedFrame(for: sender, within: sender.screen?.visibleFrame ?? defaultFrame)
  }

  /// 只在用户执行系统缩放时测量；切页和异步结果更新不触发窗口尺寸反馈。
  func fittedFrame(for window: NSWindow, within visibleFrame: NSRect) -> NSRect {
    let available = visibleFrame.insetBy(dx: DS.Space.s3, dy: DS.Space.s3)
    guard available.width > 0, available.height > 0 else { return window.frame }
    let width = min(max(window.frame.width, window.contentMinSize.width), available.width)
    // 普通视图包含 ScrollView，其理想高度不代表内容高度；复用静态渲染路径展开内容。
    let measuring = NSHostingView(
      rootView: EgressWindowView(session: session).environment(model)
        .environment(\.isSnapshot, true)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true))
    let height = min(
      max(ceil(measuring.fittingSize.height), window.contentMinSize.height), available.height)
    return NSRect(
      x: min(max(window.frame.minX, available.minX), available.maxX - width),
      y: max(available.minY, min(window.frame.maxY, available.maxY) - height),
      width: width, height: height)
  }

  func cancelLeakTests() { session.cancelLeakTests() }
}
