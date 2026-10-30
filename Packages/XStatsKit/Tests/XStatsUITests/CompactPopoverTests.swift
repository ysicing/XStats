// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct CompactPopoverTests {
  @Test func defaultsKeepSummariesAndHideSecondaryDetailsWithoutOverwritingChoices() throws {
    let suite = "CompactPopoverTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    for section in [
      PopoverSection.cpuCores, .cpuClusters, .cpuLoadAverage, .diskHealth,
      .thermalPower,
    ] {
      #expect(!settings.isVisible(section))
    }
    for section in [
      PopoverSection.cpuHeatmap, .cpuApps, .memoryWaterline, .memoryCompression, .memoryApps,
      .diskActivity,
      .diskProcesses,
    ] {
      #expect(settings.isVisible(section))
    }
    settings.hiddenPopoverSections = []
    #expect(AppSettings(defaults: defaults).hiddenPopoverSections.isEmpty)
    let document = settings.exportDocument()
    let restored = AppSettings(defaults: defaults)
    restored.hiddenPopoverSections = [.cpuApps]
    restored.apply(document)
    #expect(restored.hiddenPopoverSections.isEmpty)

    restored.customPopoverContentEnabled = true
    restored.setVisible(.memoryCompression, false)
    let customized = AppSettings(defaults: defaults)
    #expect(!customized.popoverSections(for: .memory).contains(.memoryCompression))
    customized.customPopoverContentEnabled = false
    #expect(customized.popoverSections(for: .memory).contains(.memoryCompression))
    customized.customPopoverContentEnabled = true
    #expect(!customized.popoverSections(for: .memory).contains(.memoryCompression))
  }

  @Test func diskVolumesAreRequestedOnlyByVisibleDiskContent() throws {
    let suite = "CompactPopoverTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.menuBarItems = [.disk]
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    #expect(!model.diskVolumesVisible)
    model.openPopover = .disk
    #expect(model.diskVolumesVisible)
    model.openPopover = nil
    model.isMainWindowVisible = true
    settings.panelTab = .disk
    #expect(model.diskVolumesVisible)
    settings.setModuleEnabled(.disk, false)
    #expect(!model.diskVolumesVisible)
    settings.setModuleEnabled(.disk, true)
    #expect(model.diskVolumesVisible)
    settings.panelTab = .overview
    #expect(!model.diskVolumesVisible)
    model.isMainWindowVisible = false
    #expect(!model.diskVolumesVisible)
  }
}
