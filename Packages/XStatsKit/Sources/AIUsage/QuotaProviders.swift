// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum AIQuotaKind: String, Codable, Sendable, Identifiable {
  case session, weekly, opusWeekly, sonnetWeekly
  public var id: Self { self }
}

public struct AIQuotaWindow: Codable, Equatable, Sendable, Identifiable {
  public let kind: AIQuotaKind
  public let usedPercent: Double
  public let resetsAt: Date?
  public var id: AIQuotaKind { kind }

  public init(kind: AIQuotaKind, usedPercent: Double, resetsAt: Date?) {
    self.kind = kind
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
  }

  public var remainingPercent: Double { 100 - usedPercent }

}
