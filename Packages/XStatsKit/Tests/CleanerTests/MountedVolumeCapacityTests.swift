// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import Cleaner

struct MountedVolumeCapacityTests {
  @Test func networkVolumesUseOrdinaryFreeSpaceEvenWhenImportantUsageReportsZero() {
    #expect(
      MountedVolumes.availableCapacity(important: 0, ordinary: 18_000, isLocal: false) == 18_000)
    #expect(MountedVolumes.availableCapacity(important: 0, ordinary: nil, isLocal: false) == 0)
  }

  @Test func localVolumesIncludePurgeableSpaceAndFallBackToOrdinaryCapacity() {
    #expect(MountedVolumes.availableCapacity(important: 200, ordinary: 100, isLocal: true) == 200)
    #expect(MountedVolumes.availableCapacity(important: nil, ordinary: 100, isLocal: true) == 100)
    #expect(MountedVolumes.availableCapacity(important: -1, ordinary: -1, isLocal: true) == 0)
  }

  /// HFS、exFAT 和只读映像等非 APFS 本地卷会把 ImportantUsage 报为 0，而非缺失。
  @Test func localVolumesFallBackToOrdinaryCapacityWhenImportantUsageReportsZero() {
    #expect(
      MountedVolumes.availableCapacity(important: 0, ordinary: 4_390_912, isLocal: true)
        == 4_390_912)
    #expect(MountedVolumes.availableCapacity(important: 0, ordinary: 0, isLocal: true) == 0)
    #expect(MountedVolumes.availableCapacity(important: 0, ordinary: nil, isLocal: true) == 0)
  }
}
