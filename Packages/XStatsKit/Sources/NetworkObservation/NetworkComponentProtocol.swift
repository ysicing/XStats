// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

public enum NetworkObservationProtocol {
    public static let version = 2
    public static let componentBundleIdentifier = "work.12306.xstats.networkmonitor"
    public static let extensionIdentifier = "work.12306.xstats.app.networkextension"
    public static let agentLabel = "work.12306.xstats.networkmonitor.agent"
    public static let agentPlistName = agentLabel + ".plist"
    public static func controlServiceName(team: String) -> String { team + ".work.12306.xstats.network-observation.control" }
}

public enum NetworkComponentRegistration: String, Codable, Sendable {
    case enabled, requiresApproval, notRegistered, notFound
}
public enum NetworkComponentUpdatePhase: String, Codable, Sendable {
    case idle, checking, upToDate, available, downloading, verifying, installing, failed
}
public struct NetworkComponentUpdateStatus: Codable, Sendable, Equatable {
    public var phase: NetworkComponentUpdatePhase
    public var version: String?
    public var progress: Double?
    /// 应用自定义错误为中文源文案键，接收界面使用 tr；系统原始错误保留系统文本。
    public var error: String?
    public init(phase: NetworkComponentUpdatePhase = .idle, version: String? = nil, progress: Double? = nil, error: String? = nil) {
        self.phase = phase; self.version = version; self.progress = progress; self.error = error
    }
}
public struct NetworkComponentStatus: Codable, Sendable, Equatable {
    public var componentVersion: String
    public var componentBuild: String
    public var extensionVersion: String
    public var extensionBuild: String
    public var observationMachService: String
    public var registration: NetworkComponentRegistration
    public var filterEnabled: Bool
    public var needsSystemApproval: Bool
    public var update: NetworkComponentUpdateStatus
    public init(componentVersion: String, componentBuild: String, extensionVersion: String, extensionBuild: String,
                observationMachService: String, registration: NetworkComponentRegistration, filterEnabled: Bool,
                needsSystemApproval: Bool = false, update: NetworkComponentUpdateStatus = .init()) {
        self.componentVersion = componentVersion; self.componentBuild = componentBuild
        self.extensionVersion = extensionVersion; self.extensionBuild = extensionBuild
        self.observationMachService = observationMachService; self.registration = registration
        self.filterEnabled = filterEnabled; self.needsSystemApproval = needsSystemApproval; self.update = update
    }
}
public struct NetworkComponentResponse: Codable, Sendable {
    public let protocolVersion: Int
    public let needsRestart: Bool
    /// 同 update.error 的源文案传输约定，服务不替调用方选择显示语言。
    public let error: String?
    public let status: NetworkComponentStatus?
    public init(needsRestart: Bool = false, error: String? = nil, status: NetworkComponentStatus? = nil) {
        self.protocolVersion = NetworkObservationProtocol.version
        self.needsRestart = needsRestart; self.error = error; self.status = status
    }
}

/// 诊断只保留计数，窗口最长30秒，不包含进程、地址或通信内容。
public struct FlowDiagnosticsDTO: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let token: String
    public let newFlowCallbacks: UInt64
    public init(token: String, newFlowCallbacks: UInt64) {
        self.protocolVersion = NetworkObservationProtocol.version
        self.token = token; self.newFlowCallbacks = newFlowCallbacks
    }
}

/// 授权和更新进度使用原有认证连接推送，主应用不另设状态轮询。
@objc public protocol NetworkComponentClientService {
    func needsSystemApproval()
    func componentStatusChanged(_ data: Data)
}
