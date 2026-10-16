// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureCore
import Localization

@MainActor private final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
  private let workspace = CaptureWorkspace(host: .standalone)
  private var urls: [URL] = []
  private var launched = false
  private var terminationTask: Task<Void, Never>?
  func applicationDidFinishLaunching(_ notification: Notification) {
    launched = true
    workspace.open(.open)
    CaptureApplication.updateMenu()
    for url in urls { workspace.handle(url) }
    urls.removeAll()
  }
  func application(_ application: NSApplication, open urls: [URL]) {
    if launched {
      for url in urls { workspace.handle(url) }
    } else {
      self.urls.append(
        contentsOf: urls.filter { $0.absoluteString.utf8.count <= 2048 }.prefix(
          max(0, 8 - self.urls.count)))
    }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    workspace.open(.open)
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard terminationTask == nil else { return .terminateLater }
    guard workspace.confirmTermination() else { return .terminateCancel }
    guard workspace.hasActiveWorkspace else { return .terminateNow }
    terminationTask = Task {
      await workspace.prepareForTermination()
      sender.reply(toApplicationShouldTerminate: true)
      terminationTask = nil
    }
    return .terminateLater
  }
  func applicationWillTerminate(_ notification: Notification) { workspace.cleanUp() }
}

public enum CaptureApplication {
  @MainActor static func updateMenu() {
    let menu = NSMenu()
    let application = NSMenuItem()
    menu.addItem(application)
    let appMenu = NSMenu()
    application.submenu = appMenu
    appMenu.addItem(
      withTitle: tr("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let edit = NSMenuItem(title: tr("编辑"), action: nil, keyEquivalent: "")
    menu.addItem(edit)
    let editMenu = NSMenu()
    edit.submenu = editMenu
    for (title, action, key) in [
      (tr("复制"), "copy:", "c"), (tr("粘贴"), "paste:", "v"), (tr("全选"), "selectAll:", "a"),
    ] {
      editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
    }
    NSApp.mainMenu = menu
  }
  @MainActor public static func main() {
    let app = NSApplication.shared
    let delegate = CaptureAppDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}
