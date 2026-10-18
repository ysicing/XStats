// SPDX-License-Identifier: AGPL-3.0-or-later
import Localization
import Testing

@testable import XStatsUI

struct LoadLevelTests {
  @Test(arguments: [
    (0.0, LoadLevel.normal), (0.6, .normal), (0.799, .normal), (0.8, .warning),
    (0.899, .warning), (0.9, .critical), (1.0, .critical),
  ])
  func standardUsageLevelsFollowSharedBoundaries(value: Double, expected: LoadLevel) {
    #expect(LoadLevel.usage(value, sensitivity: .standard) == expected)
  }

  @Test(arguments: [
    (0.0, LoadLevel.normal), (0.599, .normal), (0.6, .warning), (0.849, .warning),
    (0.85, .critical), (1.0, .critical),
  ])
  func sensitiveUsageLevelsFollowSharedBoundaries(value: Double, expected: LoadLevel) {
    #expect(LoadLevel.usage(value, sensitivity: .sensitive) == expected)
  }

  @Test(arguments: [
    (1.0, LoadLevel.normal), (0.201, .normal), (0.2, .warning), (0.101, .warning),
    (0.1, .critical), (0.0, .critical),
  ])
  func remainingLevelsFollowSharedBoundaries(value: Double, expected: LoadLevel) {
    #expect(LoadLevel.remaining(value) == expected)
  }

  @Test func normalToneIsChosenByCaller() {
    #expect(LoadLevel.normal.tone(normal: .success) == .success)
    #expect(LoadLevel.warning.tone(normal: .success) == .warning)
    #expect(LoadLevel.critical.tone(normal: .success) == .error)
  }
}

struct LoadTextConsistencyTests {
  /// 文字里的“高负载”必须与着色的橙色起点一致，两种灵敏度下各入口才不会互相矛盾。
  @Test(arguments: LoadSensitivity.allCases, [0.0, 0.2, 0.5, 0.59, 0.6, 0.75, 0.8, 0.9, 1.0])
  func highLoadTextMatchesColorLevel(sensitivity: LoadSensitivity, value: Double) {
    let isHigh = loadLevel(value, sensitivity) == tr("高负载")
    #expect(isHigh == (LoadLevel.usage(value, sensitivity: sensitivity) != .normal))
  }
}
