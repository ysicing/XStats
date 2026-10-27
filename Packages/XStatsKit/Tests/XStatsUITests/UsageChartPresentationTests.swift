// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Foundation
import Testing
@testable import XStatsUI

struct UsageChartPresentationTests {
  @Test func metricsUseDistinctValuesWithoutTreatingMissingSpeedAsZero() throws {
    let bucket = try JSONDecoder().decode(
      MagpieUsageBucket.self,
      from: Data(
        #"{"time":0,"input":100,"output":50,"calls":3,"cost":0.125,"decode_ms":2000,"decode_out":40,"decode_n":2}"#
          .utf8))
    #expect(UsageActivityMetric.tokens.value(bucket) == 150)
    #expect(UsageActivityMetric.calls.value(bucket) == 3)
    #expect(UsageActivityMetric.cost.value(bucket) == 0.125)
    #expect(UsageActivityMetric.speed.value(bucket) == 20)
    let unknown = try JSONDecoder().decode(
      MagpieUsageBucket.self, from: Data(#"{"time":0,"input":0,"output":0}"#.utf8))
    #expect(UsageActivityMetric.speed.value(unknown) == nil)
    #expect(UsageActivityMetric.cost.value(unknown) == nil)
    #expect(UsageActivityMetric.calls.value(unknown) == nil)
  }

  @Test func compactCumulativeUsesMonthlySummaryAndChartImmediately() throws {
    let mode = UsageChartPresentation.mode(.cumulative, compact: true)
    #expect(mode == .monthly)

  }

  @Test(arguments: UsageActivityMode.allCases)
  func normalModesAndFullWindowRemainUnchanged(_ mode: UsageActivityMode) {
    #expect(UsageChartPresentation.mode(mode, compact: false) == mode)
    if mode != .cumulative { #expect(UsageChartPresentation.mode(mode, compact: true) == mode) }
  }

  @Test(arguments: [true, false])
  func shortAxesHaveUniqueValidIdentities(_ narrow: Bool) {
    #expect(UsageChartPresentation.tickIndices(count: 0, narrow: narrow) == [])
    #expect(UsageChartPresentation.tickIndices(count: 1, narrow: narrow) == [0])
    #expect(UsageChartPresentation.tickIndices(count: 2, narrow: narrow) == [0, 1])
    for count in [3, 7, 23, 24, 25, 30] {
      let indices = UsageChartPresentation.tickIndices(count: count, narrow: narrow)
      #expect(indices == indices.sorted())
      #expect(indices.count == Set(indices).count)
      #expect(indices.allSatisfy { (0..<count).contains($0) })
      #expect(indices.first == 0 && indices.last == count - 1)
    }
  }
}
