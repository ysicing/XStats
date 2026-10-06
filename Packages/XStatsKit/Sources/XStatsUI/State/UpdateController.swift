import AppKit
import Foundation
import Localization
import Observation
import Sparkle
import Updates

/// 在线升级：Sparkle 管理检查、跳过和安装，XStats 提供现有界面与系统通知。
@MainActor
@Observable
public final class UpdateController {
    public typealias Phase = UpdatePhase

    public private(set) var phase: Phase = .idle
    public private(set) var release: UpdateRelease?
    public private(set) var lastChecked: Date? {
        didSet { defaults.set(lastChecked, forKey: Keys.lastChecked) }
    }
    public private(set) var skippedVersion: String? {
        didSet { defaults.set(skippedVersion, forKey: Keys.skippedVersion) }
    }

    /// 手动检查发现新版本时调用，由 AppController 打开升级提示窗口
    @ObservationIgnored var onPrompt: () -> Void = {}
    /// 后台发现新版本时请求系统通知；成功提交后才记录去重状态。
    @ObservationIgnored var onUpdateAvailable: (String) async -> Bool = { _ in false }

    @ObservationIgnored var prepareForInstallation: () async throws -> Void = {}
    @ObservationIgnored var cancelInstallationPreparation: () -> Void = {}

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var sparkleInstaller: SparkleInstaller?
    @ObservationIgnored private let launchedAt: Date
    @ObservationIgnored private var isNotifying = false
    @ObservationIgnored private var started = false

    init(settings: AppSettings, defaults: UserDefaults = .standard, launchedAt: Date = Date()) {
        self.settings = settings
        self.defaults = defaults
        self.launchedAt = launchedAt
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        skippedVersion = defaults.string(forKey: Keys.skippedVersion)
        // Sparkle 公开记录键：首轮迁移继承旧成功时间，避免“刚检查过”被当成首次检查。
        // 只初始化一次，之后不覆盖 Sparkle 自己管理的检查时间。
        if defaults.object(forKey: "SULastCheckTime") == nil, let lastChecked {
            defaults.set(lastChecked, forKey: "SULastCheckTime")
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 已知版本在“以后再说”后仍可查看；跳过版本立即隐藏，离线也不撤销选择。
    var hasAvailableUpdate: Bool {
        guard let release else { return false }
        return release.version != skippedVersion
    }

    /// 只打开已发现版本的现有窗口，不重新联网检查或自动安装。
    func presentAvailableUpdate() {
        guard hasAvailableUpdate else { return }
        onPrompt()
    }

    /// Sparkle 已持久化跳过条目后，清掉对应界面缓存，避免旧提醒随兼容记录清除而重现。
    func finishSkipMigration() {
        if release?.version == skippedVersion {
            release = nil
            // 清空缓存后，周期结束回调不再看到已知版本；这里同步结束跳过检查的忙碌态。
            phase = .idle
        }
        skippedVersion = nil
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    var installationRequiresPreparation: Bool {
        phase == .installing || sparkleInstaller?.hasInstallationRequest == true
    }

    /// 未签名或临时签名的开发构建不执行在线安装，只提供手动下载
    var installBlockedReason: String? {
        // 仅为当前产品启用安装器，防止开发/旧产品构建误用发布更新源。
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID == "work.12306.xstats.app" else { return tr("开发构建不支持在线升级") }
        guard UpdateInstaller.teamIdentifier(of: Bundle.main.bundleURL) != nil else { return tr("开发构建不支持在线升级，请下载安装包") }
        return nil
    }

    // MARK: 检查

    func installationPreparationFailed(_ error: any Error) {
        sparkleInstaller?.dismissUpdateInstallation()
        phase = .failed(error.localizedDescription)
    }

    func prepareForTermination() async throws {
        if let sparkleInstaller { try await sparkleInstaller.waitForInstallationPreparation() }
        else { throw UpdateError.invalidBundle(tr("版本清单格式不正确")) }
    }

    /// 启动后创建唯一的 Sparkle 调度器；不另设 XStats 轮询定时器。
    func start() {
        guard !started else { return }
        do {
            try ensureUpdater()
            started = true
            applySchedule(initial: true)
            observeSchedule()
            checkIfNeeded()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func ensureUpdater() throws {
        guard updater == nil else { return }
        let driver = SparkleInstaller(onPhase: { [weak self] in self?.phase = $0 },
                                      onRelaunch: { [weak self] in self?.skippedVersion = nil })
        driver.prepareForInstallation = { [weak self] in try await self?.prepareForInstallation() }
        driver.cancelInstallationPreparation = { [weak self] in self?.cancelInstallationPreparation() }
        driver.onChecked = { [weak self] in self?.lastChecked = Date() }
        driver.onNoUpdate = { [weak self] in self?.release = nil }
        driver.onRelease = { [weak self] release, manual in
            guard let self else { return }
            self.release = release
            Task { [weak self] in
                await self?.announceUpdate(version: release.version, userInitiated: manual,
                                           suppressPrompt: !(self?.settings.updateCheckSchedule.promptsForUpdates ?? false))
            }
        }
        driver.legacySkippedVersion = { [weak self] in self?.skippedVersion }
        driver.hasKnownRelease = { [weak self] in self?.release != nil }
        driver.onLegacySkipMigrated = { [weak self] in self?.finishSkipMigration() }
        driver.onCycleFinished = { [weak self] success in self?.applySchedule(retry: !success) }
        sparkleInstaller = driver
        updater = try driver.start()
    }

    private func observeSchedule() {
        withObservationTracking {
            _ = settings.updateCheckSchedule
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applySchedule(initial: true)
                self?.observeSchedule()
                self?.checkIfNeeded()
            }
        }
    }

    /// Sparkle 的 timer 负责唤醒，薄策略层只保留启动检查、成功后间隔和自然月语义。
    private func applySchedule(initial: Bool = false, retry: Bool = false) {
        guard let updater else { return }
        let now = Date()
        guard let interval = settings.updateCheckSchedule.sparkleInterval(lastChecked: lastChecked, now: now,
                                                                          launchedAt: launchedAt, retry: retry) else {
            if updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = false }
            return
        }
        // 首次配置会按 Sparkle 的上次尝试时间减去 elapsed；补偿该值，保持旧成功记录的到期日。
        let elapsed = initial ? max(0, now.timeIntervalSince(updater.lastUpdateCheckDate ?? now)) : 0
        let nextInterval = max(60 * 60, interval + elapsed)
        // Sparkle 的 setter 会触发 KVO/reset，即使值相同；无变化时不要重新安排周期。
        if abs(updater.updateCheckInterval - nextInterval) >= 1 { updater.updateCheckInterval = nextInterval }
        if !updater.automaticallyChecksForUpdates { updater.automaticallyChecksForUpdates = true }
    }

    func checkIfNeeded() {
        let schedule = settings.updateCheckSchedule
        guard !isBusy, schedule.shouldCheck(lastChecked: lastChecked, now: Date(), launchedAt: launchedAt) else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !isBusy, sparkleInstaller?.isRunning != true else { return }
        do {
            try ensureUpdater()
            sparkleInstaller?.check(userInitiated: userInitiated)
        } catch {
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// 手动检查始终展示结果；后台通知遵循静默策略、开关、跳过版本及跨重启去重。
    func announceUpdate(version: String, userInitiated: Bool, suppressPrompt: Bool) async {
        if userInitiated {
            onPrompt()
            return
        }
        guard !suppressPrompt, settings.notifyUpdates, version != skippedVersion,
              !isNotifying else { return }
        if let last = defaults.string(forKey: Keys.notifiedVersion), !UpdateFeed.isNewer(version, than: last) { return }
        // 通知权限弹窗期间允许查看更新，但不能重复提交后台通知。
        isNotifying = true
        defer { isNotifying = false }
        if await onUpdateAvailable(version) { defaults.set(version, forKey: Keys.notifiedVersion) }
    }

    /// 截图用：直接放入一个示例版本
    func showPreview(_ release: UpdateRelease) {
        self.release = release
        phase = .available
    }

    func skipCurrentRelease() {
        guard let release, !isBusy else { return }
        // 点击后立即生效，即使此时离线；签名条目重新可达时再交给 Sparkle 持久化。
        skippedVersion = release.version
        do {
            try ensureUpdater()
            sparkleInstaller?.check(userInitiated: false, action: .skip(release))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: 安装

    func install() {
        guard let release, !isBusy, sparkleInstaller?.isRunning != true else { return }
        if let reason = installBlockedReason {
            phase = .failed(reason)
            return
        }
        guard UpdateFeed.systemSatisfies(release.minimumSystem) else {
            phase = .failed(tr("新版本需要 macOS \(release.minimumSystem) 或更高版本"))
            return
        }
        do {
            try ensureUpdater()
            sparkleInstaller?.check(userInitiated: false, action: .install(release))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func cancel() { sparkleInstaller?.cancel() }

    /// 手动下载地址：拿到清单时用其中的 DMG，否则回到 GitHub Releases——那里始终挂着最新版 dmg
    var manualDownloadURL: URL {
        release?.dmg ?? URL(string: "https://github.com/ysicing/xstats/releases/latest")!
    }

    func openManualDownload() {
        NSWorkspace.shared.open(manualDownloadURL)
    }

    private enum Keys {
        static let lastChecked = "updateLastChecked"
        static let skippedVersion = "updateSkippedVersion"
        static let notifiedVersion = "updateNotifiedVersion"
    }
}
