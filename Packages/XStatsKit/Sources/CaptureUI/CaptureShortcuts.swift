// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import CaptureCore
import Localization
import OSLog

/// Lightweight host-owned settings. Registering shortcuts never creates a capture controller.
@MainActor public final class CaptureShortcuts: ObservableObject {
  @Published private(set) var screenshotKey: CaptureHotKey?
  @Published private(set) var recordingKey: CaptureHotKey?
  @Published private(set) var conflict = false
  @Published private(set) var enabled = false
  private let defaults: UserDefaults
  private let hotKeys = CaptureHotKeys()
  private var editing = false
  private var externalRecording = false
  private static let logger = Logger(
    subsystem: CaptureRequest.bundleIdentifier, category: "shortcuts")
  var onAction: (CaptureRequest.Action) -> Void {
    get { hotKeys.onAction }
    set { hotKeys.onAction = newValue }
  }

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    screenshotKey = defaults.data(forKey: "capture.screenshotKey")
      .flatMap { try? JSONDecoder().decode(CaptureHotKey.self, from: $0) }
    recordingKey = defaults.data(forKey: "capture.recordingKey")
      .flatMap { try? JSONDecoder().decode(CaptureHotKey.self, from: $0) }
  }
  private var bindings: [CaptureRequest.Action: CaptureHotKey] {
    var result: [CaptureRequest.Action: CaptureHotKey] = [:]
    result[.screenshot] = screenshotKey
    result[.record] = recordingKey
    return result
  }
  private func valid(_ bindings: [CaptureRequest.Action: CaptureHotKey]) -> Bool {
    let combinations = Set(bindings.values.map { UInt64($0.code) << 32 | UInt64($0.carbon) })
    return combinations.count == bindings.count && bindings.values.allSatisfy(\.isUsable)
  }
  func setShortcut(_ key: CaptureHotKey?, for action: CaptureRequest.Action) {
    guard action == .screenshot || action == .record else { return }
    let previous = bindings
    var candidate = previous
    candidate[action] = key
    guard valid(candidate) else {
      conflict = true
      return
    }
    if enabled, !hotKeys.apply(candidate) {
      // Carbon registers each binding separately. Restore the last working group
      // before publishing or persisting anything from the rejected edit.
      _ = hotKeys.apply(previous)
      conflict = true
      Self.logger.notice("Shortcut edit rejected; previous bindings restored when available")
      return
    }
    if action == .screenshot { screenshotKey = key } else { recordingKey = key }
    let name = action == .screenshot ? "capture.screenshotKey" : "capture.recordingKey"
    defaults.set(key.flatMap { try? JSONEncoder().encode($0) }, forKey: name)
    conflict = false
  }
  func setEnabled(_ value: Bool) {
    guard value else {
      if enabled, !bindings.isEmpty { Self.logger.info("Global shortcuts stopped") }
      hotKeys.clear()
      enabled = false
      conflict = false
      return
    }
    guard !enabled else { return }
    enabled = true
    guard !editing && !externalRecording else { return }
    conflict = !valid(bindings) || !hotKeys.apply(bindings)
    if conflict {
      Self.logger.error("Global shortcut registration failed")
    } else if !bindings.isEmpty {
      Self.logger.info("Global shortcuts started")
    }
  }
  func setEditing(_ value: Bool) {
    guard editing != value else { return }
    editing = value
    if value {
      hotKeys.clear()
      return
    }
    guard enabled && !externalRecording else { return }
    conflict = !valid(bindings) || !hotKeys.apply(bindings)
    if conflict { Self.logger.error("Global shortcut registration failed after editing") }
  }
  /// 宿主录制其他快捷键时临时释放注册，不改变用户绑定或启用状态。
  public func setExternalRecording(_ value: Bool) {
    guard externalRecording != value else { return }
    externalRecording = value
    if value {
      hotKeys.clear()
    } else if enabled && !editing {
      conflict = !valid(bindings) || !hotKeys.apply(bindings)
    }
  }
  public func stop() { setEnabled(false) }
}

/// Both hosts use the same native recorder and conflict feedback.
public struct CaptureShortcutSettingsView: View {
  @ObservedObject private var shortcuts: CaptureShortcuts
  private let onRecordingChanged: (Bool) -> Void
  public init(shortcuts: CaptureShortcuts, onRecordingChanged: @escaping (Bool) -> Void = { _ in })
  {
    self.shortcuts = shortcuts
    self.onRecordingChanged = onRecordingChanged
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(tr("截图快捷键"))
        Spacer()
        CaptureShortcutRecorder(
          value: shortcuts.screenshotKey, onChange: { shortcuts.setShortcut($0, for: .screenshot) },
          onRecordingChanged: { value in
            shortcuts.setEditing(value)
            onRecordingChanged(value)
          }
        )
        .frame(maxWidth: 240).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Text(tr("录屏快捷键"))
        Spacer()
        CaptureShortcutRecorder(
          value: shortcuts.recordingKey, onChange: { shortcuts.setShortcut($0, for: .record) },
          onRecordingChanged: { value in
            shortcuts.setEditing(value)
            onRecordingChanged(value)
          }
        )
        .frame(maxWidth: 240).fixedSize(horizontal: false, vertical: true)
      }
      Text(tr("点击设置快捷键；Delete 清除，Esc 取消。"))
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if shortcuts.conflict {
        Text(tr("快捷键无效或已被占用，原设置已保留。"))
          .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
