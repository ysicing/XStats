// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

struct LauncherDirectorySettings: View {
  private let store: LauncherApplicationDirectories
  private let language: AppLanguage?
  @State private var directories: [LauncherApplicationDirectories.Directory]
  @State private var feedback: String?
  @State private var feedbackIsError = false
  @State private var activePanel: NSOpenPanel?

  init(
    store: LauncherApplicationDirectories = LauncherApplicationDirectories(),
    language: AppLanguage? = nil
  ) {
    self.store = store
    self.language = language
    _directories = State(initialValue: store.directories)
  }

  var body: some View {
    SettingsGroup(caption: tr("应用目录")) {
      GroupRow(showsDivider: false) {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s2) { actions }
            VStack(alignment: .leading, spacing: DS.Space.s2) { actions }
          }
          Text(tr("保留系统默认目录；最多添加 16 个自定义目录，仅扫描目录及下一层。"))
            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
          if let feedback {
            Text(feedback)
              .dsFont(.xs)
              .foregroundStyle(feedbackIsError ? DS.Palette.error : DS.Palette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("launcher-directory-feedback")
          }
        }
      }
      ForEach(directories) { directory in
        GroupRow {
          HStack(spacing: DS.Space.s2) {
            Text(verbatim: directory.path)
              .dsFont(.xs)
              .lineLimit(2)
              .truncationMode(.middle)
              .frame(maxWidth: .infinity, alignment: .leading)
              .help(directory.path)
            Button(tr("移除目录")) { remove(directory) }
              .buttonStyle(DSButtonStyle(kind: .secondary))
              .accessibilityLabel(tr("移除应用目录"))
          }
        }
      }
    }
    .onAppear { directories = store.directories }
    .onReceive(store.notificationCenter.publisher(for: .launcherApplicationsChanged)) { _ in
      directories = store.directories
    }
    .onDisappear {
      let panel = activePanel
      activePanel = nil
      panel?.cancel(nil)
    }
  }

  @ViewBuilder private var actions: some View {
    Button(tr("添加目录…")) { chooseDirectory() }
      .disabled(
        activePanel != nil || directories.count >= LauncherApplicationDirectories.maximumCount)
    Button(tr("刷新应用")) {
      store.notificationCenter.post(name: .launcherApplicationsChanged, object: nil)
      feedbackIsError = false
      feedback = tr("已请求刷新应用")
    }
  }

  private func chooseDirectory() {
    guard activePanel == nil else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.treatsFilePackagesAsDirectories = false
    panel.title = tr("添加应用目录")
    panel.prompt = tr("添加")
    activePanel = panel
    panel.begin { response in
      guard activePanel === panel else { return }
      activePanel = nil
      guard response == .OK, let url = panel.url else { return }
      do {
        let added = try store.add(url)
        directories = store.directories
        feedbackIsError = false
        feedback = added ? tr("已添加目录，已请求刷新应用") : tr("该目录已包含在应用扫描范围中")
      } catch {
        showError(error)
      }
    }
  }

  /// 显式语言供独立预览使用，不修改进程级 L10n；默认仍跟随应用语言。
  private func tr(_ source: String) -> String {
    guard let language else { return Localization.tr(source) }
    return L10n.translate(source, language: language)
  }

  private func remove(_ directory: LauncherApplicationDirectories.Directory) {
    do {
      if try store.remove(directory.id) {
        feedbackIsError = false
        feedback = tr("已移除目录，已请求刷新应用")
      }
      directories = store.directories
    } catch {
      showError(error)
    }
  }

  private func showError(_ error: Error) {
    feedbackIsError = true
    switch error as? LauncherApplicationDirectories.DirectoryError {
    case .applicationBundle: feedback = tr("请选择应用所在的文件夹，不能选择应用包")
    case .notDirectory: feedback = tr("请选择文件夹")
    case .unreadable: feedback = tr("无法读取该目录，请检查访问权限")
    case .limitReached: feedback = tr("最多添加 16 个自定义应用目录")
    case nil: feedback = tr("无法保存应用目录授权，请重新选择目录")
    }
    Log.app.error(
      "Launcher directory access failed: \(String(describing: error).prefix(160), privacy: .private)"
    )
  }
}
