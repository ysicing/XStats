// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import Cleaner
import Foundation
import Localization
import Metrics
import Observation

/// 卸载应用：列出已安装的应用，查找残留文件，连同残留一起移到废纸篓，并从程序坞移除图标
@MainActor
@Observable
public final class UninstallerController {
    public private(set) var enabled: Bool
    public private(set) var apps: [InstalledApp] = []
    public private(set) var sizes: [String: UInt64] = [:]
    public private(set) var isLoading = false
    public private(set) var selected: InstalledApp?
    public private(set) var pendingUninstall: InstalledApp?
    public private(set) var leftovers: [AppLeftover] = []
    public private(set) var isScanning = false
    public private(set) var scanIncomplete = false
    public private(set) var otherInstalledCopies: [URL] = []
    public private(set) var installationCheckIncomplete = false
    @ObservationIgnored private var selectedScan: AppLeftoverScan?
    public private(set) var isRemoving = false
    public private(set) var outcome: (text: String, isError: Bool)?
    var chosen: Set<String> = []
    /// 有应用启动或退出时变化，让“正在运行”的提示跟着刷新
    private var runningRevision = 0
    @ObservationIgnored private var runningApplicationsObservation: NSKeyValueObservation?
    @ObservationIgnored private let home: String
    @ObservationIgnored private let currentBundleIdentifier: String?
    @ObservationIgnored private let listApplications: @Sendable () throws -> [InstalledApp]
    @ObservationIgnored private let findLeftovers: @Sendable (InstalledApp) throws -> AppLeftoverScan
    @ObservationIgnored private let checkInstallations: @Sendable (InstalledApp) throws -> AppInstallationCheck
    @ObservationIgnored private let measureSize: @Sendable (URL) throws -> UInt64
    @ObservationIgnored private let recycleFiles: ([URL], @escaping @Sendable ([URL: URL], String?) -> Void) -> Void
    @ObservationIgnored private var preflightTask: Task<Void, Never>?
    @ObservationIgnored private var applicationTask: Task<Void, Never>?
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var applicationGeneration = UUID()
    @ObservationIgnored private var selectionGeneration = UUID()
    @ObservationIgnored private var hasScannedSelection = false
    @ObservationIgnored private var applicationRemoved = false

    public convenience init(enabled: Bool = true) {
        self.init(currentBundleIdentifier: Bundle.main.bundleIdentifier, enabled: enabled)
    }

    init(currentBundleIdentifier: String?,
         enabled: Bool = true,
         home: String = NSHomeDirectory(),
         listApplications: @escaping @Sendable () throws -> [InstalledApp] = { try AppUninstaller.scanInstalledApps() },
         findLeftovers: (@Sendable (InstalledApp) throws -> [AppLeftover])? = nil,
         findLeftoversReport: (@Sendable (InstalledApp) throws -> AppLeftoverScan)? = nil,
         checkInstallations: (@Sendable (InstalledApp) throws -> AppInstallationCheck)? = nil,
         measureSize: @escaping @Sendable (URL) throws -> UInt64 = { try CleanEngine.scanAllocatedSize(of: $0) },
         recycleFiles: @escaping ([URL], @escaping @Sendable ([URL: URL], String?) -> Void) -> Void = { urls, completion in
             NSWorkspace.shared.recycle(urls) { moved, error in completion(moved, error?.localizedDescription) }
         }) {
        self.home = home
        self.enabled = enabled
        self.currentBundleIdentifier = currentBundleIdentifier
        self.listApplications = listApplications
        if let findLeftoversReport {
            self.findLeftovers = findLeftoversReport
        } else if let findLeftovers {
            self.findLeftovers = { AppLeftoverScan(items: try findLeftovers($0)) }
        } else {
            self.findLeftovers = { try AppUninstaller.scanLeftoversReport(for: $0, home: home) }
        }
        self.checkInstallations = checkInstallations ?? { try AppUninstaller.checkOtherInstallations(of: $0, home: home) }
        self.measureSize = measureSize
        self.recycleFiles = recycleFiles
        if enabled { observeRunningApplications() }
    }

    /// 关闭功能只取消查看任务；已交给系统的废纸篓操作必须正常收尾。
    public func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            observeRunningApplications()
        } else {
            preflightTask?.cancel()
            cancelScanning()
            runningApplicationsObservation = nil
            if !isRemoving {
                apps = []; sizes = [:]; selected = nil; leftovers = []; chosen = []
                hasScannedSelection = false
                scanIncomplete = false
                selectedScan = nil; otherInstalledCopies = []; installationCheckIncomplete = false
                outcome = nil
            }
        }
    }

    private func observeRunningApplications() {
        guard runningApplicationsObservation == nil else { return }
        // LSUIElement 应用（如 MacTools）不会发送普通应用的启动／退出通知。
        // 观察运行列表才能覆盖这些应用；异步回到主线程，等 AppKit 更新列表后再通知视图。
        runningApplicationsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.enabled else { return }
                self.runningRevision += 1
            }
        }
    }

    var chosenSize: UInt64 {
        leftovers.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var canUninstall: Bool {
        enabled && selected != nil && hasScannedSelection && !isScanning && !isRemoving
            && !chosen.isEmpty && (includesApplication || applicationRemoved)
    }

    var includesApplication: Bool {
        leftovers.contains { $0.kind == .application && chosen.contains($0.id) }
    }

    func loadApps() {
        guard enabled, !isRemoving, applicationTask == nil else { return }
        let generation = UUID()
        applicationGeneration = generation
        isLoading = true
        let list = listApplications
        let measure = measureSize
        applicationTask = Task { [weak self] in
            defer {
                if let self, self.applicationGeneration == generation {
                    self.isLoading = false
                    self.applicationTask = nil
                }
            }
            do {
                let apps = try await Self.scan(list)
                guard let self, !Task.isCancelled, self.applicationGeneration == generation else { return }
                self.apps = apps.filter { (try? AppUninstaller.validate($0, currentBundleIdentifier: self.currentBundleIdentifier)) != nil }
                self.isLoading = false
                // 列表先展示；完整计量结束前仍保持重入保护，显式刷新或关闭页面会取消当前子任务。
                for app in self.apps where self.sizes[app.id] == nil {
                    try Task.checkCancellation()
                    let size = try await Self.scan { try measure(app.url) }
                    guard !Task.isCancelled, self.applicationGeneration == generation else { return }
                    self.sizes[app.id] = size
                }
            } catch {
                guard let self, self.applicationGeneration == generation, !Task.isCancelled else { return }
                self.outcome = (error.localizedDescription, true)
            }
        }
    }

    /// 同步文件遍历放到 utility 子任务执行；子任务继承父任务取消，遍历内部据此中止。
    private static func scan<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask(priority: .utility) { try Task.checkCancellation(); return try work() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
        }
    }

    /// 用户显式刷新：中断进行中的列举或计量后重新列举，已算出的大小保留。
    func reloadApps() {
        guard enabled, !isRemoving else { return }
        applicationTask?.cancel()
        applicationTask = nil
        loadApps()
    }

    /// 返回本次扫描任务，调用方可以等待结果与状态发布完成。
    @discardableResult
    func select(_ app: InstalledApp?) -> Task<Void, Never>? {
        guard enabled, !isRemoving else { return nil }
        if let app, currentBundleIdentifier?.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame {
            outcome = (AppUninstallError.currentApp.description, true)
            return nil
        }
        selectionTask?.cancel()
        let generation = UUID()
        selectionGeneration = generation
        selectionTask = nil
        isScanning = false
        hasScannedSelection = false
        scanIncomplete = false
        selectedScan = nil
        otherInstalledCopies = []
        installationCheckIncomplete = false
        pendingUninstall = nil
        selected = app
        applicationRemoved = false
        leftovers = []
        chosen = []
        outcome = nil
        guard let app else { return nil }
        isScanning = true
        let find = findLeftovers
        selectionTask = Task { [weak self] in
            defer {
                if let self, self.selectionGeneration == generation {
                    self.isScanning = false
                    self.selectionTask = nil
                }
            }
            do {
                let found = try await Self.scan { try find(app) }
                // 应用相同也可能是另一次扫描，不能用 selected == app 代替任务代次。
                guard let self, !Task.isCancelled, self.selectionGeneration == generation, self.selected == app else { return }
                self.selectedScan = found
                self.otherInstalledCopies = found.otherInstalledCopies
                self.installationCheckIncomplete = found.installationCheckIncomplete
                self.leftovers = found.items
                self.chosen = Set(found.items.filter { !$0.requiresReview }.map(\.id))
                self.scanIncomplete = !found.unreadablePaths.isEmpty
                if self.scanIncomplete { Log.app.warning("Uninstall scan incomplete unreadable=\(found.unreadablePaths.count)") }
                self.hasScannedSelection = true
            } catch {
                guard let self, self.selectionGeneration == generation, !Task.isCancelled else { return }
                self.outcome = (error.localizedDescription, true)
            }
        }
        return selectionTask
    }

    /// 离开页面、关闭或最小化窗口时中断遍历；已完成结果保留，未完成结果稍后重扫。
    func cancelScanning(preservingConfirmation: Bool = false) {
        applicationGeneration = UUID()
        selectionGeneration = UUID()
        applicationTask?.cancel()
        selectionTask?.cancel()
        applicationTask = nil
        selectionTask = nil
        isLoading = false
        isScanning = false
        // 系统授权或隐藏窗口只暂停遍历；显式退出页面、关闭功能仍作废确认。
        if !preservingConfirmation { pendingUninstall = nil }
    }

    func resumeScanning() {
        guard enabled else { return }
        if apps.isEmpty || apps.contains(where: { sizes[$0.id] == nil }) { loadApps() }
        resumeSelectionScan()
    }

    func resumeSelectionScan() {
        guard enabled else { return }
        if let selected, !hasScannedSelection, !isScanning { select(selected) }
    }

    /// 拖进来的 .app
    func select(url: URL) {
        guard enabled, !isRemoving else { return }
        guard let app = AppUninstaller.app(at: url) else {
            outcome = (tr("不是应用程序"), true)
            return
        }
        do {
            try AppUninstaller.validate(app, home: home, currentBundleIdentifier: currentBundleIdentifier)
            select(app)
        } catch {
            outcome = ("\(error)", true)
        }
    }

    func toggle(_ leftover: AppLeftover) {
        // 应用本体必须一起移除，否则没有意义；回收期间固定目标
        guard enabled, !isRemoving, leftover.kind != .application else { return }
        if chosen.contains(leftover.id) { chosen.remove(leftover.id) } else { chosen.insert(leftover.id) }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        _ = runningRevision
        return !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
    }

    func quit(_ app: InstalledApp) {
        guard enabled, !isRemoving else { return }
        guard currentBundleIdentifier?.caseInsensitiveCompare(app.bundleIdentifier) != .orderedSame else {
            outcome = (AppUninstallError.currentApp.description, true)
            return
        }
        for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier) {
            // 防御直接调用或异常 Bundle 元数据，绝不向当前进程发送退出请求。
            guard running.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                outcome = (AppUninstallError.currentApp.description, true)
                continue
            }
            let accepted = running.terminate()
            Log.app.notice("卸载前请求退出应用 \(app.name, privacy: .public)，包名 \(app.bundleIdentifier, privacy: .public)，PID \(running.processIdentifier)，请求已发送：\(accepted)")
        }
    }

    func requestUninstall() {
        guard let selected, canUninstall else { return }
        pendingUninstall = selected
    }

    func cancelUninstall() {
        pendingUninstall = nil
    }

    /// 原生截图仅注入演示候选；不扫描真实应用，也不调用废纸篓或程序坞操作。
    func showPreview(app: InstalledApp, items: [AppLeftover], applicationRemoved: Bool, scanIncomplete: Bool = false,
                     copies: [URL] = [], installationCheckIncomplete: Bool = false) {
        cancelScanning()
        enabled = true
        apps = applicationRemoved ? [] : [app]
        sizes = [app.id: 20_000_000]
        selected = app
        leftovers = items
        chosen = Set(items.filter { !$0.requiresReview }.map(\.id))
        hasScannedSelection = true
        self.scanIncomplete = scanIncomplete
        selectedScan = nil; otherInstalledCopies = copies
        self.installationCheckIncomplete = installationCheckIncomplete
        self.applicationRemoved = applicationRemoved
    }

    @discardableResult
    func confirmUninstall() -> Task<Void, Never>? {
        guard let pendingUninstall, pendingUninstall == selected else { return nil }
        self.pendingUninstall = nil
        return uninstall()
    }

    private func uninstall() -> Task<Void, Never>? {
        guard let app = selected, canUninstall else { return nil }
        let requested = leftovers.filter { chosen.contains($0.id) }
        let scan = selectedScan
        let check = checkInstallations
        // 在副本检查期间也固定目标和选择，检查通过后再交给系统回收。
        cancelScanning()
        isRemoving = true
        outcome = nil
        let task = Task {
            var recyclingStarted = false
            defer {
                preflightTask = nil
                if !recyclingStarted {
                    isRemoving = false
                    if !enabled {
                        selected = nil; leftovers = []; chosen = []; selectedScan = nil
                        otherInstalledCopies = []; installationCheckIncomplete = false
                        hasScannedSelection = false; scanIncomplete = false; applicationRemoved = false
                    }
                }
            }
            do {
                let installations = try await Self.scan { try check(app) }
                guard enabled, !Task.isCancelled else { return }
                otherInstalledCopies = installations.otherInstalledCopies
                installationCheckIncomplete = !installations.unreadableDirectories.isEmpty
                let items = installations.preservesSharedData ? requested.filter { $0.kind == .application } : requested
                if installations.preservesSharedData {
                    leftovers.removeAll { $0.kind != .application }
                    chosen = Set(leftovers.filter { !$0.requiresReview }.map(\.id))
                    Log.app.notice("Uninstall preserving shared data copies=\(installations.otherInstalledCopies.count) incomplete=\(self.installationCheckIncomplete)")
                }
                guard !items.isEmpty else {
                    outcome = (installations.otherInstalledCopies.isEmpty
                        ? tr("无法完整检查应用安装位置；为避免影响其他副本，本次保留共用数据。")
                        : tr("检测到相同应用的其他安装副本；共用的数据已保留，未移动任何文件。"), true)
                    return
                }
                if items.contains(where: { $0.kind == .application }) {
                    try AppUninstaller.validate(app, home: home, currentBundleIdentifier: currentBundleIdentifier)
                }
                guard !isRunning(app) else { throw AppUninstallError.running }
                for item in items {
                    if let scan {
                        try AppUninstaller.validateLeftover(item.url, for: app, scan: scan, home: home)
                    } else {
                        try AppUninstaller.validateLeftover(item.url, for: app, home: home)
                    }
                }
                recyclingStarted = true
                recycleFiles(items.map(\.url)) { [weak self] moved, message in
                    Task { @MainActor in
                        self?.finishUninstall(app, items: items, moved: moved, errorMessage: message)
                    }
                }
            } catch {
                if enabled, !Task.isCancelled {
                    outcome = ((error as? AppUninstallError)?.description ?? error.localizedDescription, true)
                    Log.app.error("Uninstall preflight failed: \(error.localizedDescription.prefix(512), privacy: .private)")
                }
            }
        }
        preflightTask = task
        return task
    }

    /// 回收可部分成功；只有本体确实移动后，才能移除列表和程序坞入口。
    func finishUninstall(_ app: InstalledApp, items: [AppLeftover], moved: [URL: URL], errorMessage: String?) {
        isRemoving = false
        // 回收结果的键可能是规范化后的 URL（如目录末尾斜杠不同），按标准化路径比对。
        let movedPaths = Set(moved.keys.map(\.standardizedFileURL.path))
        let wasMoved = { (url: URL) in movedPaths.contains(url.standardizedFileURL.path) }
        let movedItems = items.filter { wasMoved($0.url) }
        guard !movedItems.isEmpty else {
            outcome = (tr("没有移动任何文件\(errorMessage.map { tr("：\($0)") } ?? "")"), true)
            return
        }
        let bytes = movedItems.reduce(0) { $0 + $1.size }
        let remaining = items.count - movedItems.count
        let partial = remaining > 0 ? tr("，\(remaining.formatted(.number.locale(L10n.locale))) 项未能移动") : ""
        let detail = errorMessage.map { tr("：\($0)") } ?? ""
        let appMoved = wasMoved(app.url)
        if appMoved {
            let dock = Self.removeDockTile(for: app.url)
            let residualCount = movedItems.filter { $0.kind != .application }.count.formatted(.number.locale(L10n.locale))
            outcome = (tr("已将 \(app.name) 与 \(residualCount) 项残留移到废纸篓，约 \(Format.bytes(bytes, base: .decimal))\(dock ? tr("，已从程序坞移除") : "")\(partial)。需要时可以在废纸篓里放回。") + detail,
                       remaining > 0 || errorMessage != nil)
            apps.removeAll { $0 == app }
            sizes.removeValue(forKey: app.id)
        } else if items.contains(where: { $0.kind == .application }) {
            let count = movedItems.count.formatted(.number.locale(L10n.locale))
            outcome = (tr("应用本体未能移动；已将 \(count) 项残留移到废纸篓，约 \(Format.bytes(bytes, base: .decimal))。请解决错误后重试。") + detail, true)
        } else {
            let count = movedItems.count.formatted(.number.locale(L10n.locale))
            outcome = (tr("已将 \(app.name) 的 \(count) 项残留移到废纸篓，约 \(Format.bytes(bytes, base: .decimal))\(partial)。需要时可以在废纸篓里放回。") + detail,
                       remaining > 0 || errorMessage != nil)
        }
        if selected == app {
            applicationRemoved = applicationRemoved || appMoved
            leftovers.removeAll { wasMoved($0.url) }
            chosen.subtract(movedItems.map(\.id))
            // 本体已移动也保留失败及未勾选的残留，允许逐项确认后重试。
            if leftovers.isEmpty { selected = nil; chosen = []; applicationRemoved = false }
        }
        Log.app.notice("卸载 \(app.bundleIdentifier, privacy: .public)，实际移到废纸篓 \(movedItems.count) 项，本体已移动：\(appMoved)")
    }

    /// 修改程序坞偏好里的 persistent-apps 并重启程序坞
    private static func removeDockTile(for url: URL) -> Bool {
        let domain = "com.apple.dock" as CFString
        let key = "persistent-apps" as CFString
        guard let tiles = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]],
              let updated = AppUninstaller.removingDockTile(for: url, from: tiles) else { return false }
        CFPreferencesSetAppValue(key, updated as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
        return true
    }
}
