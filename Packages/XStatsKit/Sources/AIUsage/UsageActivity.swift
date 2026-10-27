// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum UsageActivityMode: String, CaseIterable, Sendable {
  case daily, weekly, monthly, cumulative
}

/// 保留 Magpie 返回的统计桶边界，不重新分配跨小时或跨周的 Token。
public struct UsageTimeSeries: Sendable {
  public struct Bucket: Identifiable, Sendable {
    public let start: Date
    public let end: Date
    public let total: Int
    public var id: Date { start }
  }
}
