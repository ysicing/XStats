// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics
@testable import XStatsUI

struct CPUPresentationTests {
    @Test func superAndPerformanceGroupsHaveDistinctWorkloadRoles() {
        let superCore = CPUCluster(id: 0, name: "Fixture S", coreIndices: [12, 13], kind: .superCore)
        let performance = CPUCluster(id: 1, name: "Fixture P", coreIndices: [0, 1], kind: .performance)
        let topology = CPUTopology(brand: "Fixture S/P", logicalCores: 4, clusters: [superCore, performance])
        #expect(superCore.workloadRole(in: topology) == .heavy)
        #expect(performance.workloadRole(in: topology) == .parallel)
    }

    @Test func traditionalPerformanceAndEfficiencyRolesRemainDistinct() {
        let performance = CPUCluster(id: 0, name: "Fixture P", coreIndices: [2, 3], kind: .performance)
        let efficiency = CPUCluster(id: 1, name: "Fixture E", coreIndices: [0, 1], kind: .efficiency)
        let topology = CPUTopology(brand: "Fixture P/E", logicalCores: 4, clusters: [performance, efficiency])
        #expect(performance.workloadRole(in: topology) == .heavy)
        #expect(efficiency.workloadRole(in: topology) == .light)
    }

    @Test func genericGroupDoesNotInventWorkloadRole() {
        let generic = CPUCluster(id: 0, name: "Fixture", coreIndices: [0, 1], kind: .unknown)
        let topology = CPUTopology(brand: "Fixture", logicalCores: 2, clusters: [generic])
        #expect(generic.workloadRole(in: topology) == nil)
    }

    @Test func unfamiliarHigherTierDoesNotMakePerformanceTierTheFastest() {
        let future = CPUCluster(id: 0, name: "Future", coreIndices: [2, 3], kind: .unknown)
        let performance = CPUCluster(id: 1, name: "P", coreIndices: [0, 1], kind: .performance)
        let topology = CPUTopology(brand: "Fixture", logicalCores: 4, clusters: [future, performance])
        #expect(performance.workloadRole(in: topology) == .parallel)
        #expect(future.workloadRole(in: topology) == nil)
    }

    @Test(arguments: [(ProcessInfo.ThermalState.nominal, Tone.success), (.fair, .warning),
                      (.serious, .error), (.critical, .error)])
    func thermalPressureSeverityDoesNotDependOnTemperature(_ state: ProcessInfo.ThermalState, _ tone: Tone) {
        #expect(Tone.forThermalState(state) == tone)
    }

    @MainActor @Test func thermalStateChangesPropagateWithoutChangingCPUUtilization() {
        let store = MetricsStore()
        var snapshot = MetricsSnapshot()
        snapshot.cpu = CPULoad(total: 0.5, user: 0.3, system: 0.2, perCore: [0.5], loadAverage: [])
        snapshot.cpu?.thermalState = .nominal
        store.apply(snapshot)
        #expect(store.cpu?.thermalState == .nominal)
        snapshot.cpu?.thermalState = .serious
        store.apply(snapshot)
        #expect(store.cpu?.total == 0.5)
        #expect(store.cpu?.thermalState == .serious)
    }
}
