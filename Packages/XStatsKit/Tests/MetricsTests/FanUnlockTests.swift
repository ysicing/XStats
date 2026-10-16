// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import SMC

private final class FanFirmware: FanSMCAccess {
  var values: [SMCKey: Double] = [
    SMCKey("FNum"): 2, SMCKey("F0Md"): 0, SMCKey("F1Md"): 0,
    SMCKey("F0Mn"): 1000, SMCKey("F0Mx"): 5000, SMCKey("Ftst"): 0,
  ]
  var writes: [(SMCKey, Double)] = []
  var sleeps: [TimeInterval] = []
  var readyAfter = 0
  var modeAttempts = 0
  var ignoresModeWrites = false
  var failsTarget = false

  func double(_ key: SMCKey) -> Double? { values[key] }
  func exists(_ key: SMCKey) -> Bool { values[key] != nil }
  func write(_ key: SMCKey, value: Double) throws {
    writes.append((key, value))
    if key == SMCKey("F0Md"), value == 1 {
      modeAttempts += 1
      if modeAttempts <= readyAfter { throw SMCError.firmwareRejected(key, 1) }
      if ignoresModeWrites { return }
    }
    if key == SMCKey("F0Tg"), failsTarget { throw SMCError.firmwareRejected(key, 1) }
    values[key] = value
  }
  func control() -> FanControl { FanControl(access: self, sleep: { self.sleeps.append($0) }) }
}

struct FanUnlockTests {
  @Test func directModeNeedsNoUnlockOrDelayAndClampsRPM() throws {
    let firmware = FanFirmware()
    try firmware.control().setManual(fan: 0, rpm: 8000)
    #expect(firmware.values[SMCKey("F0Tg")] == 5000)
    #expect(firmware.values[SMCKey("Ftst")] == 0 && firmware.sleeps.isEmpty)
  }

  @Test func legacyUnlockReturnsAsSoonAsFirmwareAcceptsAndReadsBack() throws {
    let firmware = FanFirmware()
    firmware.readyAfter = 3
    try firmware.control().setManual(fan: 0, rpm: 2000)
    #expect(firmware.values[SMCKey("F0Md")] == 1)
    #expect(firmware.values[SMCKey("F0Tg")] == 2000)
    #expect(firmware.sleeps.reduce(0, +) < 0.2)
  }

  @Test func silentModeRejectionTimesOutAndRestoresSystemOwnership() {
    let firmware = FanFirmware()
    firmware.ignoresModeWrites = true
    #expect(throws: SMCError.self) { try firmware.control().setManual(fan: 0, rpm: 2000) }
    #expect(firmware.values[SMCKey("F0Tg")] == nil)
    #expect(firmware.values[SMCKey("F0Md")] == 0 && firmware.values[SMCKey("Ftst")] == 0)
    #expect(firmware.sleeps.reduce(0, +) <= 15.1)
    #expect(firmware.modeAttempts <= 301)
  }

  @Test func failedTargetRestoresOnlyNewlyAcquiredFanWithoutDisruptingOtherFan() {
    let firmware = FanFirmware()
    firmware.values[SMCKey("F1Md")] = 1
    firmware.values[SMCKey("Ftst")] = 1
    firmware.failsTarget = true
    #expect(throws: SMCError.self) { try firmware.control().setManual(fan: 0, rpm: 2000) }
    #expect(firmware.values[SMCKey("F0Md")] == 0)
    #expect(firmware.values[SMCKey("F1Md")] == 1 && firmware.values[SMCKey("Ftst")] == 1)
  }

  @Test func unknownFanCountCannotResetAnotherFansGlobalUnlock() {
    let firmware = FanFirmware()
    firmware.values[SMCKey("FNum")] = nil
    firmware.values[SMCKey("F1Md")] = 1
    firmware.values[SMCKey("Ftst")] = 1
    firmware.failsTarget = true
    #expect(throws: SMCError.self) { try firmware.control().setManual(fan: 0, rpm: 2000) }
    #expect(firmware.values[SMCKey("F0Md")] == 0)
    #expect(firmware.values[SMCKey("F1Md")] == 1 && firmware.values[SMCKey("Ftst")] == 1)
  }

  @Test func missingOtherFansModeCannotResetGlobalUnlock() {
    let firmware = FanFirmware()
    firmware.values[SMCKey("F1Md")] = nil
    firmware.values[SMCKey("Ftst")] = 1
    firmware.failsTarget = true
    #expect(throws: SMCError.self) { try firmware.control().setManual(fan: 0, rpm: 2000) }
    #expect(firmware.values[SMCKey("Ftst")] == 1)
  }

  /// helper 只在复位不抛错时才清除“已接管”记录；FNum 读不到却当作 0 台风扇会让风扇永久停在手动转速。
  @Test func resettingWithUnreadableFanCountFailsInsteadOfPretendingSuccess() {
    let firmware = FanFirmware()
    firmware.values[SMCKey("FNum")] = nil
    firmware.values[SMCKey("F0Md")] = 1
    firmware.values[SMCKey("Ftst")] = 1
    #expect(throws: SMCError.self) { try firmware.control().resetAll() }
  }

  @Test func confirmedFanlessMachineResetsWithoutError() throws {
    let firmware = FanFirmware()
    firmware.values[SMCKey("FNum")] = 0
    try firmware.control().resetAll()
  }

  @Test func unreadableModeKeyIsReportedAsUnknownRatherThanAutomatic() {
    let firmware = FanFirmware()
    firmware.values[SMCKey("FNum")] = 1
    firmware.values[SMCKey("F0Ac")] = 1_500
    firmware.values[SMCKey("F0Md")] = nil
    let unknown = firmware.control().read()
    #expect(unknown.count == 1 && unknown[0].isModeKnown == false)

    firmware.values[SMCKey("F0Md")] = 1
    let manual = firmware.control().read()
    #expect(manual[0].isModeKnown && manual[0].isManual)
  }

  @Test func resettingAllFansReturnsGlobalUnlockToSystem() throws {
    let firmware = FanFirmware()
    firmware.values[SMCKey("F0Md")] = 1
    firmware.values[SMCKey("F1Md")] = 1
    firmware.values[SMCKey("Ftst")] = 1
    try firmware.control().resetAll()
    #expect(firmware.values[SMCKey("F0Md")] == 0 && firmware.values[SMCKey("F1Md")] == 0)
    #expect(firmware.values[SMCKey("Ftst")] == 0)
  }
}
