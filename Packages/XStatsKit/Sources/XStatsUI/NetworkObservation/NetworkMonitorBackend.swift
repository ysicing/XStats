// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import AppKit
import NetworkObservation
import Security
import Updates

@MainActor protocol NetworkMonitorBackend: AnyObject {
    var onApproval: (() -> Void)? { get set }
    var onInstallationProgress: ((Double?) -> Void)? { get set }
    func activate() async throws -> Bool
    func cancelActivation()
    func setFilterEnabled(_ enabled: Bool) async throws
    func read(after cursor: Int64, epoch: String) async throws -> ObservationBatch
    func stopReading()
    func uninstall() async throws -> Bool
}

enum NetworkMonitorError: Error, LocalizedError {
    case unsupportedVersion, missingExtension, unsigned, installLocation, unavailable, timeout, wrongConfiguration, extensionNeedsUpdate, restartRequired

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: tr("需要 macOS 15 或更新版本")
        case .missingExtension: tr("此构建未包含网络扩展。")
        case .unsigned: tr("需要包含网络扩展权限的签名构建。")
        case .installLocation: tr("请先将 XStats 安装到应用程序文件夹。")
        case .unavailable: tr("无法连接网络扩展，请重试。")
        case .timeout: tr("网络扩展响应超时，请重试。")
        case .wrongConfiguration: tr("网络过滤配置与此扩展不匹配。")
        case .extensionNeedsUpdate: tr("网络扩展需要更新，请重新启用连接查看。")
        case .restartRequired: tr("需要重启系统")
        }
    }
}

/// XPC 的回复、错误、取消与超时只能完成同一次读取一次；不在主线程阻塞等待。
final class NetworkMonitorReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?

    func install(_ continuation: CheckedContinuation<Data, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

@MainActor final class NativeNetworkMonitorBackend: NSObject, NetworkMonitorBackend {
    static let extensionIdentifier = "work.12306.xstats.app.networkextension"
    var onApproval: (() -> Void)?
    var onInstallationProgress: ((Double?) -> Void)?
    private var connection: NSXPCConnection?
    private var control: NSXPCConnection?
    private var activationGeneration = 0
    private var installationTask: Task<Void, any Error>?
    init(connection: NSXPCConnection? = nil) { self.connection = connection; super.init() }

    func activate() async throws -> Bool {
        guard NetworkMonitorSupport.isAvailable else { throw NetworkMonitorError.unsupportedVersion }
        let generation = activationGeneration
        _ = try signingTeam()
        if !(await NetworkComponentInstaller.isInstalled()) {
            onInstallationProgress?(0)
            defer { onInstallationProgress?(nil) }
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
        }
        try Task.checkCancellation()
        guard generation == activationGeneration else { throw CancellationError() }
        try await NetworkComponentInstaller.validateInstalled()
        if control == nil {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = ["--activate"]
            _ = try await NSWorkspace.shared.openApplication(at: NetworkComponentInstaller.componentURL, configuration: configuration)
            onApproval?()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(60))
            repeat {
                do { try await connectControl(); _ = try await command("status"); break }
                catch { stopReading() }
                try await Task.sleep(for: .milliseconds(500))
            } while clock.now < deadline
        }
        guard generation == activationGeneration else { throw CancellationError() }
        return try await command("activate").needsRestart
    }
    func cancelActivation() { activationGeneration += 1; installationTask?.cancel() }
    func setFilterEnabled(_ enabled: Bool) async throws {
        if !enabled, control == nil {
            guard await NetworkComponentInstaller.isInstalled() else { return }
            try await connectControl()
        }
        _ = try await command(enabled ? "enable" : "disable")
    }
    func uninstall() async throws -> Bool { try await connectControl(); return try await command("uninstall").needsRestart }

    private func connectControl() async throws {
        if control != nil { return }
        let peer = try ensureConnection()
        let reply = EndpointReply()
        let endpoint = try await withCheckedThrowingContinuation { continuation in
            reply.install(continuation)
            guard let proxy = peer.remoteObjectProxyWithErrorHandler({ @Sendable error in reply.finish(.failure(error)) }) as? NetworkObservationService else {
                reply.finish(.failure(NetworkMonitorError.unavailable)); return
            }
            proxy.controlEndpoint { @Sendable endpoint in
                if let endpoint { reply.finish(.success(NetworkControlEndpoint(endpoint))) }
                else { reply.finish(.failure(NetworkMonitorError.unavailable)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { reply.finish(.failure(NetworkMonitorError.timeout)) }
        }
        let candidate = NSXPCConnection(listenerEndpoint: endpoint.value)
        let team = try signingTeam()
        candidate.setCodeSigningRequirement("anchor apple generic and identifier \"work.12306.xstats.networkmonitor\" and certificate leaf[subject.OU] = \"\(team)\"")
        candidate.remoteObjectInterface = NSXPCInterface(with: NetworkComponentService.self)
        let identity = ObjectIdentifier(candidate)
        let clear: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, let candidate = self.control, ObjectIdentifier(candidate) == identity else { return }
                candidate.invalidate(); self.control = nil
            }
        }
        candidate.invalidationHandler = clear
        candidate.interruptionHandler = clear
        candidate.resume()
        control = candidate
    }
    private func command(_ command: String) async throws -> NetworkComponentResponse {
        guard let control else { throw NetworkMonitorError.unavailable }
        let reply = NetworkMonitorReply()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard let proxy = control.remoteObjectProxyWithErrorHandler({ @Sendable error in reply.finish(.failure(error)) }) as? NetworkComponentService else {
                    reply.finish(.failure(NetworkMonitorError.unavailable)); return
                }
                proxy.perform(command) { @Sendable data in reply.finish(.success(data)) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 65) { reply.finish(.failure(NetworkMonitorError.timeout)) }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
        let response = try JSONDecoder().decode(NetworkComponentResponse.self, from: data)
        if let error = response.error { throw NSError(domain: "NetworkComponent", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
        return response
    }

    func read(after cursor: Int64, epoch: String) async throws -> ObservationBatch {
        guard NetworkMonitorSupport.isAvailable else { throw NetworkMonitorError.unsupportedVersion }
        let connection = try ensureConnection()
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


    private func ensureConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        guard let component = Bundle(url: NetworkComponentInstaller.componentURL),
              component.bundleIdentifier == NetworkComponentInstaller.bundleIdentifier,
              let name = component.object(forInfoDictionaryKey: "NetworkObservationMachService") as? String,
              !name.isEmpty else { throw NetworkMonitorError.missingExtension }
        let team = try signingTeam()
        let candidate = NSXPCConnection(machServiceName: name, options: .privileged)
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
    private func signingTeam() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { throw NetworkMonitorError.unsigned }
        return team
    }

}

/// 回调可能来自任意 XPC 队列；锁只保护一次性 continuation，不在锁内执行外部代码。
private final class EndpointReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NetworkControlEndpoint, any Error>?
    private var result: Result<NetworkControlEndpoint, any Error>?
    func install(_ value: CheckedContinuation<NetworkControlEndpoint, any Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    func finish(_ value: Result<NetworkControlEndpoint, any Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let callback = continuation; continuation = nil; lock.unlock()
        callback?.resume(with: value)
    }
}
