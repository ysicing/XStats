// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import XStatsUI

@MainActor
struct PopoverSectionOrderTests {
  @Test func customContentDefaultsOffAndRetainsChoicesAcrossToggles() throws {
    let suite = "PopoverSectionOrderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(!settings.customPopoverContentEnabled)
    let standard = MenuBarItem.cpu.popoverSections.filter {
      !PopoverSection.hiddenByDefault.contains($0)
    }
    settings.setVisible(.cpuCores, true)
    settings.setVisible(.cpuApps, false)
    settings.movePopoverSection(.cpuHeatmap, for: .cpu, by: -1)
    #expect(settings.popoverSections(for: .cpu) == standard)
    #expect(!settings.isVisible(.cpuCores) && settings.isVisible(.cpuApps))
    settings.customPopoverContentEnabled = true
    let custom = settings.popoverSections(for: .cpu)
    #expect(custom == [.cpuHeatmap, .cpuCores])
    settings.customPopoverContentEnabled = false
    #expect(settings.popoverSections(for: .cpu) == standard)
    let restored = AppSettings(defaults: defaults)
    #expect(!restored.customPopoverContentEnabled)
    restored.customPopoverContentEnabled = true
    #expect(restored.popoverSections(for: .cpu) == custom)
    #expect(
      restored.popoverSections(for: .cpu, isDetailPage: true) == MenuBarItem.cpu.popoverSections)
  }

  @Test func collectionDemandFollowsEffectiveVisibilityAndStopsWhenClosed() throws {
    let suite = "PopoverSectionOrderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.enabledMonitoringModules = [.gpu]
    settings.menuBarItems = []
    settings.historyEnabled = false
    settings.enabledAlerts = []
    settings.hiddenPopoverSections.insert(.gpuDetails)
    let model = AppModel(
      settings: settings, historyURL: nil, magpieClient: UnavailableMagpieClient())
    model.openPopover = .gpu
    #expect(model.demand.gpuFrequency)
    settings.customPopoverContentEnabled = true
    #expect(!model.demand.gpuFrequency)
    settings.customPopoverContentEnabled = false
    #expect(model.demand.gpuFrequency)
    model.openPopover = nil
    #expect(!model.demand.hasSamples)
  }

  @Test func legacyCustomizationEnablesOnlyWhenChoicesDifferFromDefaults() throws {
    let suite = "PopoverSectionOrderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for hidden in [PopoverSection.hiddenByDefault, [], [.cpuApps]] {
      defaults.removePersistentDomain(forName: suite)
      defaults.set(hidden.map(\.rawValue), forKey: "hiddenPopoverSections")
      let settings = AppSettings(defaults: defaults)
      #expect(settings.customPopoverContentEnabled == (hidden != PopoverSection.hiddenByDefault))
      settings.customPopoverContentEnabled = false
      #expect(!AppSettings(defaults: defaults).customPopoverContentEnabled)
    }
    defaults.removePersistentDomain(forName: suite)
    defaults.set(["cpu": ["cpuApps"]], forKey: "popoverSectionOrders")
    let settings = AppSettings(defaults: defaults)
    #expect(settings.customPopoverContentEnabled)
    #expect(settings.popoverSections(for: .cpu).first == .cpuApps)
  }

  @Test func customContentDocumentPreservesExplicitOffAndMigratesLegacyChoices() throws {
    let suite = "PopoverSectionOrderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.setVisible(.cpuCores, true)
    let document = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(settings.exportDocument()))
    settings.customPopoverContentEnabled = true
    settings.apply(document)
    #expect(!settings.customPopoverContentEnabled)
    #expect(!settings.hiddenPopoverSections.contains(.cpuCores))
    var legacy = document
    legacy.customPopoverContentEnabled = nil
    settings.apply(legacy)
    #expect(settings.customPopoverContentEnabled && settings.isVisible(.cpuCores))
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(settings.customPopoverContentEnabled)
  }

  @Test func dragPasteboardTypeIsRecognizedBySwiftUI() throws {
    // AppKit 允许任意粘贴板名称，SwiftUI 目标却需要可解析的 UTType。
    // 未声明的自定义名称会让源成功启动、目标始终收不到拖入和落下。
    let type = try #require(UTType(SettingsReorderHandle.pasteboardType.rawValue))
    #expect(type.conforms(to: .data))
  }

  @Test func legacySettingsAndInvalidEntriesKeepEveryAllowedSectionExactlyOnce() throws {
    let suite = "PopoverSectionOrderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.orderedPopoverSections(for: .network) == MenuBarItem.network.popoverSections)
    settings.setPopoverSectionOrders([
      "network": ["networkInterface", "networkInterface", "cpuApps", "futureSection"],
      "futureItem": ["networkDNS"],
    ])
    let expected: [PopoverSection] =
      [.networkInterface]
      + MenuBarItem.network.popoverSections.filter {
        $0 != .networkInterface
      }
    #expect(settings.orderedPopoverSections(for: .network) == expected)
    #expect(AppSettings(defaults: defaults).orderedPopoverSections(for: .network) == expected)
    #expect(
      settings.popoverSections(for: .network, isDetailPage: true)
        == MenuBarItem.network.popoverSections)
  }

  @Test func movesPreserveHiddenPositionsAndOtherItemsAndResetOnlyOrder() throws {
    let suite = "PopoverSectionOrderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.customPopoverContentEnabled = true
    let modules = settings.enabledMonitoringModules
    settings.setVisible(.batteryBluetooth, false)
    settings.movePopoverSection(.batteryBluetooth, for: .battery, by: -5)
    #expect(settings.orderedPopoverSections(for: .battery).first == .batteryBluetooth)
    #expect(!settings.popoverSections(for: .battery).contains(.batteryBluetooth))
    settings.setVisible(.batteryBluetooth, true)
    #expect(settings.popoverSections(for: .battery).first == .batteryBluetooth)
    #expect(
      settings.orderedPopoverSections(for: .temperature) == MenuBarItem.temperature.popoverSections)
    settings.movePopoverSection(.batteryBluetooth, for: .battery, by: -1)
    #expect(settings.orderedPopoverSections(for: .battery).first == .batteryBluetooth)
    settings.setVisible(.batteryApps, false)
    settings.resetPopoverSectionOrder(for: .battery)
    #expect(settings.orderedPopoverSections(for: .battery) == MenuBarItem.battery.popoverSections)
    #expect(!settings.isVisible(.batteryApps) && settings.enabledMonitoringModules == modules)
  }

  @Test func documentRoundTripAndLegacyImportPreserveOrders() throws {
    let suite = "PopoverSectionOrderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let source = AppSettings(defaults: defaults)
    source.movePopoverSection(.networkInterface, for: .network, by: -2)
    let expected = source.orderedPopoverSections(for: .network)
    let document = try JSONDecoder().decode(
      SettingsDocument.self, from: JSONEncoder().encode(source.exportDocument()))
    source.resetPopoverSectionOrder(for: .network)
    source.apply(document)
    #expect(source.orderedPopoverSections(for: .network) == expected)
    source.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(source.orderedPopoverSections(for: .network) == expected)
    #expect(AppSettings(defaults: defaults).orderedPopoverSections(for: .network) == expected)
  }

  @Test func editorExcludesUnavailableHardwareWithoutChangingPreferences() throws {
    let suite = "PopoverSectionOrderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.customPopoverContentEnabled = true
    settings.setVisible(.batteryHealth, false)
    let hidden = settings.hiddenPopoverSections
    let order = settings.orderedPopoverSections(for: .battery)
    let desktop = settings.editablePopoverSections(
      for: .battery, hasBattery: false, supportsFans: true)
    #expect(desktop == [.batteryPower, .batteryApps, .thermalSensors, .batteryBluetooth])
    #expect(desktop.filter { settings.isVisible($0) }.count == 4)
    #expect(
      settings.editablePopoverSections(for: .battery, hasBattery: true, supportsFans: true) == order
    )
    #expect(
      settings.editablePopoverSections(for: .fan, hasBattery: false, supportsFans: false).isEmpty)
    #expect(
      settings.editablePopoverSections(for: .fan, hasBattery: false, supportsFans: true) == [
        .thermalFans
      ])
    #expect(settings.hiddenPopoverSections == hidden && settings.popoverSectionOrders.isEmpty)
  }

  @Test func filteredEditorMovesAndDragsPreserveUnavailableSlotsAndSavedChoices() throws {
    let suite = "PopoverSectionOrderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.customPopoverContentEnabled = true
    settings.setVisible(.batteryHistory, false)
    let hidden = settings.hiddenPopoverSections
    let initial = settings.orderedPopoverSections(for: .battery)
    let editable = settings.editablePopoverSections(
      for: .battery, hasBattery: false, supportsFans: true)
    // 蓝牙设备前隔着两项不支持的内容，单击向上仍应跨到温度之前。
    settings.movePopoverSection(.batteryBluetooth, for: .battery, by: -1, among: editable)
    let afterArrow = settings.editablePopoverSections(
      for: .battery, hasBattery: false, supportsFans: true)
    #expect(afterArrow == [.batteryPower, .batteryApps, .batteryBluetooth, .thermalSensors])
    var draft = PopoverSectionDrag(section: .thermalSensors, order: afterArrow)
    draft.move(over: .batteryPower)
    let offset = try #require(draft.offset(in: afterArrow))
    settings.movePopoverSection(draft.section, for: .battery, by: offset, among: afterArrow)
    #expect(
      settings.editablePopoverSections(for: .battery, hasBattery: false, supportsFans: true)
        == draft.previewOrder)
    let saved = settings.orderedPopoverSections(for: .battery)
    for section in [PopoverSection.batteryHistory, .batteryHealth] {
      #expect(saved.firstIndex(of: section) == initial.firstIndex(of: section))
    }
    #expect(settings.hiddenPopoverSections == hidden)
    #expect(AppSettings(defaults: defaults).orderedPopoverSections(for: .battery) == saved)
    // 过期的顺序和越界移动不能覆盖已保存的结果。
    #expect(draft.offset(in: draft.previewOrder) == nil)
    settings.movePopoverSection(.batteryPower, for: .battery, by: 1, among: editable)
    settings.movePopoverSection(.thermalSensors, for: .battery, by: -1, among: draft.previewOrder)
    #expect(settings.orderedPopoverSections(for: .battery) == saved)
  }

  @Test func dragPreviewDoesNotPersistUntilAcceptedAndRejectsStaleOrder() throws {
    let suite = "PopoverSectionOrderTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.customPopoverContentEnabled = true
    let order = settings.orderedPopoverSections(for: .cpu)
    settings.setVisible(.cpuApps, false)
    var draft = PopoverSectionDrag(section: .cpuApps, order: order)
    draft.move(over: .cpuCores)
    #expect(draft.previewOrder.first == .cpuApps)
    #expect(settings.popoverSectionOrders[.cpu] == nil)
    #expect(AppSettings(defaults: defaults).orderedPopoverSections(for: .cpu) == order)
    // 离开列表或按 Esc 时只丢弃草稿，偏好仍是原顺序；有效落下才调用已有的移动入口。
    let offset = try #require(draft.offset(in: settings.orderedPopoverSections(for: .cpu)))
    settings.movePopoverSection(draft.section, for: .cpu, by: offset)
    #expect(AppSettings(defaults: defaults).orderedPopoverSections(for: .cpu) == draft.previewOrder)
    #expect(!settings.isVisible(.cpuApps))
    #expect(draft.offset(in: settings.orderedPopoverSections(for: .cpu)) == nil)
    #expect(draft.offset(in: settings.orderedPopoverSections(for: .network)) == nil)
  }

  @Test func dragCanReverseDirectionAndIgnoreForeignTargets() {
    let order = MenuBarItem.cpu.popoverSections
    var draft = PopoverSectionDrag(section: .cpuCores, order: order)
    draft.move(over: .cpuApps)
    #expect(draft.previewOrder.last == .cpuCores)
    draft.move(over: .networkDNS)
    #expect(draft.previewOrder.last == .cpuCores)
    draft.move(over: .cpuHeatmap)
    #expect(draft.previewOrder == order)
    draft.move(over: .cpuCores)
    #expect(draft.offset(in: order) == 0)
  }

}
