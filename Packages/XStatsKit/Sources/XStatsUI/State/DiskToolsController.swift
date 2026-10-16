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
  @ObservationIgnored private var volumeTask: Task<Void, Never>?
  @ObservationIgnored private var volumesVisible = false
  @ObservationIgnored private var volumesPaused = false
  @ObservationIgnored private var volumeRefreshPending = false
  @ObservationIgnored private let readVolumes: @Sendable () -> [MountedVolume]
  @ObservationIgnored private let scanSpace:
    @Sendable (@Sendable (SpaceScanProgress) -> Void) throws -> SpaceScanResult

  init(
    helper: HelperClient, defaults: UserDefaults = .standard,
    readVolumes: @escaping @Sendable () -> [MountedVolume] = { MountedVolumes.list() },
    scanSpace:
      @escaping @Sendable (@Sendable (SpaceScanProgress) -> Void) throws -> SpaceScanResult = {
        try SpaceScanner.scan(progress: $0)
      }
  ) {
    self.helper = helper
    self.defaults = defaults
    self.readVolumes = readVolumes
    self.scanSpace = scanSpace
    lastVerified = defaults.object(forKey: Keys.lastVerified) as? Date
    lastVerifiedOK = defaults.object(forKey: Keys.lastVerifiedOK) as? Bool ?? true
  }

  /// 快照仅在主窗口打开时读取；卷信息由可见需求独立管理，弹窗不启动快照扫描。
  func pageOpened() {
    refreshSnapshots()
  }

  func setVolumesVisible(_ visible: Bool) {
    guard volumesVisible != visible else { return }
    volumesVisible = visible
    updateVolumeDemand()
  }

  func setPaused(_ paused: Bool) {
    guard volumesPaused != paused else { return }
    volumesPaused = paused
    updateVolumeDemand()
  }

  private var needsVolumes: Bool { volumesVisible && !volumesPaused }

  private func updateVolumeDemand() {
    let center = NSWorkspace.shared.notificationCenter
    guard needsVolumes else {
      for observer in volumeObservers { center.removeObserver(observer) }
      volumeObservers.removeAll()
      volumeRefreshPending = false
      volumeTask?.cancel()
      volumes = []
      return
    }
    if volumeObservers.isEmpty {
      for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
        volumeObservers.append(
          center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshVolumes() }
          })
      }
    }
    refreshVolumes()
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
        snapshotOutcome = Outcome(
          text: tr("已删除 \(identifiers.count) 个快照，腾出的空间稍后会反映在“可清除”里"), isError: false)
      }
      refreshSnapshots()
    }
  }

  // MARK: 卷宗

  func refreshVolumes() {
    guard needsVolumes else { return }
    guard volumeTask == nil else {
      volumeRefreshPending = true
      return
    }
    volumeRefreshPending = false
    let readVolumes = readVolumes
    volumeTask = Task { [weak self] in
      let worker = Task.detached(priority: .utility) {
        guard !Task.isCancelled else { return [MountedVolume]() }
        return readVolumes()
      }
      let result = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard let self else { return }
      let cancelled = Task.isCancelled
      volumeTask = nil
      if needsVolumes && !cancelled { volumes = result }
      // 多次装卸通知合并为一次后续读取；旧读取结束前不启动并发扫描。
      if needsVolumes && (cancelled || volumeRefreshPending) { refreshVolumes() }
    }
  }

  /// 原生截图使用确定性卷信息，不访问真实挂载路径。
  func showPreview(volumes: [MountedVolume]) { self.volumes = volumes }

  func eject(_ volume: MountedVolume) {
    guard !ejecting.contains(volume.id) else { return }
    ejecting.insert(volume.id)
    volumeOutcome = nil
    Task {
      defer { ejecting.remove(volume.id) }
      do {
        try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url) }
          .value
        volumeOutcome = Outcome(text: tr("已推出“\(volume.name)”"), isError: false)
      } catch {
        volumeOutcome = Outcome(
          text: tr("无法推出“\(volume.name)”：\(error.localizedDescription)"), isError: true)
      }
      refreshVolumes()
    }
  }

  // MARK: 空间分析

  func startScan() {
    guard scanTask == nil else { return }
    scanPhase = .scanning(SpaceScanProgress(items: 0, bytes: 0, current: ""))
    trashOutcome = nil
    let scanSpace = scanSpace
    scanTask = Task {
      defer { scanTask = nil }
      do {
        // 用户点了按钮在等结果，不用 utility：那一档的磁盘读取会被系统限速
        let scan = Task.detached(priority: .userInitiated) {
          try scanSpace { progress in
            Task { @MainActor in self.report(progress) }
          }
        }
        // 分离任务不继承取消，需显式转发，遍历才能在检查点提前结束
        let result = try await withTaskCancellationHandler {
          try await scan.value
        } onCancel: {
          scan.cancel()
        }
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
        scanPhase = .finished(
          SpaceScanResult(
            root: result.root, folders: result.folders,
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
