// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Testing
@testable import XStatsUI

struct LaunchpadTriggerTests {
  private func contacts(count: Int = 4, radius: Double = 0.25, offset: Double = 0)
    -> [LaunchpadPinch.Contact]
  {
    (0..<count).map { index in
      let angle = Double(index) * 2 * .pi / Double(count)
      return .init(
        id: Int32(index), x: 0.5 + cos(angle) * radius + offset, y: 0.5 + sin(angle) * radius)
    }
  }

  @Test(arguments: [4, 5]) func contractionFollowsFingersAndCommitsOnRelease(fingers: Int) {
    var pinch = LaunchpadPinch(fingers: fingers)
    #expect(pinch.update(contacts(count: fingers)) == nil)
    if case .progress(let value) = pinch.update(contacts(count: fingers, radius: 0.2)) {
      #expect(abs(value - 0.5) < 0.001)
    } else {
      Issue.record("Pinch did not start")
    }
    if case .progress(let value) = pinch.update(contacts(count: fingers, radius: 0.15)) {
      #expect(abs(value - 1) < 0.001)
    } else {
      Issue.record("Pinch lost contact")
    }
    #expect(pinch.update([]) == .end(true))
    #expect(pinch.update(contacts(count: fingers)) == nil)
  }

  @Test func translationWrongCountIdentityAndInvalidCoordinatesCannotOpen() {
    var pinch = LaunchpadPinch()
    #expect(pinch.update(contacts(count: 3)) == nil)
    #expect(pinch.update(contacts()) == nil)
    #expect(pinch.update(contacts(offset: 0.1)) == nil)
    _ = pinch.update(contacts(radius: 0.22))
    #expect(pinch.update([]) == .end(false))
    _ = pinch.update(contacts())
    _ = pinch.update(contacts(radius: 0.15))
    var swapped = contacts(radius: 0.15)
    swapped[0] = .init(id: 99, x: swapped[0].x, y: swapped[0].y)
    #expect(pinch.update(swapped) == .end(false))
    #expect(pinch.update(swapped) == nil)
    _ = pinch.update([])
    _ = pinch.update(contacts())
    _ = pinch.update(contacts(radius: 0.15))
    #expect(pinch.update([.init(id: 0, x: .nan, y: 0)]) == .end(false))
  }

  @MainActor @Test func cornersRespectScreenOriginsAndSettingsPersistWithoutGlobalMonitors() throws
  {
    let screen = NSRect(x: -1440, y: 200, width: 1440, height: 900)
    #expect(LaunchpadTriggers.hitsCorner(NSPoint(x: -1439, y: 1099), frame: screen, corner: 1))
    #expect(LaunchpadTriggers.hitsCorner(NSPoint(x: -1, y: 201), frame: screen, corner: 4))
    #expect(!LaunchpadTriggers.hitsCorner(NSPoint(x: -500, y: 600), frame: screen, corner: 1))
    #expect(!LaunchpadTriggers.hitsCorner(NSPoint(x: 100, y: 1099), frame: screen, corner: 1))
    let suite = "LaunchpadTriggerTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.launchpadPinchFingers == 0 && settings.launchpadHotCorner == 0)
    settings.launchpadPinchFingers = 5
    settings.launchpadHotCorner = 3
    let restored = AppSettings(defaults: defaults)
    #expect(restored.launchpadPinchFingers == 5 && restored.launchpadHotCorner == 3)
    var document = settings.exportDocument()
    document.language = nil
    settings.launchpadPinchFingers = 0
    settings.launchpadHotCorner = 0
    settings.apply(document)
    #expect(settings.launchpadPinchFingers == 5 && settings.launchpadHotCorner == 3)
    settings.apply(try JSONDecoder().decode(SettingsDocument.self, from: Data("{}".utf8)))
    #expect(settings.launchpadPinchFingers == 5 && settings.launchpadHotCorner == 3)
    document.launchpadPinchFingers = 99
    document.launchpadHotCorner = -1
    settings.apply(document)
    #expect(settings.launchpadPinchFingers == 0 && settings.launchpadHotCorner == 0)
    let trigger = LaunchpadTriggers()
    trigger.configure(fingers: 0, corner: 0)
    trigger.stop()
    trigger.stop()
  }
}
