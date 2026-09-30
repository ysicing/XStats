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

    public convenience init() {
        self.init(currentBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    init(currentBundleIdentifier: String?,
         listApplications: @escaping @Sendable () throws -> [InstalledApp] = { try AppUninstaller.scanInstalledApps() },
         findLeftovers: @escaping @Sendable (InstalledApp) throws -> [AppLeftover] = { try AppUninstaller.scanLeftovers(for: $0) },
         measureSize: @escaping @Sendable (URL) throws -> UInt64 = { try CleanEngine.scanAllocatedSize(of: $0) },
         recycleFiles: @escaping ([URL], @escaping @Sendable ([URL: URL], String?) -> Void) -> Void = { urls, completion in
             NSWorkspace.shared.recycle(urls) { moved, error in completion(moved, error?.localizedDescription) }
         }) {
        self.currentBundleIdentifier = currentBundleIdentifier
        self.listApplications = listApplications
        self.findLeftovers = findLeftovers
        self.measureSize = measureSize
        self.recycleFiles = recycleFiles
        // LSUIElement 应用（如 MacTools）不会发送普通应用的启动／退出通知。
        // 观察运行列表才能覆盖这些应用；异步回到主线程，等 AppKit 更新列表后再通知视图。
        runningApplicationsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.runningRevision += 1 }
        }
    }

    var chosenSize: UInt64 {
        leftovers.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var canUninstall: Bool {
        selected != nil && hasScannedSelection && !isScanning && !isRemoving
            && leftovers.contains { $0.kind == .application && chosen.contains($0.id) }
    }

    func loadApps() {
        guard !isRemoving, applicationTask == nil else { return }
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
                let apps = try await withThrowingTaskGroup(of: [InstalledApp].self) { group in
                    group.addTask(priority: .utility) { try Task.checkCancellation(); return try list() }
                    return try await group.next() ?? []
                }
                guard let self, !Task.isCancelled, self.applicationGeneration == generation else { return }
                self.apps = apps.filter { (try? AppUninstaller.validate($0, currentBundleIdentifier: self.currentBundleIdentifier)) != nil }
                self.isLoading = false
                // 列表先展示；完整计量结束前仍保持重入保护，显式刷新或关闭页面会取消当前子任务。
                for app in self.apps where self.sizes[app.id] == nil {
                    try Task.checkCancellation()
                    let size = try await withThrowingTaskGroup(of: UInt64.self) { group in
                        group.addTask(priority: .utility) { try Task.checkCancellation(); return try measure(app.url) }
                        return try await group.next() ?? 0
                    }
                    guard !Task.isCancelled, self.applicationGeneration == generation else { return }
                    self.sizes[app.id] = size
                }
            } catch {
                guard let self, self.applicationGeneration == generation, !Task.isCancelled else { return }
                self.outcome = (error.localizedDescription, true)
            }
        }
    }

    /// 用户显式刷新：中断进行中的列举或计量后重新列举，已算出的大小保留。
    func reloadApps() {
        guard !isRemoving else { return }
        applicationTask?.cancel()
        applicationTask = nil
        loadApps()
    }

    func select(_ app: InstalledApp?) {
        guard !isRemoving else { return }
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
                let found = try await withThrowingTaskGroup(of: [AppLeftover].self) { group in
                    group.addTask(priority: .utility) { try Task.checkCancellation(); return try find(app) }
                    return try await group.next() ?? []
                }
                // 应用相同也可能是另一次扫描，不能用 selected == app 代替任务代次。
                guard let self, !Task.isCancelled, self.selectionGeneration == generation, self.selected == app else { return }
                self.leftovers = found
                self.chosen = Set(found.map(\.id))
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
        if apps.isEmpty || apps.contains(where: { sizes[$0.id] == nil }) { loadApps() }
        if let selected, !hasScannedSelection, !isScanning { select(selected) }
    }

    /// 拖进来的 .app
    func select(url: URL) {
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
        guard !isRemoving, leftover.kind != .application else { return }
        if chosen.contains(leftover.id) { chosen.remove(leftover.id) } else { chosen.insert(leftover.id) }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        _ = runningRevision
        return !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
    }

    func quit(_ app: InstalledApp) {
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
        let movedItems = items.filter { moved[$0.url] != nil }
        guard !movedItems.isEmpty else {
            outcome = (tr("没有移动任何文件\(errorMessage.map { tr("：\($0)") } ?? "")"), true)
            return
        }
        let bytes = movedItems.reduce(0) { $0 + $1.size }
        let remaining = items.count - movedItems.count
        let partial = remaining > 0 ? tr("，\(remaining.formatted(.number.locale(L10n.locale))) 项未能移动") : ""
        let detail = errorMessage.map { tr("：\($0)") } ?? ""
        if moved[app.url] != nil {
            let dock = Self.removeDockTile(for: app.url)
            let residualCount = movedItems.filter { $0.kind != .application }.count.formatted(.number.locale(L10n.locale))
            outcome = (tr("已将 \(app.name) 与 \(residualCount) 项残留移到废纸篓，约 \(Format.bytes(bytes, base: .decimal))\(dock ? tr("，已从程序坞移除") : "")\(partial)。需要时可以在废纸篓里放回。") + detail,
                       remaining > 0 || errorMessage != nil)
            if selected == app { selected = nil; leftovers = []; chosen = [] }
            apps.removeAll { $0 == app }
        } else {
            let count = movedItems.count.formatted(.number.locale(L10n.locale))
            outcome = (tr("应用本体未能移动；已将 \(count) 项残留移到废纸篓，约 \(Format.bytes(bytes, base: .decimal))。请解决错误后重试。") + detail, true)
            if selected == app {
                leftovers.removeAll { moved[$0.url] != nil }
                chosen.subtract(movedItems.map(\.id))
            }
        }
        Log.app.notice("卸载 \(app.bundleIdentifier, privacy: .public)，实际移到废纸篓 \(movedItems.count) 项，本体已移动：\(moved[app.url] != nil)")
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
