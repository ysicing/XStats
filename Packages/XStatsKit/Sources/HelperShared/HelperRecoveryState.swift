// SPDX-License-Identifier: AGPL-3.0-or-later

/// 每项接管意图独立保留，只有对应的硬件恢复成功后才能清除。
public struct HelperRecoveryState: Codable, Sendable {
  public var sleepDisabled: Bool
  private var inheritedFanOverride: Bool
  private var manualFans: Set<Int> = []

  public var fansOverridden: Bool { inheritedFanOverride || !manualFans.isEmpty }
  public var hasPendingRecovery: Bool { sleepDisabled || fansOverridden }

  public init(sleepDisabled: Bool = false, fansOverridden: Bool = false) {
    self.sleepDisabled = sleepDisabled
    inheritedFanOverride = fansOverridden
  }

  public mutating func recordFanOverride(_ fan: Int) {
    manualFans.insert(fan)
  }

  public mutating func recordFanRestored(_ fan: Int) {
    manualFans.remove(fan)
  }

  public mutating func recordAllFansRestored() {
    inheritedFanOverride = false
    manualFans.removeAll()
  }

  private enum CodingKeys: String, CodingKey {
    case sleepDisabled, fansOverridden
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    sleepDisabled = try values.decode(Bool.self, forKey: .sleepDisabled)
    // 旧记录没有具体风扇编号，恢复单个风扇不能证明全部已恢复。
    inheritedFanOverride = try values.decode(Bool.self, forKey: .fansOverridden)
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(sleepDisabled, forKey: .sleepDisabled)
    try values.encode(fansOverridden, forKey: .fansOverridden)
  }
}
