// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import Localization

/// 应用菜单。仅菜单栏运行时不显示，但仍负责 ⌘C / ⌘V / ⌘W 等快捷键
@MainActor
enum MainMenu {
  static func make(
    target: AnyObject, aboutAction: Selector, settingsAction: Selector, updateAction: Selector,
    openWindowAction: Selector, guideAction: Selector, feedbackAction: Selector
  ) -> NSMenu {
    let main = NSMenu()

    let app = NSMenu(title: "XStats")
    app.addItem(withTitle: tr("关于 XStats"), action: aboutAction, keyEquivalent: "").target = target
    app.addItem(withTitle: tr("检查更新…"), action: updateAction, keyEquivalent: "").target = target
    app.addItem(.separator())
    app.addItem(withTitle: tr("设置…"), action: settingsAction, keyEquivalent: ",").target = target
    app.addItem(.separator())
    app.addItem(
      withTitle: tr("隐藏 XStats"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(
      withTitle: tr("隐藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    )
    .keyEquivalentModifierMask = [.command, .option]
    app.addItem(
      withTitle: tr("全部显示"), action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: "")
    app.addItem(.separator())
    app.addItem(
      withTitle: tr("退出 XStats"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    add(app, to: main)

    let edit = NSMenu(title: tr("编辑"))
    edit.addItem(withTitle: tr("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: tr("重做"), action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: tr("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: tr("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: tr("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: tr("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    add(edit, to: main)

    let window = NSMenu(title: tr("窗口"))
    window.addItem(withTitle: tr("打开 XStats 主窗口"), action: openWindowAction, keyEquivalent: "0")
      .target = target
    window.addItem(.separator())
    window.addItem(
      withTitle: tr("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(
      withTitle: tr("关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    add(window, to: main)
    NSApp.windowsMenu = window

    let help = NSMenu(title: tr("帮助"))
    help.addItem(withTitle: tr("使用文档"), action: guideAction, keyEquivalent: "").target = target
    help.addItem(withTitle: tr("反馈问题"), action: feedbackAction, keyEquivalent: "").target = target
    add(help, to: main)
    NSApp.helpMenu = help

    return main
  }

  private static func add(_ submenu: NSMenu, to main: NSMenu) {
    let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
    item.submenu = submenu
    main.addItem(item)
  }
}
