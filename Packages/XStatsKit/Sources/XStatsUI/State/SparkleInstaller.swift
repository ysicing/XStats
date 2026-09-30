// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Sparkle
import Updates

/// Sparkle 的单一更新流程；复用 XStats 界面和系统通知，不自动下载或安装。
@MainActor
final class SparkleInstaller: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    enum Action { case install(UpdateRelease), skip(UpdateRelease) }

    private let bundle: Bundle
    private let onPhase: (UpdateController.Phase) -> Void
    private let onRelaunch: () -> Void
    var onRelease: (UpdateRelease, Bool) -> Void = { _, _ in }
    var onChecked: () -> Void = {}
    var onNoUpdate: () -> Void = {}
    var onCycleFinished: (Bool) -> Void = { _ in }
    var legacySkippedVersion: () -> String? = { nil }
    var onLegacySkipMigrated: () -> Void = {}

    // 控制器强持有 updater，Sparkle 强持有 userDriver；此处只能弱引用，避免循环持有。
    private weak var updater: SPUUpdater?
    private var action: Action?
    private var cancellation: (() -> Void)?
    private var cancelled = false
    private var loadedFeed = false
    private var userInitiated = false
    private var endpointIndex = 0
    private var retryingFeed = false
    private let endpoints: [URL]
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var lastProgress: Double = 0

    var isRunning: Bool { updater?.sessionInProgress == true }

    init(bundle: Bundle = .main,
         endpoints: [URL] = UpdateFeed.sparkleURLs(prefersChina: UpdateFeed.prefersChinaEndpoint()),
         onPhase: @escaping (UpdateController.Phase) -> Void, onRelaunch: @escaping () -> Void) {
        self.bundle = bundle
        self.endpoints = endpoints
        self.onPhase = onPhase
        self.onRelaunch = onRelaunch
    }

    /// 调用方保留返回值。整个应用只创建一个 updater，不在每次检查或重试时创建 XPC 引擎。
    func start() throws -> SPUUpdater {
        if let updater { return updater }
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        self.updater = updater
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false
        updater.sendsSystemProfile = false
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        updater.userAgentString = UpdateFeed.userAgent(currentVersion: version)
        try updater.start()
        return updater
    }

    func check(userInitiated: Bool, action: Action? = nil) {
        guard !isRunning else { return }
        self.action = action
        cancelled = false
        loadedFeed = false
        endpointIndex = 0
        retryingFeed = false
        self.userInitiated = userInitiated
        if userInitiated || action != nil { updater?.checkForUpdates() }
        else { updater?.checkForUpdatesInBackground() }
    }

    func cancel() {
        guard let cancellation else { return }
        cancelled = true
        self.cancellation = nil
        cancellation()
        onPhase(.available)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        endpoints.indices.contains(endpointIndex) ? endpoints[endpointIndex].absoluteString : nil
    }

    @objc(feedParametersForUpdater:sendingSystemProfile:)
    func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] {
        guard let identifier = try? InstallationIdentity().hashedID() else { return [] }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return [["key": "installation_id", "value": identifier], ["key": "current_version", "value": version]]
    }

    @objc(updater:mayPerformUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // 自动调度进入新周期时复位；区域重试保留本周期的用户意图和确认版本。
        if !retryingFeed {
            endpointIndex = 0
            cancelled = false
            loadedFeed = false
            if updateCheck == .updatesInBackground { userInitiated = false; action = nil }
        }
        retryingFeed = false
        onPhase(.checking)
    }

    @objc(updaterShouldPromptForPermissionToCheckForUpdates:)
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    @objc(updater:shouldDownloadReleaseNotesForUpdate:)
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    @objc(updater:didFinishLoadingAppcast:)
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        loadedFeed = true
        onChecked()
    }

    @objc(updaterDidNotFindUpdate:error:)
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard !cancelled else { return }
        let info = (error as NSError).userInfo
        if let reason = info[SPUNoUpdateFoundReasonKey] as? NSNumber,
           reason.int32Value == SPUNoUpdateFoundReason.systemIsTooOld.rawValue,
           let item = info[SPULatestAppcastItemFoundKey] as? SUAppcastItem,
           let release = try? Self.release(from: item) {
            onRelease(release, userInitiated)
            onPhase(.available)
        } else {
            onNoUpdate()
            let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            let latest = info[SPULatestAppcastItemFoundKey] as? SUAppcastItem
            // “没有可提醒的更新”还可能是用户跳过了新版，不能误显示“已是最新版本”。
            onPhase(latest.map { UpdateFeed.isNewer($0.versionString, than: build) } == true ? .idle : .upToDate)
        }
    }

    @objc(updater:shouldProceedWithUpdate:updateCheck:error:)
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        let candidate = try Self.release(from: updateItem)
        // 检查与用户点击之间可能已发布下一版；安装/跳过只能作用于刚确认的那个包。
        if let action {
            let expected: UpdateRelease
            switch action { case .install(let release), .skip(let release): expected = release }
            guard candidate.build == expected.build, candidate.version == expected.version,
                  candidate.url == expected.url, candidate.size == expected.size,
                  candidate.minimumSystem == expected.minimumSystem else {
                throw UpdateError.invalidBundle(tr("版本清单格式不正确"))
            }
        }
    }

    static func release(from item: SUAppcastItem) throws -> UpdateRelease {
        guard let url = item.fileURL, url.scheme == "https", url.pathExtension == "zip",
              item.contentLength > 0, item.contentLength <= UInt64(Int64.max),
              let build = UInt64(item.versionString), build > 0,
              item.installationType == "application", !item.isInformationOnlyUpdate else {
            throw UpdateError.invalidBundle(tr("版本清单格式不正确"))
        }
        // 这些扩展字段和摘要都来自已验证签名的 XML，不能另从未签名 JSON 补入安装元数据。
        let properties = item.propertiesDictionary
        let dmg = (properties["xstats:dmg"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        // Sparkle 会按系统偏好筛选 description，应用语言所需的中英文保留在签名扩展字段中。
        let notes = ((properties["xstats:notes-zh-Hans"] as? String) ?? item.itemDescription)?
            .components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? []
        let englishNotes = (properties["xstats:notes-en"] as? String)?
            .components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return UpdateRelease(version: item.displayVersionString, build: item.versionString,
                             date: properties["xstats:date"] as? String ?? "",
                             minimumSystem: item.minimumSystemVersion ?? "14.0", url: url,
                             sha256: properties["xstats:sha256"] as? String ?? "", size: Int64(item.contentLength),
                             dmg: dmg, notes: notes, changelog: item.fullReleaseNotesURL,
                             englishNotes: englishNotes)
    }

    @objc(updaterWillRelaunchApplication:)
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { onRelaunch() }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        cancellation = nil
        // 只在尚未收到有效签名 feed 时串行尝试备用区域；下载/安装失败绝不重启安装。
        if error != nil, !loadedFeed, !cancelled, endpointIndex == 0, endpoints.count > 1 {
            endpointIndex = 1
            retryingFeed = true
            if userInitiated || action != nil { updater.checkForUpdates() }
            else { updater.checkForUpdatesInBackground() }
            return
        }
        if case .skip? = action {
            // 跳过点击已在本机排队；网络失败不能撤销选择或转为安装错误。
            onPhase(.available)
        } else if let error, !cancelled {
            let failure = error as NSError
            if failure.domain != SUSparkleErrorDomain || failure.code != SUError.noUpdateError.rawValue {
                onPhase(userInitiated || action != nil ? .failed(error.localizedDescription) : .idle)
            }
        }
        // 结束后必须保留本轮最后检查的地址。Sparkle 的配置 reset 会把 URL 变化
        // 解释成用户更换更新源，立即检查（即使自动检查关闭）。下一轮真正开始时再复位。
        retryingFeed = false
        action = nil
        onCycleFinished(loadedFeed)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { self.cancellation = cancellation }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        guard !cancelled, let release = try? Self.release(from: appcastItem) else { reply(.dismiss); return }
        // Sparkle 也可能恢复已验证的缓存条目；后续安装失败不能作为更新源失败重试。
        loadedFeed = true
        if let action {
            switch action {
            case .install: reply(.install)
            case .skip:
                reply(.skip)
                if release.version == legacySkippedVersion() { onLegacySkipMigrated() }
            }
        } else if !userInitiated, release.version == legacySkippedVersion() {
            // 兼容记录和离线排队只有展示版本号；遇到签名条目后通过公开 reply 交给 Sparkle。
            reply(.skip)
            onLegacySkipMigrated()
            // 跳过新版只结束提醒流程，当前安装仍是旧版。
            onPhase(.idle)
        } else {
            onPhase(.available)
            onRelease(release, userInitiated)
            // 后台通知无需长时间悬挂一个更新会话；安装按钮会重新核验同一份签名元数据。
            reply(.dismiss)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        loadedFeed = true
        self.cancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        lastProgress = 0
        if cancelled { self.cancellation = nil; cancellation(); return }
        onPhase(.downloading(0))
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard !cancelled, expectedLength > 0 else { return }
        let addition = receivedLength.addingReportingOverflow(length)
        receivedLength = addition.overflow ? expectedLength : min(expectedLength, addition.partialValue)
        let progress = Double(receivedLength) / Double(expectedLength)
        // 网络块可能很小，最多每半个百分点重绘一次进度，完成时补齐最后一帧。
        guard progress > lastProgress, progress == 1 || progress - lastProgress >= 0.005 else { return }
        lastProgress = progress
        onPhase(.downloading(progress))
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        if !cancelled { onPhase(.verifying) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !cancelled else { reply(.skip); return }
        onPhase(.installing)
        let app = bundle.bundleURL
        Task {
            do {
                // Widget 继续使用旧可执行文件会使升级后的组件刷新失败，仅停止本安装路径的进程。
                try await Task.detached(priority: .utility) { try UpdateInstaller.stopWidgetExtension(in: app) }.value
                reply(.install)
            } catch {
                onPhase(.failed(error.localizedDescription))
                reply(.skip)
            }
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                             retryTerminatingApplication: @escaping () -> Void) {
        if !cancelled { onPhase(.installing) }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() { cancellation = nil }
}
