// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import HelperShared
import Testing

@Suite struct HelperRecoveryStateTests {
  @Test func legacyDoubleMarkerRetainsFansAfterSleepRecovery() throws {
    let data = try PropertyListSerialization.data(
      fromPropertyList: ["sleepDisabled": true, "fansOverridden": true],
      format: .binary, options: 0)
    var state = try PropertyListDecoder().decode(HelperRecoveryState.self, from: data)
    state.sleepDisabled = false
    let restarted = try roundTrip(state)
    #expect(restarted.hasPendingRecovery && restarted.fansOverridden)
    #expect(!restarted.sleepDisabled)
  }

  @Test(arguments: [false, true], [false, true])
  func partialRecoveryRetainsEveryUnrestoredMarker(
    restoreSleep: Bool, restoreFans: Bool
  ) throws {
    var state = HelperRecoveryState(sleepDisabled: true, fansOverridden: true)
    if restoreSleep { state.sleepDisabled = false }
    if restoreFans { state.recordAllFansRestored() }
    let restarted = try roundTrip(state)
    #expect(restarted.sleepDisabled == !restoreSleep)
    #expect(restarted.fansOverridden == !restoreFans)
    #expect(restarted.hasPendingRecovery == !(restoreSleep && restoreFans))
  }

  @Test func restoringOneKnownFanCannotClearAnInheritedOverride() throws {
    var state = HelperRecoveryState(sleepDisabled: false, fansOverridden: true)
    state.recordFanOverride(0)
    state.recordFanRestored(0)
    #expect(state.fansOverridden && state.hasPendingRecovery)
    #expect(try roundTrip(state).fansOverridden)
    state.recordAllFansRestored()
    #expect(!state.hasPendingRecovery)
  }

  @Test func manualIntentSurvivesFailureAndRestartUntilAllFansAreRestored() throws {
    var state = HelperRecoveryState()
    state.recordFanOverride(0)
    state.recordFanOverride(1)
    #expect(try roundTrip(state).fansOverridden)
    state.recordFanRestored(0)
    #expect(state.fansOverridden)
    state.recordFanRestored(1)
    #expect(!state.hasPendingRecovery)
  }

  @Test func fanRecoveryDoesNotClearFailedSleepRecovery() throws {
    var state = HelperRecoveryState(sleepDisabled: true, fansOverridden: true)
    state.recordAllFansRestored()
    let restarted = try roundTrip(state)
    #expect(restarted.sleepDisabled && restarted.hasPendingRecovery)
    #expect(!restarted.fansOverridden)
  }

  private func roundTrip(_ state: HelperRecoveryState) throws -> HelperRecoveryState {
    try PropertyListDecoder().decode(
      HelperRecoveryState.self, from: PropertyListEncoder().encode(state))
  }
}
