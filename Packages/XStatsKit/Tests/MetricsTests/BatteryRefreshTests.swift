// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import IOKit.ps
import Testing
@testable import Metrics

struct BatteryRefreshTests {
    @Test func presenceDistinguishesAbsentBatteryIncompleteReadAndExternalPowerSource() {
        #expect(BatterySampler.readPowerSources(nil).hasInternalBattery == nil)
        #expect(BatterySampler.readPowerSources([]).hasInternalBattery == false)
        #expect(BatterySampler.readPowerSources([nil]).hasInternalBattery == nil)
        #expect(BatterySampler.readPowerSources([[:]]).hasInternalBattery == nil)
        let external: [String: Any] = [kIOPSTypeKey: kIOPSUPSType]
        #expect(BatterySampler.readPowerSources([external]).hasInternalBattery == false)
        #expect(BatterySampler.readPowerSources([external, nil]).hasInternalBattery == nil)
        let internalSource: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: 50,
                                           kIOPSMaxCapacityKey: 100]
        let reading = BatterySampler.readPowerSources([nil, external, internalSource])
        #expect(reading.hasInternalBattery == true)
        #expect(reading.battery?.level == 0.5)
    }

}
