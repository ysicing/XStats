// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Foundation
import Localization
import NetworkObservation
import Sparkle
import Updates

/// launchd 的按需控制服务。冷启动只监听，不激活 NE，也不创建更新检查周期。
@MainActor final class NetworkComponentServiceHost: NSObject, NetworkComponentService {
    private let manager = NetworkComponentManager()
    private var listener: NSXPCListener?
    private var listenerDelegate: ComponentListener?
    private var clients: [UUID: ComponentClientSession] = [:]
    private var lifetime: ComponentServiceLifetime!
    private var driver: SparkleInstaller?
    private var updater: SPUUpdater?
    private var checkReplies: [CheckedContinuation<NetworkComponentResponse, Never>] = []
    private var sdkReplies: [CheckedContinuation<Void, Never>] = []
    private var mutation: Task<NetworkComponentResponse, Never>?
    private var preparationTask: Task<Void, any Error>?
    private var stopTask: Task<Void, any Error>?
    private var rollbackTask: Task<Void, Never>?
    private var updatePreparing = false
    private var installationCancelled = false
    private var originalFilterEnabled = false
    private var filterRevision = 0
    private var preparationRevision = 0
    private var desiredFilterEnabled: Bool?
    private var enabled = false
    private var shutdownRequested = false
    private var preparedForHandoff = false
    private var phase: UpdatePhase = .idle
    private var release: UpdateRelease?
    private static let releaseKey = "networkComponentConfirmedReleaseV2"
    static let relaunchKey = "networkComponentUpdaterRelaunchBuildV2"

    func start() throws {
        let team = try NetworkCodeIdentity.currentTeam()
        let name = NetworkObservationProtocol.controlServiceName(team: team)
        guard Bundle.main.object(forInfoDictionaryKey: "NetworkObservationProtocolVersion") as? Int == NetworkObservationProtocol.version,
              Bundle.main.object(forInfoDictionaryKey: "NetworkObservationControlMachService") as? String == name else {
            throw NetworkMonitorError.protocolMismatch
        }
        if let data = UserDefaults.standard.data(forKey: Self.releaseKey), data.count <= 32 * 1024 {
            release = try? JSONDecoder().decode(UpdateRelease.self, from: data)
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
            if let cached = release, !UpdateFeed.isNewer(cached.build, than: build) {
                release = nil
                UserDefaults.standard.removeObject(forKey: Self.releaseKey)
            }
            if release != nil { phase = .available }
        }
        lifetime = ComponentServiceLifetime { [weak self] in self?.exitWhenIdle() }
        manager.onApproval = { [weak self] in
            guard let self else { return }
            for client in self.clients.values { client.needsApproval() }
            self.publishStatus()
        }
        let listener = NSXPCListener(machServiceName: name)
        let requirement = "anchor apple generic and (identifier \"work.12306.xstats.app\" or identifier \"work.12306.xstats.networkmonitor\") and certificate leaf[subject.OU] = \"\(team)\""
        let delegate = ComponentListener(host: self, requirement: requirement)
        listener.delegate = delegate
        listener.resume()
        self.listener = listener; listenerDelegate = delegate
        lifetime.start()
    }

    nonisolated func perform(_ command: String, reply: @escaping @Sendable (Data) -> Void) {
        Task { @MainActor in
            lifetime.beginRPC()
            let response = await run(command)
            reply((try? JSONEncoder().encode(response)) ?? Data())
            lifetime.finishRPC()
        }
    }

    func addClient(_ client: ComponentClientSession) -> Bool {
        guard clients.count < 32, !client.isEnded else { client.invalidate(); return false }
        clients[client.id] = client
        return true
    }
    func removeClient(_ id: UUID) {
        clients.removeValue(forKey: id)
        cancelUnobservedRequest()
    }
    private func cancelUnobservedRequest(sdkCycleFinished: Bool = false) {
        // 已消失的控制客户端不能留下无限等待授权的 RPC；已确认的 Sparkle 周期继续收尾。
        if clients.isEmpty, !updatePreparing, sdkCycleFinished || driver?.isRunning != true { manager.cancelActivation() }
    }

    private func run(_ command: String) async -> NetworkComponentResponse {
        do {
            switch command {
            case "status":
                if mutation == nil, !updatePreparing { try await refreshStatus() }
                return response()
            case "checkUpdates", "checkUpdatesBackground":
                guard !shutdownRequested, mutation == nil, !updatePreparing else { throw NetworkMonitorError.unavailable }
                try await refreshStatus()
                try ensureUpdater()
                guard driver?.isRunning != true else { return response() }
                installationCancelled = false
                return await withCheckedContinuation { continuation in
                    checkReplies.append(continuation)
                    lifetime.setSDKActive(true)
                    driver?.check(userInitiated: command == "checkUpdates")
                }
            case "installUpdate":
                guard !shutdownRequested, mutation == nil, !updatePreparing, let release else { throw NetworkMonitorError.unavailable }
                try await refreshStatus()
                try ensureUpdater()
                guard driver?.isRunning != true else { throw NetworkMonitorError.unavailable }
                installationCancelled = false
                preparedForHandoff = false
                lifetime.setSDKActive(true)
                driver?.check(userInitiated: true, action: .install(release))
                return response()
            case "cancelUpdate":
                cancelUpdate()
                return response()
            case "activate", "enable", "disable", "shutdown", "uninstall":
                return await mutate(command)
            default: throw NetworkMonitorError.unavailable
            }
        } catch { return response(error: error.localizedDescription) }
    }

    private func mutate(_ command: String) async -> NetworkComponentResponse {
        guard command != "uninstall" || !preparedForHandoff else { return response(error: NetworkMonitorError.unavailable.localizedDescription) }
        let stopping = command == "disable" || command == "shutdown" || command == "uninstall"
        if stopping {
            desiredFilterEnabled = false; filterRevision += 1
            manager.cancelActivation()
            if command != "disable" { shutdownRequested = true; cancelUpdate() }
            if updatePreparing {
                do { try await stopDuringUpdate() } catch { return response(error: error.localizedDescription) }
            }
            if command == "uninstall" {
                do { try await abandonUpdateForUninstall() }
                catch { return response(error: error.localizedDescription) }
            }
            while let previous = mutation { _ = await previous.value }
        } else if shutdownRequested || mutation != nil || updatePreparing {
            return response(error: NetworkMonitorError.unavailable.localizedDescription)
        }
        if command == "enable" { desiredFilterEnabled = true; filterRevision += 1 }
        let revision = filterRevision
        let task = Task { @MainActor in
            defer { mutation = nil; publishStatus() }
            do {
                var restart = false
                switch command {
                case "activate": restart = try await manager.activate()
                case "enable":
                    restart = try await manager.activate()
                    guard revision == filterRevision, !shutdownRequested else { throw CancellationError() }
                    if !restart { try await manager.setFilterEnabled(true) }
                case "disable", "shutdown": try await manager.setFilterEnabled(false)
                case "uninstall": restart = try await manager.uninstall()
                default: throw NetworkMonitorError.unavailable
                }
                enabled = try await manager.filterEnabled()
                if command == "shutdown" || command == "uninstall" { lifetime.requestShutdown() }
                return response(needsRestart: restart)
            } catch { return response(error: error.localizedDescription) }
        }
        mutation = task
        return await task.value
    }

    private func refreshStatus() async throws {
        enabled = try await manager.filterEnabled()
        try await manager.refreshApprovalState()
    }

    private func ensureUpdater() throws {
        guard driver == nil else { return }
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, let url = URL(string: feed) else {
            throw NetworkMonitorError.missingExtension
        }
        let driver = SparkleInstaller(endpoints: [url], onPhase: { [weak self] phase in
            guard let self else { return }
            self.phase = self.installationCancelled && phase != .installing ? (self.release == nil ? .idle : .available) : phase
            self.publishStatus()
        }, onRelaunch: {
            // Sparkle 默认重启应用入口。新进程只刷新 registration 后退出，不弹 GUI 或恢复旧过滤意图。
            UserDefaults.standard.set(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, forKey: Self.relaunchKey)
            UserDefaults.standard.synchronize()
        })
        driver.hasKnownRelease = { [weak self] in self?.release != nil }
        driver.onRelease = { [weak self] release, _ in
            self?.release = release
            if let data = try? JSONEncoder().encode(release), data.count <= 32 * 1024 {
                UserDefaults.standard.set(data, forKey: Self.releaseKey)
            } else { UserDefaults.standard.removeObject(forKey: Self.releaseKey) }
            UserDefaults.standard.synchronize()
        }
        driver.onNoUpdate = { [weak self] in
            self?.release = nil; UserDefaults.standard.removeObject(forKey: Self.releaseKey)
            UserDefaults.standard.synchronize()
        }
        driver.onCycleFinished = { [weak self] success in
            guard let self else { return }
            self.lifetime.setSDKActive(false)
            let sdkReplies = self.sdkReplies; self.sdkReplies.removeAll()
            for reply in sdkReplies { reply.resume() }
            let replies = self.checkReplies; self.checkReplies.removeAll()
            let result = self.response(error: success ? nil : tr("检查更新失败"))
            for reply in replies { reply.resume(returning: result) }
            self.cancelUnobservedRequest(sdkCycleFinished: true)
            self.publishStatus()
        }
        driver.prepareForInstallation = { [weak self, weak driver] in
            guard let self, let target = driver?.installationExtension else { throw NetworkMonitorError.missingExtension }
            try await self.prepareInstallation(target: target)
        }
        driver.cancelInstallationPreparation = { [weak self] in self?.rollbackPreparation() }
        updater = try driver.start()
        self.driver = driver
    }

    private func prepareInstallation(target: UpdateRelease.NetworkExtension) async throws {
        guard !installationCancelled, mutation == nil, !shutdownRequested else { throw CancellationError() }
        updatePreparing = true
        lifetime.setPreparationActive(true)
        preparationRevision = filterRevision
        originalFilterEnabled = false
        let task = Task {
            originalFilterEnabled = try await manager.filterEnabled()
            _ = try await manager.prepareForUpdate(target: target)
            try Task.checkCancellation()
            let after = try await manager.filterEnabled()
            enabled = after
        }
        preparationTask = task
        defer { preparationTask = nil }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try await stopTask?.value
        guard !installationCancelled, !shutdownRequested else { throw CancellationError() }
        preparedForHandoff = true
    }

    private func stopDuringUpdate() async throws {
        if stopTask == nil {
            let preparation = preparationTask, rollback = rollbackTask
            stopTask = Task {
                defer { stopTask = nil }
                _ = await preparation?.result
                await rollback?.value
                try await manager.setFilterEnabled(false)
                enabled = false
                publishStatus()
            }
        }
        try await stopTask?.value
    }

    private func rollbackPreparation() {
        guard updatePreparing, rollbackTask == nil else { return }
        UserDefaults.standard.removeObject(forKey: Self.relaunchKey)
        let preparation = preparationTask
        rollbackTask = Task {
            defer {
                rollbackTask = nil; updatePreparing = false
                preparedForHandoff = false
                lifetime.setPreparationActive(false); publishStatus()
            }
            _ = await preparation?.result
            // 回退只恢复本次准备停用的旧过滤会话；后来的 disable/shutdown 意图优先。
            if originalFilterEnabled, filterRevision == preparationRevision, desiredFilterEnabled != false, !shutdownRequested {
                try? await manager.setFilterEnabled(true)
                enabled = (try? await manager.filterEnabled()) ?? false
            }
        }
    }

    private func cancelUpdate() {
        installationCancelled = true
        driver?.cancel()
        if updatePreparing { driver?.dismissUpdateInstallation() }
    }

    private func abandonUpdateForUninstall() async throws {
        if driver?.isRunning == true { await withCheckedContinuation { sdkReplies.append($0) } }
        if driver?.hasInstallationRequest == true {
            guard let release else { throw NetworkMonitorError.unavailable }
            // 明确卸载代表撤销先前确认的缓存安装。只有这里使用 SDK 的 skip，普通取消/disable 不跳过版本。
            lifetime.setSDKActive(true)
            driver?.check(userInitiated: true, action: .skip(release))
            if driver?.isRunning == true { await withCheckedContinuation { sdkReplies.append($0) } }
            guard driver?.hasInstallationRequest != true else { throw NetworkMonitorError.unavailable }
        }
        release = nil; phase = .idle
        UserDefaults.standard.removeObject(forKey: Self.releaseKey)
        UserDefaults.standard.synchronize()
    }

    private func snapshot() -> NetworkComponentStatus {
        let bundle = Bundle.main
        var update = NetworkComponentUpdateStatus(version: release?.version)
        switch phase {
        case .idle: update.phase = .idle
        case .checking: update.phase = .checking
        case .upToDate: update.phase = .upToDate
        case .available: update.phase = .available
        case .downloading(let value): update.phase = .downloading; update.progress = value
        case .verifying: update.phase = .verifying
        case .installing: update.phase = .installing
        case .failed(let error): update.phase = .failed; update.error = String(error.prefix(4096))
        }
        return .init(componentVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                     componentBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                     extensionVersion: bundle.object(forInfoDictionaryKey: "NetworkObservationExtensionVersion") as? String ?? "",
                     extensionBuild: bundle.object(forInfoDictionaryKey: "NetworkObservationExtensionBuild") as? String ?? "",
                     observationMachService: bundle.object(forInfoDictionaryKey: "NetworkObservationMachService") as? String ?? "",
                     registration: ComponentRegistration.status, filterEnabled: enabled,
                     needsSystemApproval: manager.needsSystemApproval, update: update)
    }
    private func response(needsRestart: Bool = false, error: String? = nil) -> NetworkComponentResponse {
        .init(needsRestart: needsRestart, error: error, status: snapshot())
    }
    private func publishStatus() {
        guard let data = try? JSONEncoder().encode(snapshot()), data.count <= 256 * 1024 else { return }
        for client in clients.values { client.statusChanged(data) }
    }
    private func exitWhenIdle() {
        guard mutation == nil, !updatePreparing, manager.hasPendingSystemRequest == false,
              driver?.isRunning != true, driver?.hasInstallationRequest != true else { return }
        // 包删除与注销由外部主应用串行处理；服务不在延迟退出时再访问可能已删除的自身可执行文件。
        NSApp.terminate(nil)
    }
    var installationPending: Bool { driver?.hasInstallationRequest == true }
    func prepareForTermination() async throws {
        try await driver?.waitForInstallationPreparation()
        try await stopTask?.value
    }
}

/// delegate 初次移交连接后只在 MainActor 操作它；系统回调只改锁保护的结束标记并投递身份。
final class ComponentClientSession: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private let connection: NSXPCConnection
    private var ended = false
    var isEnded: Bool { lock.lock(); defer { lock.unlock() }; return ended }
    init(connection: NSXPCConnection, host: NetworkComponentServiceHost, requirement: String) {
        self.connection = connection
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: NetworkComponentService.self)
        connection.exportedObject = host
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkComponentClientService.self)
        let id = id
        connection.invalidationHandler = { @Sendable [weak self, weak host] in
            self?.markEnded(); Task { @MainActor in host?.removeClient(id) }
        }
        connection.interruptionHandler = { @Sendable [weak self, weak host] in
            self?.markEnded(); Task { @MainActor in host?.removeClient(id) }
        }
    }
    private func markEnded() { lock.lock(); ended = true; lock.unlock() }
    @MainActor func resume() { if !isEnded { connection.resume() } }
    @MainActor func invalidate() { markEnded(); connection.invalidate() }
    @MainActor func needsApproval() {
        guard !isEnded else { return }
        (connection.remoteObjectProxyWithErrorHandler { @Sendable _ in } as? NetworkComponentClientService)?.needsSystemApproval()
    }
    @MainActor func statusChanged(_ data: Data) {
        guard !isEnded else { return }
        (connection.remoteObjectProxyWithErrorHandler { @Sendable _ in } as? NetworkComponentClientService)?.componentStatusChanged(data)
    }
}

private final class ComponentListener: NSObject, NSXPCListenerDelegate {
    private weak var host: NetworkComponentServiceHost?
    private let requirement: String
    init(host: NetworkComponentServiceHost, requirement: String) { self.host = host; self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let host else { return false }
        let client = ComponentClientSession(connection: connection, host: host, requirement: requirement)
        Task { @MainActor in if host.addClient(client) { client.resume() } }
        return true
    }
}
