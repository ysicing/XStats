// SPDX-License-Identifier: AGPL-3.0-or-later
import Testing
import SMC
@testable import Metrics

struct SensorDiscoveryTests {
  @Test func emptyDiscoveryRetriesOnlyOnDemandAndKeepsRecoveredKeys() {
    var calls = 0
    let sampler = SensorSampler {
      calls += 1
      return calls == 1 ? [:] : [.cpu: [SMCKey("Tp0C")]]
    }
    #expect(sampler.sample(groups: []) == nil)
    #expect(calls == 0)
    let now = ContinuousClock.now
    #expect(sampler.temperatureKeys(now: now).isEmpty)
    #expect(sampler.temperatureKeys(now: now + .seconds(29)).isEmpty)
    #expect(calls == 1)
    #expect(sampler.temperatureKeys(now: now + .seconds(30))[.cpu]?.count == 1)
    #expect(sampler.temperatureKeys(now: now + .seconds(120))[.cpu]?.count == 1)
    #expect(calls == 2)
  }
}
