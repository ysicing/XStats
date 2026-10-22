// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Localization
import Metrics
import Observation

/// 应用管理仅在可见时读取清单与计量。浏览任务可以取消，已确认的 brew 写操作与用户主动的检查更新独立收尾。
@MainActor @Observable
final class AppManagementController {
  enum Tab: String, CaseIterable { case apps, homebrew }
  private(set) var apps: [InstalledApp] = []
  private(set) var metadata: [String: ApplicationMetadata] = [:]
  private(set) var sizes: [String: UInt64] = [:]
  private(set) var packages: [HomebrewPackage] = []
  private(set) var packageSizes: [String: UInt64] = [:]
  private(set) var runningPaths: Set<String> = []
  /// 视图逐行只做集合查找；运行列表或清单变化时预先计算，避免计量期间反复解析符号链接和读取 Bundle。
  private(set) var runningAppIDs: Set<String> = []
  private(set) var runningPackageIDs: Set<String> = []
  private(set) var currentAppPackageIDs: Set<String> = []
  private(set) var casksByPath: [String: HomebrewPackage] = [:]
  /// 展示来源可从快照恢复；卸载路由始终依赖本次实际读取的 casksByPath。
  private(set) var homebrewAppPaths: Set<String> = []
  private(set) var isLoadingApps = false
  private(set) var isMeasuringApps = false
  private(set) var isRefreshingApps = false
  private(set) var isLoadingBrew = false
  private(set) var isCheckingUpdates = false
  private(set) var isCheckingAppStore = false
  private(set) var appStoreUpdates: [String: AppStoreUpdates.Entry] = [:]
  @ObservationIgnored private var storeTask: Task<Void, Never>?
  @ObservationIgnored private var storeGeneration = UUID()
  @ObservationIgnored private var storeCache: [String: StoreCheck] = [:]
  @ObservationIgnored private var storeHandoffPending = false
  @ObservationIgnored private var activationObserver: NSObjectProtocol?
  @ObservationIgnored private let checkStore:
    @Sendable ([AppStoreUpdates.Candidate], String) async throws -> AppStoreUpdates.Report
  @ObservationIgnored private let openStore: @MainActor (URL) -> Bool
  private struct StoreCheck {
    let candidate: AppStoreUpdates.Candidate
    let entry: AppStoreUpdates.Entry?
    let checkedAt: Date
    let region: String
  }
  static let storeResultLifetime: TimeInterval = 3600
  static let storeMissingRetryDelay: TimeInterval = 600
  /// 尚无可用清单且最近一次读取失败：普通卸载降级可用，页面提示无法识别 Homebrew 来源。
  private(set) var brewInventoryFailed = false
  private(set) var operation: HomebrewManagement.Action?
  private(set) var operationPackage: HomebrewPackage?
  let homebrewOperations: HomebrewOperationState
  var error: String?
  struct Completion: Identifiable {
    let id = UUID()
    let action: HomebrewManagement.Action
    let packageName: String
    var text: String {
      action == .upgrade ? tr("已更新“\(packageName)”") : tr("已卸载“\(packageName)”")
    }
  }
  private(set) var completion: Completion?
  private(set) var visible = false
  private var enabled = true
  private var paused = false
  private var tab: Tab = .apps
  @ObservationIgnored private var appTask: Task<Void, Never>?
  @ObservationIgnored private var brewTask: Task<Void, Never>?
  @ObservationIgnored private var operationTask: Task<Void, Never>?
  @ObservationIgnored private var updateTask: Task<Void, Never>?
  @ObservationIgnored private var appGeneration = UUID()
  @ObservationIgnored private var brewGeneration = UUID()
  @ObservationIgnored private var measuredApps: Set<String> = []
  @ObservationIgnored private var measuredPackages: Set<String> = []
  @ObservationIgnored private var appReadDate: Date?
  @ObservationIgnored private var metadataReadDates: [String: Date] = [:]
  static let appInventoryLifetime: TimeInterval = 30
  static let appMetadataLifetime: TimeInterval = 60
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private var appFingerprints: [String: AppInventoryCache.Fingerprint] = [:]
  @ObservationIgnored private var measuredAppDates: [String: Date] = [:]
  private var didLoadCache = false
  @ObservationIgnored private var hasCachedAppInventory = false
  @ObservationIgnored private let cacheURL: URL?
  @ObservationIgnored private var cacheWriteFailed = false
  @ObservationIgnored private var brewReadDate: Date?
  /// 清单读取失败的时间；退避期内自动读取不再重跑 brew，用户显式刷新可绕过。
  @ObservationIgnored private var brewFailureDate: Date?
  static let brewInventoryLifetime: TimeInterval = 300
  static let brewRetryDelay: TimeInterval = 600
  @ObservationIgnored private var runningObservation: NSKeyValueObservation?
  @ObservationIgnored private let listApps: @Sendable () throws -> [InstalledApp]
  @ObservationIgnored private let inspectApp: @Sendable (InstalledApp) -> ApplicationMetadata
  @ObservationIgnored private let measureSize: @Sendable (URL) throws -> UInt64
  @ObservationIgnored private let listPackages: @Sendable () async throws -> [HomebrewPackage]
  @ObservationIgnored private let updateIndex: @Sendable () async throws -> Void
  @ObservationIgnored private let performAction:
    @Sendable (HomebrewManagement.Action, HomebrewPackage) async throws -> Void
  let brewAvailable: Bool
  var isReading: Bool { appTask != nil || brewTask != nil }
  /// Homebrew 来源已确定：读取成功，或读取失败后降级为普通卸载（不因 brew 故障禁用全部卸载）。
  var hasBrewInventory: Bool { !brewAvailable || brewReadDate != nil || brewInventoryFailed }
  var hasAppInventory: Bool { appReadDate != nil || hasCachedAppInventory }
  var isRestoringAppCache: Bool { cacheURL != nil && !didLoadCache }

  func isCurrentApp(_ package: HomebrewPackage) -> Bool {
    currentAppPackageIDs.contains(package.id)
  }

  private static func containsCurrentApp(_ package: HomebrewPackage) -> Bool {
    let current = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    let identifier = Bundle.main.bundleIdentifier
    return package.applicationURLs.contains { url in
      if url.resolvingSymlinksInPath().path == current { return true }
      guard let identifier, let candidate = Bundle(url: url)?.bundleIdentifier else { return false }
      return candidate.caseInsensitiveCompare(identifier) == .orderedSame
    }
  }

  /// 列表里的路径可能是 /Applications 下的符号链接，系统报告的则常是 Caskroom 真实目录。
  func isRunning(_ url: URL) -> Bool {
    if runningPaths.contains(url.path) || runningPaths.contains(url.standardizedFileURL.path) {
      return true
    }
    return runningPaths.contains(url.resolvingSymlinksInPath().path)
  }

  /// 操作前读取真实运行状态，避免清单刷新与确认之间应用刚好启动。
  func isRunning(_ package: HomebrewPackage) -> Bool {
    if package.applicationURLs.contains(where: { isRunning($0) }) { return true }
    let targets = Set(package.applicationURLs.flatMap { Self.bundlePathIdentities($0) })
    return NSWorkspace.shared.runningApplications.contains { application in
      guard let url = application.bundleURL else { return false }
      return !targets.isDisjoint(with: Self.bundlePathIdentities(url))
    }
  }

  private static func bundlePathIdentities(_ url: URL) -> Set<String> {
    [url.path, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
  }

  init(
    listApps: @escaping @Sendable () throws -> [InstalledApp] = {
      try AppUninstaller.scanInstalledApps()
    },
    inspectApp: @escaping @Sendable (InstalledApp) -> ApplicationMetadata = {
      ApplicationMetadata.read($0)
    },
    measureSize: @escaping @Sendable (URL) throws -> UInt64 = {
      try CleanEngine.bundleAllocatedSize(of: $0)
    },
    brewAvailable: Bool = HomebrewManagement.isAvailable,
    listPackages: @escaping @Sendable () async throws -> [HomebrewPackage] = {
      try await HomebrewManagement.inventory()
    },
    updateIndex: @escaping @Sendable () async throws -> Void = {
      try await HomebrewManagement.checkUpdates()
    },
    performAction:
      @escaping @Sendable (HomebrewManagement.Action, HomebrewPackage) async throws -> Void = {
        try await HomebrewManagement.perform($0, package: $1)
      },
    checkStore:
      @escaping @Sendable ([AppStoreUpdates.Candidate], String) async throws ->
      AppStoreUpdates.Report = { try await AppStoreUpdates.check($0, country: $1) },
    openStore: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
    cacheURL: URL? = nil, now: @escaping @Sendable () -> Date = { Date() },
    homebrewOperations: HomebrewOperationState = HomebrewOperationState()
  ) {
    self.listApps = listApps
    self.inspectApp = inspectApp
    self.measureSize = measureSize
    self.brewAvailable = brewAvailable
    self.listPackages = listPackages
    self.updateIndex = updateIndex
    self.performAction = performAction
    self.checkStore = checkStore
    self.openStore = openStore
    self.cacheURL = cacheURL
    self.now = now
    self.homebrewOperations = homebrewOperations
  }

  func setEnabled(_ value: Bool) {
    enabled = value
    if !value {
      setVisible(false)
      apps = []
      metadata = [:]
      sizes = [:]
      measuredApps = []
      packages = []
      packageSizes = [:]
      measuredPackages = []
      casksByPath = [:]
      homebrewAppPaths = []
      storeCache = [:]
      appStoreUpdates = [:]
      storeHandoffPending = false
      appReadDate = nil
      brewReadDate = nil
      brewFailureDate = nil
      brewInventoryFailed = false
      updatePackageIdentities()
      appFingerprints = [:]
      measuredAppDates = [:]
      metadataReadDates = [:]
      didLoadCache = false
      hasCachedAppInventory = false
    }
  }

  func setPaused(_ value: Bool) {
    paused = value
    if value {
      completion = nil
      cancelReading()
    } else if visible {
      resume()
    }
  }

  func setVisible(_ value: Bool, tab: Tab? = nil) {
    if let tab { self.tab = tab }
    visible = value && enabled
    if !visible { completion = nil }
    if visible && !paused { resume() } else { cancelReading() }
  }

  func selectTab(_ value: Tab) {
    guard tab != value else { return }
    tab = value
    completion = nil
    cancelReading()
    if visible && !paused { resume() }
  }

  private func resume() {
    guard operation == nil else { return }
    refreshAfterStoreHandoff()
    updateRunningPaths()
    if activationObserver == nil {
      activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard
          let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication,
          application.processIdentifier == ProcessInfo.processInfo.processIdentifier
        else { return }
        Task { @MainActor [weak self] in
          guard let self, self.visible, !self.paused, self.storeHandoffPending else { return }
          self.refreshAfterStoreHandoff()
          self.resume()
        }
      }
    }
    if runningObservation == nil {
      runningObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
        Task { @MainActor [weak self] in
          guard let self, self.visible, !self.paused else { return }
          self.updateRunningPaths()
        }
      }
    }
    if tab == .apps {
      readApps(force: false)
      checkAppStoreUpdates()
    }
    readBrew(force: false)
  }

  private func updateRunningPaths() {
    var paths = Set<String>()
    for application in NSWorkspace.shared.runningApplications {
      guard let url = application.bundleURL else { continue }
      paths.formUnion(Self.bundlePathIdentities(url))
    }
    guard runningPaths != paths else { return }
    runningPaths = paths
    updateRunningIDs()
  }

  private func updateRunningIDs() {
    let apps = Set(apps.filter { isRunning($0.url) }.map(\.id))
    let packages = Set(packages.filter { $0.applicationURLs.contains { isRunning($0) } }.map(\.id))
    if runningAppIDs != apps { runningAppIDs = apps }
    if runningPackageIDs != packages { runningPackageIDs = packages }
  }

  private func updatePackageIdentities() {
    let current = Set(packages.filter(Self.containsCurrentApp).map(\.id))
    if currentAppPackageIDs != current { currentAppPackageIDs = current }
    updateRunningIDs()
  }

  func refresh() {
    guard visible, !paused, operation == nil else { return }
    cancelReading()
    error = nil
    completion = nil
    if tab == .apps { readApps(force: true) }
    readBrew(force: true)
    resume()
  }

  /// 卸载等已知变更后重新核对清单；与手动刷新不同，未变化的应用沿用指纹与 24 小时体积缓存。
  func reloadInventory() {
    // 隐藏或暂停期间也必须记住已知变更，恢复时绕过清单缓存；只读扫描仍按可见性启动。
    appReadDate = nil
    guard visible, !paused, operation == nil else { return }
    cancelReading()
    resume()
  }

  private func cancelReading() {
    appGeneration = UUID()
    brewGeneration = UUID()
    appTask?.cancel()
    brewTask?.cancel()
    appTask = nil
    brewTask = nil
    isLoadingApps = false
    isMeasuringApps = false
    isRefreshingApps = false
    isLoadingBrew = false
    runningObservation = nil
    storeGeneration = UUID()
    storeTask?.cancel()
    storeTask = nil
    isCheckingAppStore = false
    if let activationObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
    }
    activationObserver = nil
  }

  private func readApps(force: Bool) {
    guard visible, !paused, enabled, appTask == nil else { return }
    let date = now()
    // 短时间切页复用清单；已知安装变化清空 appReadDate，手动刷新始终绕过缓存。
    let needsInventory =
      force
      || (appReadDate.map {
        !(0..<Self.appInventoryLifetime).contains(date.timeIntervalSince($0))
      } ?? true)
    let metadataExpired = apps.contains { app in
      guard metadata[app.id] != nil, let readAt = metadataReadDates[app.id] else { return true }
      return !(0..<Self.appMetadataLifetime).contains(date.timeIntervalSince(readAt))
    }
    if !needsInventory, !metadataExpired, apps.allSatisfy({ measuredApps.contains($0.id) }) {
      return
    }
    let generation = UUID()
    appGeneration = generation
    isLoadingApps = !hasAppInventory || force
    isRefreshingApps = force
    appTask = Task { [weak self] in
      defer {
        if let self, self.appGeneration == generation {
          self.appTask = nil
          self.isLoadingApps = false
          self.isMeasuringApps = false
          self.isRefreshingApps = false
        }
      }
      guard let self else { return }
      do {
        try await self.loadCachedAppInventoryIfNeeded(generation: generation, force: force)
        if needsInventory { try await self.refreshInventory(force: force, generation: generation) }
        try await self.refreshStaleMetadata(generation: generation)
        try await self.measureUnsizedApps(generation: generation)
      } catch {
        guard !Task.isCancelled, self.appGeneration == generation else { return }
        self.error = tr("无法读取应用列表，请重新扫描")
        Log.app.error(
          "Application inventory failed: \(String(describing: error).prefix(500), privacy: .private)"
        )
      }
    }
  }

  /// 阶段一：铺一份上次落盘的清单，界面立刻有内容可看，后续阶段再核对最新状态。
  private func loadCachedAppInventoryIfNeeded(generation: UUID, force: Bool) async throws {
    guard !didLoadCache, let url = cacheURL else { return }
    let cached: AppInventoryCache?
    do {
      cached = try await Self.read { try AppInventoryCache.load(from: url) }
    } catch is CancellationError { throw CancellationError() } catch {
      cached = nil
      Log.app.info(
        "Application display cache ignored: \(String(describing: error).prefix(500), privacy: .private)"
      )
    }
    try Task.checkCancellation()
    guard appGeneration == generation else { return }
    didLoadCache = true
    guard let cached else { return }
    apps = cached.entries.map(\.app)
    updateRunningIDs()
    if brewReadDate == nil {
      homebrewAppPaths = Set(cached.entries.filter { $0.isHomebrew == true }.map(\.path))
    }
    for entry in cached.entries {
      metadata[entry.path] = entry.metadata
      sizes[entry.path] = entry.size
      appFingerprints[entry.path] = entry.fingerprint
      measuredAppDates[entry.path] = entry.measuredAt
    }
    measuredApps = Set(
      cached.entries.filter {
        guard let date = $0.measuredAt else { return false }
        return (0...AppInventoryCache.measurementLifetime).contains(Date().timeIntervalSince(date))
      }.map(\.path))
    // 展示快照不能充当本次进程已核对清单的标记；中途离开后仍需重新核对。
    hasCachedAppInventory = true
    if !force { isLoadingApps = false }
  }

  /// 阶段二：核对远端最新清单，与已有指纹比对出哪些 app 不需要重新计量。
  private func refreshInventory(force: Bool, generation: UUID) async throws {
    let list = listApps
    let inventory = try await Self.read {
      let apps = try list()
      guard apps.count <= AppInventoryCache.maximumEntries else {
        throw HomebrewManagement.InventoryError.invalidOutput
      }
      var fingerprints: [String: AppInventoryCache.Fingerprint] = [:]
      for app in apps {
        try Task.checkCancellation()
        fingerprints[app.id] = AppInventoryCache.Fingerprint.read(app)
      }
      return (apps, fingerprints)
    }
    try Task.checkCancellation()
    guard appGeneration == generation else { return }
    let (newApps, fingerprints) = inventory
    let previous = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    let unchangedContents = Set(
      newApps.filter {
        !force && previous[$0.id] == $0 && appFingerprints[$0.id] == fingerprints[$0.id]
      }.map(\.id))
    let unchanged = Set(
      newApps.filter {
        guard unchangedContents.contains($0.id), let date = measuredAppDates[$0.id] else {
          return false
        }
        return (0...AppInventoryCache.measurementLifetime).contains(now().timeIntervalSince(date))
      }.map(\.id))
    apps = newApps
    appReadDate = now()
    updateRunningIDs()
    let ids = Set(newApps.map(\.id))
    metadata = metadata.filter { unchangedContents.contains($0.key) }
    metadataReadDates = metadataReadDates.filter { unchangedContents.contains($0.key) }
    // 保留旧显示值，实际测量只重做新增、变化或超过一天的应用；手动扫描重新计量全部。
    sizes = sizes.filter { ids.contains($0.key) }
    measuredApps.formIntersection(unchanged)
    measuredAppDates = measuredAppDates.filter { unchanged.contains($0.key) }
    appFingerprints = fingerprints
  }

  /// 阶段三：lastOpened 等不受文件指纹约束的元数据，按独立期限过期刷新。
  private func refreshStaleMetadata(generation: UUID) async throws {
    // lastOpened 不受文件指纹约束，独立按期限刷新；仅在页面被访问时检查，不增加定时器。
    let pendingMetadata = apps.filter { app in
      guard metadata[app.id] != nil, let date = metadataReadDates[app.id] else { return true }
      return !(0..<Self.appMetadataLifetime).contains(now().timeIntervalSince(date))
    }
    guard !pendingMetadata.isEmpty else { return }
    let inspect = inspectApp
    let details = try await Self.read {
      var result: [String: ApplicationMetadata] = [:]
      for app in pendingMetadata {
        try Task.checkCancellation()
        result[app.id] = inspect(app)
      }
      return result
    }
    try Task.checkCancellation()
    guard appGeneration == generation else { return }
    metadata.merge(details) { _, new in new }
    for app in pendingMetadata { metadataReadDates[app.id] = now() }
  }

  /// 阶段四：刷新 App Store 更新状态，并分批测量尚未计量的体积。
  private func measureUnsizedApps(generation: UUID) async throws {
    isLoadingApps = false
    checkAppStoreUpdates()
    isMeasuringApps = apps.contains { !measuredApps.contains($0.id) }
    if isMeasuringApps {
      await saveAppCache()
      try Task.checkCancellation()
      guard appGeneration == generation else { return }
    }
    let measure = measureSize
    let pendingSizes = apps.filter { !measuredApps.contains($0.id) }
    var next = 0
    while next < pendingSizes.count {
      let start = next
      // 在后台按项数和时间分批，避免每项体积都唤醒主线程并重排表格。
      let batch = try await Self.read {
        var results: [(String, UInt64?)] = []
        let deadline = ContinuousClock.now + .milliseconds(100)
        for app in pendingSizes[start..<min(start + 20, pendingSizes.count)] {
          try Task.checkCancellation()
          let size: UInt64?
          do { size = try measure(app.url) } catch is CancellationError {
            throw CancellationError()
          } catch { size = nil }
          try Task.checkCancellation()
          results.append((app.id, size))
          if ContinuousClock.now >= deadline { break }
        }
        return results
      }
      try Task.checkCancellation()
      guard appGeneration == generation else { return }
      var sizes = self.sizes
      for (id, size) in batch {
        sizes[id] = size
        measuredApps.insert(id)
        measuredAppDates[id] = now()
      }
      if self.sizes != sizes { self.sizes = sizes }
      next += batch.count
    }
    await saveAppCache()
  }

  private func saveAppCache() async {
    guard let url = cacheURL else { return }
    let snapshot = AppInventoryCache(
      entries: apps.map {
        AppInventoryCache.Entry(
          app: $0, metadata: metadata[$0.id], size: sizes[$0.id],
          measuredAt: measuredAppDates[$0.id], fingerprint: appFingerprints[$0.id],
          isHomebrew: homebrewAppPaths.contains($0.id))
      })
    do {
      try await Self.read { try snapshot.save(to: url) }
      if cacheWriteFailed { Log.app.notice("Application display cache writes recovered") }
      cacheWriteFailed = false
    } catch is CancellationError { /* 页面关闭时不再写入快照。 */  } catch {
      if !cacheWriteFailed {
        Log.app.error(
          "Application display cache write failed: \(String(describing: error).prefix(500), privacy: .private)"
        )
      }
      cacheWriteFailed = true
    }
  }

  /// 商店结果只用于展示和外部跳转；不参与卸载路由或安装授权。
  private func storeCandidate(for app: InstalledApp) -> AppStoreUpdates.Candidate? {
    guard metadata[app.id]?.isAppStore == true, metadata[app.id]?.architecture != .iOS,
      let version = app.version, !version.isEmpty,
      !app.bundleIdentifier.isEmpty, !homebrewAppPaths.contains(app.id)
    else { return nil }
    return .init(
      bundleIdentifier: app.bundleIdentifier, version: version,
      storeID: metadata[app.id]?.appStoreID)
  }

  func checkAppStoreUpdates(force: Bool = false) {
    guard enabled, visible, !paused, tab == .apps, appReadDate != nil, !isLoadingApps,
      operation == nil
    else { return }
    let candidates = Dictionary(
      uniqueKeysWithValues: apps.compactMap { app in
        storeCandidate(for: app).map { (app.id, $0) }
      })
    let region = Locale.current.region?.identifier ?? "US"
    storeCache = storeCache.filter {
      candidates[$0.key] == $0.value.candidate && $0.value.region == region
    }
    let system = ProcessInfo.processInfo.operatingSystemVersion
    let systemVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
    let date = now()
    appStoreUpdates = storeCache.compactMapValues { check in
      let age = date.timeIntervalSince(check.checkedAt)
      guard (0..<Self.storeResultLifetime).contains(age) else { return nil }
      return check.entry?.update(for: check.candidate, systemVersion: systemVersion)
    }
    guard storeTask == nil else { return }
    let pending = candidates.filter { id, candidate in
      guard !force, let check = storeCache[id], check.candidate == candidate else { return true }
      let lifetime = check.entry == nil ? Self.storeMissingRetryDelay : Self.storeResultLifetime
      return !(0..<lifetime).contains(date.timeIntervalSince(check.checkedAt))
    }
    guard !pending.isEmpty else { return }
    let generation = UUID()
    storeGeneration = generation
    let query = checkStore
    isCheckingAppStore = true
    storeTask = Task { [weak self] in
      defer {
        if let self, self.storeGeneration == generation {
          self.storeTask = nil
          self.isCheckingAppStore = false
        }
      }
      do {
        let report = try await query(Array(pending.values), region)
        try Task.checkCancellation()
        guard let self, self.storeGeneration == generation else { return }
        let current = Dictionary(uniqueKeysWithValues: self.apps.map { ($0.id, $0) })
        for (id, candidate) in pending {
          guard let app = current[id], self.storeCandidate(for: app) == candidate else { continue }
          let entry = report.entries[candidate.bundleIdentifier]
          self.storeCache[id] = StoreCheck(
            candidate: candidate, entry: entry, checkedAt: self.now(), region: region)
          self.appStoreUpdates[id] = entry?.update(for: candidate, systemVersion: systemVersion)
        }
        if report.failedRequests > 0 {
          Log.app.error(
            "App Store version lookup incomplete: \(report.failedRequests) failed requests")
        } else {
          Log.app.info(
            "App Store version lookup completed: \(report.entries.count) catalog entries")
        }
      } catch {
        guard let self, !Task.isCancelled, self.storeGeneration == generation else { return }
        for (id, candidate) in pending {
          self.storeCache[id] = StoreCheck(
            candidate: candidate, entry: nil, checkedAt: self.now(), region: region)
          self.appStoreUpdates[id] = nil
        }
        Log.app.error(
          "App Store version lookup failed: \(String(describing: error).prefix(500), privacy: .private)"
        )
      }
    }
  }

  func openAppStoreUpdate(for app: InstalledApp) {
    let system = ProcessInfo.processInfo.operatingSystemVersion
    let systemVersion = "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
    guard visible, enabled, !paused, operation == nil,
      let current = apps.first(where: { $0.id == app.id }), current == app,
      let candidate = storeCandidate(for: current), let entry = appStoreUpdates[app.id],
      entry.update(for: candidate, systemVersion: systemVersion) != nil
    else { return }
    if openStore(entry.storeURL) {
      storeHandoffPending = true
      Log.app.notice("App Store update handed off")
    } else {
      error = tr("无法打开 App Store，请手动打开后更新")
      Log.app.error("App Store update handoff failed")
    }
  }

  private func refreshAfterStoreHandoff() {
    guard storeHandoffPending, tab == .apps else { return }
    storeHandoffPending = false
    cancelReading()
    appReadDate = nil
    storeCache = [:]
    appStoreUpdates = [:]
  }

  /// `force` 仅用于用户手动刷新：重新读取清单并重新计量全部软件包。
  /// 自动读取在清单过期时重新读取，只重测内容有变化的包；失败后按退避间隔重试。
  private func readBrew(force: Bool) {
    guard visible, !paused, enabled, brewAvailable, brewTask == nil, updateTask == nil,
      operation == nil
    else { return }
    let stale =
      brewReadDate.map { Date().timeIntervalSince($0) > Self.brewInventoryLifetime } ?? true
    let retryBlocked =
      brewFailureDate.map { Date().timeIntervalSince($0) < Self.brewRetryDelay } ?? false
    let needsInventory = force || (stale && !retryBlocked)
    if !needsInventory,
      brewReadDate == nil || tab == .apps
        || packages.allSatisfy({ measuredPackages.contains($0.id) })
    {
      return
    }
    let generation = UUID()
    brewGeneration = generation
    let list = listPackages
    let measure = measureSize
    isLoadingBrew = needsInventory
    brewTask = Task { [weak self] in
      defer {
        if let self, self.brewGeneration == generation {
          self.brewTask = nil
          self.isLoadingBrew = false
        }
      }
      do {
        if needsInventory {
          let packages = try await list()
          try Task.checkCancellation()
          guard let self, self.brewGeneration == generation else { return }
          let previous = Dictionary(
            self.packages.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
          self.packages = packages
          self.brewReadDate = Date()
          self.isLoadingBrew = false
          if self.brewFailureDate != nil { Log.app.notice("Homebrew inventory recovered") }
          self.brewFailureDate = nil
          self.brewInventoryFailed = false
          let ids = Set(packages.map(\.id))
          // 手动刷新重新计量全部；其余情况只重测新增或内容变化（版本、产物等）的包。
          // 描述、安装原因与可用更新等元数据变化不触发目录重新计量。
          let unchanged = Set(
            packages.filter { package in
              guard !force, let old = previous[package.id] else { return false }
              return old.installedVersions == package.installedVersions
                && old.installationURLs == package.installationURLs
                && old.installedAt == package.installedAt
            }.map(\.id))
          self.packageSizes = force ? [:] : self.packageSizes.filter { ids.contains($0.key) }
          self.measuredPackages.formIntersection(unchanged)
          self.casksByPath = [:]
          for package in packages where package.kind == .cask {
            for url in package.applicationURLs {
              self.casksByPath[url.standardizedFileURL.path] = package
            }
          }
          self.homebrewAppPaths = Set(self.casksByPath.keys)
          self.updatePackageIdentities()
          if self.appTask == nil, self.appReadDate != nil { await self.saveAppCache() }
          try Task.checkCancellation()
          guard self.brewGeneration == generation else { return }
        }
        guard let self, self.tab == .homebrew else { return }
        for package in self.packages where !self.measuredPackages.contains(package.id) {
          do {
            let size = try await Self.read {
              var total: UInt64 = 0
              for url in package.installationURLs {
                try Task.checkCancellation()
                total += try measure(url)
              }
              return total
            }
            try Task.checkCancellation()
            guard self.brewGeneration == generation else { return }
            if !package.installationURLs.isEmpty { self.packageSizes[package.id] = size }
          } catch is CancellationError { throw CancellationError() } catch
          { /* 部分 Cask 没有 app 产物或本体不可读，不将其误报成完整清单失败。 */  }
          try Task.checkCancellation()
          guard self.brewGeneration == generation else { return }
          self.measuredPackages.insert(package.id)
        }
      } catch {
        guard let self, !Task.isCancelled, self.brewGeneration == generation else { return }
        // 只有清单读取会走到这里（计量失败逐包吞掉）。记录失败时间用于退避，
        // 尚无清单时降级：清空路由表，普通卸载可用并提示无法识别 Homebrew 来源。
        let firstFailure = self.brewFailureDate == nil
        self.brewFailureDate = Date()
        if self.brewReadDate == nil {
          // 来源未知时不保留旧包列表与来源标记，避免界面显示 Homebrew 却走普通卸载。
          self.brewInventoryFailed = true
          self.casksByPath = [:]
          self.homebrewAppPaths = []
          self.packages = []
          self.updatePackageIdentities()
        }
        self.error = tr("Homebrew 操作失败，请在终端检查后重试")
        if firstFailure {
          Log.app.error(
            "Homebrew inventory failed: \(String(describing: error).prefix(500), privacy: .private)"
          )
        }
      }
    }
  }

  /// 用户主动发起的 brew update 与写操作一样独立收尾，不随切换标签、关闭窗口或锁屏取消；App 退出时允许终止。
  func checkBrewUpdates() {
    guard visible, !paused, enabled, brewAvailable, operation == nil, updateTask == nil else {
      return
    }
    let homebrewOperations = homebrewOperations
    guard homebrewOperations.begin() else { return }
    brewGeneration = UUID()
    brewTask?.cancel()
    brewTask = nil
    isLoadingBrew = false
    error = nil
    completion = nil
    isCheckingUpdates = true
    let update = updateIndex
    updateTask = Task { [weak self] in
      defer { homebrewOperations.finish() }
      var succeeded = false
      do {
        try await update()
        succeeded = true
        Log.app.notice("Homebrew update index refreshed")
      } catch {
        self?.error = tr("Homebrew 操作失败，请在终端检查后重试")
        Log.app.error(
          "Homebrew update failed: \(String(describing: error).prefix(500), privacy: .private)")
      }
      guard let self else { return }
      self.updateTask = nil
      self.isCheckingUpdates = false
      guard self.enabled else { return }
      guard succeeded else {
        // 检查更新期间可能取消了清单读取；失败后仍需补读，避免卸载入口停留在不可用状态。
        if self.visible, !self.paused { self.readBrew(force: false) }
        return
      }
      // 远端索引已更新：标记清单过期，由 Homebrew 重新判定 outdated；保留路由表直至新清单到达。
      if self.brewReadDate != nil { self.brewReadDate = .distantPast }
      self.brewFailureDate = nil
      if self.visible, !self.paused { self.readBrew(force: false) }
    }
  }

  /// 原生截图使用演示清单，不扫描本机或调用 Homebrew。
  func showPreview(
    apps: [InstalledApp], metadata: [String: ApplicationMetadata], sizes: [String: UInt64],
    packages: [HomebrewPackage], storeUpdates: [String: AppStoreUpdates.Entry] = [:]
  ) {
    cancelReading()
    didLoadCache = true
    self.apps = apps
    self.metadata = metadata
    self.sizes = sizes
    self.packages = packages
    appStoreUpdates = storeUpdates
    packageSizes = Dictionary(
      uniqueKeysWithValues: packages.enumerated().map {
        ($0.element.id, UInt64(($0.offset + 1) * 45_000_000))
      })
    casksByPath = [:]
    for package in packages {
      for url in package.applicationURLs { casksByPath[url.path] = package }
    }
    homebrewAppPaths = Set(casksByPath.keys)
    runningPaths = Set(apps.prefix(2).flatMap { Self.bundlePathIdentities($0.url) })
    updatePackageIdentities()
    measuredApps = Set(apps.map(\.id))
    measuredPackages = Set(packages.map(\.id))
    appReadDate = Date()
    brewReadDate = Date()
  }

  func perform(_ action: HomebrewManagement.Action, package: HomebrewPackage) {
    guard enabled, visible, !paused, operation == nil, !isCheckingUpdates,
      packages.contains(package), !isCurrentApp(package),
      !(action == .upgrade && (!package.outdated || package.pinned))
    else { return }
    guard !isRunning(package) else {
      error = tr("应用正在运行，请先退出")
      return
    }
    let homebrewOperations = homebrewOperations
    guard homebrewOperations.begin() else { return }
    cancelReading()
    operation = action
    operationPackage = package
    error = nil
    completion = nil
    let perform = performAction
    // 已确认的安装／卸载不能因为切换标签或关闭窗口被中途打断。
    operationTask = Task { [weak self] in
      defer { homebrewOperations.finish() }
      do {
        try await perform(action, package)
        // 离开页面后不补播过时的成功反馈；写操作本身仍然正常收尾。
        if let self, self.visible, !self.paused {
          self.completion = Completion(action: action, packageName: package.displayName)
        }
        Log.app.notice("Homebrew operation completed action=\(action.rawValue, privacy: .public)")
      } catch ToolExecutionError.timedOut {
        // 超时只停止等待，brew 可能仍在后台执行，不能报告为失败或成功。
        self?.error = tr("Homebrew 操作超过 1 小时仍未结束，请在终端核对其状态")
        Log.app.error("Homebrew operation timed out action=\(action.rawValue, privacy: .public)")
      } catch ToolExecutionError.failed(_, let status, let output) {
        self?.error = tr("Homebrew 操作失败，请在终端检查后重试")
        // 写操作输出不落盘；退出码公开，启动失败等已有诊断保持有界且私有。
        Log.app.error(
          "Homebrew operation failed action=\(action.rawValue, privacy: .public) status=\(status, privacy: .public) detail=\(output.prefix(500), privacy: .private); rerun the brew command in Terminal to inspect its output"
        )
      } catch {
        self?.error = tr("Homebrew 操作失败，请在终端检查后重试")
        Log.app.error(
          "Homebrew operation failed action=\(action.rawValue, privacy: .public) error=\(String(describing: error).prefix(500), privacy: .private)"
        )
      }
      guard let self else { return }
      self.operation = nil
      self.operationPackage = nil
      self.operationTask = nil
      // 只让相关数据失效：清单重新读取后，依赖等内容变化的包按差异重测；
      // 该 Cask 的应用丢弃计量时间以便重测，其余应用沿用指纹与体积缓存。
      // 已知安装状态改变，必须立即重读清单，不受此前读取失败的退避限制。
      self.brewReadDate = nil
      self.brewFailureDate = nil
      self.casksByPath = [:]
      self.appReadDate = nil
      self.measuredPackages.remove(package.id)
      for url in package.applicationURLs {
        let id = url.standardizedFileURL.path
        self.measuredApps.remove(id)
        self.measuredAppDates.removeValue(forKey: id)
        self.metadataReadDates.removeValue(forKey: id)
      }
      if self.visible, !self.paused, self.enabled { self.resume() }
    }
  }

  func showUninstallCompletion(for app: InstalledApp) {
    // 窗口隐藏或离开页面后不补播过时的成功提示。
    guard visible, !paused else { return }
    completion = Completion(action: .uninstall, packageName: app.name)
  }

  func dismissCompletion(_ id: UUID) {
    // 上一条提示的延迟任务不能清除后来完成的新操作。
    guard completion?.id == id else { return }
    completion = nil
  }

  /// 带取消传播的 utility 遍历，避免为每个包创建常驻任务。
  private static func read<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws
    -> T
  {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask(priority: .utility) {
        try Task.checkCancellation()
        return try work()
      }
      guard let value = try await group.next() else { throw CancellationError() }
      return value
    }
  }
}
