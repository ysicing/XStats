// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AudioControl
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct AudioApplicationPinTests {
  @Test func pinsPersistIndependentlyOfAudioAdjustmentsAndOnlyReorderVisibleApps() throws {
    let suite = "XStats.AudioApplicationPinTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = AudioController(defaults: defaults)
    defer { controller.stop() }
    let apps = [
      app("alpha", playing: true), app("beta", playing: true), app("hidden", playing: false),
    ]
    controller.showPreview(
      AudioHardwareSnapshot(devices: [], outputID: nil, inputID: nil, applications: apps),
      volumes: [:], outputs: [:])
    controller.toggleAppPin(apps[1])
    controller.toggleAppPin(apps[2])
    #expect(controller.listedApplications.map(\.id) == ["beta", "alpha"])
    #expect(controller.snapshot.applications == apps)
    #expect(controller.volumes.isEmpty)
    #expect(controller.outputRoutes.isEmpty)
    #expect(defaults.data(forKey: "audio.applicationVolumes") == nil)
    #expect(defaults.data(forKey: "audio.applicationOutputs") == nil)
    let restored = AudioController(defaults: defaults)
    defer { restored.stop() }
    #expect(restored.pinnedApplications == ["beta", "hidden"])
    restored.showPreview(controller.snapshot, volumes: [:], outputs: [:])
    #expect(restored.listedApplications.map(\.id) == ["beta", "alpha"])
    restored.toggleAppPin(apps[1])
    #expect(restored.listedApplications.map(\.id) == ["alpha", "beta"])
    let saved = try JSONDecoder().decode(
      [String].self, from: try #require(defaults.data(forKey: "audio.pinnedApplications")))
    #expect(saved == ["hidden"])
    restored.setDemand(enabled: true, visible: false, menuVisible: false)
    restored.setDemand(enabled: false, visible: false, menuVisible: false)
    #expect(restored.pinnedApplications == ["hidden"], "关闭音频只清理实时状态，不忘记置顶选择")
  }

  @Test func transientAndInvalidIdentitiesCannotBePinnedOrRestored() throws {
    let suite = "XStats.AudioApplicationPinTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let invalid = ["", "pid:123:45", String(repeating: "a", count: 513)]
    defaults.set(
      try JSONEncoder().encode(invalid + ["player", "player"]), forKey: "audio.pinnedApplications")
    let controller = AudioController(defaults: defaults)
    defer { controller.stop() }
    #expect(controller.pinnedApplications == ["player"])
    for id in invalid {
      #expect(!controller.canPinApp(app(id)))
      controller.toggleAppPin(app(id))
    }
    #expect(controller.pinnedApplications == ["player"])
    for data in [Data("invalid".utf8), Data(repeating: 32, count: 1_048_577)] {
      defaults.set(data, forKey: "audio.pinnedApplications")
      let restored = AudioController(defaults: defaults)
      #expect(restored.pinnedApplications.isEmpty)
      restored.stop()
    }
  }

  @Test func pinStorageIsBoundedAndUnpinningStillWorksAtCapacity() throws {
    let suite = "XStats.AudioApplicationPinTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let ids = (0..<300).map { "app.\($0)" }
    defaults.set(try JSONEncoder().encode(ids), forKey: "audio.pinnedApplications")
    let controller = AudioController(defaults: defaults)
    defer { controller.stop() }
    #expect(controller.pinnedApplications == Set(ids.prefix(256)))
    #expect(!controller.canPinApp(app("new")))
    controller.toggleAppPin(app("new"))
    #expect(!controller.pinnedApplications.contains("new"))
    #expect(controller.canPinApp(app(ids[0])))
    controller.toggleAppPin(app(ids[0]))
    controller.toggleAppPin(app("new"))
    #expect(controller.pinnedApplications.count == 256)
    #expect(controller.pinnedApplications.contains("new"))
    let restored = AudioController(defaults: defaults)
    defer { restored.stop() }
    #expect(restored.pinnedApplications == controller.pinnedApplications)
  }

  private func app(_ id: String, playing: Bool = true) -> AudioApplication {
    AudioApplication(id: id, name: id, processObjectIDs: [1], isPlaying: playing)
  }
}
