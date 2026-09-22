// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum AIProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex, claude

    public var id: Self { self }
}

public protocol AIUsageProvider: Sendable {
    var id: AIProviderID { get }
    func fetch() async throws -> AIUsageSnapshot
}

public struct AIUsageSnapshot: Equatable, Sendable {
    public let provider: AIProviderID
    public let fetchedAt: Date
    public var localUsage: LocalUsageReport?

    public init(provider: AIProviderID, fetchedAt: Date) {
        self.provider = provider
        self.fetchedAt = fetchedAt
        self.localUsage = nil
    }
}

/// 只读扫描会失败在两处：打不开缓存库，或日志读到一半出错。两者都保留上一次的统计结果。
public enum AIUsageFailure: Error, Equatable, Sendable {
    case network
    case invalidResponse
}
