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
    public private(set) var isRemoving = false
    public private(set) var outcome: (text: String, isError: Bool)?
    var chosen: Set<String> = []
    /// 有应用启动或退出时变化，让“正在运行”的提示跟着刷新
    private var runningRevision = 0
    @ObservationIgnored private var runningApplicationsObservation: NSKeyValueObservation?
    @ObservationIgnored private let currentBundleIdentifier: String?
    @ObservationIgnored private let listApplications: @Sendable () throws -> [InstalledApp]
    @ObservationIgnored private let findLeftovers: @Sendable (InstalledApp) throws -> [AppLeftover]
    @ObservationIgnored private let measureSize: @Sendable (URL) throws -> UInt64
    @ObservationIgnored private let recycleFiles: ([URL], @escaping @Sendable ([URL: URL], String?) -> Void) -> Void
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
         listApplications: @escaping @Sendable () throws -> [InstalledApp] = { try AppUninstaller.scanInstalledApps() },
         findLeftovers: @escaping @Sendable (InstalledApp) throws -> [AppLeftover] = { try AppUninstaller.scanLeftovers(for: $0) },
         measureSize: @escaping @Sendable (URL) throws -> UInt64 = { try CleanEngine.scanAllocatedSize(of: $0) },
         recycleFiles: @escaping ([URL], @escaping @Sendable ([URL: URL], String?) -> Void) -> Void = { urls, completion in
             NSWorkspace.shared.recycle(urls) { moved, error in completion(moved, error?.localizedDescription) }
         }) {
        self.enabled = enabled
        self.currentBundleIdentifier = currentBundleIdentifier
        self.listApplications = listApplications
        self.findLeftovers = findLeftovers
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
            cancelScanning()
            runningApplicationsObservation = nil
            if !isRemoving {
                apps = []; sizes = [:]; selected = nil; leftovers = []; chosen = []
                hasScannedSelection = false
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

    func select(_ app: InstalledApp?) {
        guard enabled, !isRemoving else { return }
        if let app, currentBundleIdentifier?.caseInsensitiveCompare(app.bundleIdentifier) == .orderedSame {
            outcome = (AppUninstallError.currentApp.description, true)
            return
        }
        selectionTask?.cancel()
        let generation = UUID()
        selectionGeneration = generation
        selectionTask = nil
        isScanning = false
        hasScannedSelection = false
        pendingUninstall = nil
        selected = app
        applicationRemoved = false
        leftovers = []
        chosen = []
        outcome = nil
        guard let app else { return }
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
                self.leftovers = found
                self.chosen = Set(found.filter { !$0.requiresReview }.map(\.id))
                self.hasScannedSelection = true
            } catch {
                guard let self, self.selectionGeneration == generation, !Task.isCancelled else { return }
                self.outcome = (error.localizedDescription, true)
            }
        }
    }

    /// 离开页面、关闭或最小化窗口时中断遍历；已完成结果保留，未完成结果稍后重扫。
    func cancelScanning() {
        applicationGeneration = UUID()
        selectionGeneration = UUID()
        applicationTask?.cancel()
        selectionTask?.cancel()
        applicationTask = nil
        selectionTask = nil
        isLoading = false
        isScanning = false
        pendingUninstall = nil
    }

    func resumeScanning() {
        guard enabled else { return }
        if apps.isEmpty || apps.contains(where: { sizes[$0.id] == nil }) { loadApps() }
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
            try AppUninstaller.validate(app, currentBundleIdentifier: currentBundleIdentifier)
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
    func showPreview(app: InstalledApp, items: [AppLeftover], applicationRemoved: Bool) {
        cancelScanning()
        enabled = true
        apps = applicationRemoved ? [] : [app]
        sizes = [app.id: 20_000_000]
        selected = app
        leftovers = items
        chosen = Set(items.filter { !$0.requiresReview }.map(\.id))
        hasScannedSelection = true
        self.applicationRemoved = applicationRemoved
    }

    func confirmUninstall() {
        guard let pendingUninstall, pendingUninstall == selected else { return }
        self.pendingUninstall = nil
        uninstall()
    }

    private func uninstall() {
        guard let app = selected, canUninstall else { return }
        do {
            try AppUninstaller.validate(app, currentBundleIdentifier: currentBundleIdentifier)
            guard !isRunning(app) else { throw AppUninstallError.running }
            // 用户确认与回收之间目录可能已被替换，所有选中路径必须再次通过安全检查。
            for item in leftovers where chosen.contains(item.id) {
                try AppUninstaller.validateLeftover(item.url, for: app)
            }
        } catch {
            outcome = ("\(error)", true)
            return
        }
        let items = leftovers.filter { chosen.contains($0.id) }
        let urls = items.map(\.url)
        // 回收开始后不能让仍在运行的列表扫描重新发布已经移除的应用。
        cancelScanning()
        isRemoving = true
        outcome = nil
        // NSWorkspace 负责需要管理员权限的情况（例如 root 拥有的应用），并能在废纸篓中“放回原处”
        recycleFiles(urls) { [weak self] moved, message in
            Task { @MainActor in
                guard let self else { return }
                self.finishUninstall(app, items: items, moved: moved, errorMessage: message)
            }
        }
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
