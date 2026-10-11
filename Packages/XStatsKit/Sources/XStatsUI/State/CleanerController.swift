import AppKit
import Cleaner
import Foundation
import Observation

@MainActor
@Observable
public final class CleanerController {
    public enum Phase: Equatable {
        case idle, scanning, ready, cleaning, finished
    }

    public private(set) var phase: Phase = .idle
    public private(set) var scans: [RuleScan] = []
    public private(set) var lastScan: Date?
    public private(set) var report: CleanReport?
    public private(set) var cleanProgress: CleanProgress?
    /// 单次文件删除可能尚未返回；先显示取消请求，随后由任务停止剩余步骤。
    public private(set) var isCancelling = false
    public var selection: Set<String> {
        didSet { settings.cleanSelectedRuleIDs = selection }
    }
    public var isConfirming = false
    private var deselectedItems: Set<String> = []

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let rules = RuleCatalog.rules()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        let validIDs = Set(rules.map(\.id))
        let initial = settings.cleanSelectedRuleIDs ?? Set(rules.filter(\.selectedByDefault).map(\.id))
        selection = initial.intersection(validIDs)
    }

    var isBusy: Bool { phase == .scanning || phase == .cleaning }

    func scan(ifNeeded: Bool = false) {
        guard settings.cleanerEnabled, !isBusy, !(ifNeeded && lastScan != nil) else { return }
        phase = .scanning
        isConfirming = false
        let environment = environment()
        let rules = rules
        task = Task {
            let results = await CleanEngine.scan(rules, environment: environment)
            guard !Task.isCancelled else { phase = scans.isEmpty ? .idle : .ready; return }
            scans = results
            deselectedItems.formIntersection(results.flatMap { $0.items.map(\.id) })
            lastScan = Date()
            phase = .ready
        }
    }

    func requestClean() {
        guard settings.cleanerEnabled, (phase == .ready || phase == .finished), !selectedScans.isEmpty else { return }
        isConfirming = true
    }

    func cancelClean() {
        isConfirming = false
    }

    func cancelOperation() {
        guard isBusy else { return }
        if phase == .cleaning { isCancelling = true }
        task?.cancel()
    }

    func confirmClean() {
        guard settings.cleanerEnabled, isConfirming else { return }
        isConfirming = false
        report = nil
        cleanProgress = nil
        isCancelling = false
        phase = .cleaning
        Log.app.notice("Cleanup started rules=\(self.selectedScans.count) items=\(self.selectedScans.reduce(0) { $0 + $1.items.count })")
        let environment = environment()
        let scans = selectedScans
        let selection = selection
        let preferTrash = settings.cleanPrefersTrash
        task = Task { [self] in
            var result = await CleanEngine.clean(scans, selected: selection, preferTrash: preferTrash,
                                                environment: environment, refreshRunningApps: {
                await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
            }) { [weak self] progress in
                await MainActor.run { self?.cleanProgress = progress }
            }
            result.wasCancelled = result.wasCancelled || Task.isCancelled
            report = result
            Log.app.notice("Cleanup completed removed=\(result.removedCount) skipped=\(result.skippedCount) failures=\(result.failures.count) cancelled=\(result.wasCancelled)")
            cleanProgress = nil
            if result.wasCancelled {
                // 清理可能已完成一部分，原来的候选列表不再代表当前状态。
                self.scans = []
                lastScan = nil
                isCancelling = false
                phase = .finished
                return
            }
            // 清理后重新计算剩余可清理空间
            let rescanned = await CleanEngine.scan(rules, environment: self.environment())
            if !Task.isCancelled {
                self.scans = rescanned
                lastScan = Date()
            } else {
                self.scans = []
                lastScan = nil
            }
            isCancelling = false
            phase = .finished
        }
    }

    func toggle(_ scan: RuleScan) {
        guard scan.isCleanable, !isBusy else { return }
        if selectedItems(in: scan).count < scan.items.count {
            deselectedItems.subtract(scan.items.map(\.id))
            selection.insert(scan.id)
        } else { selection.remove(scan.id) }
        isConfirming = false
    }

    func toggle(_ item: CleanItem, in scan: RuleScan) {
        guard !isBusy, !scan.rule.usesToolCleaner else { return }
        let wasSelected = selectedItems(in: scan).contains { $0.id == item.id }
        if !selection.contains(scan.id) {
            deselectedItems.formUnion(scan.items.map(\.id))
            selection.insert(scan.id)
        }
        if wasSelected { deselectedItems.insert(item.id) } else { deselectedItems.remove(item.id) }
        isConfirming = false
    }

    func selectedItems(in scan: RuleScan) -> [CleanItem] {
        guard selection.contains(scan.id), scan.isCleanable else { return [] }
        return scan.items.filter {
            !deselectedItems.contains($0.id) && !CleanupExclusions.overlapsLexically($0.url, paths: settings.cleanExcludedPaths)
        }
    }

    var excludedPaths: [String] { settings.cleanExcludedPaths }
    var exclusionLimitReached: Bool { excludedPaths.count >= 50 }

    @discardableResult
    func exclude(_ url: URL) -> Bool {
        guard !isBusy else { return false }
        isConfirming = false
        guard !exclusionLimitReached else {
            // 拒绝持久化时也撤销本次选择，避免菜单打开后容量变化导致“要求保留却被清理”。
            for scan in scans {
                let protected = scan.items.filter { CleanupExclusions.overlapsLexically($0.url, paths: [url.path]) }
                deselectedItems.formUnion(protected.map(\.id))
                if scan.rule.usesToolCleaner, !protected.isEmpty { selection.remove(scan.id) }
            }
            return false
        }
        guard !CleanupExclusions.normalized([url.path]).isEmpty else { return false }
        settings.cleanExcludedPaths = CleanupExclusions.normalized(excludedPaths + [url.path])
        scan()
        return true
    }

    func removeExclusion(_ path: String) {
        guard !isBusy else { return }
        settings.cleanExcludedPaths.removeAll { $0 == path }
        isConfirming = false
        scan()
    }

    var totalBytes: UInt64 {
        scans.filter(\.isCleanable).reduce(0) { $0 + $1.totalSize }
    }

    var selectedScans: [RuleScan] {
        scans.compactMap { scan in
            let items = selectedItems(in: scan)
            guard !items.isEmpty else { return nil }
            return RuleScan(rule: scan.rule, items: items, skippedCount: scan.skippedCount, blocked: scan.blocked,
                            toolPreview: scan.toolPreview, skippedReasons: scan.skippedReasons, unreadableCount: scan.unreadableCount,
                            toolCachePlan: scan.toolCachePlan)
        }
    }

    var selectedBytes: UInt64 {
        selectedScans.reduce(0) { $0 + $1.totalSize }
    }

    var needsFullDiskAccess: Bool {
        scans.contains { $0.blocked == .needsFullDiskAccess }
    }
    var hasIncompleteScan: Bool { scans.contains { $0.unreadableCount > 0 } }

    /// 定向截图只使用注入结果，不启动扫描或清理。
    func showPreview(_ results: [RuleScan]) {
        scans = results
        deselectedItems = []
        phase = .ready
        lastScan = Date()
    }

    func scans(in category: CleanCategory) -> [RuleScan] {
        scans.filter { $0.rule.category == category }
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func revealLog() {
        let log = CleanLog().url
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        }
    }

    func reveal(_ item: CleanItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// 运行中的应用在主线程读取一次后传入后台扫描
    private func environment() -> CleanEnvironment {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return CleanEnvironment(runningBundleIdentifiers: { running }, excludedPaths: settings.cleanExcludedPaths)
    }
}
