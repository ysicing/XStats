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

  @Test func fanOnlySamplingRetriesFailedConnectionsAtMostEveryThirtySeconds() {
    var attempts = 0
    var now = ContinuousClock.now
    let sampler = SensorSampler(
      openConnection: {
        attempts += 1
        return nil
      },
      clock: { now })
    #expect(attempts == 1)
    for _ in 0..<100 {
      #expect(sampler.sample(groups: [], includeFans: true) == nil)
    }
    #expect(attempts == 1)
    now += .seconds(29)
    #expect(sampler.sample(groups: [], includeFans: true) == nil)
    #expect(attempts == 1)
    now += .seconds(1)
    #expect(sampler.sample(groups: [], includeFans: true) == nil)
    #expect(attempts == 2)
    for _ in 0..<100 {
      #expect(sampler.sample(groups: [], includeFans: true) == nil)
    }
    #expect(attempts == 2)
    now += .seconds(30)
    #expect(sampler.detectFanCount() == nil)
    #expect(attempts == 3)
  }

  @Test func temperatureAndFanDemandShareOneReconnectBudget() {
    var attempts = 0
    var now = ContinuousClock.now
    let sampler = SensorSampler(
      openConnection: {
        attempts += 1
        return nil
      },
      clock: { now })
    #expect(sampler.sample(groups: [.cpu], includeFans: false) == nil)
    #expect(attempts == 1)
    now += .seconds(30)
    #expect(sampler.sample(groups: [], includeFans: true) == nil)
    #expect(sampler.sample(groups: [.cpu], includeFans: true) == nil)
    #expect(sampler.detectFanCount() == nil)
    #expect(attempts == 2)
  }

  @Test func absentDemandDoesNotRetryFailedConnections() {
    var attempts = 0
    var now = ContinuousClock.now
    let sampler = SensorSampler(
      openConnection: {
        attempts += 1
        return nil
      },
      clock: { now })
    now += .seconds(300)
    #expect(sampler.sample(groups: [], includeFans: false) == nil)
    #expect(attempts == 1)
  }
}
