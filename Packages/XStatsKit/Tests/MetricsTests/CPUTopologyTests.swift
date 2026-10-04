// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Metrics

struct CPUTopologyTests {
    @Test func preservesPerformanceAndEfficiencyGroups() {
        let topology = CPUSampler.topology(brand: "Fixture P/E", logicalCores: 8,
                                          levels: [("Performance", 4), ("Efficiency", 4)])
        #expect(topology.clusters.map(\.kind) == [.performance, .efficiency])
        #expect(topology.clusters.map(\.id) == [0, 1])
        #expect(topology.clusters.map(\.coreIndices) == [[4, 5, 6, 7], [0, 1, 2, 3]])
    }

    @Test func preservesSuperAndPerformanceWithoutInventingEfficiency() {
        let topology = CPUSampler.topology(brand: "Fixture S/P", logicalCores: 18,
                                          levels: [("Super", 6), ("Performance", 12)])
        #expect(topology.clusters.map(\.kind) == [.superCore, .performance])
        #expect(topology.clusters.map(\.coreIndices) == [Array(12..<18), Array(0..<12)])
    }

    @Test func preservesThreeCoreTypesAndTheirProcessorIndices() {
        let topology = CPUSampler.topology(brand: "Fixture S/P/E", logicalCores: 12,
                                          levels: [("Super", 2), ("Performance", 4), ("Efficiency", 6)])
        #expect(topology.clusters.map(\.kind) == [.superCore, .performance, .efficiency])
        #expect(topology.clusters.map(\.coreIndices) == [[10, 11], [6, 7, 8, 9], [0, 1, 2, 3, 4, 5]])
    }

    @Test(arguments: [[("Performance", 4), ("Efficiency", 0)],
                      [("Super", 2), ("Performance", 4)],
                      [("Performance", 8), ("Efficiency", 4)],
                      [("Performance", -1), ("Efficiency", 9)], []])
    func inconsistentCountsFallBackWithoutDroppingOrInventingCores(_ levels: [(String, Int)]) {
        let topology = CPUSampler.topology(brand: "Fixture", logicalCores: 8, levels: levels)
        #expect(topology.clusters.count == 1)
        #expect(topology.clusters.first?.kind == .unknown)
        #expect(topology.clusters.first?.coreIndices == Array(0..<8))
    }

    @Test func unfamiliarNamesAreNotClassifiedFromChipBrand() {
        let topology = CPUSampler.topology(brand: "Apple M6", logicalCores: 8,
                                          levels: [("Future Fast", 4), ("Future Small", 4)])
        #expect(topology.clusters.map(\.kind) == [.unknown, .unknown])
        #expect(topology.clusters.map(\.name) == ["Future Fast", "Future Small"])
    }

    @Test func normalizesSystemCoreTypeNames() {
        let topology = CPUSampler.topology(brand: "Fixture", logicalCores: 8,
                                          levels: [(" SUPER ", 2), ("performance", 4), ("Efficiency", 2)])
        #expect(topology.clusters.map(\.kind) == [.superCore, .performance, .efficiency])
    }

}
