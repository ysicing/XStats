// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

/// 独立计时入口：左键快捷弹窗，右键原生菜单；关闭弹窗释放视图及其刷新需求。
@MainActor
final class RestMenuBarController: NSObject {
  private let model: AppModel
  private let windows: RestWindowController
  private let prepareToShow: () -> Void
  private var item: NSStatusItem?
  private var panel: StatusPanel?
  private var renderedSymbol: String?
  var isPresented: Bool { panel?.isVisible == true }

  init(model: AppModel, windows: RestWindowController, prepareToShow: @escaping () -> Void) {
    self.model = model
    self.windows = windows
    self.prepareToShow = prepareToShow
    super.init()
  }

  func sync() {
    guard model.settings.restEnabled else {
      dismiss()
      if let item { NSStatusBar.system.removeStatusItem(item) }
      item = nil
      renderedSymbol = nil
      model.rest.setMenuBarVisible(false)
      model.timer.setMenuVisible(false)
      return
    }
    if item == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.autosaveName = "XStats.rest"
      if let button = item.button {
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
      }
      self.item = item
    }
    model.rest.setMenuBarVisible(true)
    model.timer.setMenuVisible(true)
    update()
  }

  func update() {
    guard let button = item?.button else { return }
    let reading = TimerMenuBarReading(
      timer: model.timer, rest: model.rest,
      eyeRestRemaining: model.wellness.isEyeRestActive
        ? model.wellness.eyeRestSecondsRemaining : nil, breakKind: model.wellness.breakKind)
    button.title = reading.title.isEmpty ? "" : " " + reading.title
    if renderedSymbol != reading.symbol {
      button.image = NSImage(systemSymbolName: reading.symbol, accessibilityDescription: nil)
      button.image?.isTemplate = true
      renderedSymbol = reading.symbol
    }
    let reminder = model.wellness.pending.isEmpty ? "" : " · " + tr("待处理")
    let description = tr("计时") + " · " + reading.phaseTitle + " · " + reading.stateTitle + reminder
    button.toolTip = description
    button.setAccessibilityLabel(description)
  }

  func dismiss() { panel?.dismiss() }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    if NSApp.currentEvent?.type == .rightMouseUp, let item {
      dismiss()
      item.menu = contextMenu()
      sender.performClick(nil)
      item.menu = nil
    } else {
      show()
    }
  }

  func contextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(withTitle: tr("打开计时页面"), action: #selector(openPage), keyEquivalent: "").target =
      self
    menu.addItem(withTitle: tr("显示迷你 HUD"), action: #selector(openHUD), keyEquivalent: "").target =
      self
    if windows.canRestoreRest {
      let restore = menu.addItem(
        withTitle: tr("恢复全屏提醒"), action: #selector(restoreReminder), keyEquivalent: "")
      restore.identifier = NSUserInterfaceItemIdentifier("restore-rest-reminder")
      restore.target = self
    }
    menu.addItem(.separator())
    if model.wellness.isEyeRestActive {
      menu.addItem(withTitle: tr("结束休息"), action: #selector(endBreak), keyEquivalent: "").target =
        self
    } else {
      for (index, kind) in ManualBreakKind.allCases.enumerated() {
        let entry = menu.addItem(
          withTitle: kind.menuTitle(settings: model.settings), action: #selector(startBreak(_:)),
          keyEquivalent: "")
        entry.tag = index
        entry.target = self
      }
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: tr("关闭显示器"), action: #selector(sleepDisplay), keyEquivalent: "")
      .target = self
    return menu
  }

  @objc private func startBreak(_ sender: NSMenuItem) {
    guard ManualBreakKind.allCases.indices.contains(sender.tag) else { return }
    model.wellness.startBreak(ManualBreakKind.allCases[sender.tag])
  }
  @objc private func endBreak() { model.wellness.finishEyeRest(completed: false) }
  @objc private func sleepDisplay() { model.wellness.onSleepDisplay?() }

  func show() {
    guard let button = item?.button, let window = button.window else { return }
    prepareToShow()
    if panel == nil {
      let model = self.model
      let windows = self.windows
      let panel = StatusPanel(
        width: 400, minHeight: 180,
        content: { [weak self] in
          TimerPopover(
            windows: windows,
            openPage: { self?.openPage() }, showHUD: { self?.openHUD() }, close: { self?.dismiss() }
          )
          .environment(model)
        },
        measuring: {
          TimerPopover(windows: windows, openPage: {}, showHUD: {}, close: {})
            .environment(model).environment(\.isSnapshot, true)
        })
      panel.onVisibilityChange = { [weak self] visible in
        guard let self else { return }
        self.item?.button?.highlight(visible)
        self.model.timer.setPopoverVisible(visible)
      }
      self.panel = panel
    }
    model.rest.sync()
    model.timer.refresh()
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    panel?.toggle(below: anchor, on: window.screen)
  }

  @objc private func openPage() {
    dismiss()
    model.openMainWindow(.rest)
  }

  @objc private func openHUD() {
    dismiss()
    windows.showHUD()
  }

  @objc private func restoreReminder() {
    dismiss()
    windows.restoreRest()
  }
}
