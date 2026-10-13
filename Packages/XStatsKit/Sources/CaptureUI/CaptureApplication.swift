// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureCore
import Localization

@MainActor private final class CaptureAppDelegate: NSObject, NSApplicationDelegate {
    let controller = CaptureController()
    private var urls: [URL] = []
    private var launched = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let application = NSMenuItem(); menu.addItem(application)
        let appMenu = NSMenu(); application.submenu = appMenu
        appMenu.addItem(withTitle: tr("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(title: tr("编辑"), action: nil, keyEquivalent: ""); menu.addItem(edit)
        let editMenu = NSMenu(); edit.submenu = editMenu
        for (title, action, key) in [(tr("复制"), "copy:", "c"), (tr("粘贴"), "paste:", "v"), (tr("全选"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = menu
        launched = true
        controller.showHome(); controller.installObservers()
        for url in urls { controller.handle(url) }; urls.removeAll()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { for url in urls { controller.handle(url) } }
        else { self.urls.append(contentsOf: urls.filter { $0.absoluteString.utf8.count <= 2048 }.prefix(max(0, 8 - self.urls.count))) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { controller.showHome(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.hasUnsavedWork else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = tr("退出并丢弃未保存的内容？")
        alert.addButton(withTitle: tr("丢弃并退出")); alert.addButton(withTitle: tr("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { await controller.discardAndStop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { controller.cleanUp() }
}

public enum CaptureApplication {
    @MainActor public static func main() {
        let app = NSApplication.shared
        let delegate = CaptureAppDelegate()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
