import AppKit
import Cleaner
import Foundation
import HelperShared
import Localization
import Metrics
import Observation

/// 磁盘页上能动手的部分：文件系统检查、Time Machine 本地快照、其他已装载的磁盘、家目录空间分析
@MainActor
@Observable
final class DiskToolsController {
    struct Outcome: Equatable {
        let text: String
        let isError: Bool
    }

    enum VerifyPhase: Equatable {
        case idle
        case running
        case finished(VolumeVerification)
        case failed(String)
    }

    enum ScanPhase: Equatable {
        case idle
        case scanning(SpaceScanProgress)
        case finished(SpaceScanResult)
        case failed(String)
    }

    // MARK: 文件系统检查

    private(set) var verifyPhase: VerifyPhase = .idle
    private(set) var lastVerified: Date? {
        didSet { defaults.set(lastVerified, forKey: Keys.lastVerified) }
    }
    private(set) var lastVerifiedOK: Bool {
        didSet { defaults.set(lastVerifiedOK, forKey: Keys.lastVerifiedOK) }
    }

    // MARK: 本地快照

    private(set) var snapshots: [LocalSnapshot] = []
    private(set) var snapshotsLoaded = false
    private(set) var isDeletingSnapshots = false
    private(set) var snapshotOutcome: Outcome?

    // MARK: 其他磁盘

    private(set) var volumes: [MountedVolume] = []
    private(set) var ejecting: Set<String> = []
    private(set) var volumeOutcome: Outcome?

    // MARK: 空间占用

    private(set) var scanPhase: ScanPhase = .idle
    private(set) var trashOutcome: Outcome?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    @ObservationIgnored private let helper: HelperClient
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []

    init(helper: HelperClient, defaults: UserDefaults = .standard) {
        self.helper = helper
        self.defaults = defaults
        lastVerified = defaults.object(forKey: Keys.lastVerified) as? Date
        lastVerifiedOK = defaults.object(forKey: Keys.lastVerifiedOK) as? Bool ?? true
    }

    /// 磁盘页打开时刷新快照与卷宗；接入、拔出磁盘时跟着刷新
    func pageOpened() {
        refreshSnapshots()
        refreshVolumes()
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
    }

    // MARK: 检查

    func verify() {
        guard verifyPhase != .running else { return }
        verifyPhase = .running
        Task {
            let result = await Task.detached { VolumeVerifier.verify() }.value
            verifyPhase = .finished(result)
            lastVerified = result.date
            lastVerifiedOK = result.ok
            if result.ok {
                Log.app.notice("磁盘检查通过")
            } else {
                Log.app.error("磁盘检查发现问题：\(result.summary, privacy: .public)")
            }
        }
    }

    // MARK: 快照

    func refreshSnapshots() {
        Task {
            let list = await Task.detached { LocalSnapshots.list() }.value
            snapshots = list
            snapshotsLoaded = true
        }
    }

    /// 删掉全部本地快照：辅助工具够新就走它，否则请求一次管理员授权
    func deleteAllSnapshots() {
        guard !isDeletingSnapshots, !snapshots.isEmpty else { return }
        let identifiers = snapshots.map(\.identifier).filter(LocalSnapshotCommand.isValidIdentifier)
        guard !identifiers.isEmpty else {
            snapshotOutcome = Outcome(text: tr("快照名称格式不认识，没有删除"), isError: true)
            return
        }
        isDeletingSnapshots = true
        snapshotOutcome = nil
        Task {
            defer { isDeletingSnapshots = false }
            let error: String?
            if let version = await helper.remoteProtocolVersion(), version >= 4 {
                error = await helper.deleteLocalSnapshots(identifiers: identifiers)
            } else {
                error = await MaintenanceController.runWithAdministratorPrompt(
                    shell: LocalSnapshotCommand.shellCommand(identifiers: identifiers),
                    prompt: tr("XStats 需要管理员权限来删除 Time Machine 本地快照。"))
            }
            if let error {
                Log.app.error("删除本地快照失败：\(error, privacy: .public)")
                snapshotOutcome = Outcome(text: error, isError: error != MaintenanceController.cancelled)
            } else {
                Log.app.notice("已删除 \(identifiers.count) 个本地快照")
                snapshotOutcome = Outcome(text: tr("已删除 \(identifiers.count) 个快照，腾出的空间稍后会反映在“可清除”里"), isError: false)
            }
            refreshSnapshots()
        }
    }

    // MARK: 卷宗

    func refreshVolumes() {
        Task {
            volumes = await Task.detached { MountedVolumes.list() }.value
        }
    }

    func eject(_ volume: MountedVolume) {
        guard !ejecting.contains(volume.id) else { return }
        ejecting.insert(volume.id)
        volumeOutcome = nil
        Task {
            defer { ejecting.remove(volume.id) }
            do {
                try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url) }.value
                volumeOutcome = Outcome(text: tr("已推出“\(volume.name)”"), isError: false)
            } catch {
                volumeOutcome = Outcome(text: tr("无法推出“\(volume.name)”：\(error.localizedDescription)"), isError: true)
            }
            refreshVolumes()
        }
    }

    // MARK: 空间分析

    func startScan() {
        guard scanTask == nil else { return }
        scanPhase = .scanning(SpaceScanProgress(items: 0, bytes: 0, current: ""))
        trashOutcome = nil
        scanTask = Task {
            defer { scanTask = nil }
            do {
                // 用户点了按钮在等结果，不用 utility：那一档的磁盘读取会被系统限速
                let result = try await Task.detached(priority: .userInitiated) {
                    try SpaceScanner.scan { progress in
                        Task { @MainActor in self.report(progress) }
                    }
                }.value
                scanPhase = .finished(result)
                Log.app.notice("空间分析完成：\(result.scannedItems) 个条目")
            } catch is CancellationError {
                scanPhase = .idle
            } catch {
                scanPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func report(_ progress: SpaceScanProgress) {
        if case .scanning = scanPhase { scanPhase = .scanning(progress) }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    /// 把扫描结果里的一个文件移到废纸篓，然后从结果里去掉它
    func trash(_ file: SpaceScanResult.File) {
        do {
            try SpaceScanner.trash(file.url)
            trashOutcome = Outcome(text: tr("已把“\(file.name)”移到废纸篓"), isError: false)
            if case .finished(let result) = scanPhase {
                scanPhase = .finished(SpaceScanResult(root: result.root, folders: result.folders,
                                                      largestFiles: result.largestFiles.filter { $0.id != file.id },
                                                      scannedItems: result.scannedItems, totalBytes: result.totalBytes, date: result.date))
            }
            Log.app.notice("空间分析：移到废纸篓 \(file.url.path, privacy: .private)")
        } catch {
            trashOutcome = Outcome(text: tr("无法移到废纸篓：\(error.localizedDescription)"), isError: true)
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private enum Keys {
        static let lastVerified = "diskLastVerified"
        static let lastVerifiedOK = "diskLastVerifiedOK"
    }
}
