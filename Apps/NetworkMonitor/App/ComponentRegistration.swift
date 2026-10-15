// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import CryptoKit
import Foundation
import NetworkObservation
import Security
import ServiceManagement

struct ComponentRegistrationResult: Codable, Sendable {
    let protocolVersion: Int
    let registration: NetworkComponentRegistration
    let error: String?
    init(error: String? = nil) {
        protocolVersion = NetworkObservationProtocol.version
        registration = ComponentRegistration.status
        self.error = error
    }
}

/// 仅从外部 GUI/CLI 调用刷新；unregister 会杀掉 launchd 服务，服务不能注销自己。
enum ComponentRegistration {
    private static let fingerprintKey = "networkAgentRegistrationFingerprintV2"
    static var status: NetworkComponentRegistration {
        switch SMAppService.agent(plistName: NetworkObservationProtocol.agentPlistName).status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    @concurrent static func ensureRegistered(forceRefresh: Bool = false) async throws {
        _ = try NetworkCodeIdentity.currentTeam()
        let app = Bundle.main.bundleURL
        let fingerprint = try registrationFingerprint(app: app)
        let agent = SMAppService.agent(plistName: NetworkObservationProtocol.agentPlistName)
        // CLI 注册结束后立即退出，不能依赖偏好写入的后台刷新时机；也刷新其他进程的登记结果。
        UserDefaults.standard.synchronize()
        let previous = UserDefaults.standard.string(forKey: fingerprintKey)
        let registered = agent.status == .enabled || agent.status == .requiresApproval
        if registered, !forceRefresh, previous == fingerprint { return }
        ComponentLog.registration.notice("Refreshing agent registration force=\(forceRefresh)")
        if registered { try await agent.unregister() }
        do { try agent.register() }
        catch {
            guard agent.status == .requiresApproval else { throw error }
        }
        guard agent.status == .enabled || agent.status == .requiresApproval else { throw NetworkMonitorError.unavailable }
        UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)
        UserDefaults.standard.synchronize()
        ComponentLog.registration.notice("Agent registration completed approvalRequired=\(agent.status == .requiresApproval)")
    }

    @concurrent static func unregister() async throws {
        let agent = SMAppService.agent(plistName: NetworkObservationProtocol.agentPlistName)
        if agent.status == .enabled || agent.status == .requiresApproval { try await agent.unregister() }
        UserDefaults.standard.removeObject(forKey: fingerprintKey)
        UserDefaults.standard.synchronize()
        ComponentLog.registration.notice("Agent unregistered")
    }

    private static func registrationFingerprint(app: URL) throws -> String {
        let infoData = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"), options: .mappedIfSafe)
        guard infoData.count <= 1024 * 1024,
              let info = try PropertyListSerialization.propertyList(from: infoData, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == NetworkObservationProtocol.componentBundleIdentifier,
              info["NetworkObservationProtocolVersion"] as? Int == NetworkObservationProtocol.version else {
            throw NetworkMonitorError.protocolMismatch
        }
        let team = try NetworkCodeIdentity.currentTeam()
        let name = NetworkObservationProtocol.controlServiceName(team: team)
        guard info["NetworkObservationControlMachService"] as? String == name else { throw NetworkMonitorError.protocolMismatch }
        let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Library/LaunchAgents/" + NetworkObservationProtocol.agentPlistName))
        guard plist.count <= 32 * 1024,
              let launch = try PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any],
              launch["Label"] as? String == NetworkObservationProtocol.agentLabel,
              launch["BundleProgram"] as? String == "Contents/MacOS/XStats Network Monitor",
              launch["ProgramArguments"] as? [String] == ["XStats Network Monitor", "--service"],
              launch["MachServices"] as? [String: Bool] == [name: true],
              launch["KeepAlive"] == nil, launch["RunAtLoad"] == nil else { throw NetworkMonitorError.protocolMismatch }
        var code: SecStaticCode?, signing: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
              let hash = (signing as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { throw NetworkMonitorError.unsigned }
        return SHA256.hash(data: hash + plist).map { String(format: "%02x", $0) }.joined()
    }
}
