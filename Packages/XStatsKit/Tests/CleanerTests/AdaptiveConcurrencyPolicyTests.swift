// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Cleaner

struct AdaptiveConcurrencyPolicyTests {
  private let idle = AdaptiveConcurrencyPolicy.Load(cpuUsage: 0.2, memoryPressure: .normal)

  @Test func growsGraduallyAndStaysWithinHalfTheProcessors() {
    var policy = AdaptiveConcurrencyPolicy(activeProcessorCount: 8)
    #expect(policy.update(load: idle, now: 0) == 2)
    #expect(policy.update(load: idle, now: 2) == 2)
    #expect(policy.update(load: idle, now: 3) == 3)
    #expect(policy.update(load: idle, now: 3.1) == 3)
    #expect(policy.update(load: idle, now: 6) == 4)
    #expect(policy.update(load: idle, now: 20) == 4)
  }

  @Test func busyOrUnknownSamplesResetTheHeadroomWindow() {
    var policy = AdaptiveConcurrencyPolicy(activeProcessorCount: 16)
    _ = policy.update(load: idle, now: 0)
    #expect(policy.update(load: idle, now: 3) == 3)
    #expect(policy.update(load: .init(cpuUsage: 0.9, memoryPressure: .normal), now: 4) == 2)
    _ = policy.update(load: idle, now: 5)
    #expect(policy.update(load: .init(cpuUsage: 0.65, memoryPressure: .normal), now: 7) == 2)
    #expect(policy.update(load: idle, now: 8) == 2)
    #expect(policy.update(load: idle, now: 11) == 3)
    #expect(policy.update(load: .init(cpuUsage: nil, memoryPressure: .normal), now: 12) == 2)
    #expect(policy.update(load: .init(cpuUsage: 0.1, memoryPressure: nil), now: 16) == 2)
    #expect(policy.update(load: .init(cpuUsage: .nan, memoryPressure: .normal), now: 20) == 2)
  }

  @Test func pressurePausesDispatchAndRecoveryStartsConservatively() {
    var policy = AdaptiveConcurrencyPolicy(activeProcessorCount: 16)
    _ = policy.update(load: idle, now: 0)
    _ = policy.update(load: idle, now: 3)
    #expect(policy.update(load: .init(cpuUsage: 0.1, memoryPressure: .warning), now: 4) == 2)
    #expect(policy.update(load: .init(cpuUsage: 0.1, memoryPressure: .critical), now: 5) == 0)
    #expect(policy.update(load: idle, now: 30) == 2)
    #expect(policy.update(load: idle, now: 33) == 3)
    #expect(
      policy.update(
        load: .init(cpuUsage: 0.1, memoryPressure: .normal, thermalState: .serious), now: 34
      ) == 2)
    #expect(
      policy.update(
        load: .init(cpuUsage: nil, memoryPressure: nil, thermalState: .critical), now: 35
      ) == 0)
  }
}
