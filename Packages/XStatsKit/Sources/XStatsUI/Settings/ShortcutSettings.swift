// SPDX-License-Identifier: AGPL-3.0-or-later

import CaptureUI
import Localization
import SwiftUI

enum ShortcutSettingsTarget: Hashable {
  case action(HotKeyAction)
  case captureScreenshot, captureRecording

  static var all: [Self] {
    HotKeyAction.allCases.map(Self.action) + [.captureScreenshot, .captureRecording]
  }

  @MainActor func title(settings: AppSettings) -> String {
    switch self {
    case .action(let action): action.title(processesEnabled: settings.processesEnabled)
    case .captureScreenshot: tr("截图快捷键")
    case .captureRecording: tr("录屏快捷键")
    }
  }
}

@MainActor
struct ShortcutSettingsEditor {
  let settings: AppSettings
  let capture: CaptureShortcuts
  var includesCapture = true

  func key(for target: ShortcutSettingsTarget) -> HotKey? {
    let key: CaptureHotKey?
    switch target {
    case .action(let action): return settings.hotKeys[action]
    case .captureScreenshot: key = capture.screenshotKey
    case .captureRecording: key = capture.recordingKey
    }
    return key.map {
      HotKey(keyCode: $0.code, modifiers: .init(rawValue: $0.modifiers), key: $0.characters)
    }
  }

  func conflict(for key: HotKey?, excluding target: ShortcutSettingsTarget)
    -> ShortcutSettingsTarget?
  {
    guard let key else { return nil }
    let targets =
      includesCapture
      ? ShortcutSettingsTarget.all : HotKeyAction.allCases.map(ShortcutSettingsTarget.action)
    return targets.first { other in
      guard other != target, let existing = self.key(for: other) else { return false }
      return existing.keyCode == key.keyCode && existing.carbonModifiers == key.carbonModifiers
    }
  }

  @discardableResult
  func set(_ key: HotKey?, for target: ShortcutSettingsTarget) -> Bool {
    guard key?.isValid != false, conflict(for: key, excluding: target) == nil else { return false }
    switch target {
    case .action(let action):
      settings.hotKeys[action] = key
      return true
    case .captureScreenshot, .captureRecording:
      let captureKey = key.map {
        CaptureHotKey(code: $0.keyCode, modifiers: $0.modifiers, characters: $0.key)
      }
      return capture.setShortcut(
        captureKey, for: target == .captureScreenshot ? .screenshot : .record)
    }
  }
}

struct ShortcutSettingsPage: View {
  @Environment(AppModel.self) private var model
  @ObservedObject private var integration: XStatsCapture

  init(integration: XStatsCapture = .shared) {
    self.integration = integration
  }

  var body: some View {
    ScrollViewReader { proxy in
      SettingsTabPage {
        HotKeySettings(integration: integration)
      }
      .onAppear {
        if let target = model.shortcutSettingsTarget { proxy.scrollTo(target, anchor: .center) }
      }
      .onChange(of: model.shortcutSettingsTarget) { _, target in
        if let target { proxy.scrollTo(target, anchor: .center) }
      }
      .onDisappear { model.shortcutSettingsTarget = nil }
    }
  }
}

struct HotKeySettings: View {
  @Environment(AppModel.self) private var model
  @ObservedObject private var integration: XStatsCapture
  @ObservedObject private var workspace: CaptureWorkspace
  @ObservedObject private var capture: CaptureShortcuts
  @State private var rejected: [ShortcutSettingsTarget: String] = [:]

  init(integration: XStatsCapture = .shared) {
    self.integration = integration
    workspace = integration.embedded
    capture = integration.embedded.shortcuts
  }

  private var editor: ShortcutSettingsEditor {
    ShortcutSettingsEditor(
      settings: model.settings, capture: capture, includesCapture: !integration.prefersStandalone)
  }

  var body: some View {
    Text(tr("全局快捷键（在任何应用中都能使用，需要包含 ⌘、⌥ 或 ⌃）"))
      .dsFont(.xs, weight: .medium).foregroundStyle(DS.Palette.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
    ForEach(HotKeyAction.Category.allCases, id: \.self) { category in
      SettingsGroup(caption: category.title) {
        ForEach(
          Array(HotKeyAction.allCases.filter { $0.category == category }.enumerated()),
          id: \.element
        ) { index, action in
          shortcutRow(.action(action), showsDivider: index > 0)
        }
      }
    }
    SettingsGroup(caption: tr("截图与录屏")) {
      if integration.prefersStandalone {
        GroupRow(showsDivider: false) {
          SettingRow(
            title: "XStats Capture",
            subtitle: tr("独立版快捷键请在 XStats Capture 的设置中管理。")
          ) {
            Button(tr("打开独立版")) { Task { await integration.openStandalone() } }
              .buttonStyle(DSButtonStyle(kind: .secondary))
              .disabled(integration.isOpening)
          }
          if let issue = integration.issue {
            Text(issue.message).dsFont(.xs).foregroundStyle(DS.Palette.error)
          }
        }
        .id(ShortcutSettingsTarget.captureScreenshot)
      } else {
        shortcutRow(.captureScreenshot, showsDivider: false)
        shortcutRow(.captureRecording, showsDivider: true)
      }
    }
  }

  private func subtitle(for target: ShortcutSettingsTarget) -> String? {
    if let message = rejected[target] { return message }
    if let other = editor.conflict(for: editor.key(for: target), excluding: target) {
      return tr("与「\(other.title(settings: model.settings))」的快捷键重复")
    }
    switch target {
    case .action(let action):
      if model.hotKeyConflicts.contains(action) {
        return tr("这个快捷键已被其他应用或系统占用，请换一个")
      }
      if !action.isEnabled(in: model.settings) { return tr("功能未启用，启用后生效") }
      return action == .showProcesses
        ? tr("进程功能开启时打开 XStats 进程页，关闭时打开系统活动监视器。") : nil
    case .captureScreenshot, .captureRecording:
      if capture.conflict { return tr("快捷键无效或已被占用，原设置已保留。") }
      return workspace.enabled ? nil : tr("功能未启用，启用后生效")
    }
  }

  private func shortcutRow(_ target: ShortcutSettingsTarget, showsDivider: Bool) -> some View {
    GroupRow(showsDivider: showsDivider) {
      SettingRow(title: target.title(settings: model.settings), subtitle: subtitle(for: target)) {
        ShortcutRecorder(
          actionTitle: target.title(settings: model.settings),
          hotKey: Binding(
            get: { editor.key(for: target) },
            set: { key in
              if let other = editor.conflict(for: key, excluding: target) {
                rejected[target] = tr("与「\(other.title(settings: model.settings))」的快捷键重复")
              } else if editor.set(key, for: target) {
                rejected[target] = nil
              } else {
                rejected[target] = tr("快捷键无效或已被占用，原设置已保留。")
              }
            }),
          captureShortcuts: capture)
      }
    }
    .background(
      model.shortcutSettingsTarget == target ? DS.Palette.primary.opacity(0.08) : .clear,
      in: RoundedRectangle(cornerRadius: DS.Radius.md)
    )
    .id(target)
  }
}
