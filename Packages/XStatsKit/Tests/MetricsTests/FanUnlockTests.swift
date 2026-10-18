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
  var ignoredModeAttempts = 0
  var unreadableModeAfterWrite = false
  var modeWriteError: SMCError?
  var failsTarget = false

  func double(_ key: SMCKey) -> Double? {
    if key == SMCKey("F0Md"), unreadableModeAfterWrite, modeAttempts > 0 { return nil }
    return values[key]
  }
  func exists(_ key: SMCKey) -> Bool { values[key] != nil }
  func write(_ key: SMCKey, value: Double) throws {
    writes.append((key, value))
    if key == SMCKey("F0Md"), value == 1 {
      modeAttempts += 1
      if let modeWriteError { throw modeWriteError }
      if modeAttempts <= readyAfter { throw SMCError.firmwareRejected(key, 1) }
      if ignoresModeWrites || modeAttempts <= ignoredModeAttempts { return }
    }
    if key == SMCKey("F0Tg"), failsTarget { throw SMCError.firmwareRejected(key, 1) }
    values[key] = value
  }
  func control() -> FanControl { FanControl(access: self, sleep: { self.sleeps.append($0) }) }
}

struct FanUnlockTests {
  @Test func detectedFanCountDistinguishesUnknownFromFanlessHardware() {
    let firmware = FanFirmware()
    let control = firmware.control()
    for value in [Double.nan, .infinity, -1, 0.5, 256] {
      firmware.values[SMCKey("FNum")] = value
      #expect(control.detectedFanCount == nil)
    }
    firmware.values[SMCKey("FNum")] = nil
    #expect(control.detectedFanCount == nil)
    firmware.values[SMCKey("FNum")] = 0
    #expect(control.detectedFanCount == 0)
    firmware.values[SMCKey("FNum")] = 2
    #expect(control.detectedFanCount == 2)
  }

  @Test(arguments: [false, true])
  func directModeNeedsNoUnlockOrDelayAndClampsRPM(hasFtst: Bool) throws {
    let firmware = FanFirmware()
    if !hasFtst { firmware.values[SMCKey("Ftst")] = nil }
    try firmware.control().setManual(fan: 0, rpm: 8000)
    #expect(firmware.values[SMCKey("F0Tg")] == 5000)
    #expect(firmware.values[SMCKey("Ftst")] == (hasFtst ? 0 : nil))
    #expect(firmware.sleeps.isEmpty)
    #expect(firmware.modeAttempts == 1)
  }

  @Test func legacyUnlockReturnsAsSoonAsFirmwareAcceptsAndReadsBack() throws {
    let firmware = FanFirmware()
    firmware.readyAfter = 3
    try firmware.control().setManual(fan: 0, rpm: 2000)
    #expect(firmware.values[SMCKey("F0Md")] == 1)
    #expect(firmware.values[SMCKey("F0Tg")] == 2000)
    #expect(firmware.sleeps.reduce(0, +) < 0.2)
  }

  @Test(.bug("https://github.com/ysicing/XStats/issues/15"), arguments: [false, true])
  func missingFtstRetriesUntilManualModeIsConfirmed(silent: Bool) throws {
    let firmware = FanFirmware()
    firmware.values[SMCKey("Ftst")] = nil
    firmware.readyAfter = silent ? 0 : 3
    firmware.ignoredModeAttempts = silent ? 3 : 0
    try firmware.control().setManual(fan: 0, rpm: 2000)
    #expect(firmware.values[SMCKey("F0Md")] == 1)
    #expect(firmware.values[SMCKey("F0Tg")] == 2000)
    #expect(firmware.modeAttempts == 4)
    #expect(firmware.sleeps.reduce(0, +) < 0.2)
    #expect(firmware.writes.allSatisfy { $0.0 != SMCKey("Ftst") })
  }

  @Test(arguments: [false, true])
  func modeWriteFailurePreservesFirmwareResult(hasFtst: Bool) {
    let firmware = FanFirmware()
    if !hasFtst { firmware.values[SMCKey("Ftst")] = nil }
    firmware.modeWriteError = .firmwareRejected(SMCKey("F0Md"), 0x85)
    do {
      try firmware.control().setManual(fan: 0, rpm: 2000)
      Issue.record("A rejected mode write must fail")
    } catch {
      guard case SMCError.firmwareRejected(let key, let code) = error else {
        Issue.record("Expected the original firmware error, got \(error)")
        return
      }
      #expect(key == SMCKey("F0Md") && code == 0x85)
    }
    #expect(firmware.values[SMCKey("F0Tg")] == nil)
    #expect(firmware.values[SMCKey("F0Md")] == 0)
    #expect(firmware.values[SMCKey("Ftst")] == (hasFtst ? 0 : nil))
    #expect(firmware.modeAttempts == 301)
    #expect(firmware.sleeps.count == 299)
    #expect(firmware.sleeps.reduce(0, +) <= 15.1)
  }

  @Test func modeWriteFailurePreservesTransportError() {
    let firmware = FanFirmware()
    firmware.values[SMCKey("Ftst")] = nil
    firmware.modeWriteError = .callFailed(SMCKey("F0Md"), KERN_FAILURE)
    do {
      try firmware.control().setManual(fan: 0, rpm: 2000)
      Issue.record("A failed mode call must fail")
    } catch {
      guard case SMCError.callFailed(let key, let code) = error else {
        Issue.record("Expected the original transport error, got \(error)")
        return
      }
      #expect(key == SMCKey("F0Md") && code == KERN_FAILURE)
    }
    #expect(firmware.values[SMCKey("F0Tg")] == nil)
  }

  @Test(arguments: [false, true], [false, true])
  func unconfirmedModeDistinguishesUnreadableFromUnappliedWrite(hasFtst: Bool, unreadable: Bool) {
    let firmware = FanFirmware()
    if !hasFtst { firmware.values[SMCKey("Ftst")] = nil }
    firmware.readyAfter = 1
    firmware.unreadableModeAfterWrite = unreadable
    firmware.ignoresModeWrites = !unreadable
    do {
      try firmware.control().setManual(fan: 0, rpm: 2000)
      Issue.record("An unconfirmed mode must not allow a target write")
    } catch {
      switch error {
      case SMCError.readbackFailed(let key):
        #expect(unreadable && key == SMCKey("F0Md"))
      case SMCError.writeNotApplied(let key):
        #expect(!unreadable && key == SMCKey("F0Md"))
      default:
        Issue.record("Expected a readback error, got \(error)")
      }
    }
    #expect(firmware.values[SMCKey("F0Tg")] == nil)
    #expect(firmware.values[SMCKey("F0Md")] == 0)
    #expect(firmware.modeAttempts == 301)
    #expect(firmware.sleeps.count == 299)
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

  @Test(arguments: [false, true])
  func failedTargetRestoresOnlyNewlyAcquiredFanWithoutDisruptingOtherFan(hasFtst: Bool) {
    let firmware = FanFirmware()
    firmware.values[SMCKey("F1Md")] = 1
    firmware.values[SMCKey("Ftst")] = hasFtst ? 1 : nil
    firmware.readyAfter = 3
    firmware.failsTarget = true
    #expect(throws: SMCError.self) { try firmware.control().setManual(fan: 0, rpm: 2000) }
    #expect(firmware.values[SMCKey("F0Md")] == 0)
    #expect(firmware.values[SMCKey("F1Md")] == 1)
    #expect(firmware.values[SMCKey("Ftst")] == (hasFtst ? 1 : nil))
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
