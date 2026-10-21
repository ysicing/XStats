// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class MenuBarApplicationFolding {
  struct Application: Identifiable {
    let id: String
    let name: String
    let icon: NSImage?
  }

  private(set) var applications: [Application] = []
  private(set) var selected: Set<String>
  private(set) var isCollapsed = false
  private(set) var isBusy = false
  private(set) var hasAccess = false
  private(set) var recoveryNeeded = false
  private(set) var issue: String?
  @ObservationIgnored var showManagement: () -> Void = {}

  private let settings: AppSettings
  private let defaults: UserDefaults
  private let store: MenuBarVisibilityStore
  private let ownBundleID: String
  private var enabledState: Bool?
  private var scopedURL: URL?
  private var terminating = false
  @ObservationIgnored private var operation: Task<Void, Never>?
  private static let selectionKey = "menuBarFoldingApplications"
  private static let bookmarkKey = "menuBarFoldingFileBookmark"

  init(settings: AppSettings, store: MenuBarVisibilityStore = .init()) {
    self.settings = settings
    defaults = settings.menuBarFoldingDefaults
    self.store = store
    ownBundleID = Bundle.main.bundleIdentifier ?? "work.12306.xstats.app"
    selected = Set(defaults.stringArray(forKey: Self.selectionKey) ?? [])
  }

  var requiresTerminationPreparation: Bool { isBusy || recoveryNeeded }
  var isEnabled: Bool { settings.menuBarFoldingEnabled }

  /// 设置观察会在 isBusy 变化后重入；繁忙期间的新开关状态随后再处理。
  func setEnabled(_ enabled: Bool) {
    guard !terminating, !isBusy, enabledState != enabled else { return }
    enabledState = enabled
    activateAccess()
    run {
      try await self.restore()
      guard enabled else { return }
      try await self.loadApplications()
      if self.settings.menuBarFoldingCollapsed && !self.selected.isEmpty {
        try await self.collapse()
      }
    }
  }

  func refresh() {
    guard !isBusy, !terminating else { return }
    activateAccess()
    run {
      try await self.restore()
      try await self.loadApplications()
    }
  }

  func select(_ identifier: String, enabled: Bool) {
    guard !isBusy, !isCollapsed, !recoveryNeeded else { return }
    if enabled { selected.insert(identifier) } else { selected.remove(identifier) }
    defaults.set(selected.sorted(), forKey: Self.selectionKey)
  }

  func toggle() {
    guard !isBusy, !terminating else { return }
    guard isEnabled || recoveryNeeded else { return }
    if !recoveryNeeded && (!hasAccess || selected.isEmpty) {
      showManagement()
      return
    }
    let expanding = isCollapsed || recoveryNeeded
    run {
      if expanding { try await self.restore() } else { try await self.collapse() }
      self.settings.menuBarFoldingCollapsed = !expanding
    }
  }

  func expand() {
    guard !isBusy, !terminating else { return }
    run { try await self.restore() }
  }

  func requestAccess() {
    guard !isBusy, !terminating else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.propertyList]
    panel.directoryURL = MenuBarVisibilityStore.fileURL.deletingLastPathComponent()
    panel.nameFieldStringValue = MenuBarVisibilityStore.fileURL.lastPathComponent
    panel.title = tr("授权菜单栏应用列表")
    panel.message = tr("请选择 group.com.apple.controlcenter.plist，仅授权此文件，用于隐藏和恢复所选应用。")
    panel.prompt = tr("授权访问")
    guard panel.runModal() == .OK, let url = panel.url,
      url.standardizedFileURL == MenuBarVisibilityStore.fileURL.standardizedFileURL
    else { return }
    do {
      let bookmark = try url.bookmarkData(options: .withSecurityScope)
      defaults.set(bookmark, forKey: Self.bookmarkKey)
      scopedURL?.stopAccessingSecurityScopedResource()
      scopedURL = nil
      refresh()
    } catch {
      issue = tr("无法读取菜单栏应用列表，请重新授权该文件。")
      Log.app.error(
        "Menu bar file grant failed: \(String(describing: error).prefix(160), privacy: .private)")
    }
  }

  /// 等待正在进行的写入，再恢复；恢复失败时由退出门禁保留应用和重试入口。
  func prepareForTermination() async throws {
    terminating = true
    await operation?.value
    do {
      try await restore()
      scopedURL?.stopAccessingSecurityScopedResource()
      scopedURL = nil
    } catch {
      terminating = false
      issue = tr("菜单栏应用尚未恢复，请重试恢复后退出。")
      throw error
    }
  }

  func cancelTermination() {
    // 后续退出门禁可能失败；退出准备已释放的文件授权需要重新激活。
    activateAccess()
    terminating = false
  }

  private func activateAccess() {
    guard scopedURL == nil, let bookmark = defaults.data(forKey: Self.bookmarkKey) else { return }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
      guard url.standardizedFileURL == MenuBarVisibilityStore.fileURL.standardizedFileURL else {
        return
      }
      if url.startAccessingSecurityScopedResource() { scopedURL = url }
      if stale {
        defaults.set(try url.bookmarkData(options: .withSecurityScope), forKey: Self.bookmarkKey)
      }
    } catch {
      hasAccess = false
    }
  }

  private func run(_ action: @escaping @MainActor () async throws -> Void) {
    isBusy = true
    issue = nil
    operation = Task {
      defer { isBusy = false }
      do {
        try await action()
      } catch {
        issue =
          recoveryNeeded
          ? tr("菜单栏应用尚未恢复，请重试恢复后退出。")
          : tr("无法读取或更新菜单栏应用列表，请授权后重试；也可在系统设置中恢复显示。")
        Log.app.error(
          "Menu bar visibility operation failed: \(String(describing: error).prefix(160), privacy: .private)"
        )
      }
    }
  }

  private func loadApplications() async throws {
    hasAccess = false
    let states = try await store.read()
    hasAccess = true
    let ids = Set(
      states.keys.filter {
        !$0.hasPrefix("com.apple.") && $0 != ownBundleID && !$0.hasPrefix(ownBundleID + ".")
      }
    ).union(selected)
    applications = ids.map { id in
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
      let name = url.map { FileManager.default.displayName(atPath: $0.path) } ?? id
      return Application(
        id: id, name: name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) })
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private func collapse() async throws {
    recoveryNeeded = true
    try await store.collapse(selected, ownBundleID: ownBundleID)
    isCollapsed = true
    Log.app.info("Menu bar application folding applied, selected count: \(self.selected.count)")
  }

  private func restore() async throws {
    // 启动时即使功能开关关闭，也要先处理上次崩溃留下的日志。
    recoveryNeeded = recoveryNeeded || store.hasRecoveryRecord
    try await store.restore()
    isCollapsed = false
    recoveryNeeded = false
  }
}
