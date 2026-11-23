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
  private let store = AppCloneStore()
  private let logger = Logger(subsystem: "work.12306.xstats.app", category: "AppClones")

  private(set) var clones: [AppClone] = []
  private(set) var isWorking = false
  private(set) var runningIDs: Set<String> = []
  var error: String?

  func refresh() async {
    do {
      clones = try await store.list()
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
    perform {
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
    perform {
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

  func moveToTrash(_ clone: AppClone) {
    perform {
      try self.ensureStopped(clone)
      try await self.store.moveToTrash(clone)
      NotificationCenter.default.post(name: .launcherApplicationsChanged, object: nil)
      self.logger.notice("Trashed clone bundle for \(clone.application.rawValue, privacy: .public)")
    }
  }

  private func ensureStopped(_ clone: AppClone) throws {
    refreshRunning()
    guard !runningIDs.contains(clone.bundleID) else { throw AppCloneStore.Failure.running }
  }

  private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
    guard !isWorking else { return }
    isWorking = true
    error = nil
    Task {
      defer { isWorking = false }
      do {
        try await operation()
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
    default:
      error = tr("分身操作失败。请检查 Xcode 命令行工具。")
    }
    logger.error(
      "Clone operation failed: \(String(describing: failure).prefix(512), privacy: .private)")
  }
}
