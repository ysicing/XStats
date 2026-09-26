import AppKit
import Foundation
import Localization
import Observation
import Updates

/// 在线升级：检查官网版本清单，发现新版时提示摘要，一键下载、校验、原地替换并重启
@MainActor
@Observable
public final class UpdateController {
    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case verifying
        case installing
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public private(set) var release: UpdateRelease?
    public private(set) var lastChecked: Date? {
        didSet { defaults.set(lastChecked, forKey: Keys.lastChecked) }
    }
    public private(set) var skippedVersion: String? {
        didSet { defaults.set(skippedVersion, forKey: Keys.skippedVersion) }
    }

    /// 自动检查发现未跳过的新版本时调用，由 AppController 打开升级提示窗口
    @ObservationIgnored var onPrompt: () -> Void = {}
    /// 安装完成后退出应用，等进程结束再打开新版
    @ObservationIgnored var terminate: () -> Void = { NSApp.terminate(nil) }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let launchedAt: Date

    init(settings: AppSettings, defaults: UserDefaults = .standard, launchedAt: Date = Date()) {
        self.settings = settings
        self.defaults = defaults
        self.launchedAt = launchedAt
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
        skippedVersion = defaults.string(forKey: Keys.skippedVersion)
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }

    /// 开发构建没有 Developer ID 签名，无法校验新版的签名团队，只能手动安装
    var installBlockedReason: String? {
        // 更新源暂不迁移，但安装包仍必须匹配 XStats 身份，不能放宽为接受旧产品。
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID == "work.12306.xstats.app" else { return tr("开发构建不支持在线升级") }
        guard UpdateInstaller.teamIdentifier(of: Bundle.main.bundleURL) != nil else { return tr("开发构建不支持在线升级，请下载安装包") }
        return nil
    }

    // MARK: 检查

    /// 启动时或运行期间按用户选择的策略检查；失败后由后续调度重试。
    func checkIfNeeded() {
        let schedule = settings.updateCheckSchedule
        guard !isBusy, schedule.shouldCheck(lastChecked: lastChecked, now: Date(), launchedAt: launchedAt) else { return }
        check(userInitiated: false, suppressPrompt: !schedule.promptsForUpdates)
    }

    func check(userInitiated: Bool, suppressPrompt: Bool = false) {
        guard !isBusy else { return }
        phase = .checking
        task = Task {
            let result = await Self.fetch(currentVersion: currentVersion)
            switch result {
            case .success(let feed):
                // 只有拿到清单才算检查过：登录时网络常常还没连上，失败后由每小时的定时器重试，而不是等一整天
                lastChecked = Date()
                // 清单里没有这台 Mac 芯片的安装包时当作没有新版本
                guard let latest = UpdateFeed.release(feed, for: .current),
                      UpdateFeed.isNewer(latest.version, than: currentVersion) else {
                    release = nil
                    phase = .upToDate
                    return
                }
                release = latest
                phase = .available
                Log.update.notice("发现新版本 \(latest.version, privacy: .public)")
                // 手动检查时总是提示；自动检查时跳过用户选择忽略的版本
                if userInitiated || (!suppressPrompt && latest.version != skippedVersion) { onPrompt() }
            case .failure(let error):
                Log.update.error("检查更新失败：\(error.localizedDescription, privacy: .public)")
                // 自动检查失败不打扰用户，只在关于页里显示
                phase = userInitiated ? .failed(error.localizedDescription) : (release == nil ? .idle : .available)
            }
        }
    }

    private static func fetch(currentVersion: String) async -> Result<UpdateRelease, UpdateError> {
        do {
            let installationID = try InstallationIdentity().hashedID()
            return await fetch(
                currentVersion: currentVersion,
                installationID: installationID,
                prefersChina: UpdateFeed.prefersChinaEndpoint()
            ) { try await URLSession.shared.data(for: $0) }
        } catch {
            return .failure(.download(error.localizedDescription))
        }
    }

    static func fetch(
        currentVersion: String,
        installationID: String,
        prefersChina: Bool,
        send: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> Result<UpdateRelease, UpdateError> {
        var lastError = UpdateError.download(tr("没有可用的更新服务"))
        for endpoint in UpdateFeed.checkURLs(prefersChina: prefersChina) {
            do {
                let request = try UpdateFeed.checkRequest(
                    url: endpoint, currentVersion: currentVersion, installationID: installationID
                )
                let (data, response) = try await send(request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    lastError = .download(tr("服务器返回 \(http.statusCode)"))
                    continue
                }
                guard let release = UpdateFeed.parse(data) else {
                    lastError = .download(tr("版本清单格式不正确"))
                    continue
                }
                return .success(release)
            } catch {
                lastError = .download(error.localizedDescription)
            }
        }
        return .failure(lastError)
    }

    /// 截图用：直接放入一个示例版本
    func showPreview(_ release: UpdateRelease) {
        self.release = release
        phase = .available
    }

    func skipCurrentRelease() {
        skippedVersion = release?.version
    }

    // MARK: 安装

    func install() {
        guard let release, !isBusy else { return }
        if let reason = installBlockedReason {
            phase = .failed(reason)
            return
        }
        guard UpdateFeed.systemSatisfies(release.minimumSystem) else {
            phase = .failed(tr("新版本需要 macOS \(release.minimumSystem) 或更高版本"))
            return
        }
        let app = Bundle.main.bundleURL
        guard let team = UpdateInstaller.teamIdentifier(of: app) else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? ""

        phase = .downloading(0)
        task = Task {
            do {
                // 临时目录与应用在同一卷上，替换时是原子改名
                let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                       appropriateFor: app, create: true)
                defer { try? FileManager.default.removeItem(at: work) }

                let archive = try await UpdateInstaller.download(release.url, into: work) { fraction in
                    Task { @MainActor in
                        guard case .downloading = self.phase else { return }
                        self.phase = .downloading(fraction)
                    }
                }
                phase = .verifying
                let candidate = try await Task.detached {
                    guard try UpdateInstaller.sha256(of: archive) == release.sha256.lowercased() else {
                        throw UpdateError.checksumMismatch
                    }
                    let candidate = try UpdateInstaller.extractApp(from: archive, into: work)
                    try UpdateInstaller.verify(candidate, bundleIdentifier: bundleID, version: release.version, teamIdentifier: team)
                    return candidate
                }.value

                phase = .installing
                if UpdateInstaller.canReplaceInPlace(app) {
                    try await Task.detached { try UpdateInstaller.replace(app, with: candidate, backupDirectory: work) }.value
                } else {
                    try await Task.detached { try UpdateInstaller.stopWidgetExtension(in: app) }.value
                    try await replaceWithAdministratorPrompt(app, with: candidate)
                }
                skippedVersion = nil
                Log.update.notice("已安装 \(release.version, privacy: .public)，重新启动")
                try? FileManager.default.removeItem(at: work)
                try UpdateInstaller.relaunch(app)
                terminate()
            } catch {
                // 取消下载时 URLSession 抛出的是 URLError，按任务是否被取消判断
                if !Task.isCancelled { Log.update.error("安装更新失败：\(error.localizedDescription, privacy: .public)") }
                phase = Task.isCancelled ? .available
                    : .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// 手动下载地址：拿到清单时用其中的 DMG，否则回到 GitHub Releases——那里始终挂着最新版 dmg
    var manualDownloadURL: URL {
        release?.dmg ?? URL(string: "https://github.com/ysicing/xstats/releases/latest")!
    }

    func openManualDownload() {
        NSWorkspace.shared.open(manualDownloadURL)
    }

    /// 当前账户不能改写应用目录时（非管理员或应用放在受保护的位置），请求一次管理员授权完成替换
    private func replaceWithAdministratorPrompt(_ app: URL, with candidate: URL) async throws {
        let quote = { (path: String) in "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let backup = candidate.deletingLastPathComponent().appendingPathComponent("previous-\(app.lastPathComponent)")
        let (a, b, c) = (quote(app.path), quote(backup.path), quote(candidate.path))
        // 旧版改名备份 → 新版移入；移入失败时还原旧版并以失败退出；成功后沿用旧版的属主
        let shell = "/bin/mv -f \(a) \(b) && { /bin/mv -f \(c) \(a) || { /bin/mv -f \(b) \(a); exit 1; }; }"
            + " && /usr/sbin/chown -R \"$(/usr/bin/stat -f %u:%g \(b))\" \(a)"
        if let error = await MaintenanceController.runWithAdministratorPrompt(shell: shell, prompt: tr("XStats 需要授权以安装新版本。")) {
            throw UpdateError.install(error)
        }
        guard FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path) else {
            throw UpdateError.install(tr("替换后未找到应用"))
        }
    }

    private enum Keys {
        static let lastChecked = "updateLastChecked"
        static let skippedVersion = "updateSkippedVersion"
    }
}
