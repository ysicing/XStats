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
        guard !isBusy, !(ifNeeded && lastScan != nil) else { return }
        phase = .scanning
        isConfirming = false
        let environment = Self.environment()
        let rules = rules
        task = Task {
            let results = await CleanEngine.scan(rules, environment: environment)
            guard !Task.isCancelled else { phase = scans.isEmpty ? .idle : .ready; return }
            scans = results
            lastScan = Date()
            phase = .ready
        }
    }

    func requestClean() {
        guard phase == .ready || phase == .finished, !selectedScans.isEmpty else { return }
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
        guard isConfirming else { return }
        isConfirming = false
        report = nil
        cleanProgress = nil
        isCancelling = false
        phase = .cleaning
        let environment = Self.environment()
        let scans = scans
        let selection = selection
        let preferTrash = settings.cleanPrefersTrash
        task = Task { [self] in
            var result = await CleanEngine.clean(scans, selected: selection, preferTrash: preferTrash,
                                                environment: environment) { [weak self] progress in
                await MainActor.run { self?.cleanProgress = progress }
            }
            result.wasCancelled = result.wasCancelled || Task.isCancelled
            report = result
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
            let rescanned = await CleanEngine.scan(rules, environment: Self.environment())
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
        guard scan.isCleanable else { return }
        if selection.contains(scan.id) { selection.remove(scan.id) } else { selection.insert(scan.id) }
        isConfirming = false
    }

    var totalBytes: UInt64 {
        scans.filter(\.isCleanable).reduce(0) { $0 + $1.totalSize }
    }

    var selectedScans: [RuleScan] {
        scans.filter { $0.isCleanable && selection.contains($0.id) }
    }

    var selectedBytes: UInt64 {
        selectedScans.reduce(0) { $0 + $1.totalSize }
    }

    var needsFullDiskAccess: Bool {
        scans.contains { $0.blocked == .needsFullDiskAccess }
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
    private static func environment() -> CleanEnvironment {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return CleanEnvironment(runningBundleIdentifiers: { running })
    }
}
