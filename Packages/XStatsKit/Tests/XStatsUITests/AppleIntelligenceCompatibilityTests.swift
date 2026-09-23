// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleIntelligenceCompatibilityTests {
    @MainActor @Test func unavailableSystemModelMustNotShowSupport() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           case .unavailable = SystemLanguageModel.default.availability {
            let status = AppleIntelligenceCompatibility.evaluate(
                chip: "Apple M2", osVersion: ProcessInfo.processInfo.operatingSystemVersion)
            #expect(status != .supported)
        }
        #endif
    }

    @Test func distinguishesHardwareAndSystemRequirements() {
        let oldSystem = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        let firstSupportedSystem = OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 0)
        let newerSystem = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

        #expect(AppleIntelligenceCompatibility.evaluate(chip: "Intel Core i9", osVersion: newerSystem,
                                                        modelIsAvailable: true) == .unsupportedHardware)
        #expect(AppleIntelligenceCompatibility.evaluate(chip: "Apple M1", osVersion: oldSystem,
                                                        modelIsAvailable: nil) == .requiresSystemUpdate)
        #expect(AppleIntelligenceCompatibility.evaluate(chip: "Apple M1", osVersion: firstSupportedSystem,
                                                        modelIsAvailable: nil) == .unknown)
        #expect(AppleIntelligenceCompatibility.evaluate(chip: "Apple M5 Max", osVersion: newerSystem,
                                                        modelIsAvailable: true) == .supported)
        #expect(AppleIntelligenceCompatibility.evaluate(chip: "Apple A18 Pro", osVersion: newerSystem,
                                                        modelIsAvailable: true) == .supported)
        #expect(AppleIntelligenceCompatibility.evaluate(chip: "Apple M2", osVersion: newerSystem,
                                                        modelIsAvailable: false) == .unavailable)
    }
}
