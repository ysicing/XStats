// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Observation
import OSLog
import WebDAVSync

enum ActivitySyncProvider: String, CaseIterable {
  case iCloud, webDAV, googleDrive, local
}

@MainActor @Observable
final class ActivitySyncController {
  private(set) var provider: ActivitySyncProvider
  private(set) var active = false
  private(set) var syncMode: ActivitySyncMode?
  var syncing: Bool { syncMode != nil }
  private(set) var message: String?
  private(set) var address: String
  private(set) var username: String
  private(set) var folderName: String
  private let store: ActivityStore
  private let deviceID: UUID
  private let defaults: UserDefaults
  @ObservationIgnored private var engine: ActivitySyncEngine?
  private let keys: ActivitySyncKeys
  private(set) var changingKey = false
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var changed = false
  @ObservationIgnored private var waitingForChange = false
  @ObservationIgnored private var retrying = false
  private let logger = Logger(subsystem: "work.12306.xstats", category: "ActivitySync")

  init(store: ActivityStore, deviceID: UUID, defaults: UserDefaults) {
    self.store = store
    self.deviceID = deviceID
    self.defaults = defaults
    keys = ActivitySyncKeys(persistent: defaults === UserDefaults.standard)
    if let raw = defaults.string(forKey: "activity.sync.provider") {
      provider = ActivitySyncProvider(rawValue: raw) ?? .local
    } else {
      provider = .iCloud
    }
    address = defaults.string(forKey: "activity.sync.address") ?? ""
    username = defaults.string(forKey: "activity.sync.username") ?? ""
    folderName = defaults.string(forKey: "activity.sync.folderName") ?? ""
  }

  deinit {
    timer?.cancel()
    worker?.cancel()
  }

  func setActive(_ active: Bool) {
    guard self.active != active else { return }
    self.active = active
    restart()
  }

  func dataChanged() {
    guard active, provider != .local else { return }
    changed = true
    guard worker == nil, !waitingForChange, !retrying else { return }
    schedule(after: 60, forChange: true)
  }

  func syncNow() {
    startSync(.manual)
  }

  func recoveryCode() async throws -> String {
    if let key = await engine?.authenticatedKey { return ActivityKeys.recoveryCode(for: key) }
    return try await ActivityKeys.recoveryCode(for: keys.key())
  }

  func importRecoveryCode(_ code: String, confirmExisting: Bool = false) async throws {
    let imported = try ActivityKeys.decode(code)
    guard !changingKey else { throw ActivityKeys.Failure.unavailable }
    changingKey = true
    if let activeKey = await engine?.authenticatedKey, activeKey != imported, !confirmExisting {
      changingKey = false
      throw ActivityKeys.Failure.replacementRequired
    }
    restart()
    await worker?.value
    defer {
      changingKey = false
      restart()
    }
    try await keys.replace(with: code, confirmExisting: confirmExisting)
    engine = nil
  }

  func cancelManualSync() {
    guard syncMode == .manual else { return }
    worker?.cancel()
  }

  private func startSync(_ mode: ActivitySyncMode) {
    guard active, provider != .local, worker == nil, !changingKey else { return }
    timer?.cancel()
    timer = nil
    waitingForChange = false
    changed = false
    let ticket = generation
    let selected = provider
    syncMode = mode
    if mode == .manual { message = nil }
    worker = Task { [weak self] in
      guard let self else { return }
      var errorMessage: String?
      var hasBacklog = false
      do {
        try Task.checkCancellation()
        let engine: ActivitySyncEngine
        if let cached = self.engine {
          engine = cached
        } else {
          let key = try await keys.key()
          try Task.checkCancellation()
          engine = ActivitySyncEngine(
            key: key,
            sharedKeys: defaults === UserDefaults.standard ? ActivitySharedKeys.available : nil)
          self.engine = engine
        }
        switch selected {
        case .local: break
        case .iCloud:
          try await engine.runInFolder(store: store, device: deviceID, bookmark: nil, mode: mode)
        case .googleDrive:
          guard let bookmark = defaults.data(forKey: "activity.sync.bookmark") else {
            throw ActivitySyncFailure.folderUnavailable
          }
          let refreshed = try await engine.runInFolder(
            store: store, device: deviceID, bookmark: bookmark, mode: mode)
          if ticket == generation, let refreshed {
            defaults.set(refreshed, forKey: "activity.sync.bookmark")
          }
        case .webDAV:
          let config = try ActivityDAVConfiguration(address: address, username: username)
          guard
            let secret = try KeychainWebDAVPasswordStore().read(
              account: "activity." + config.credentialAccount),
            !secret.isEmpty
          else { throw WebDAVError.missingPassword }
          try await engine.run(
            store: store, device: deviceID,
            repository: ActivitySyncWebDAV(configuration: config, password: secret), mode: mode)
        }
        hasBacklog = await engine.continuationDay != nil
      } catch is ActivityKeys.Failure {
        errorMessage = tr("无法读取或保存活动密钥，请检查钥匙串")
      } catch ActivitySyncFailure.keyPending {
        errorMessage = tr("正在等待 iCloud 钥匙串同步活动密钥")
      } catch ActivitySyncFailure.authenticationFailed {
        errorMessage = tr("无法验证同步数据，请核对恢复密钥和同步位置。")
      } catch ActivitySyncFailure.cloudPending {
        errorMessage = tr("等待 iCloud 云盘就绪")
      } catch let error as ActivityDAVError {
        errorMessage = error.errorDescription
      } catch {
        errorMessage = (error as? WebDAVError)?.errorDescription ?? tr("活动同步失败，将自动重试")
      }
      worker = nil
      syncMode = nil
      guard ticket == generation else {
        startSync(.automatic)
        return
      }
      if Task.isCancelled {
        schedule(after: retrying ? 180 : (changed ? 60 : 600), forChange: changed)
        return
      }
      if retrying != (errorMessage != nil) {
        if errorMessage == nil {
          logger.info("Activity synchronization recovered")
        } else {
          logger.notice("Activity synchronization pending; will retry")
        }
      }
      retrying = errorMessage != nil
      message = errorMessage ?? tr("本轮同步完成")
      schedule(after: retrying ? 180 : (changed || hasBacklog ? 60 : 600), forChange: changed)
    }
  }

  func save(
    provider: ActivitySyncProvider, address: String, username: String, secret: String, folder: URL?
  ) throws {
    if provider == .webDAV {
      let config = try ActivityDAVConfiguration(address: address, username: username)
      let account = "activity." + config.credentialAccount
      let keychain = KeychainWebDAVPasswordStore()
      if !secret.isEmpty {
        try keychain.write(secret, account: account)
      } else if try keychain.read(account: account)?.isEmpty != false {
        throw WebDAVError.missingPassword
      }
      self.address = config.directoryURL.absoluteString
      self.username = config.username
      defaults.set(self.address, forKey: "activity.sync.address")
      defaults.set(self.username, forKey: "activity.sync.username")
    }
    if provider == .googleDrive {
      if let folder {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        guard folder.isFileURL,
          try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        else { throw ActivitySyncFailure.folderUnavailable }
        let bookmark =
          try (try? folder.bookmarkData(options: .withSecurityScope)) ?? folder.bookmarkData()
        defaults.set(bookmark, forKey: "activity.sync.bookmark")
        folderName = folder.lastPathComponent
        defaults.set(folderName, forKey: "activity.sync.folderName")
      } else if defaults.data(forKey: "activity.sync.bookmark") == nil {
        throw ActivitySyncFailure.folderUnavailable
      }
    }
    self.provider = provider
    defaults.set(provider.rawValue, forKey: "activity.sync.provider")
    engine = nil
    restart()
  }

  private func restart() {
    generation = UUID()
    timer?.cancel()
    timer = nil
    worker?.cancel()
    changed = false
    retrying = false
    waitingForChange = false
    message = nil
    if worker == nil { startSync(.automatic) }
  }

  private func schedule(after seconds: Int, forChange: Bool) {
    timer?.cancel()
    waitingForChange = forChange
    timer = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(seconds), tolerance: .seconds(5)) } catch { return }
      self?.startSync(.automatic)
    }
  }
}

extension ActivitySyncEngine {
  @discardableResult
  func runInFolder(
    store: ActivityStore, device: UUID, bookmark: Data?, mode: ActivitySyncMode
  ) async throws -> Data? {
    try Task.checkCancellation()
    guard let bookmark else {
      try await run(
        store: store, device: device, repository: ActivitySyncFolder.iCloudDrive(), mode: mode)
      return nil
    }
    var stale = false
    let scopedURL = try? URL(
      resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting],
      relativeTo: nil, bookmarkDataIsStale: &stale)
    let url =
      try scopedURL
      ?? URL(
        resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
        relativeTo: nil, bookmarkDataIsStale: &stale)
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let renewed =
      stale ? try url.bookmarkData(options: scopedURL == nil ? [] : .withSecurityScope) : nil
    try await run(
      store: store, device: device, repository: ActivitySyncFolder(root: url), mode: mode)
    return renewed
  }
}
