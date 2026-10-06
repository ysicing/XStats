// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import AppKit
import NetworkObservation

typealias NetworkMonitorError = NetworkObservation.NetworkMonitorError
typealias NetworkMonitorReply = NetworkObservation.NetworkMonitorReply

@MainActor protocol NetworkMonitorBackend: AnyObject {
    var onApproval: (() -> Void)? { get set }
    var onInstallationProgress: ((Double?) -> Void)? { get set }
    var onComponentStatus: ((NetworkComponentStatus) -> Void)? { get set }
    func activate() async throws -> Bool
    func cancelActivation()
    func setFilterEnabled(_ enabled: Bool) async throws
    func read(after cursor: Int64, epoch: String) async throws -> ObservationBatch
    func stopReading()
    func uninstall() async throws -> Bool
    func componentCommand(_ command: String) async throws -> NetworkComponentResponse
}

extension NetworkMonitorBackend {
    var onComponentStatus: ((NetworkComponentStatus) -> Void)? { get { nil } set {} }
    func componentCommand(_ command: String) async throws -> NetworkComponentResponse { throw NetworkMonitorError.unavailable }
}

@MainActor final class NativeNetworkMonitorBackend: NSObject, NetworkMonitorBackend {
    static let extensionIdentifier = NetworkObservationProtocol.extensionIdentifier
    var onApproval: (() -> Void)?
    var onInstallationProgress: ((Double?) -> Void)?
    var onComponentStatus: ((NetworkComponentStatus) -> Void)?
    private var connection: NSXPCConnection?
    private var control: NSXPCConnection?
    private var activationGeneration = 0
    private var componentPreparation: Task<Void, any Error>?
    private var installationTask: Task<Void, any Error>?
    private var validatedIdentity: String?
    private var registeredIdentity: String?
    init(connection: NSXPCConnection? = nil) { self.connection = connection; super.init() }

    func activate() async throws -> Bool {
        guard NetworkMonitorSupport.isAvailable else { throw NetworkMonitorError.unsupportedVersion }
        let generation = activationGeneration
        try await prepareComponent()
        guard generation == activationGeneration else { throw CancellationError() }
        let result = try await command("activate")
        if result.status?.needsSystemApproval == true { onApproval?() }
        return result.needsRestart
    }
    func cancelActivation() { activationGeneration += 1; installationTask?.cancel() }
    func setFilterEnabled(_ enabled: Bool) async throws {
        if !enabled, !FileManager.default.fileExists(atPath: NetworkComponentInstaller.componentURL.path) { return }
        _ = try await componentCommand(enabled ? "enable" : "disable")
    }
    func uninstall() async throws -> Bool { try await componentCommand("uninstall").needsRestart }

    func componentCommand(_ action: String) async throws -> NetworkComponentResponse {
        try await prepareComponent()
        return try await command(action)
    }
    private func prepareComponent() async throws {
        if let preparation = componentPreparation { try await preparation.value; try Task.checkCancellation(); return }
        let preparation = Task { try await prepareComponentImpl() }
        componentPreparation = preparation
        defer { componentPreparation = nil }
        try await preparation.value
        try Task.checkCancellation()
    }
    private func prepareComponentImpl() async throws {
        let team = try NetworkCodeIdentity.currentTeam()
        if !FileManager.default.fileExists(atPath: NetworkComponentInstaller.componentURL.path) {
            onInstallationProgress?(0)
            defer { onInstallationProgress?(nil) }
            let generation = activationGeneration
            let task = Task {
                try await NetworkComponentInstaller().install { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.activationGeneration == generation, self.installationTask != nil else { return }
                        self.onInstallationProgress?(progress)
                    }
                }
            }
            installationTask = task
            do { try await task.value; installationTask = nil }
            catch { installationTask = nil; throw error }
            validatedIdentity = nil
        }
        let metadata = try await NetworkComponentMetadata.load(at: NetworkComponentInstaller.componentURL)
        guard metadata.protocolVersion == NetworkObservationProtocol.version,
              metadata.controlMachService == NetworkObservationProtocol.controlServiceName(team: team) else {
            throw NetworkMonitorError.protocolMismatch
        }
        let identity = try await Self.installationIdentity()
        if identity != validatedIdentity {
            try await NetworkComponentInstaller.validateInstalled()
            validatedIdentity = identity
            // 替换整个包后必须放弃旧匿名/launchd连接，避免失效回调清掉新会话。
            control?.invalidate(); control = nil
            stopReading()
        }
        if identity != registeredIdentity {
            let result = try await NetworkComponentInstaller.runCommand(
                NetworkComponentInstaller.componentURL.appendingPathComponent("Contents/MacOS/XStats Network Monitor").path,
                arguments: ["--register-service"], limit: 32 * 1024)
            let registration = try JSONDecoder().decode(RegistrationReply.self, from: result)
            guard registration.protocolVersion == NetworkObservationProtocol.version else { throw NetworkMonitorError.protocolMismatch }
            if let error = registration.error { throw NSError(domain: "NetworkComponent", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            guard registration.registration == .enabled else { throw NetworkMonitorError.backgroundApproval }
            registeredIdentity = identity
        }
        try Task.checkCancellation()
        if control == nil {
            let candidate = NSXPCConnection(machServiceName: NetworkObservationProtocol.controlServiceName(team: team), options: [])
            candidate.setCodeSigningRequirement("anchor apple generic and identifier \"work.12306.xstats.networkmonitor\" and certificate leaf[subject.OU] = \"\(team)\"")
            candidate.remoteObjectInterface = NSXPCInterface(with: NetworkComponentService.self)
            candidate.exportedInterface = NSXPCInterface(with: NetworkComponentClientService.self)
            let identifier = ObjectIdentifier(candidate)
            candidate.exportedObject = NetworkComponentClientReceiver(
                approval: { [weak self] in Task { @MainActor in
                    guard let self, let current = self.control, ObjectIdentifier(current) == identifier else { return }
                    self.onApproval?()
                } }, status: { [weak self] data in Task { @MainActor in
                    guard let self, let current = self.control, ObjectIdentifier(current) == identifier,
                          data.count <= 256 * 1024, let status = try? JSONDecoder().decode(NetworkComponentStatus.self, from: data) else { return }
                    self.onComponentStatus?(status)
                } })
            // agent 空闲退出只会中断连接；仅在服务失效（如登录项被移除）时重新注册，避免每条命令都启动注册子进程。
            let clear: @Sendable (Bool) -> Void = { [weak self] invalidated in
                Task { @MainActor in
                    guard let self, let current = self.control, ObjectIdentifier(current) == identifier else { return }
                    self.control = nil; current.invalidate()
                    if invalidated { self.registeredIdentity = nil }
                }
            }
            candidate.invalidationHandler = { clear(true) }; candidate.interruptionHandler = { clear(false) }
            candidate.resume(); control = candidate
        }
    }
    private struct RegistrationReply: Decodable {
        let protocolVersion: Int
        let registration: NetworkComponentRegistration
        let error: String?
    }
    // 此缓存只省去重复文件验签；Mach对端每条消息仍由系统校验精确ID与团队。
    // 安装/升级替换包、签名资源、plist或执行文件时，身份立即失效并重新严格验证。
    @concurrent private static func installationIdentity() async throws -> String {
        let app = NetworkComponentInstaller.componentURL
        let paths = ["", "Contents/Info.plist", "Contents/MacOS/XStats Network Monitor", "Contents/_CodeSignature/CodeResources", "Contents/Library/LaunchAgents/" + NetworkObservationProtocol.agentPlistName]
        return try paths.map { path in
            let attributes = try FileManager.default.attributesOfItem(atPath: app.appendingPathComponent(path).path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            return "\(attributes[.systemFileNumber] ?? ""):\(attributes[.size] ?? ""):\(modified)"
        }.joined(separator: "|")
    }
    private func command(_ action: String) async throws -> NetworkComponentResponse {
        guard let control else { throw NetworkMonitorError.unavailable }
        let reply = NetworkMonitorReply()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard !Task.isCancelled else { reply.finish(.failure(CancellationError())); return }
                guard let proxy = control.remoteObjectProxyWithErrorHandler({ @Sendable error in reply.finish(.failure(error)) }) as? NetworkComponentService else {
                    reply.finish(.failure(NetworkMonitorError.unavailable)); return
                }
                proxy.perform(action) { @Sendable data in reply.finish(.success(data)) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 65) { reply.finish(.failure(NetworkMonitorError.timeout)) }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
        try Task.checkCancellation()
        guard data.count <= 256 * 1024 else { throw NetworkMonitorError.unavailable }
        let response = try JSONDecoder().decode(NetworkComponentResponse.self, from: data)
        guard response.protocolVersion == NetworkObservationProtocol.version else { throw NetworkMonitorError.protocolMismatch }
        if response.status?.needsSystemApproval == true { onApproval?() }
        if let error = response.error { throw NSError(domain: "NetworkComponent", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        if let status = response.status { onComponentStatus?(status) }
        return response
    }
    func read(after cursor: Int64, epoch: String) async throws -> ObservationBatch {
        guard NetworkMonitorSupport.isAvailable else { throw NetworkMonitorError.unsupportedVersion }
        let connection = try await ensureConnection()
        let reply = NetworkMonitorReply()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard !Task.isCancelled else { reply.finish(.failure(CancellationError())); return }
                // Foundation 的旧回调签名未标注 Sendable；显式声明以免继承 MainActor，XPC 会在后台队列调用它们。
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ @Sendable error in reply.finish(.failure(error)) }) as? NetworkObservationService else {
                    reply.finish(.failure(NetworkMonitorError.unavailable)); return
                }
                proxy.readEvents(after: cursor, epoch: epoch) { @Sendable data in reply.finish(.success(data)) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    reply.finish(.failure(NetworkMonitorError.timeout))
                }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
        try Task.checkCancellation()
        return try Self.decodeBatch(data)
    }



    private func ensureConnection() async throws -> NSXPCConnection {
        if let connection { return connection }
        let metadata = try await NetworkComponentMetadata.load(at: NetworkComponentInstaller.componentURL)
        try Task.checkCancellation()
        if let connection { return connection }
        guard metadata.protocolVersion == NetworkObservationProtocol.version else { throw NetworkMonitorError.protocolMismatch }
        let team = try NetworkCodeIdentity.currentTeam()
        let candidate = NSXPCConnection(machServiceName: metadata.observationMachService, options: .privileged)
        candidate.setCodeSigningRequirement("anchor apple generic and identifier \"\(Self.extensionIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\"")
        candidate.remoteObjectInterface = NSXPCInterface(with: NetworkObservationService.self)
        candidate.resume(); connection = candidate
        return candidate
    }
    static func decodeBatch(_ data: Data) throws -> ObservationBatch {
        let batch = try ObservationBatch.decode(data)
        // 相同构建号可能让 macOS 继续运行旧扩展；缺字段是协议不匹配，不能当作零条活动连接。
        guard batch.activeIDs != nil else { throw NetworkMonitorError.extensionNeedsUpdate }
        return batch
    }

    func stopReading() { connection?.invalidate(); connection = nil }
}

/// XPC 在任意队列调用；这些不可变 Sendable 回调只把事件转交 MainActor。
private final class NetworkComponentClientReceiver: NSObject, NetworkComponentClientService, Sendable {
    private let approval: @Sendable () -> Void
    private let status: @Sendable (Data) -> Void
    init(approval: @escaping @Sendable () -> Void, status: @escaping @Sendable (Data) -> Void) { self.approval = approval; self.status = status }
    func needsSystemApproval() { approval() }
    func componentStatusChanged(_ data: Data) { status(data) }
}
