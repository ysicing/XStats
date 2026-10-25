import AppKit
import Cleaner
import Foundation
import Observation

@MainActor
@Observable
public final class CleanerController {
  enum Engine: Hashable { case native, mole }
  private(set) var engine: Engine = .native
  let mole: MoleController

  func selectEngine(_ engine: Engine) {
    guard phase != .cleaning, !mole.isRunning, engine != .mole || mole.executable != nil else {
      return
    }
    if phase == .scanning { cancelOperation() }
    cancelClean()
    mole.cancelConfirmation()
    self.engine = engine
  }

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
  /// 弹出确认时冻结的选择；提示文案与最终执行使用同一份，避免确认期间选择或排除项变化后“所见非所清”。
  private(set) var pendingScans: [RuleScan] = []
  private var deselectedItems: Set<String> = []
  private var applications: CacheApplicationInventory?

  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let cpuUsage: @MainActor @Sendable () -> Double?
  // 不支持清理的规则不参与应用识别或扫描；专属目录仍由引擎独立保护。
  @ObservationIgnored private let rules = RuleCatalog.rules().filter { !$0.previewOnly }
  @ObservationIgnored private var task: Task<Void, Never>?

  init(
    settings: AppSettings,
    mole: MoleController? = nil,
    cpuUsage: @escaping @MainActor @Sendable () -> Double? = { nil }
  ) {
    self.settings = settings
    self.mole = mole ?? MoleController(settings: settings)
    self.cpuUsage = cpuUsage
    let validIDs = Set(rules.map(\.id))
    let initial = settings.cleanSelectedRuleIDs ?? Set(rules.filter(\.selectedByDefault).map(\.id))
    selection = initial.intersection(validIDs)
    self.mole.nativeIsBusy = { [weak self] in self?.isBusy == true }
    self.mole.onExecutionFinished = { [weak self] in self?.discardScanResults() }
  }

  /// Mole 按自己的规则删除文件，原生候选与容量不再代表当前状态；切回原生引擎时重新扫描。
  private func discardScanResults() {
    guard !isBusy else { return }
    scans = []
    report = nil
    lastScan = nil
    phase = .idle
    invalidateConfirmation()
  }

  var isBusy: Bool { phase == .scanning || phase == .cleaning }

  func scan(ifNeeded: Bool = false) {
    guard engine == .native, !mole.isRunning else { return }
    guard settings.cleanerEnabled, !isBusy, !(ifNeeded && lastScan != nil) else { return }
    phase = .scanning
    invalidateConfirmation()
    let environment = environment()
    let rules = rules
    task = Task {
      let applications = try? await CacheApplicationInventory.read(
        rules: rules, environment: environment)
      guard !Task.isCancelled else {
        phase = scans.isEmpty ? .idle : .ready
        return
      }
      let results = await CleanEngine.scan(rules, environment: environment)
      guard !Task.isCancelled else {
        phase = scans.isEmpty ? .idle : .ready
        return
      }
      self.applications = applications
      if let applications { rememberApplications(applications) }
      scans = results
      deselectedItems.formIntersection(results.flatMap { $0.items.map(\.id) })
      lastScan = Date()
      phase = .ready
    }
  }

  func requestClean() {
    guard engine == .native, !mole.isRunning else { return }
    guard settings.cleanerEnabled, phase == .ready || phase == .finished, !selectedScans.isEmpty
    else { return }
    pendingScans = selectedScans
    isConfirming = true
  }

  func cancelClean() {
    invalidateConfirmation()
  }

  /// 选择、排除项或扫描结果变化后，之前冻结的确认内容不再有效。
  private func invalidateConfirmation() {
    isConfirming = false
    pendingScans = []
  }

  func cancelOperation() {
    guard isBusy else { return }
    if phase == .cleaning { isCancelling = true }
    task?.cancel()
  }

  func confirmClean() {
    guard engine == .native, !mole.isRunning else { return }
    // 系统弹层可能先清除展示绑定，所以以冻结的选择而不是 isConfirming 判断是否已确认。
    guard settings.cleanerEnabled, phase == .ready || phase == .finished, !pendingScans.isEmpty
    else { return }
    let scans = pendingScans
    invalidateConfirmation()
    report = nil
    cleanProgress = nil
    isCancelling = false
    phase = .cleaning
    Log.app.notice(
      "Cleanup started rules=\(scans.count) items=\(scans.reduce(0) { $0 + $1.items.count })"
    )
    let environment = environment()
    let selection = Set(scans.map(\.id))
    let preferTrash = settings.cleanPrefersTrash
    task = Task { [self] in
      var result = await CleanEngine.clean(
        scans, selected: selection, preferTrash: preferTrash,
        environment: environment,
        refreshRunningApps: {
          await MainActor.run {
            Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
          }
        },
        refreshRunningApplicationNames: {
          await MainActor.run { Self.runningApplicationNames() }
        }
      ) { [weak self] progress in
        await MainActor.run { self?.cleanProgress = progress }
      }
      result.wasCancelled = result.wasCancelled || Task.isCancelled
      report = result
      Log.app.notice(
        "Cleanup completed removed=\(result.removedCount) skipped=\(result.skippedCount) failures=\(result.failures.count) cancelled=\(result.wasCancelled)"
      )
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
      let rescanEnvironment = self.environment()
      let applications = try? await CacheApplicationInventory.read(
        rules: rules, environment: rescanEnvironment)
      let rescanned = await CleanEngine.scan(rules, environment: rescanEnvironment)
      if !Task.isCancelled {
        self.applications = applications
        if let applications { rememberApplications(applications) }
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
    } else {
      selection.remove(scan.id)
    }
    invalidateConfirmation()
  }

  func toggle(_ item: CleanItem, in scan: RuleScan) {
    guard !isBusy, scan.isCleanable, !scan.rule.usesToolCleaner else { return }
    let wasSelected = selectedItems(in: scan).contains { $0.id == item.id }
    if !selection.contains(scan.id) {
      deselectedItems.formUnion(scan.items.map(\.id))
      selection.insert(scan.id)
    }
    if wasSelected { deselectedItems.insert(item.id) } else { deselectedItems.remove(item.id) }
    invalidateConfirmation()
  }

  func selectedItems(in scan: RuleScan) -> [CleanItem] {
    guard selection.contains(scan.id), scan.isCleanable else { return [] }
    return scan.items.filter {
      !deselectedItems.contains($0.id)
        && !CleanupExclusions.overlapsLexically($0.url, paths: settings.cleanExcludedPaths)
    }
  }

  var excludedPaths: [String] { settings.cleanExcludedPaths }
  var exclusionLimitReached: Bool { excludedPaths.count >= 50 }

  @discardableResult
  func exclude(_ url: URL) -> Bool {
    guard !isBusy else { return false }
    invalidateConfirmation()
    guard !exclusionLimitReached else {
      // 拒绝持久化时也撤销本次选择，避免菜单打开后容量变化导致“要求保留却被清理”。
      for scan in scans {
        let protected = scan.items.filter {
          CleanupExclusions.overlapsLexically($0.url, paths: [url.path])
        }
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
    invalidateConfirmation()
    scan()
  }

  var totalBytes: UInt64 {
    CleanItem.totalSize(
      of: scans.filter { $0.isCleanable && !$0.rule.usesToolCleaner }.flatMap(\.items))
  }

  var selectedScans: [RuleScan] {
    scans.compactMap { scan in
      let items = selectedItems(in: scan)
      guard !items.isEmpty else { return nil }
      return RuleScan(
        rule: scan.rule, items: items, skippedCount: scan.skippedCount, blocked: scan.blocked,
        toolPreview: scan.toolPreview, skippedReasons: scan.skippedReasons,
        unreadableCount: scan.unreadableCount,
        toolCachePlan: scan.toolCachePlan, interruption: scan.interruption)
    }
  }

  /// 确认弹窗展示的内容：已冻结时用冻结的选择，否则退回当前选择。
  var confirmationScans: [RuleScan] { pendingScans.isEmpty ? selectedScans : pendingScans }

  var selectedBytes: UInt64 {
    CleanItem.totalSize(of: selectedScans.filter { !$0.rule.usesToolCleaner }.flatMap(\.items))
  }

  var needsFullDiskAccess: Bool {
    scans.contains { !$0.rule.previewOnly && $0.blocked == .needsFullDiskAccess }
  }
  var hasIncompleteScan: Bool {
    scans.contains { !$0.rule.previewOnly && ($0.unreadableCount > 0 || $0.interruption != nil) }
  }

  /// 定向截图只使用注入结果，不启动扫描或清理。
  func showPreview(_ results: [RuleScan], applications: CacheApplicationInventory? = nil) {
    self.applications = applications
    scans = results
    deselectedItems = []
    invalidateConfirmation()
    phase = .ready
    lastScan = Date()
  }

  enum ApplicationState {
    case untracked, unknown, installed, previouslyInstalled, cacheRemains, notFound
  }

  func applicationState(for scan: RuleScan) -> ApplicationState {
    guard scan.rule.tracksApplicationPresence else { return .untracked }
    if applications?.installedRuleIDs.contains(scan.id) == true { return .installed }
    // 清单读取失败或不完整时无法确认已卸载，历史记录不能推断为“曾安装”。
    guard applications?.isComplete == true else { return .unknown }
    if settings.cleanObservedApplicationRuleIDs.contains(scan.id) { return .previouslyInstalled }
    return scan.items.isEmpty ? .notFound : .cacheRemains
  }

  func shouldDisplay(_ scan: RuleScan) -> Bool {
    // 清理列表只展示支持清理的规则；隐藏仅查看项不撤销底层路径保护。
    guard !scan.rule.previewOnly else { return false }
    // 只有完整空结果才能判定无缓存；运行保护、权限失败和预算中断均不代表没有内容。
    return applicationState(for: scan) != .notFound || !scan.isComplete || scan.skippedCount > 0
  }

  func keepsEmptyVisible(_ scan: RuleScan) -> Bool {
    applicationState(for: scan) == .previouslyInstalled
  }

  func rememberApplications(_ applications: CacheApplicationInventory) {
    guard !Task.isCancelled else { return }
    let validIDs = Set(rules.filter(\.tracksApplicationPresence).map(\.id))
    let observed = settings.cleanObservedApplicationRuleIDs
      .union(applications.installedRuleIDs).intersection(validIDs)
    if observed != settings.cleanObservedApplicationRuleIDs {
      settings.cleanObservedApplicationRuleIDs = observed
    }
  }

  func scans(in category: CleanCategory) -> [RuleScan] {
    scans.filter { $0.rule.category == category }
  }

  func openFullDiskAccessSettings() {
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    else { return }
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
    let names = Self.runningApplicationNames()
    var environment = CleanEnvironment(
      runningBundleIdentifiers: { running }, runningApplicationNames: { names },
      excludedPaths: settings.cleanExcludedPaths)
    let cpuUsage = cpuUsage
    environment.scanLoad = { .current(cpuUsage: await cpuUsage()) }
    return environment
  }
  private static func runningApplicationNames() -> Set<String> {
    Set(
      NSWorkspace.shared.runningApplications.flatMap { app in
        // 辅助进程可能独立存活；同时记录其外层 .app，避免主进程退出后失去名称保护。
        let bundleNames = (app.bundleURL?.pathComponents ?? []).filter { $0.hasSuffix(".app") }
          .map { String($0.dropLast(4)) }
        // 同时记录可执行文件名：localizedName 可能被本地化，辅助进程的名称也未必与外层应用一致。
        return bundleNames
          + [app.localizedName, app.executableURL?.lastPathComponent]
          .compactMap { $0 }
      })
  }
}
