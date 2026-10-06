// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import NetworkExtension
import NetworkObservation
import Security
import SystemExtensions
import Updates

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

@MainActor final class NetworkComponentManager: NSObject, @preconcurrency OSSystemExtensionRequestDelegate {
    static let extensionIdentifier = "work.12306.xstats.app.networkextension"
    static func requiresReplacement(installed: UpdateRelease.NetworkExtension?, target: UpdateRelease.NetworkExtension) -> Bool { installed != target }
    var onApproval: (() -> Void)?
    private var request: OSSystemExtensionRequest?
    private var requestContinuation: CheckedContinuation<Bool, any Error>?
    private var propertiesContinuation: CheckedContinuation<[InstalledExtension], any Error>?
    private var connection: NSXPCConnection?
    private var connectionServiceName: String?
    private var activationGeneration = 0
    private struct InstalledExtension: Sendable {
        let version: UInt64?
        let displayVersion: String
        var release: UpdateRelease.NetworkExtension? { version.map { .init(version: displayVersion, build: String($0)) } }
        let enabled: Bool
        let uninstalling: Bool
    }

    init(connection: NSXPCConnection? = nil) {
        self.connection = connection
        super.init()
    }

    func activate() async throws -> Bool {
        let generation = activationGeneration
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else { throw NetworkMonitorError.unsupportedVersion }
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(Self.extensionIdentifier).systemextension")
        guard FileManager.default.fileExists(atPath: extensionURL.path) else { throw NetworkMonitorError.missingExtension }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { throw NetworkMonitorError.installLocation }
        _ = try signingTeam()
        let target = try bundledExtension()
        let installed = try await installedProperties().first(where: { $0.enabled && !$0.uninstalling })
        guard activationGeneration == generation else { throw CancellationError() }
        // App 构建号不参与扩展替换判定；同一扩展不提交激活，也不关闭已有过滤会话。
        if !Self.requiresReplacement(installed: installed?.release, target: target) { return false }
        _ = try await prepareForUpdate(target: target)
        guard activationGeneration == generation else { throw CancellationError() }
        return try await submit(.activationRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main))
    }

    private func bundledExtension() throws -> UpdateRelease.NetworkExtension {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "NetworkObservationExtensionVersion") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "NetworkObservationExtensionBuild") as? String,
              let number = UInt64(build), number > 0 else { throw NetworkMonitorError.missingExtension }
        return .init(version: version, build: String(number))
    }

    func cancelActivation() {
        activationGeneration += 1
        request = nil
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume(throwing: CancellationError())
        propertiesContinuation?.resume(throwing: CancellationError())
        propertiesContinuation = nil
    }

    /// 相同扩展返回原启用状态；确需替换时停用并确认生命周期收尾。
    func prepareForUpdate(target: UpdateRelease.NetworkExtension) async throws -> Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else { return false }
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        guard let identifier = manager.providerConfiguration?.filterDataProviderBundleIdentifier else { stopReading(); return false }
        guard identifier == Self.extensionIdentifier else { throw NetworkMonitorError.wrongConfiguration }
        let wasEnabled = manager.isEnabled
        let properties = try await installedProperties()
        let installed = properties.first(where: { $0.enabled })
        if installed == nil {
            guard !properties.contains(where: { $0.uninstalling }) else { throw NetworkMonitorError.restartRequired }
            if wasEnabled { try await setFilterEnabled(false) }
            stopReading()
            return wasEnabled
        }
        if !Self.requiresReplacement(installed: installed?.release, target: target) { stopReading(); return wasEnabled }
        guard let version = installed?.version else { throw NetworkMonitorError.extensionNeedsUpdate }
        if wasEnabled { try await setFilterEnabled(false) }
        defer { stopReading() }
        let service = try Self.serviceName(forInstalledBuild: version)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        repeat {
            try Task.checkCancellation()
            if try await filterIsStopped(service: service) { return wasEnabled }
            try await Task.sleep(for: .milliseconds(250), tolerance: .milliseconds(50))
        } while clock.now < deadline
        throw NetworkMonitorError.timeout
    }

    private func filterIsStopped(service: String) async throws -> Bool {
        let peer = try ensureConnection(service: service)
        let reply = NetworkMonitorReply()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard !Task.isCancelled else { reply.finish(.failure(CancellationError())); return }
                guard let proxy = peer.remoteObjectProxyWithErrorHandler({ @Sendable error in reply.finish(.failure(error)) }) as? NetworkObservationService else {
                    reply.finish(.failure(NetworkMonitorError.unavailable)); return
                }
                proxy.isFilterStopped { @Sendable stopped in reply.finish(.success(Data([stopped ? 1 : 0]))) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    reply.finish(.failure(NetworkMonitorError.timeout))
                }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
        try Task.checkCancellation()
        return data == Data([1])
    }

    private func installedProperties() async throws -> [InstalledExtension] {
        guard request == nil else { throw NetworkMonitorError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let request = OSSystemExtensionRequest.propertiesRequest(forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
            self.request = request
            propertiesContinuation = continuation
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func filterEnabled() async throws -> Bool {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        return manager.isEnabled
    }

    func setFilterEnabled(_ enabled: Bool) async throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else { throw NetworkMonitorError.unsupportedVersion }
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        if let current = manager.providerConfiguration?.filterDataProviderBundleIdentifier,
           current != Self.extensionIdentifier { throw NetworkMonitorError.wrongConfiguration }
        if manager.isEnabled == enabled,
           !enabled || (manager.providerConfiguration?.filterSockets == true && manager.providerConfiguration?.filterPackets == false) {
            return
        }
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

    private func ensureConnection(service: String? = nil) throws -> NSXPCConnection {
        if let connection, service == nil || connectionServiceName == service { return connection }
        guard let name = service ?? Bundle.main.object(forInfoDictionaryKey: "NetworkObservationMachService") as? String,
              !name.isEmpty else { throw NetworkMonitorError.missingExtension }
        let team = try signingTeam()
        stopReading()
        let candidate = NSXPCConnection(machServiceName: name, options: .privileged)
        candidate.setCodeSigningRequirement("anchor apple generic and identifier \"\(Self.extensionIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\"")
        candidate.remoteObjectInterface = NSXPCInterface(with: NetworkObservationService.self)
        candidate.resume()
        connection = candidate
        connectionServiceName = name
        return candidate
    }

    /// 使用系统报告的旧构建定位旧服务；服务前缀来自已签名的主应用，不接受远端任意地址。
    static func serviceName(forInstalledBuild build: UInt64, bundle: Bundle = .main) throws -> String {
        guard let name = bundle.object(forInfoDictionaryKey: "NetworkObservationMachService") as? String,
              let current = bundle.object(forInfoDictionaryKey: "NetworkObservationExtensionBuild") as? String else { throw NetworkMonitorError.missingExtension }
        return try serviceName(current: name, currentBuild: current, installedBuild: build)
    }

    static func serviceName(current: String, currentBuild: String, installedBuild: UInt64) throws -> String {
        let suffix = "." + currentBuild
        guard UInt64(currentBuild) != nil, current.hasSuffix(suffix), installedBuild > 0 else { throw NetworkMonitorError.extensionNeedsUpdate }
        return String(current.dropLast(suffix.count)) + "." + String(installedBuild)
    }

    func stopReading() {
        connection?.invalidate()
        connection = nil
        connectionServiceName = nil
    }

    func uninstall() async throws -> Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 else { throw NetworkMonitorError.unsupportedVersion }
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

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        guard self.request === request else { return }
        self.request = nil
        let continuation = propertiesContinuation
        propertiesContinuation = nil
        continuation?.resume(returning: properties.map { InstalledExtension(version: UInt64($0.bundleVersion), displayVersion: $0.bundleShortVersion, enabled: $0.isEnabled, uninstalling: $0.isUninstalling) })
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        guard self.request === request else { return }
        self.request = nil
        let continuation = requestContinuation
        requestContinuation = nil
        continuation?.resume(throwing: error)
        propertiesContinuation?.resume(throwing: error)
        propertiesContinuation = nil
    }
}

extension NetworkComponentManager {
    func register(endpoint: NSXPCListenerEndpoint) async throws {
        let peer = try ensureConnection()
        let reply = NetworkMonitorReply()
        _ = try await withCheckedThrowingContinuation { continuation in
            reply.install(continuation)
            guard let proxy = peer.remoteObjectProxyWithErrorHandler({ @Sendable error in reply.finish(.failure(error)) }) as? NetworkObservationService else {
                reply.finish(.failure(NetworkMonitorError.unavailable)); return
            }
            proxy.registerControlEndpoint(endpoint) { @Sendable in reply.finish(.success(Data())) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { reply.finish(.failure(NetworkMonitorError.timeout)) }
        }
    }
}
