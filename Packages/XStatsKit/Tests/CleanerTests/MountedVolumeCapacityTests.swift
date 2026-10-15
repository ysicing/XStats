// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Cleaner

struct MountedVolumeCapacityTests {
    @Test func networkVolumesUseOrdinaryFreeSpaceEvenWhenImportantUsageReportsZero() {
        #expect(MountedVolumes.availableCapacity(important: 0, ordinary: 18_000, isLocal: false) == 18_000)
        #expect(MountedVolumes.availableCapacity(important: 0, ordinary: nil, isLocal: false) == 0)
    }

    @Test func localVolumesIncludePurgeableSpaceAndFallBackToOrdinaryCapacity() {
        #expect(MountedVolumes.availableCapacity(important: 200, ordinary: 100, isLocal: true) == 200)
        #expect(MountedVolumes.availableCapacity(important: nil, ordinary: 100, isLocal: true) == 100)
        #expect(MountedVolumes.availableCapacity(important: -1, ordinary: -1, isLocal: true) == 0)
    }
}
