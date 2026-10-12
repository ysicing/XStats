// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Localization
import Metrics
import Observation

/// 应用管理仅在可见时读取清单与计量。浏览任务可以取消，已确认的 brew 写操作独立收尾。
@MainActor @Observable
final class AppManagementController {
    enum Tab: String, CaseIterable { case apps, homebrew }
    private(set) var apps: [InstalledApp] = []
    private(set) var metadata: [String: ApplicationMetadata] = [:]
    private(set) var sizes: [String: UInt64] = [:]
    private(set) var packages: [HomebrewPackage] = []
    private(set) var packageSizes: [String: UInt64] = [:]
    private(set) var runningPaths: Set<String> = []
    private(set) var casksByPath: [String: HomebrewPackage] = [:]
    /// 展示来源可从快照恢复；卸载路由始终依赖本次实际读取的 casksByPath。
    private(set) var homebrewAppPaths: Set<String> = []
    private(set) var isLoadingApps = false
    private(set) var isMeasuringApps = false
    private(set) var isRefreshingApps = false
    private(set) var isLoadingBrew = false
    private(set) var isCheckingUpdates = false
    private(set) var operation: HomebrewManagement.Action?
    private(set) var operationPackage: HomebrewPackage?
    var error: String?
    var message: String?
    private(set) var visible = false
    private var enabled = true
    private var paused = false
    private var tab: Tab = .apps
    @ObservationIgnored private var appTask: Task<Void, Never>?
    @ObservationIgnored private var brewTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var appGeneration = UUID()
    @ObservationIgnored private var brewGeneration = UUID()
    @ObservationIgnored private var measuredApps: Set<String> = []
    @ObservationIgnored private var measuredPackages: Set<String> = []
    @ObservationIgnored private var appReadDate: Date?
    @ObservationIgnored private var appFingerprints: [String: AppInventoryCache.Fingerprint] = [:]
    @ObservationIgnored private var measuredAppDates: [String: Date] = [:]
    private var didLoadCache = false
    @ObservationIgnored private var hasCachedAppInventory = false
    @ObservationIgnored private let cacheURL: URL?
    @ObservationIgnored private var cacheWriteFailed = false
    @ObservationIgnored private var brewReadDate: Date?
    @ObservationIgnored private var runningObservation: NSKeyValueObservation?
    @ObservationIgnored private let listApps: @Sendable () throws -> [InstalledApp]
    @ObservationIgnored private let inspectApp: @Sendable (InstalledApp) -> ApplicationMetadata
    @ObservationIgnored private let measureSize: @Sendable (URL) throws -> UInt64
    @ObservationIgnored private let listPackages: @Sendable () async throws -> [HomebrewPackage]
    @ObservationIgnored private let updateIndex: @Sendable () async throws -> Void
    @ObservationIgnored private let performAction: @Sendable (HomebrewManagement.Action, HomebrewPackage) async throws -> Void
    let brewAvailable: Bool
    var isReading: Bool { appTask != nil || brewTask != nil }
    var hasBrewInventory: Bool { !brewAvailable || brewReadDate != nil }
    var hasAppInventory: Bool { appReadDate != nil || hasCachedAppInventory }
    var isRestoringAppCache: Bool { cacheURL != nil && !didLoadCache }

    func isCurrentApp(_ package: HomebrewPackage) -> Bool {
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let identifier = Bundle.main.bundleIdentifier
        return package.applicationURLs.contains { url in
            if url.resolvingSymlinksInPath().path == current { return true }
            guard let identifier, let candidate = Bundle(url: url)?.bundleIdentifier else { return false }
            return candidate.caseInsensitiveCompare(identifier) == .orderedSame
        }
    }

    /// 操作前读取真实运行状态，避免清单刷新与确认之间应用刚好启动。
    func isRunning(_ package: HomebrewPackage) -> Bool {
        let targets = Set(package.applicationURLs.map { $0.resolvingSymlinksInPath().path })
        return NSWorkspace.shared.runningApplications.contains {
            guard let url = $0.bundleURL else { return false }
            return targets.contains(url.resolvingSymlinksInPath().path)
        }
    }

    init(listApps: @escaping @Sendable () throws -> [InstalledApp] = { try AppUninstaller.scanInstalledApps() },
         inspectApp: @escaping @Sendable (InstalledApp) -> ApplicationMetadata = { ApplicationMetadata.read($0) },
         measureSize: @escaping @Sendable (URL) throws -> UInt64 = { try CleanEngine.scanAllocatedSize(of: $0) },
         brewAvailable: Bool = HomebrewManagement.isAvailable,
         listPackages: @escaping @Sendable () async throws -> [HomebrewPackage] = { try await HomebrewManagement.inventory() },
         updateIndex: @escaping @Sendable () async throws -> Void = { try await HomebrewManagement.checkUpdates() },
         performAction: @escaping @Sendable (HomebrewManagement.Action, HomebrewPackage) async throws -> Void = { try await HomebrewManagement.perform($0, package: $1) },
         cacheURL: URL? = nil) {
        self.listApps = listApps; self.inspectApp = inspectApp; self.measureSize = measureSize
        self.brewAvailable = brewAvailable; self.listPackages = listPackages
        self.updateIndex = updateIndex; self.performAction = performAction
        self.cacheURL = cacheURL
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            setVisible(false)
            apps = []; metadata = [:]; sizes = [:]; measuredApps = []
            packages = []; packageSizes = [:]; measuredPackages = []; casksByPath = [:]
            homebrewAppPaths = []
            appReadDate = nil; brewReadDate = nil
            appFingerprints = [:]; measuredAppDates = [:]
            didLoadCache = false
            hasCachedAppInventory = false
        }
    }

    func setPaused(_ value: Bool) {
        paused = value
        if value { cancelReading() } else if visible { resume() }
    }

    func setVisible(_ value: Bool, tab: Tab? = nil) {
        if let tab { self.tab = tab }
        visible = value && enabled
        if visible && !paused { resume() } else { cancelReading() }
    }

    func selectTab(_ value: Tab) {
        guard tab != value else { return }
        tab = value
        cancelReading()
        if visible && !paused { resume() }
    }

    private func resume() {
        guard operation == nil else { return }
        updateRunningPaths()
        if runningObservation == nil {
            runningObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.visible, !self.paused else { return }
                    self.updateRunningPaths()
                }
            }
        }
        if tab == .apps {
            readApps(force: false, refreshInventory: true)
        }
        readBrew(force: brewReadDate.map { Date().timeIntervalSince($0) > 300 } ?? false)
    }

    private func updateRunningPaths() {
        let paths = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
        if runningPaths != paths { runningPaths = paths }
    }

    func refresh() {
        guard visible, !paused, operation == nil else { return }
        cancelReading()
        error = nil; message = nil
        if tab == .apps { readApps(force: true) }
        readBrew(force: true)
        resume()
    }

    private func cancelReading() {
        appGeneration = UUID(); brewGeneration = UUID()
        appTask?.cancel(); brewTask?.cancel()
        appTask = nil; brewTask = nil
        isLoadingApps = false; isMeasuringApps = false; isRefreshingApps = false; isLoadingBrew = false; isCheckingUpdates = false
        runningObservation = nil
    }

    private func readApps(force: Bool, refreshInventory: Bool = false) {
        guard visible, !paused, enabled, appTask == nil else { return }
        if !force, !refreshInventory, appReadDate != nil, apps.allSatisfy({ measuredApps.contains($0.id) }) { return }
        let generation = UUID(); appGeneration = generation
        let list = listApps; let inspect = inspectApp; let measure = measureSize
        let needsInventory = force || refreshInventory || appReadDate == nil
        isLoadingApps = !hasAppInventory || force
        isRefreshingApps = force
        appTask = Task { [weak self] in
            defer { if let self, self.appGeneration == generation {
                self.appTask = nil; self.isLoadingApps = false; self.isMeasuringApps = false; self.isRefreshingApps = false
            } }
            do {
                if let self, !self.didLoadCache, let url = self.cacheURL {
                    let cached: AppInventoryCache?
                    do { cached = try await Self.read { try AppInventoryCache.load(from: url) } }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        cached = nil
                        Log.app.info("Application display cache ignored: \(String(describing: error).prefix(500), privacy: .private)")
                    }
                    try Task.checkCancellation()
                    guard self.appGeneration == generation else { return }
                    self.didLoadCache = true
                    if let cached {
                        self.apps = cached.entries.map(\.app)
                        if self.brewReadDate == nil {
                            self.homebrewAppPaths = Set(cached.entries.filter { $0.isHomebrew == true }.map(\.path))
                        }
                        for entry in cached.entries {
                            self.metadata[entry.path] = entry.metadata
                            self.sizes[entry.path] = entry.size
                            self.appFingerprints[entry.path] = entry.fingerprint
                            self.measuredAppDates[entry.path] = entry.measuredAt
                        }
                        self.measuredApps = Set(cached.entries.filter {
                            guard let date = $0.measuredAt else { return false }
                            return (0...AppInventoryCache.measurementLifetime).contains(Date().timeIntervalSince(date))
                        }.map(\.path))
                        // 展示快照不能充当本次进程已核对清单的标记；中途离开后仍需重新核对。
                        self.hasCachedAppInventory = true
                        if !force { self.isLoadingApps = false }
                    }
                }
                if needsInventory {
                    let inventory = try await Self.read {
                        let apps = try list()
                        guard apps.count <= AppInventoryCache.maximumEntries else { throw HomebrewManagement.InventoryError.invalidOutput }
                        var fingerprints: [String: AppInventoryCache.Fingerprint] = [:]
                        for app in apps {
                            try Task.checkCancellation()
                            fingerprints[app.id] = AppInventoryCache.Fingerprint.read(app)
                        }
                        return (apps, fingerprints)
                    }
                    try Task.checkCancellation()
                    guard let self, self.appGeneration == generation else { return }
                    let (apps, fingerprints) = inventory
                    let previous = Dictionary(self.apps.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                    let unchanged = Set(apps.filter {
                        guard !force, previous[$0.id] == $0, self.appFingerprints[$0.id] == fingerprints[$0.id],
                              let date = self.measuredAppDates[$0.id] else { return false }
                        return (0...AppInventoryCache.measurementLifetime).contains(Date().timeIntervalSince(date))
                    }.map(\.id))
                    self.apps = apps; self.appReadDate = Date()
                    let ids = Set(apps.map(\.id))
                    self.metadata = self.metadata.filter { ids.contains($0.key) }
                    // 保留旧显示值，实际测量只重做新增、变化或超过一天的应用；手动扫描重新计量全部。
                    self.sizes = self.sizes.filter { ids.contains($0.key) }
                    self.measuredApps.formIntersection(unchanged)
                    self.measuredAppDates = self.measuredAppDates.filter { unchanged.contains($0.key) }
                    self.appFingerprints = fingerprints
                }
                guard let self else { return }
                let pendingMetadata = self.apps.filter { needsInventory || self.metadata[$0.id] == nil }
                if !pendingMetadata.isEmpty {
                    let details = try await Self.read {
                        var result: [String: ApplicationMetadata] = [:]
                        for app in pendingMetadata {
                            try Task.checkCancellation()
                            result[app.id] = inspect(app)
                        }
                        return result
                    }
                    try Task.checkCancellation()
                    guard self.appGeneration == generation else { return }
                    self.metadata.merge(details) { _, new in new }
                }
                self.isLoadingApps = false
                self.isMeasuringApps = self.apps.contains { !self.measuredApps.contains($0.id) }
                if self.isMeasuringApps {
                    await self.saveAppCache()
                    try Task.checkCancellation()
                    guard self.appGeneration == generation else { return }
                }
                for app in self.apps where !self.measuredApps.contains(app.id) {
                    do {
                        let size = try await Self.read { try measure(app.url) }
                        try Task.checkCancellation()
                        guard self.appGeneration == generation else { return }
                        self.sizes[app.id] = size
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        guard self.appGeneration == generation else { return }
                        self.sizes.removeValue(forKey: app.id)
                    }
                    try Task.checkCancellation()
                    guard self.appGeneration == generation else { return }
                    self.measuredApps.insert(app.id)
                    self.measuredAppDates[app.id] = Date()
                }
                await self.saveAppCache()
            } catch {
                guard let self, !Task.isCancelled, self.appGeneration == generation else { return }
                self.error = tr("无法读取应用列表，请重新扫描")
                Log.app.error("Application inventory failed: \(String(describing: error).prefix(500), privacy: .private)")
            }
        }
    }

    private func saveAppCache() async {
        guard let url = cacheURL else { return }
        let snapshot = AppInventoryCache(entries: apps.map {
            AppInventoryCache.Entry(app: $0, metadata: metadata[$0.id], size: sizes[$0.id],
                                    measuredAt: measuredAppDates[$0.id], fingerprint: appFingerprints[$0.id],
                                    isHomebrew: homebrewAppPaths.contains($0.id))
        })
        do {
            try await Self.read { try snapshot.save(to: url) }
            if cacheWriteFailed { Log.app.notice("Application display cache writes recovered") }
            cacheWriteFailed = false
        }
        catch is CancellationError { /* 页面关闭时不再写入快照。 */ }
        catch {
            if !cacheWriteFailed {
                Log.app.error("Application display cache write failed: \(String(describing: error).prefix(500), privacy: .private)")
            }
            cacheWriteFailed = true
        }
    }

    private func readBrew(force: Bool, checkUpdates: Bool = false) {
        guard visible, !paused, enabled, brewAvailable, brewTask == nil, operation == nil else { return }
        if !force, brewReadDate != nil, tab == .apps || packages.allSatisfy({ measuredPackages.contains($0.id) }) { return }
        let generation = UUID(); brewGeneration = generation
        let list = listPackages; let update = updateIndex; let measure = measureSize
        isLoadingBrew = brewReadDate == nil || force; isCheckingUpdates = checkUpdates
        brewTask = Task { [weak self] in
            defer { if let self, self.brewGeneration == generation {
                self.brewTask = nil; self.isLoadingBrew = false; self.isCheckingUpdates = false
            } }
            do {
                if checkUpdates { try await update() }
                if force || self?.brewReadDate == nil {
                    let packages = try await list()
                    try Task.checkCancellation()
                    guard let self, self.brewGeneration == generation else { return }
                    self.packages = packages; self.brewReadDate = Date(); self.isLoadingBrew = false
                    self.isCheckingUpdates = false
                    let ids = Set(packages.map(\.id))
                    self.packageSizes = force ? [:] : self.packageSizes.filter { ids.contains($0.key) }
                    self.measuredPackages = force ? [] : self.measuredPackages.intersection(ids)
                    self.casksByPath = [:]
                    for package in packages where package.kind == .cask {
                        for url in package.applicationURLs { self.casksByPath[url.standardizedFileURL.path] = package }
                    }
                    self.homebrewAppPaths = Set(self.casksByPath.keys)
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
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* 部分 Cask 没有 app 产物或本体不可读，不将其误报成完整清单失败。 */ }
                    try Task.checkCancellation()
                    guard self.brewGeneration == generation else { return }
                    self.measuredPackages.insert(package.id)
                }
                if checkUpdates { Log.app.notice("Homebrew update index refreshed") }
            } catch {
                guard let self, !Task.isCancelled, self.brewGeneration == generation else { return }
                self.error = tr("Homebrew 操作失败，请在终端检查后重试")
                Log.app.error("Homebrew inventory failed: \(String(describing: error).prefix(500), privacy: .private)")
            }
        }
    }

    func checkBrewUpdates() {
        guard visible, !paused, operation == nil, !isCheckingUpdates else { return }
        brewTask?.cancel(); brewTask = nil
        error = nil; message = nil
        readBrew(force: true, checkUpdates: true)
    }

    /// 原生截图使用演示清单，不扫描本机或调用 Homebrew。
    func showPreview(apps: [InstalledApp], metadata: [String: ApplicationMetadata], sizes: [String: UInt64], packages: [HomebrewPackage]) {
        cancelReading()
        didLoadCache = true
        self.apps = apps; self.metadata = metadata; self.sizes = sizes; self.packages = packages
        packageSizes = Dictionary(uniqueKeysWithValues: packages.enumerated().map { ($0.element.id, UInt64(($0.offset + 1) * 45_000_000)) })
        casksByPath = [:]
        for package in packages {
            for url in package.applicationURLs { casksByPath[url.path] = package }
        }
        homebrewAppPaths = Set(casksByPath.keys)
        runningPaths = Set(apps.prefix(2).map(\.id))
        measuredApps = Set(apps.map(\.id)); measuredPackages = Set(packages.map(\.id))
        appReadDate = Date(); brewReadDate = Date()
    }

    func perform(_ action: HomebrewManagement.Action, package: HomebrewPackage) {
        guard enabled, visible, !paused, operation == nil, !isCheckingUpdates,
              packages.contains(package), !isCurrentApp(package),
              !isRunning(package), !(action == .upgrade && (!package.outdated || package.pinned)) else { return }
        cancelReading()
        operation = action; operationPackage = package; error = nil; message = nil
        let perform = performAction
        // 已确认的安装／卸载不能因为切换标签或关闭窗口被中途打断。完成后使两个列表失效。
        operationTask = Task { [weak self] in
            do {
                try await perform(action, package)
                self?.message = tr("Homebrew 操作已完成")
                Log.app.notice("Homebrew operation completed action=\(action.rawValue, privacy: .public)")
            } catch {
                self?.error = tr("Homebrew 操作失败，请在终端检查后重试")
                Log.app.error("Homebrew operation failed action=\(action.rawValue, privacy: .public) error=\(String(describing: error).prefix(500), privacy: .private)")
            }
            guard let self else { return }
            self.operation = nil; self.operationPackage = nil; self.operationTask = nil
            self.appReadDate = nil; self.brewReadDate = nil
            self.measuredApps = []; self.measuredPackages = []; self.sizes = [:]; self.packageSizes = [:]
            self.metadata = [:]; self.casksByPath = [:]
            self.homebrewAppPaths = []
            if self.visible, !self.paused, self.enabled { self.resume() }
        }
    }

    /// 带取消传播的 utility 遍历，避免为每个包创建常驻任务。
    private static func read<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .utility) { try Task.checkCancellation(); return try work() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
