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
    private(set) var isLoadingApps = false
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
         performAction: @escaping @Sendable (HomebrewManagement.Action, HomebrewPackage) async throws -> Void = { try await HomebrewManagement.perform($0, package: $1) }) {
        self.listApps = listApps; self.inspectApp = inspectApp; self.measureSize = measureSize
        self.brewAvailable = brewAvailable; self.listPackages = listPackages
        self.updateIndex = updateIndex; self.performAction = performAction
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            setVisible(false)
            apps = []; metadata = [:]; sizes = [:]; measuredApps = []
            packages = []; packageSizes = [:]; measuredPackages = []; casksByPath = [:]
            appReadDate = nil; brewReadDate = nil
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
            readApps(force: appReadDate.map { Date().timeIntervalSince($0) > 300 } ?? false)
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
        isLoadingApps = false; isLoadingBrew = false; isCheckingUpdates = false
        runningObservation = nil
    }

    private func readApps(force: Bool) {
        guard visible, !paused, enabled, appTask == nil else { return }
        if !force, appReadDate != nil, apps.allSatisfy({ measuredApps.contains($0.id) }) { return }
        let generation = UUID(); appGeneration = generation
        let list = listApps; let inspect = inspectApp; let measure = measureSize
        isLoadingApps = appReadDate == nil || force
        appTask = Task { [weak self] in
            defer { if let self, self.appGeneration == generation { self.appTask = nil; self.isLoadingApps = false } }
            do {
                if force || self?.appReadDate == nil {
                    let apps = try await Self.read { try list() }
                    try Task.checkCancellation()
                    guard let self, self.appGeneration == generation else { return }
                    guard apps.count <= 10_000 else { throw HomebrewManagement.InventoryError.invalidOutput }
                    self.apps = apps; self.appReadDate = Date()
                    let ids = Set(self.apps.map(\.id))
                    self.metadata = self.metadata.filter { ids.contains($0.key) }
                    self.sizes = force ? [:] : self.sizes.filter { ids.contains($0.key) }
                    self.measuredApps = force ? [] : self.measuredApps.intersection(ids)
                    self.isLoadingApps = false
                }
                guard let self else { return }
                for app in self.apps where !self.measuredApps.contains(app.id) {
                    let details = try await Self.read { inspect(app) }
                    try Task.checkCancellation()
                    guard self.appGeneration == generation else { return }
                    self.metadata[app.id] = details
                    do {
                        let size = try await Self.read { try measure(app.url) }
                        try Task.checkCancellation()
                        guard self.appGeneration == generation else { return }
                        self.sizes[app.id] = size
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* 单个包不可读仍保留其列表行；显式刷新可以重试计量。 */ }
                    try Task.checkCancellation()
                    guard self.appGeneration == generation else { return }
                    self.measuredApps.insert(app.id)
                }
            } catch {
                guard let self, !Task.isCancelled, self.appGeneration == generation else { return }
                self.error = tr("无法读取应用列表，请重新扫描")
                Log.app.error("Application inventory failed: \(String(describing: error).prefix(500), privacy: .private)")
            }
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
        self.apps = apps; self.metadata = metadata; self.sizes = sizes; self.packages = packages
        packageSizes = Dictionary(uniqueKeysWithValues: packages.enumerated().map { ($0.element.id, UInt64(($0.offset + 1) * 45_000_000)) })
        casksByPath = [:]
        for package in packages {
            for url in package.applicationURLs { casksByPath[url.path] = package }
        }
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
