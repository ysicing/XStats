// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

@MainActor
final class DNSBenchmarkWindowController: NSObject, NSWindowDelegate {
  private let model: AppModel
  private let controller = DNSBenchmarkController()
  private var window: NSWindow?
  private(set) var isVisible = false
  var onVisibilityChange: ((Bool) -> Void)?

  init(model: AppModel) {
    self.model = model
    super.init()
  }

  func refreshLanguage() { window?.title = tr("DNS 测试") }
  func cancel() { controller.cancel() }

  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    if !isVisible {
      isVisible = true
      onVisibilityChange?(true)
    }
    if window.isMiniaturized { window.deminiaturize(nil) }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = tr("DNS 测试")
    WindowChrome.apply(to: window)
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.contentMinSize = NSSize(width: 640, height: 480)
    window.contentView = NSHostingView(
      rootView: DNSBenchmarkWindowView(controller: controller)
        .appLanguageEnvironment().environment(model))
    if !window.setFrameUsingName("XStatsDNSBenchmarkWindow") { window.center() }
    window.setFrameAutosaveName("XStatsDNSBenchmarkWindow")
    return window
  }

  func windowWillClose(_ notification: Notification) {
    controller.cancel()
    isVisible = false
    onVisibilityChange?(false)
  }

  func windowDidMiniaturize(_ notification: Notification) { controller.cancel() }
}
