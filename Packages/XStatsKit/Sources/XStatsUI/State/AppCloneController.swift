// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Observation
import OSLog

extension CloneApplication {
  var displayName: String {
    switch self {
    case .weChat: tr("微信")
    case .qq: "QQ"
    case .lark: tr("飞书")
    case .telegram: tr("Telegram（原生 Swift）")
    case .telegramDesktop: "Telegram Desktop"
    case .weCom: tr("企业微信")
    }
  }

  @MainActor var installedURL: URL? {
    for identifier in sourceIdentifiers {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
        return url
      }
    }
    return nil
  }
}

@MainActor
@Observable
final class AppCloneController {
  enum Operation: Equatable {
    case creating
    case updating(UUID)
    case opening(UUID)
    case removing(UUID)

    var title: String {
      switch self {
      case .creating: tr("正在创建分身")
      case .updating: tr("正在更新")
      case .opening: tr("正在打开")
      case .removing: tr("正在移除")
      }
    }

    var targetID: UUID? {
      switch self {
      case .creating: nil
      case .updating(let id), .opening(let id), .removing(let id): id
      }
    }
  }

  private let store = AppCloneStore()
  private let logger = Logger(subsystem: "work.12306.xstats.app", category: "AppClones")

  private(set) var clones: [AppClone] = []
  private(set) var applicationIcons: [CloneApplication: NSImage] = [:]
  private(set) var operation: Operation?
  var isWorking: Bool { operation != nil }
  private(set) var runningIDs: Set<String> = []
  var error: String?

  func refresh() async {
    do {
      let refreshedClones = try await store.list()
      var icons: [CloneApplication: NSImage] = [:]
      for application in Set(refreshedClones.map(\.application)) {
        if let url = application.installedURL {
          icons[application] = NSWorkspace.shared.icon(forFile: url.path)
        }
      }
      applicationIcons = icons
      clones = refreshedClones
    } catch {
      report(error)
    }
    refreshRunning()
  }

  func refreshRunning() {
    runningIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
  }

  func suggestedName(for application: CloneApplication, locale: Locale) -> String {
    let names = Set(clones.lazy.filter { $0.application == application }.map(\.name))
    var number = 1
    while names.contains("\(application.displayName) \(number.formatted(.number.locale(locale)))") {
      number += 1
    }
    return "\(application.displayName) \(number.formatted(.number.locale(locale)))"
  }

  func create(application: CloneApplication, name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 64,
      name.rangeOfCharacter(from: .controlCharacters) == nil
    else { return }
    let clone = AppClone(
      id: UUID(), number: .random(in: 100_000_000_000_000...999_999_999_999_999),
      application: application, name: name)
    build(clone, updating: false)
  }

  func update(_ clone: AppClone) {
    build(clone, updating: true)
  }

  private func build(_ clone: AppClone, updating: Bool) {
    perform(updating ? .updating(clone.id) : .creating) {
      guard let source = clone.application.installedURL else {
        throw AppCloneStore.Failure.invalidSource
      }
      try self.ensureStopped(clone)
      defer { NotificationCenter.default.post(name: .launcherApplicationsChanged, object: nil) }
      try await self.store.build(clone, source: source, updating: updating) {
        try await self.ensureStopped(clone)
      }
      self.logger.notice("Built clone for \(clone.application.rawValue, privacy: .public)")
    }
  }

  func launch(_ clone: AppClone) {
    perform(.opening(clone.id)) {
      let url = self.store.bundleURL(clone)
      guard AppCloneStore.hasIdentity(url, clone.bundleID) else {
        throw AppCloneStore.Failure.invalidClone
      }
      _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
  }

  func reveal(_ clone: AppClone, data: Bool = false) {
    let url = store.bundleURL(clone)
    if data {
      let profile = url.deletingLastPathComponent().appending(path: "Data")
      NSWorkspace.shared.activateFileViewerSelecting([profile])
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    }
  }

  func moveToTrash(_ clone: AppClone, includingData: Bool) {
    perform(.removing(clone.id)) {
      try self.ensureStopped(clone)
      if includingData {
        try await self.store.moveToTrashIncludingData(clone)
      } else {
        try await self.store.moveToTrash(clone)
      }
      NotificationCenter.default.post(name: .launcherApplicationsChanged, object: nil)
      self.logger.notice(
        "Trashed clone for \(clone.application.rawValue, privacy: .public), including data: \(includingData, privacy: .public)"
      )
    }
  }

  private func ensureStopped(_ clone: AppClone) throws {
    refreshRunning()
    guard !runningIDs.contains(clone.bundleID) else { throw AppCloneStore.Failure.running }
  }

  private func perform(
    _ operation: Operation, action: @escaping @MainActor () async throws -> Void
  ) {
    guard !isWorking else { return }
    self.operation = operation
    error = nil
    Task {
      defer { self.operation = nil }
      do {
        try await action()
      } catch {
        report(error)
      }
      await refresh()
    }
  }

  private func report(_ failure: Error) {
    switch failure {
    case AppCloneStore.Failure.invalidSource:
      error = tr("找不到受支持的原应用")
    case AppCloneStore.Failure.untrustedSource:
      error = tr("无法验证原应用的发布者或签名。")
    case AppCloneStore.Failure.running:
      error = tr("请先退出分身")
    case AppCloneStore.Failure.registrationTooLarge:
      error = tr("分身名称过长，请缩短后重试。")
    default:
      error = tr("分身操作失败。请检查 Xcode 命令行工具。")
    }
    logger.error(
      "Clone operation failed: \(String(describing: failure).prefix(512), privacy: .private)")
  }
}
