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
    public var selection: Set<String>
    public var isConfirming = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let rules = RuleCatalog.rules()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        selection = Set(rules.filter(\.selectedByDefault).map(\.id))
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
            scans = results
            lastScan = Date()
            phase = .ready
        }
    }

    func requestClean() {
        guard phase == .ready || phase == .finished, selectedBytes > 0 else { return }
        isConfirming = true
    }

    func cancelClean() {
        isConfirming = false
    }

    func confirmClean() {
        guard isConfirming else { return }
        isConfirming = false
        phase = .cleaning
        let environment = Self.environment()
        let scans = scans
        let selection = selection
        let preferTrash = settings.cleanPrefersTrash
        task = Task {
            let result = await CleanEngine.clean(scans, selected: selection, preferTrash: preferTrash, environment: environment)
            report = result
            phase = .finished
            // 清理后重新计算剩余可清理空间
            let rescanned = await CleanEngine.scan(rules, environment: Self.environment())
            self.scans = rescanned
            lastScan = Date()
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
