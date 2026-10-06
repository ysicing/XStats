// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import NetworkExtension
import NetworkObservation
import Security
import SystemExtensions

@MainActor protocol NetworkMonitorBackend: AnyObject {
    var onApproval: (() -> Void)? { get set }
    func activate() async throws -> Bool
    func cancelActivation()
    func setFilterEnabled(_ enabled: Bool) async throws
    func read(after cursor: Int64, epoch: String) async throws -> ObservationBatch
    func stopReading()
    func uninstall() async throws -> Bool
}

enum NetworkMonitorError: Error, LocalizedError {
    case unsupportedVersion, missingExtension, unsigned, installLocation, unavailable, timeout, wrongConfiguration, extensionNeedsUpdate

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

@MainActor final class NativeNetworkMonitorBackend: NSObject, NetworkMonitorBackend, @preconcurrency OSSystemExtensionRequestDelegate {
    static let extensionIdentifier = "work.12306.xstats.app.networkextension"
    var onApproval: (() -> Void)?
    private var request: OSSystemExtensionRequest?
    private var requestContinuation: CheckedContinuation<Bool, any Error>?
    private var connection: NSXPCConnection?

    func activate() async throws -> Bool {
        guard NetworkMonitorSupport.isAvailable else { throw NetworkMonitorError.unsupportedVersion }
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(Self.extensionIdentifier).systemextension")
        guard FileManager.default.fileExists(atPath: extensionURL.path) else { throw NetworkMonitorError.missingExtension }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { throw NetworkMonitorError.installLocation }
        _ = try signingTeam()
        return try await submit(.activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main))
    }

    func cancelActivation() {
        request = nil
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume(throwing: CancellationError())
    }

    func setFilterEnabled(_ enabled: Bool) async throws {
        guard NetworkMonitorSupport.isAvailable else { throw NetworkMonitorError.unsupportedVersion }
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        if let current = manager.providerConfiguration?.filterDataProviderBundleIdentifier,
           current != Self.extensionIdentifier { throw NetworkMonitorError.wrongConfiguration }
        if enabled {
            let configuration = NEFilterProviderConfiguration()
            configuration.filterSockets = true
            configuration.filterPackets = false
            configuration.filterDataProviderBundleIdentifier = Self.extensionIdentifier
            manager.providerConfiguration = configuration
            manager.localizedDescription = tr("XStats 网络连接查看")
        } else if manager.providerConfiguration == nil {
            return
        }
        manager.isEnabled = enabled
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        guard manager.isEnabled == enabled else { throw NetworkMonitorError.wrongConfiguration }
    }

    func read(after cursor: Int64, epoch: String) async throws -> ObservationBatch {
        guard NetworkMonitorSupport.isAvailable else { throw NetworkMonitorError.unsupportedVersion }
        if connection == nil {
            guard let name = Bundle.main.object(forInfoDictionaryKey: "NetworkObservationMachService") as? String,
                  !name.isEmpty else { throw NetworkMonitorError.missingExtension }
            let team = try signingTeam()
            let candidate = NSXPCConnection(machServiceName: name, options: .privileged)
            candidate.setCodeSigningRequirement("anchor apple generic and identifier \"\(Self.extensionIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\"")
            candidate.remoteObjectInterface = NSXPCInterface(with: NetworkObservationService.self)
            candidate.resume()
            connection = candidate
        }
        guard let connection else { throw NetworkMonitorError.unavailable }
        let reply = NetworkMonitorReply()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard !Task.isCancelled else { reply.finish(.failure(CancellationError())); return }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in reply.finish(.failure(error)) }) as? NetworkObservationService else {
                    reply.finish(.failure(NetworkMonitorError.unavailable)); return
                }
                proxy.readEvents(after: cursor, epoch: epoch) { reply.finish(.success($0)) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    reply.finish(.failure(NetworkMonitorError.timeout))
                }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
        try Task.checkCancellation()
        return try Self.decodeBatch(data)
    }

    static func decodeBatch(_ data: Data) throws -> ObservationBatch {
        let batch = try ObservationBatch.decode(data)
        // 相同构建号可能让 macOS 继续运行旧扩展；缺字段是协议不匹配，不能当作零条活动连接。
        guard batch.activeIDs != nil else { throw NetworkMonitorError.extensionNeedsUpdate }
        return batch
    }

    func stopReading() {
        connection?.invalidate()
        connection = nil
    }

    func uninstall() async throws -> Bool {
        guard NetworkMonitorSupport.isAvailable else { throw NetworkMonitorError.unsupportedVersion }
        stopReading()
        try await setFilterEnabled(false)
        let manager = NEFilterManager.shared()
        if manager.providerConfiguration != nil { try await manager.removeFromPreferences() }
        return try await submit(.deactivationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main))
    }

    private func submit(_ request: OSSystemExtensionRequest) async throws -> Bool {
        guard requestContinuation == nil else { throw NetworkMonitorError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            self.request = request
            requestContinuation = continuation
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

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

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard self.request === request else { return }
        onApproval?()
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard self.request === request else { return }
        self.request = nil
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume(returning: result == .willCompleteAfterReboot)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        guard self.request === request else { return }
        self.request = nil
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume(throwing: error)
    }
}
