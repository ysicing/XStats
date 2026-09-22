// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum AIProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude

    public var id: Self { self }
}

public enum AIQuotaKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case session, weekly, sparkSession, sparkWeekly

    public var id: Self { self }
}

public enum AIUsageDisplayMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case remaining, used

    public var id: Self { self }
}

public struct AIQuotaWindow: Equatable, Sendable, Identifiable {
    public let kind: AIQuotaKind
    public let usedPercent: Double
    public let resetsAt: Date?

    public var id: AIQuotaKind { kind }
    public var renderedUsedFraction: Double { min(max(usedPercent / 100, 0), 1) }

    public init(kind: AIQuotaKind, usedPercent: Double, resetsAt: Date?) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct AIUsageSnapshot: Equatable, Sendable {
    public let provider: AIProviderID
    public let planName: String?
    public let windows: [AIQuotaWindow]
    public let remainingCredits: Double?
    public let fetchedAt: Date
    public var localUsage: LocalUsageReport?

    public init(provider: AIProviderID, planName: String?, windows: [AIQuotaWindow],
                remainingCredits: Double?, fetchedAt: Date) {
        self.provider = provider
        self.planName = planName
        self.windows = windows
        self.remainingCredits = remainingCredits
        self.fetchedAt = fetchedAt
        self.localUsage = nil
    }

    public func window(_ kind: AIQuotaKind) -> AIQuotaWindow? {
        windows.first { $0.kind == kind }
    }

    /// 菜单栏自动模式展示底层已用比例最高的一项，避免平均值掩盖即将耗尽的额度。
    public var attentionWindow: AIQuotaWindow? {
        windows.max { $0.usedPercent < $1.usedPercent }
    }

    public func displayedPercent(for window: AIQuotaWindow, mode: AIUsageDisplayMode) -> Double {
        switch mode {
        case .used: window.usedPercent
        case .remaining: max(0, 100 - min(max(window.usedPercent, 0), 100))
        }
    }
}

public enum AIUsageFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case notConfigured
    case apiKeyUnsupported
    case invalidCredentials
    case unauthorized
    case rateLimited(Date?)
    case network
    case invalidResponse
    case server(Int)

    public var preservesLastGood: Bool {
        switch self {
        case .rateLimited, .network, .invalidResponse, .server: true
        case .notConfigured, .apiKeyUnsupported, .invalidCredentials, .unauthorized: false
        }
    }

    public var retryAt: Date? {
        if case .rateLimited(let date) = self { date } else { nil }
    }

    public var description: String {
        switch self {
        case .notConfigured: "notConfigured"
        case .apiKeyUnsupported: "apiKeyUnsupported"
        case .invalidCredentials: "invalidCredentials"
        case .unauthorized: "unauthorized"
        case .rateLimited: "rateLimited"
        case .network: "network"
        case .invalidResponse: "invalidResponse"
        case .server(let status): "server(\(status))"
        }
    }
}
