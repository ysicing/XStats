// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Localization
import SwiftUI

/// 启动项：LaunchAgents / LaunchDaemons 里的后台项目，当前用户的可以直接停用
@MainActor
@Observable
final class StartupItemsController {
  private(set) var items: [LaunchItem] = []
  private(set) var status = LaunchStatus()
  private(set) var isLoading = false
  private(set) var working: String?
  private(set) var message: (text: String, isError: Bool)?

  private var section: AppServicesSection = .startup
  private var visible = false
  private var paused = false
  private var generation = UUID()
  private var refreshTask: Task<Void, Never>?
  private let readInventory: @Sendable ([LaunchItem.Scope]) async -> ([LaunchItem], LaunchStatus)

  init(
    readInventory: @escaping @Sendable ([LaunchItem.Scope]) async -> ([LaunchItem], LaunchStatus) =
      { scopes in
        let worker = Task.detached {
          (LaunchItems.scan(scopes: scopes), LaunchItems.status(scopes: scopes))
        }
        return await withTaskCancellationHandler {
          await worker.value
        } onCancel: {
          worker.cancel()
        }
      }
  ) {
    self.readInventory = readInventory
  }

  func setVisible(_ value: Bool, section: AppServicesSection? = nil) {
    if let section, self.section != section {
      cancelReading()
      self.section = section
      items = []
      status = LaunchStatus()
      message = nil
    }
    visible = value
    if value && !paused { refresh() } else { cancelReading() }
  }

  func setPaused(_ value: Bool) {
    paused = value
    if value { cancelReading() } else if visible { refresh() }
  }

  private func cancelReading() {
    generation = UUID()
    refreshTask?.cancel()
    refreshTask = nil
    isLoading = false
  }

  func refresh() {
    guard visible, !paused, !isLoading, working == nil else { return }
    isLoading = true
    let current = UUID()
    generation = current
    let scopes = section.launchScopes
    guard !scopes.isEmpty else {
      isLoading = false
      return
    }
    refreshTask = Task {
      guard !Task.isCancelled else { return }
      let (items, status) = await readInventory(scopes)
      guard !Task.isCancelled, generation == current, visible, !paused else { return }
      self.items = items
      self.status = status
      isLoading = false
      refreshTask = nil
    }
  }

  func showPreview(items: [LaunchItem], status: LaunchStatus) {
    self.items = items
    self.status = status
  }

  func setEnabled(_ enabled: Bool, _ item: LaunchItem) {
    guard visible, !paused, working == nil, item.scope == .user else { return }
    cancelReading()
    working = item.id
    message = nil
    Task {
      let error = await Task.detached { LaunchItems.setEnabled(enabled, item: item) }.value
      working = nil
      if let error {
        message = (error, true)
      } else {
        Log.app.notice(
          "\(enabled ? "启用" : "停用", privacy: .public)启动项 \(item.label, privacy: .public)")
        message = (tr("已\(enabled ? tr("启用") : tr("停用"))“\(item.label)”"), false)
      }
      isLoading = false
      refresh()
    }
  }
}

struct StartupItemsPage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
  let section: AppServicesSection
  let search: String

  var body: some View {
    let controller = model.startupItems

    PageScroll {
      if let message = controller.message {
        InfoBanner(
          icon: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
          text: message.text, tone: message.isError ? .error : .success)
      }
      ForEach(section.launchScopes, id: \.self) { scope in
        let items = Self.filteredItems(
          controller.items, section: section, scope: scope, search: search)
        Card {
          CardHeader(
            icon: scope == .system ? "lock.shield" : "person.crop.circle",
            title: scope == .system ? tr("后台守护进程") : scope.title
          ) {
            HStack(spacing: DS.Space.s2) {
              Text(verbatim: scopeDetail(scope, count: items.count))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
            }
          }
          if scope == .system, !items.isEmpty {
            InfoBanner(
              icon: "info.circle",
              text: tr("如果应用已卸载，但启动项仍在，可点击该项右侧的放大镜，在访达中手动删除对应的启动配置文件。"))
          }
          if items.isEmpty {
            Text(controller.isLoading && controller.items.isEmpty ? tr("正在读取…") : tr("没有匹配的项目"))
              .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
          }
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 { HairlineDivider() }
            StartupItemRow(
              item: item, status: controller.status, isWorking: controller.working == item.id,
              operationInProgress: controller.working != nil
            ) { enabled in
              controller.setEnabled(enabled, item)
            }
          }
        }
      }
    }
    .onAppear {
      if !isSnapshot { controller.setVisible(model.isMainWindowVisible, section: section) }
    }
    .onDisappear { if !isSnapshot { controller.setVisible(false) } }
    .onChange(of: section) { _, value in
      if !isSnapshot { controller.setVisible(model.isMainWindowVisible, section: value) }
    }
    .onChange(of: model.isMainWindowVisible) { _, visible in
      if !isSnapshot { controller.setVisible(visible, section: section) }
    }
  }

  static func filteredItems(
    _ items: [LaunchItem], section: AppServicesSection, scope: LaunchItem.Scope, search: String
  ) -> [LaunchItem] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard section.launchScopes.contains(scope) else { return [] }
    return items.filter { item in
      item.scope == scope
        && (query.isEmpty
          || [item.label, item.program ?? "", item.plist.path]
            .contains { $0.localizedStandardContains(query) })
    }
  }

  private func scopeDetail(_ scope: LaunchItem.Scope, count: Int) -> String {
    switch scope {
    case .user:
      count == 1 ? tr("1 项 · 可直接停用") : tr("\(count) 项 · 可直接停用")
    case .allUsers, .system:
      count == 1 ? tr("1 项 · 需要管理员权限，只读") : tr("\(count) 项 · 需要管理员权限，只读")
    }
  }
}

private struct StartupItemRow: View {
  let item: LaunchItem
  let status: LaunchStatus
  let isWorking: Bool
  let operationInProgress: Bool
  let setEnabled: (Bool) -> Void

  var body: some View {
    let disabled = status.isDisabled(item)
    HStack(spacing: DS.Space.s3) {
      AppIconCache.shared.image(bundlePath: item.appBundlePath)
        .resizable()
        .frame(
          width: DS.Size.iconStandalone + DS.Space.s1, height: DS.Size.iconStandalone + DS.Space.s1)
      VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
        HStack(spacing: DS.Space.s2) {
          Text(verbatim: title)
            .dsFont(.sm, weight: .medium)
            .foregroundStyle(disabled ? DS.Palette.textTertiary : DS.Palette.textPrimary)
            .lineLimit(1)
          badge(disabled: disabled)
        }
        Text(verbatim: [item.label, flags].filter { !$0.isEmpty }.joined(separator: " · "))
          .dsFont(.xs)
          .foregroundStyle(DS.Palette.textSecondary)
          .lineLimit(1)
          .truncationMode(.middle)
        if let program = item.program {
          Text(verbatim: program.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            .dsFont(.xs)
            .foregroundStyle(DS.Palette.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(program)
        }
      }
      Spacer(minLength: DS.Space.s2)
      MiniIconButton(systemName: "magnifyingglass", help: tr("在访达中显示")) {
        NSWorkspace.shared.activateFileViewerSelecting([item.plist])
      }
      if item.scope == .user {
        if isWorking {
          ProgressView().controlSize(.small)
        } else {
          DSToggle(
            isOn: Binding(get: { !disabled }, set: { setEnabled($0) }), label: tr("启用 \(title)")
          )
          .disabled(operationInProgress)
        }
      }
    }
  }

  private var title: String {
    if let bundle = item.appBundlePath {
      return AppNameCache.shared.name(forBundle: bundle)
    }
    return item.program.map { ($0 as NSString).lastPathComponent } ?? item.label
  }

  private var flags: String {
    [item.runAtLoad ? tr("登录时运行") : nil, item.keepAlive ? tr("保持运行") : nil].compactMap { $0 }
      .joined(separator: tr("、"))
  }

  @ViewBuilder
  private func badge(disabled: Bool) -> some View {
    if disabled {
      StatusBadge(text: tr("已停用"))
    } else if let pid = status.pid(item) {
      StatusBadge(text: tr("运行中 · PID \(pid)"), tone: .success)
    } else if status.isLoaded(item) {
      StatusBadge(text: tr("已加载"), tone: .primary)
    }
  }
}
