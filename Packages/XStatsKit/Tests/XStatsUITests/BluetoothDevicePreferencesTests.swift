// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct BluetoothDevicePreferencesTests {
  private let first = ["aa", "bb", "cc", "dd", "ee", "01"].joined(separator: ":")
  private let second = ["aa", "bb", "cc", "dd", "ee", "02"].joined(separator: "-")

  @Test func preferencesSurviveRenameAndPersistOnlyStableAddresses() throws {
    let suite = "XStats.BluetoothPreferences.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.bluetoothDevicePreferences.togglePin(first)
    settings.bluetoothDevicePreferences.toggleHidden(second)
    settings.bluetoothDevicePreferences.togglePin("Headphones")
    let restored = AppSettings(defaults: defaults).bluetoothDevicePreferences
    #expect(restored.pinned == ["aabbccddee01"])
    #expect(restored.hidden == ["aabbccddee02"])
    let devices = [(address: second, name: "Same name"), (address: first, name: "Renamed")]
    #expect(restored.arranged(devices, address: \.address).map(\.name) == ["Renamed"])
  }

  @Test func selectedAndPendingDevicesRemainSelectableWhenHidden() {
    var preferences = BluetoothDevicePreferences()
    preferences.toggleHidden(first)
    let devices = [first, second, ""]
    #expect(preferences.arranged(devices, address: { $0 }) == [second, ""])
    #expect(preferences.arranged(devices, address: { $0 }, keeping: ["aabbccddee01"]) == devices)
    preferences.revealAll()
    #expect(preferences.arranged(devices, address: { $0 }) == devices)
  }

  @Test func pinningPreservesOtherOrderAndUnhidesTheDevice() {
    var preferences = BluetoothDevicePreferences()
    preferences.toggleHidden(second)
    preferences.togglePin(second)
    #expect(preferences.hidden.isEmpty)
    #expect(preferences.arranged([first, "", second], address: { $0 }) == [second, first, ""])
    preferences.togglePin(second)
    #expect(preferences.arranged([first, second], address: { $0 }) == [first, second])
  }

  @Test func corruptAndOversizedPreferencesAreBounded() throws {
    let entries = (0..<400).map { String(format: "%012x", $0) }
    let data = try JSONSerialization.data(withJSONObject: ["pinned": entries, "hidden": entries])
    let preferences = try JSONDecoder().decode(BluetoothDevicePreferences.self, from: data)
    #expect(preferences.pinned.count == 256)
    #expect(preferences.hidden.count == 256)
    let invalid = Data(
      #"{"pinned":["Keyboard","aa:bb:cc:dd:ee:ff","aabbccddeeff"],"hidden":["invalid"]}"#.utf8)
    let sanitized = try JSONDecoder().decode(BluetoothDevicePreferences.self, from: invalid)
    #expect(sanitized.pinned == ["aabbccddeeff"])
    #expect(sanitized.hidden.isEmpty)
  }
}
