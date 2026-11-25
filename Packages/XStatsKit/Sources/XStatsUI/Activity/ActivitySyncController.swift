// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import CryptoKit
import Localization
import Observation
import OSLog
import WebDAVSync

enum ActivitySyncProvider: String, CaseIterable {
  case iCloud, webDAV, googleDrive
}

@MainActor @Observable
final class ActivitySyncController {
  private(set) var provider: ActivitySyncProvider
  private(set) var enabled: Bool
  private(set) var intervalMinutes: Int
  private(set) var preferences: SyncPreferences?
  @ObservationIgnored private let preferenceStore: SyncPreferences?
  @ObservationIgnored private var preparedScope: String?
  @ObservationIgnored private var localKey: SymmetricKey?
  private var sessionAvailable = false
  private var recordsActivity = false
  var active: Bool {
    enabled && sessionAvailable
  }
  private(set) var syncMode: ActivitySyncMode?
  var syncing: Bool { syncMode != nil }
  private enum SyncMessage {
    case text(String)
    case downloadRequested
  }
  private var lastMessage: SyncMessage?
  var message: String? {
    switch lastMessage {
    case .downloadRequested:
      intervalMinutes > 0
        ? tr("已请求下载同步文件，XStats 会自动重试。")
        : tr("已请求下载同步文件，请稍后重试。")
    case .text(let text): text
    case nil: nil
    }
  }
  private(set) var address: String
  private(set) var username: String
  private(set) var folderName: String
  private let store: ActivityStore
  private let deviceID: UUID
  private let defaults: UserDefaults
  private let repository: (any ActivitySyncRepository)?
  @ObservationIgnored private var engine: ActivitySyncEngine?
  private let keys: ActivitySyncKeys
  private let sharedKeys: ActivitySharedKeys?
  private static let importedKeyFingerprint = "activity.sync.importedKeyFingerprint"
  private(set) var changingKey = false
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored private var worker: Task<Void, Never>?
  @ObservationIgnored private var requestedSync = false
  @ObservationIgnored private var retrying = false
  /// 上一轮自动同步结束的时间；唤醒或解锁后据此只等待剩余间隔，不立即重新同步。
  /// ContinuousClock 在系统睡眠期间继续计时，长时间睡眠后会按到期处理。
  @ObservationIgnored private var lastFinished: ContinuousClock.Instant?
  /// 连续失败轮数；断网或服务不可用时按指数放宽间隔，最长 60 分钟。
  @ObservationIgnored private var failureStreak = 0
  private let logger = Logger(subsystem: "work.12306.xstats", category: "ActivitySync")

  init(
    store: ActivityStore, deviceID: UUID, defaults: UserDefaults,
    repository: (any ActivitySyncRepository)? = nil, settings: AppSettings? = nil,
    deviceName: String? = nil, sharedKeys: ActivitySharedKeys? = nil
  ) {
    self.store = store
    self.deviceID = deviceID
    self.defaults = defaults
    self.repository = repository
    self.sharedKeys =
      sharedKeys ?? (defaults === UserDefaults.standard ? ActivitySharedKeys.available : nil)
    preferenceStore = settings.map {
      SyncPreferences(settings: $0, deviceID: deviceID, deviceName: deviceName, defaults: defaults)
    }
    keys = ActivitySyncKeys(persistent: defaults === UserDefaults.standard)
    provider =
      defaults.string(forKey: "activity.sync.provider")
      .flatMap(ActivitySyncProvider.init(rawValue:)) ?? .iCloud
    enabled = defaults.bool(forKey: "sync.enabled")
    let minutes = defaults.object(forKey: "sync.intervalMinutes") as? Int
    intervalMinutes = minutes.flatMap { [0, 5, 10, 30, 60].contains($0) ? $0 : nil } ?? 10
    address = defaults.string(forKey: "activity.sync.address") ?? ""
    username = defaults.string(forKey: "activity.sync.username") ?? ""
    folderName = defaults.string(forKey: "activity.sync.folderName") ?? ""
    if defaults.string(forKey: "sync.googleFolderID") == nil,
      let bookmark = defaults.data(forKey: "activity.sync.bookmark")
    {
      defaults.set(Self.digest(bookmark), forKey: "sync.googleFolderID")
    }
    preferenceStore?.onNeedsSync = { [weak self] in self?.preferenceRequest() }
  }

  deinit {
    timer?.cancel()
    worker?.cancel()
  }

  func setSession(available: Bool, recordsActivity: Bool) {
    guard sessionAvailable != available || self.recordsActivity != recordsActivity else { return }
    // 仅会话可用性变化（锁屏、休眠、唤醒）时保留上次完成时间，恢复后只等待剩余间隔。
    let sessionOnly = self.recordsActivity == recordsActivity
    sessionAvailable = available
    self.recordsActivity = recordsActivity
    restart(keepingSchedule: sessionOnly)
    if available, enabled, preferences == nil, preferenceStore != nil,
      SyncPreferences.hasSavedState(scope, deviceID: deviceID, defaults: defaults)
    {
      Task { await preparePreferences() }
    }
  }

  func setEnabled(_ value: Bool) {
    guard enabled != value else { return }
    if !value { defaults.set(true, forKey: "sync.revoke." + scope) }
    enabled = value
    defaults.set(value, forKey: "sync.enabled")
    restart()
    if !value {
      do { try revokePendingPreferences() } catch {
        lastMessage = .text(tr("无法更改设置同步"))
      }
    }
    if value, preferenceStore != nil, preferences == nil {
      Task { await preparePreferences() }
    }
  }

  func setIntervalMinutes(_ value: Int) {
    guard [0, 5, 10, 30, 60].contains(value), intervalMinutes != value else { return }
    intervalMinutes = value
    defaults.set(value, forKey: "sync.intervalMinutes")
    timer?.cancel()
    timer = nil
    if value == 0, syncMode == .automatic {
      restart()
    } else if worker == nil {
      schedule()
    }
  }

  func syncNow() {
    startSync(.manual)
  }

  var destinationID: String {
    switch provider {
    case .googleDrive:
      return "googleDrive." + (defaults.string(forKey: "sync.googleFolderID") ?? "")
    case .webDAV: return "webDAV." + Self.digest(Data("\(address)\n\(username)".utf8))
    case .iCloud: return "iCloud"
    }
  }

  private static func digest(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  private var scope: String {
    let id = destinationID
    return id + (defaults.string(forKey: "sync.scope." + id) ?? "")
  }

  func preparePreferences() async {
    do {
      try await loadPreferences()
      if active, worker == nil, timer == nil { startSync(.automatic) }
    } catch {
      if !Task.isCancelled { lastMessage = .text(tr("无法读取或保存活动密钥，请检查钥匙串")) }
    }
  }

  private func loadPreferences() async throws {
    let id = scope
    guard let preferenceStore else { return }
    if preparedScope == id {
      try revokePendingPreferences()
      return
    }
    if localKey == nil {
      let persistent = defaults === UserDefaults.standard
      let key = try await Task.detached {
        persistent
          ? try ActivityKeys.preferencesKey(createIfMissing: true) : SymmetricKey(size: .bits256)
      }.value
      if localKey == nil { localKey = key }
    }
    try Task.checkCancellation()
    guard id == scope, let localKey else { throw CancellationError() }
    guard preparedScope != id else { return }
    try preferenceStore.selectDestination(id, key: localKey)
    preparedScope = id
    preferences = preferenceStore
    try revokePendingPreferences()
  }

  private func revokePendingPreferences() throws {
    let key = "sync.revoke." + scope
    guard defaults.bool(forKey: key), let preferences else { return }
    try preferences.cancel()
    defaults.removeObject(forKey: key)
  }

  private func preferenceRequest() {
    // 用户确认首轮设置或解决冲突时立即交换；仅手动模式不启动后续定时轮询。
    generation = UUID()
    worker?.cancel()
    timer?.cancel()
    timer = nil
    requestedSync = preferences?.wantsSync == true
    if worker == nil {
      if requestedSync {
        requestedSync = false
        startSync(.manual, activity: .automatic)
      } else {
        schedule()
      }
    }
  }

  private func synchronize(
    _ engine: ActivitySyncEngine, repository: any ActivitySyncRepository,
    mode: ActivitySyncMode, activity: ActivitySyncMode, ticket: UUID
  ) async throws {
    var activityDate: Date?
    var activityFailure: (any Error)?
    if recordsActivity {
      do {
        try await engine.run(
          store: store, device: deviceID, repository: repository, mode: activity)
        activityDate = Date()
      } catch { activityFailure = error }
    }
    try Task.checkCancellation()
    guard ticket == generation else { throw CancellationError() }
    try await loadPreferences()
    if let preferences {
      let completedActivity = activityDate
      let verified = try await engine.exchangeMetadata(device: deviceID, repository: repository) {
        documents in
        let identifier = await engine.datasetIdentifier
        return try await self.prepareMetadata(
          documents, identifier: identifier, activityDate: completedActivity, mode: mode,
          ticket: ticket)
      }
      try Task.checkCancellation()
      guard ticket == generation else { throw CancellationError() }
      if let verified { try preferences.didPublish(verified) }
    }
    if let activityFailure { throw activityFailure }
  }

  private func prepareMetadata(
    _ documents: [UUID: Data], identifier: String?, activityDate: Date?, mode: ActivitySyncMode,
    ticket: UUID
  ) async throws -> Data? {
    try Task.checkCancellation()
    guard generation == ticket, let identifier else { throw CancellationError() }
    let markerKey = "sync.marker." + destinationID
    if let previous = defaults.string(forKey: markerKey), previous != identifier {
      defaults.set("." + identifier, forKey: "sync.scope." + destinationID)
      clearPreferences()
      try await loadPreferences()
    }
    defaults.set(identifier, forKey: markerKey)
    guard generation == ticket else { throw CancellationError() }
    return try preferences?.prepare(
      documents, activitySyncedAt: activityDate,
      minimumStatusInterval: mode == .automatic ? 3_600 : 0)
  }

  private func clearPreferences() {
    preferenceStore?.clearDestination()
    preparedScope = nil
    preferences = nil
  }

  func recoveryCode() async throws -> String {
    if let key = await engine?.authenticatedKey { return ActivityKeys.recoveryCode(for: key) }
    return try await ActivityKeys.recoveryCode(for: keys.key())
  }

  func importRecoveryCode(_ code: String, confirmExisting: Bool = false) async throws {
    let imported = try ActivityKeys.decode(code)
    guard !changingKey else { throw ActivityKeys.Failure.unavailable }
    changingKey = true
    if !confirmExisting {
      do {
        let activeKey = await engine?.authenticatedKey
        let sharedKey = try sharedKeys?.read("default")
        if [activeKey, sharedKey].contains(where: { $0 != nil && $0 != imported }) {
          throw ActivityKeys.Failure.replacementRequired
        }
      } catch {
        changingKey = false
        throw error
      }
    }
    restart()
    await worker?.value
    defer {
      changingKey = false
      restart()
    }
    try await keys.replace(with: code, confirmExisting: confirmExisting)
    // 先保存本机导入意图。即使共享钥匙串暂时写入失败或应用重启，也不能回退到旧密钥。
    defaults.set(
      imported.withUnsafeBytes { ActivitySyncShard.checksum(Data($0)) },
      forKey: Self.importedKeyFingerprint)
    engine = nil
    do {
      try sharedKeys?.replace("default", imported)
    } catch {
      throw ActivityKeys.Failure.sharedKeyUnavailable
    }
  }

  func cancelManualSync() {
    guard syncMode == .manual else { return }
    defaults.set(true, forKey: "sync.revoke." + scope)
    do { try revokePendingPreferences() } catch {
      lastMessage = .text(tr("无法更改设置同步"))
    }
    worker?.cancel()
  }

  /// activity 默认跟随 mode；设置交换请求只需立即发布设置，活动数据按自动模式增量处理，
  /// 避免一次设置变更遍历全部历史月份。
  private func startSync(_ mode: ActivitySyncMode, activity: ActivitySyncMode? = nil) {
    let activityMode = activity ?? mode
    guard active, worker == nil, !changingKey,
      mode == .manual || intervalMinutes > 0
    else { return }
    timer?.cancel()
    timer = nil
    let ticket = generation
    let selected = provider
    syncMode = mode
    if mode == .manual { lastMessage = nil }
    worker = Task { [weak self] in
      guard let self else { return }
      var errorMessage: SyncMessage?
      do {
        try Task.checkCancellation()
        let engine: ActivitySyncEngine
        if let cached = self.engine {
          engine = cached
        } else {
          let key = try await keys.key()
          try Task.checkCancellation()
          let explicitlyImported =
            defaults.string(forKey: Self.importedKeyFingerprint)
            == key.withUnsafeBytes { ActivitySyncShard.checksum(Data($0)) }
          engine = ActivitySyncEngine(
            key: key, sharedKeys: sharedKeys, explicitlyImported: explicitlyImported)
          self.engine = engine
        }
        if let repository {
          try await synchronize(
            engine, repository: repository, mode: mode, activity: activityMode, ticket: ticket)
        } else {
          switch selected {
          case .iCloud, .googleDrive:
            let bookmark =
              selected == .googleDrive ? defaults.data(forKey: "activity.sync.bookmark") : nil
            guard selected != .googleDrive || bookmark != nil else {
              throw ActivitySyncFailure.folderUnavailable
            }
            let refreshed = try await ActivitySyncFolder.withFolder(bookmark) { folder in
              try await self.synchronize(
                engine, repository: folder, mode: mode, activity: activityMode, ticket: ticket)
            }
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
            try await synchronize(
              engine,
              repository: ActivitySyncWebDAV(configuration: config, password: secret), mode: mode,
              activity: activityMode, ticket: ticket)
          }
        }
      } catch is ActivityKeys.Failure {
        errorMessage = .text(tr("无法读取或保存活动密钥，请检查钥匙串"))
      } catch ActivitySyncFailure.keyPending {
        errorMessage = .text(tr("正在等待 iCloud 钥匙串同步活动密钥"))
      } catch ActivitySyncFailure.authenticationFailed {
        errorMessage = .text(tr("无法验证同步数据，请核对恢复密钥和同步位置。"))
      } catch ActivitySyncFailure.cloudUnavailable {
        errorMessage = .text(tr("暂时无法访问 iCloud 云盘，请在系统设置中确认已开启“同步此 Mac”。"))
      } catch ActivitySyncFailure.downloadRequested {
        errorMessage = .downloadRequested
      } catch let error as ActivityDAVError {
        errorMessage = error.errorDescription.map(SyncMessage.text)
      } catch {
        errorMessage = .text((error as? WebDAVError)?.errorDescription ?? tr("同步失败"))
      }
      if ticket == generation { preferences?.discardPrepared() }
      worker = nil
      syncMode = nil
      guard ticket == generation else {
        if requestedSync {
          requestedSync = false
          startSync(.manual, activity: .automatic)
        } else if lastFinished == nil {
          startSync(.automatic)
        } else {
          schedule()
        }
        return
      }
      if Task.isCancelled {
        schedule()
        return
      }
      lastFinished = .now
      // 等待 iCloud 下载属于正常进度，按原间隔重试，不计入退避。
      if case .text = errorMessage { failureStreak += 1 } else { failureStreak = 0 }
      if retrying != (errorMessage != nil) {
        if errorMessage == nil {
          logger.info("Activity synchronization recovered")
        } else {
          logger.notice("Activity synchronization pending; will retry")
        }
      }
      retrying = errorMessage != nil
      lastMessage = errorMessage ?? .text(tr("本轮同步完成"))
      schedule()
    }
  }

  func save(
    provider: ActivitySyncProvider, address: String, username: String, secret: String, folder: URL?
  ) throws {
    let previousDestination = destinationID
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
        defaults.set(
          Self.digest(Data(folder.standardizedFileURL.path.utf8)), forKey: "sync.googleFolderID")
        folderName = folder.lastPathComponent
        defaults.set(folderName, forKey: "activity.sync.folderName")
      } else if defaults.data(forKey: "activity.sync.bookmark") == nil {
        throw ActivitySyncFailure.folderUnavailable
      }
    }
    self.provider = provider
    defaults.set(provider.rawValue, forKey: "activity.sync.provider")
    engine = nil
    if previousDestination != destinationID { clearPreferences() }
    restart()
    if previousDestination != destinationID { Task { await preparePreferences() } }
  }

  /// keepingSchedule 仅用于会话恢复：未到间隔时只排定剩余时间。其他调用（开关、目标或密钥变化）
  /// 清除上次完成时间并立即同步。
  private func restart(keepingSchedule: Bool = false) {
    if !keepingSchedule {
      lastFinished = nil
      failureStreak = 0
    }
    generation = UUID()
    preferences?.discardPrepared()
    timer?.cancel()
    timer = nil
    worker?.cancel()
    requestedSync = false
    retrying = false
    lastMessage = nil
    guard worker == nil else { return }
    if lastFinished == nil { startSync(.automatic) } else { schedule() }
  }

  private func schedule() {
    timer?.cancel()
    guard intervalMinutes > 0, active else {
      timer = nil
      return
    }
    let base = intervalMinutes * 60
    // 首次失败按原间隔重试，之后每次翻倍；间隔本身超过 60 分钟时不再放宽。
    let backoff = min(base << min(max(failureStreak - 1, 0), 4), max(base, 3_600))
    let interval = Duration.seconds(backoff)
    let elapsed = lastFinished.map { $0.duration(to: .now) } ?? .zero
    let delay = max(.zero, interval - elapsed)
    // 分钟级同步无需精确到秒，放宽容差便于系统合并唤醒。
    let tolerance = Duration.seconds(intervalMinutes * 6)
    timer = Task { [weak self] in
      do { try await Task.sleep(for: delay, tolerance: tolerance) } catch { return }
      self?.startSync(.automatic)
    }
  }
}

extension ActivitySyncFolder {
  static func withFolder(
    _ bookmark: Data?, action: @Sendable (Self) async throws -> Void
  ) async throws -> Data? {
    try Task.checkCancellation()
    guard let bookmark else {
      try await action(iCloudDrive())
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
    try await action(Self(root: url))
    return renewed
  }
}
