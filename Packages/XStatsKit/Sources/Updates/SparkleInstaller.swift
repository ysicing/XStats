// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Sparkle

/// Sparkle 的单一更新流程；复用 XStats 界面和系统通知，不自动下载或安装。
@MainActor
public final class SparkleInstaller: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    public enum Action { case install(UpdateRelease), skip(UpdateRelease) }

    private let bundle: Bundle
    private let onPhase: (UpdatePhase) -> Void
    private let onRelaunch: () -> Void
    public var onRelease: (UpdateRelease, Bool) -> Void = { _, _ in }
    public var onChecked: () -> Void = {}
    public var onNoUpdate: () -> Void = {}
    public var onCycleFinished: (Bool) -> Void = { _ in }
    public var legacySkippedVersion: () -> String? = { nil }
    public var hasKnownRelease: () -> Bool = { false }
    public var onLegacySkipMigrated: () -> Void = {}
    public var prepareForInstallation: () async throws -> Void = {}
    public var cancelInstallationPreparation: () -> Void = {}

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
    private var installationTask: Task<Void, Never>?
    private var installationPreparationError: (any Error)?
    private var installationPrepared = false
    private struct InstallationReply {
        let callback: (SPUUserUpdateChoice) -> Void
        let isReady: Bool
    }
    private var installationReplies: [InstallationReply] = []
    private var cachedInstallationPending = false
    private var cachedExtension: UpdateRelease.NetworkExtension?
    public var installationExtension: UpdateRelease.NetworkExtension? {
        if case .install(let release)? = action { return release.networkExtension }
        return cachedExtension
    }

    public var isRunning: Bool { updater?.sessionInProgress == true || installationTask != nil }
    public var hasInstallationRequest: Bool {
        if cachedInstallationPending { return true }
        guard !cancelled else { return false }
        if case .install? = action { return true }
        return false
    }

    public init(bundle: Bundle = .main,
         endpoints: [URL] = UpdateFeed.sparkleURLs(prefersChina: UpdateFeed.prefersChinaEndpoint()),
         onPhase: @escaping (UpdatePhase) -> Void, onRelaunch: @escaping () -> Void) {
        self.bundle = bundle
        self.endpoints = endpoints
        self.onPhase = onPhase
        self.onRelaunch = onRelaunch
    }

    /// 调用方保留返回值。整个应用只创建一个 updater，不在每次检查或重试时创建 XPC 引擎。
    public func start() throws -> SPUUpdater {
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

    public func check(userInitiated: Bool, action: Action? = nil) {
        guard !isRunning else { return }
        self.action = action
        installationPrepared = false
        installationPreparationError = nil
        cancelled = false
        loadedFeed = false
        endpointIndex = 0
        retryingFeed = false
        self.userInitiated = userInitiated
        if userInitiated || action != nil { updater?.checkForUpdates() }
        else { updater?.checkForUpdatesInBackground() }
    }

    public func cancel() {
        guard let cancellation else { return }
        cancelled = true
        self.cancellation = nil
        cancellation()
        onPhase(.available)
    }

    public func feedURLString(for updater: SPUUpdater) -> String? {
        endpoints.indices.contains(endpointIndex) ? endpoints[endpointIndex].absoluteString : nil
    }

    @objc(feedParametersForUpdater:sendingSystemProfile:)
    public func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] {
        guard let identifier = try? InstallationIdentity().hashedID() else { return [] }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return [["key": "installation_id", "value": identifier], ["key": "current_version", "value": version]]
    }

    @objc(updater:mayPerformUpdateCheck:error:)
    public func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
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
    public func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    @objc(updater:shouldDownloadReleaseNotesForUpdate:)
    public func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool { false }

    @objc(updater:didFinishLoadingAppcast:)
    public func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        loadedFeed = true
        onChecked()
    }

    @objc(updaterDidNotFindUpdate:error:)
    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
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
    public func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        let candidate = try Self.release(from: updateItem)
        // 检查与用户点击之间可能已发布下一版；安装/跳过只能作用于刚确认的那个包。
        if let action {
            let expected: UpdateRelease
            switch action { case .install(let release), .skip(let release): expected = release }
            guard candidate.build == expected.build, candidate.version == expected.version,
                  candidate.url == expected.url, candidate.size == expected.size,
                  candidate.minimumSystem == expected.minimumSystem, candidate.networkExtension == expected.networkExtension else {
                throw UpdateError.releaseChanged
            }
        }
    }

    public static func release(from item: SUAppcastItem) throws -> UpdateRelease {
        guard let url = item.fileURL, url.scheme == "https", url.pathExtension == "zip",
              item.contentLength > 0, item.contentLength <= UInt64(Int64.max),
              let build = UInt64(item.versionString), build > 0,
              item.installationType == "application", !item.isInformationOnlyUpdate else {
            throw UpdateError.invalidBundle(tr("版本清单格式不正确"))
        }
        // 这些扩展字段和摘要都来自已验证签名的 XML，不能另从未签名 JSON 补入安装元数据。
        let properties = item.propertiesDictionary
        var networkExtension: UpdateRelease.NetworkExtension?
        if properties["xstats:network-extension-version"] != nil || properties["xstats:network-extension-build"] != nil {
            guard let version = properties["xstats:network-extension-version"] as? String, !version.isEmpty,
                  let build = properties["xstats:network-extension-build"] as? String,
                  let number = UInt64(build), number > 0 else {
                throw UpdateError.invalidBundle(tr("版本清单格式不正确"))
            }
            networkExtension = .init(version: version, build: String(number))
        }
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
                             englishNotes: englishNotes, networkExtension: networkExtension)
    }

    @objc(updaterWillRelaunchApplication:)
    public func updaterWillRelaunchApplication(_ updater: SPUUpdater) { onRelaunch() }

    @objc(updater:didFinishUpdateCycleForUpdateCheck:error:)
    public func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error != nil {
            if let installationTask { installationTask.cancel() }
            else { cancelInstallationPreparation() }
        }
        cancellation = nil
        // 只在尚未收到有效签名 feed 时串行尝试后续入口，每个地址最多一次；下载/安装失败绝不重启安装。
        if error != nil, !loadedFeed, !cancelled, endpointIndex + 1 < endpoints.count {
            endpointIndex += 1
            retryingFeed = true
            if userInitiated || action != nil { updater.checkForUpdates() }
            else { updater.checkForUpdatesInBackground() }
            return
        }
        if case .skip? = action {
            // 跳过点击已在本机排队；网络失败不能撤销选择或转为安装错误。
            // 版本已从更新源撤回时 release 已被清空，保留“未找到更新”给出的状态。
            if hasKnownRelease() { onPhase(.available) }
        } else if let error, !cancelled {
            let failure = error as NSError
            if failure.domain != SUSparkleErrorDomain || failure.code != SUError.noUpdateError.rawValue {
                // 后台检查失败不撤销此前已发现的新版提示。
                if userInitiated || action != nil { onPhase(.failed(error.localizedDescription)) }
                else { onPhase(hasKnownRelease() ? .available : .idle) }
            }
        }
        // 结束后必须保留本轮最后检查的地址。Sparkle 的配置 reset 会把 URL 变化
        // 解释成用户更换更新源，立即检查（即使自动检查关闭）。下一轮真正开始时再复位。
        retryingFeed = false
        action = nil
        onCycleFinished(loadedFeed)
    }

    public func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    public func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { self.cancellation = cancellation }

    public func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        let signedRelease = try? Self.release(from: appcastItem)
        // 即使本轮检查已取消，SDK 报告的已安装缓存仍可能在退出时继续，不能丢掉退出门禁。
        if state.stage == .installing {
            cachedInstallationPending = true
            cachedExtension = signedRelease?.networkExtension
        }
        guard !cancelled, let release = signedRelease else { reply(.dismiss); return }
        // Sparkle 也可能恢复已验证的缓存条目；后续安装失败不能作为更新源失败重试。
        loadedFeed = true
        if let action {
            switch action {
            case .install:
                if state.stage == .installing { prepareCachedInstallation(reply: reply) }
                else { reply(.install) }
            case .skip:
                cachedInstallationPending = false
                reply(.skip)
                if release.version == legacySkippedVersion() { onLegacySkipMigrated() }
            }
        } else if !userInitiated, release.version == legacySkippedVersion() {
            // 兼容记录和离线排队只有展示版本号；遇到签名条目后通过公开 reply 交给 Sparkle。
            cachedInstallationPending = false
            reply(.skip)
            onLegacySkipMigrated()
            // 跳过新版只结束提醒流程，当前安装仍是旧版。
            onPhase(.idle)
        } else {
            onPhase(.available)
            onRelease(release, userInitiated)
            // 后台通知无需长时间悬挂一个更新会话；安装按钮会重新核验同一份签名元数据。
            // 已进入安装阶段的缓存来自之前确认的安装；保留它，但退出仍必须经过准备门禁。
            // showUpdateFound 的 skip 会持久跳过该版本，不能代替取消一次缓存安装。
            reply(.dismiss)
        }
    }

    public func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    public func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    public func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }
    public func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement() }

    public func showDownloadInitiated(cancellation: @escaping () -> Void) {
        loadedFeed = true
        self.cancellation = cancellation
        expectedLength = 0
        receivedLength = 0
        lastProgress = 0
        if cancelled { self.cancellation = nil; cancellation(); return }
        onPhase(.downloading(0))
    }

    public func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }

    public func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard !cancelled, expectedLength > 0 else { return }
        let addition = receivedLength.addingReportingOverflow(length)
        receivedLength = addition.overflow ? expectedLength : min(expectedLength, addition.partialValue)
        let progress = Double(receivedLength) / Double(expectedLength)
        // 网络块可能很小，最多每半个百分点重绘一次进度，完成时补齐最后一帧。
        guard progress > lastProgress, progress == 1 || progress - lastProgress >= 0.005 else { return }
        lastProgress = progress
        onPhase(.downloading(progress))
    }

    public func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        if !cancelled { onPhase(.verifying) }
    }

    public func showExtractionReceivedProgress(_ progress: Double) {}

    public func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !cancelled || cachedInstallationPending else { reply(.skip); return }
        if installationPrepared { reply(.install); return }
        // 退出路径和 SDK 真实 Ready 回调可能先后到达，两者共享准备结果，不能互相取消。
        installationReplies.append(InstallationReply(callback: reply, isReady: true))
        beginInstallationPreparation()
    }

    private func prepareCachedInstallation(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if installationPrepared { reply(.install); return }
        installationReplies.append(InstallationReply(callback: reply, isReady: false))
        beginInstallationPreparation()
    }

    private func beginInstallationPreparation() {
        guard installationTask == nil, !installationPrepared else { return }
        onPhase(.installing)
        installationPreparationError = nil
        let app = bundle.bundleURL
        installationTask = Task {
            defer { installationTask = nil }
            do {
                try await prepareForInstallation()
                try Task.checkCancellation()
                // Widget 继续使用旧可执行文件会使升级后的组件刷新失败，仅停止本安装路径的进程。
                try await Task.detached(priority: .utility) { try UpdateInstaller.stopWidgetExtension(in: app) }.value
                try Task.checkCancellation()
                installationPrepared = true
                finishInstallationReplies(.install)
            } catch {
                installationPreparationError = error
                cancelInstallationPreparation()
                onPhase(.failed(error.localizedDescription))
                finishInstallationReplies(.skip)
            }
        }
    }

    public func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                             retryTerminatingApplication: @escaping () -> Void) {
        if !cancelled { onPhase(.installing) }
    }

    public func waitForInstallationPreparation() async throws {
        // 下载／解压途中退出时 Sparkle 可立即安装，未到 showReady 也必须准备网络和 Widget。
        beginInstallationPreparation()
        await installationTask?.value
        if let installationPreparationError { throw installationPreparationError }
    }

    private func finishInstallationReplies(_ choice: SPUUserUpdateChoice) {
        let replies = installationReplies
        installationReplies.removeAll()
        // 只有真实 SDK Ready 的 skip 会取消缓存；单独退出准备失败时缓存仍在，门禁也须保留。
        if choice == .skip && replies.contains(where: { $0.isReady }) { cachedInstallationPending = false }
        for reply in replies {
            // Found 的 skip 会持久跳过版本；失败时只保留已确认的缓存，并继续保护退出。
            reply.callback(choice == .skip && !reply.isReady ? .dismiss : choice)
        }
    }

    public func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    public func dismissUpdateInstallation() {
        cancellation = nil
        if let installationTask { installationTask.cancel() }
        else { cancelInstallationPreparation() }
    }
}
