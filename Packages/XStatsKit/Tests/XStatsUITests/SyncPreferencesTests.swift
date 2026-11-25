// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import XStatsUI

@MainActor
struct SyncPreferencesTests {
  @Test func firstImportWaitsForVerifiedPublicationAndReportsRealMetadata() throws {
    let source = Peer(name: "工作 Mac")
    let follower = Peer()
    defer {
      source.clean()
      follower.clean()
    }
    let activityTime = Date(timeIntervalSince1970: 1_750_000_000)
    source.settings.appearance = .dark
    follower.settings.appearance = .light
    var documents: [UUID: Data] = [:]
    let publisher = try source.open()
    try seed(publisher, in: &documents)
    let advertisedTime = try #require(publisher.lastSettingsSyncAt)
    try exchange(publisher, in: &documents, activityTime: activityTime)
    let receiver = try follower.open()
    try receiver.setEnabled(true)
    #expect(receiver.wantsSync)
    let registration = try #require(try receiver.prepare(documents, activitySyncedAt: nil))
    #expect(receiver.devices.map(\.name) == ["工作 Mac"])
    #expect(receiver.devices.first?.lastActivitySyncAt == activityTime)
    #expect(receiver.devices.first?.lastSettingsSyncAt == advertisedTime)
    #expect(receiver.lastSettingsSyncAt == nil)

    let prompt = try #require(receiver.firstChoice)
    #expect(prompt.fields.map(\.field) == [.appearance])
    let metadata = try #require(JSONSerialization.jsonObject(with: registration) as? [String: Any])
    let fields = try #require(metadata["fields"] as? [Any])
    #expect(fields.isEmpty)
    documents[follower.id] = registration
    try receiver.didPublish(documents)
    #expect(receiver.firstChoice?.id == prompt.id)
    #expect(follower.settings.appearance == .light)
    #expect(receiver.lastSettingsSyncAt == nil)
    try receiver.acceptFirst(prompt, selections: [.appearance: .device(source.id)])
    let prepared = try receiver.prepare(documents, activitySyncedAt: nil)
    let upload = try #require(prepared)
    #expect(follower.settings.appearance == .light)
    #expect(throws: SyncPreferences.Failure.unverifiedPublication) {
      try receiver.didPublish(documents)
    }
    #expect(receiver.lastSettingsSyncAt == nil)
    #expect(receiver.devices.count == 2)
    documents[follower.id] = upload
    try receiver.didPublish(documents)
    #expect(follower.settings.appearance == .dark)
    #expect(receiver.firstChoice == nil)
    let reported = try #require(receiver.devices.first { $0.id == follower.id })
    #expect(reported.name == nil)
    #expect(reported.lastActivitySyncAt == nil)
    #expect(reported.lastSettingsSyncAt == nil)
    let verifiedTime = try #require(receiver.lastSettingsSyncAt)
    try exchange(receiver, in: &documents)
    #expect(receiver.devices.first { $0.id == follower.id }?.lastSettingsSyncAt == verifiedTime)
    #expect(receiver.lastSettingsSyncAt != nil)
  }

  @Test func customAudioAndOtherSettingsStayLocal() throws {
    let source = Peer()
    let follower = Peer()
    defer {
      source.clean()
      follower.clean()
    }
    source.settings.restEnabled = true
    source.settings.restSound = .stream
    source.settings.restWorkMinutes = 43
    follower.settings.restSound = .custom
    follower.settings.restWorkMinutes = 32
    var documents: [UUID: Data] = [:]
    try seed(source.open(), in: &documents)
    let receiver = try follower.open()
    try receiver.setEnabled(true)
    try exchange(receiver, in: &documents)
    let prompt = try #require(receiver.firstChoice)
    #expect(prompt.fields.map(\.field) == [.restEnabled])
    #expect(throws: SyncPreferences.Failure.invalidSelection) {
      try receiver.acceptFirst(prompt, selections: [.restSound: .device(source.id)])
    }
    try receiver.acceptFirst(prompt, selections: [.restEnabled: .device(source.id)])
    try exchange(receiver, in: &documents)
    #expect(follower.settings.restEnabled)
    #expect(follower.settings.restSound == .custom)
    #expect(follower.settings.restWorkMinutes == 32)
    let own = String(decoding: try #require(documents[follower.id]), as: UTF8.self)
    #expect(own.contains("restSound") == false)
    #expect(own.contains("restWorkMinutes") == false)
  }

  @Test func offlineEditSurvivesRestartAndConflictDoesNotBlockOtherFields() throws {
    let left = Peer()
    let right = Peer()
    defer {
      left.clean()
      right.clean()
    }
    var documents: [UUID: Data] = [:]
    let (_, other) = try joined(left, right, documents: &documents)
    left.settings.appearance = .dark
    left.settings.restSound = .rain
    let resumed = try left.open()
    #expect(resumed.isEnabled)

    right.settings.appearance = .light
    right.settings.menuBarLayout = .combined
    try exchange(other, in: &documents)
    let prepared = try resumed.prepare(documents, activitySyncedAt: nil)
    let upload = try #require(prepared)
    #expect(resumed.conflicts.map(\.field) == [.appearance])
    #expect(left.settings.menuBarLayout == .separate)
    documents[left.id] = upload
    try resumed.didPublish(documents)
    #expect(left.settings.appearance == .dark)
    #expect(left.settings.menuBarLayout == .combined)
    try exchange(other, in: &documents)
    #expect(right.settings.restSound == .rain)
  }

  @Test(arguments: [false, true])
  func publishedLocalEditPrecedesPeerEditAfterRestart(editedAgain: Bool) throws {
    let left = Peer()
    let right = Peer()
    defer {
      left.clean()
      right.clean()
    }
    var documents: [UUID: Data] = [:]
    let (writer, reader) = try joined(left, right, documents: &documents)
    left.settings.appearance = .dark
    documents[left.id] = try #require(try writer.prepare(documents, activitySyncedAt: nil))
    writer.discardPrepared()

    try exchange(reader, in: &documents)
    #expect(right.settings.appearance == .dark)
    right.settings.appearance = .light
    try exchange(reader, in: &documents)

    let resumed = try left.open()
    if editedAgain { left.settings.appearance = .system }
    try exchange(resumed, in: &documents)
    #expect(left.settings.appearance == (editedAgain ? .system : .light))
    #expect(resumed.conflicts.map(\.field) == (editedAgain ? [.appearance] : []))
  }

  @Test func resolutionExpiresOnNewerVersionBeforeAndDuringPublication() throws {
    let left = Peer()
    let right = Peer()
    defer {
      left.clean()
      right.clean()
    }
    var documents: [UUID: Data] = [:]
    let (sync, other) = try joined(left, right, documents: &documents)
    left.settings.appearance = .dark
    right.settings.appearance = .light
    try exchange(other, in: &documents)
    try exchange(sync, in: &documents)
    let previous = try #require(sync.conflicts.first)
    try sync.resolve(previous, using: .local)

    right.settings.appearance = .system
    try exchange(other, in: &documents)
    try exchange(sync, in: &documents)
    let current = try #require(sync.conflicts.first)
    #expect(current.id != previous.id)
    #expect(current.remoteValues.contains { $0.deviceID == right.id && $0.value == "system" })
    #expect(throws: SyncPreferences.Failure.staleChoice) {
      try sync.resolve(previous, using: .local)
    }

    try sync.resolve(current, using: .device(right.id))
    let prepared = try sync.prepare(documents, activitySyncedAt: nil)
    let upload = try #require(prepared)
    right.settings.appearance = .light
    try exchange(other, in: &documents)
    documents[left.id] = upload
    try sync.didPublish(documents)
    #expect(left.settings.appearance == .dark)
    let refreshed = try #require(sync.conflicts.first)
    #expect(refreshed.remoteValues.contains { $0.deviceID == right.id && $0.value == "light" })
    try sync.resolve(refreshed, using: .device(right.id))
    try exchange(sync, in: &documents)
    #expect(left.settings.appearance == .light)
    #expect(sync.conflicts.isEmpty)
  }

  @Test func editReturningToBaselineStillConflictsWithConcurrentRemoteEdit() throws {
    let left = Peer()
    let right = Peer()
    defer {
      left.clean()
      right.clean()
    }
    var documents: [UUID: Data] = [:]
    let (sync, other) = try joined(left, right, documents: &documents)
    var requests = 0
    sync.onNeedsSync = { requests += 1 }
    left.settings.appearance = .dark
    left.settings.appearance = .system
    #expect(requests == 0)
    right.settings.appearance = .light
    try exchange(other, in: &documents)
    let reopened = try left.open()
    try exchange(reopened, in: &documents)
    let conflict = try #require(reopened.conflicts.first)
    #expect(conflict.localValue == "system")
    #expect(conflict.remoteValues.contains { $0.deviceID == right.id && $0.value == "light" })
    #expect(left.settings.appearance == .system)
  }

  @Test func matchingNewDeviceDoesNotCompeteWithAConcurrentEdit() throws {
    let source = Peer()
    let follower = Peer()
    defer {
      source.clean()
      follower.clean()
    }
    source.settings.appearance = .light
    follower.settings.appearance = .light
    var documents: [UUID: Data] = [:]
    let publisher = try source.open()
    try seed(publisher, in: &documents)
    var beforeEdit = documents
    let receiver = try follower.open()
    try seed(receiver, in: &beforeEdit)
    source.settings.appearance = .dark
    try exchange(publisher, in: &documents)
    documents[follower.id] = beforeEdit[follower.id]
    try exchange(receiver, in: &documents)
    #expect(receiver.conflicts.isEmpty)
    #expect(follower.settings.appearance == .dark)
  }

  @Test(arguments: [false, true])
  func cancelledRemoteImportStillRequiresChoiceAfterRestart(writeArrived: Bool) throws {
    let left = Peer()
    let right = Peer()
    defer {
      left.clean()
      right.clean()
    }
    var documents: [UUID: Data] = [:]
    let (receiver, publisher) = try joined(left, right, documents: &documents)
    right.settings.appearance = .dark
    try exchange(publisher, in: &documents)
    let prepared = try receiver.prepare(documents, activitySyncedAt: nil)
    let upload = try #require(prepared)
    try receiver.cancel()
    if writeArrived { documents[left.id] = upload }
    let resumed = try left.open()
    try exchange(resumed, in: &documents)
    #expect(left.settings.appearance == .system)
    let choice = try #require(resumed.conflicts.first)
    #expect(choice.field == .appearance)
    try resumed.resolve(choice, using: .device(right.id))
    try exchange(resumed, in: &documents)
    #expect(left.settings.appearance == .dark)
    #expect(resumed.conflicts.isEmpty)
  }

  @Test func revisedChoiceAfterTransportFailureSupersedesPendingUpload() throws {
    let left = Peer()
    let right = Peer()
    defer {
      left.clean()
      right.clean()
    }
    var documents: [UUID: Data] = [:]
    let (receiver, publisher) = try joined(left, right, documents: &documents)
    left.settings.appearance = .light
    right.settings.appearance = .dark
    try exchange(publisher, in: &documents)
    try exchange(receiver, in: &documents)
    let choice = try #require(receiver.conflicts.first)
    try receiver.resolve(choice, using: .device(right.id))
    let failedUpload = try receiver.prepare(documents, activitySyncedAt: nil)
    #expect(failedUpload != nil)
    receiver.discardPrepared()
    try receiver.resolve(choice, using: .local)
    try exchange(receiver, in: &documents)
    #expect(left.settings.appearance == .light)
    try exchange(publisher, in: &documents)
    #expect(right.settings.appearance == .light)
  }

  @Test func assigningSameLocalValueDoesNotCreateAConflict() throws {
    let left = Peer()
    let right = Peer()
    defer {
      left.clean()
      right.clean()
    }
    var documents: [UUID: Data] = [:]
    let (sync, other) = try joined(left, right, documents: &documents)
    left.settings.appearance = .system
    right.settings.appearance = .light
    try exchange(other, in: &documents)
    try exchange(sync, in: &documents)
    #expect(sync.conflicts.isEmpty)
    #expect(left.settings.appearance == .light)
  }

  @Test func interruptedUploadRecoversOnlyFromExactReadback() throws {
    let source = Peer()
    let follower = Peer()
    defer {
      source.clean()
      follower.clean()
    }
    source.settings.appearance = .dark
    follower.settings.appearance = .light
    var documents: [UUID: Data] = [:]
    try seed(source.open(), in: &documents)
    let receiver = try follower.open()
    try receiver.setEnabled(true)
    try exchange(receiver, in: &documents)
    try receiver.acceptFirst(
      #require(receiver.firstChoice), selections: [.appearance: .device(source.id)])
    let prepared = try receiver.prepare(documents, activitySyncedAt: nil)
    let upload = try #require(prepared)
    receiver.discardPrepared()
    #expect(follower.settings.appearance == .light)
    let resumed = try follower.open()
    #expect(resumed.lastSettingsSyncAt == nil)
    documents[follower.id] = upload
    try exchange(resumed, in: &documents)
    #expect(follower.settings.appearance == .dark)
    #expect(resumed.firstChoice == nil)
    #expect(resumed.lastSettingsSyncAt != nil)
  }

  @Test func firstConfirmationRetriesAfterRestartWithNewerActivityReceipt() throws {
    let source = Peer()
    let follower = Peer()
    defer {
      source.clean()
      follower.clean()
    }
    source.settings.appearance = .dark
    follower.settings.appearance = .light
    var documents: [UUID: Data] = [:]
    try seed(source.open(), in: &documents)
    let receiver = try follower.open()
    try receiver.setEnabled(true)
    try exchange(receiver, in: &documents)
    let first = try #require(receiver.firstChoice)
    try receiver.acceptFirst(first, selections: [.appearance: .device(source.id)])
    let activity = Date(timeIntervalSince1970: 1_750_000_000)
    let upload = try #require(try receiver.prepare(documents, activitySyncedAt: activity))
    receiver.discardPrepared()

    let resumed = try follower.open()
    let nextActivity = activity.addingTimeInterval(600)
    let retry = try resumed.prepare(documents, activitySyncedAt: nextActivity)
    #expect(retry == upload)
    #expect(follower.settings.appearance == .light)
    let retriedBytes = try #require(retry)
    documents[follower.id] = retriedBytes
    try resumed.didPublish(documents)
    #expect(follower.settings.appearance == .dark)
    #expect(resumed.firstChoice == nil)

    try exchange(resumed, in: &documents, activityTime: nextActivity)
    #expect(
      resumed.devices.first { $0.id == follower.id }?.lastActivitySyncAt == nextActivity)
  }

  @Test func localEditDuringFirstPublicationInvalidatesTheConfirmation() throws {
    let source = Peer()
    let follower = Peer()
    defer {
      source.clean()
      follower.clean()
    }
    source.settings.appearance = .dark
    follower.settings.appearance = .light
    var documents: [UUID: Data] = [:]
    try seed(source.open(), in: &documents)
    let receiver = try follower.open()
    try receiver.setEnabled(true)
    try exchange(receiver, in: &documents)
    let first = try #require(receiver.firstChoice)
    try receiver.acceptFirst(first, selections: [.appearance: .device(source.id)])
    let prepared = try receiver.prepare(documents, activitySyncedAt: nil)
    let upload = try #require(prepared)

    follower.settings.appearance = .system
    documents[follower.id] = upload
    try receiver.didPublish(documents)
    #expect(follower.settings.appearance == .system)
    #expect(receiver.lastSettingsSyncAt == nil)
    let refreshed = try #require(receiver.firstChoice)
    #expect(refreshed.id != first.id)
    #expect(refreshed.fields.first?.localValue == "system")
  }

  @Test(arguments: [false, true])
  func cancelledFirstPublicationRequiresAnotherChoiceEvenIfWriteArrives(keepLocal: Bool) throws {
    let source = Peer()
    let follower = Peer()
    defer {
      source.clean()
      follower.clean()
    }
    source.settings.appearance = .dark
    follower.settings.appearance = .light
    var documents: [UUID: Data] = [:]
    try seed(source.open(), in: &documents)
    let receiver = try follower.open()
    try receiver.setEnabled(true)
    try exchange(receiver, in: &documents)
    let prompt = try #require(receiver.firstChoice)
    try receiver.acceptFirst(
      prompt, selections: [.appearance: keepLocal ? .local : .device(source.id)])
    let prepared = try receiver.prepare(documents, activitySyncedAt: nil)
    let upload = try #require(prepared)
    try receiver.cancelFirst()
    documents[follower.id] = upload
    #expect(throws: SyncPreferences.Failure.unverifiedPublication) {
      try receiver.didPublish(documents)
    }
    let resumed = try follower.open()
    #expect(resumed.wantsSync == false)
    try resumed.setEnabled(true)
    try exchange(resumed, in: &documents)
    #expect(follower.settings.appearance == .light)
    #expect(resumed.lastSettingsSyncAt == nil)
    let refreshed = try #require(resumed.firstChoice)
    let choice = try #require(refreshed.fields.first { $0.field == .appearance })
    #expect(choice.remoteValues.contains { $0.deviceID == source.id && $0.value == "dark" })
    try resumed.acceptFirst(refreshed, selections: [.appearance: .device(source.id)])
    try exchange(resumed, in: &documents)
    #expect(follower.settings.appearance == .dark)
    #expect(resumed.firstChoice == nil)
  }

  @Test func destinationsAreIsolatedAndPersistedStateIsAuthenticated() throws {
    let peer = Peer(name: "仅密文设备名")
    defer { peer.clean() }
    var documents: [UUID: Data] = [:]
    let sync = try peer.open()
    try seed(sync, in: &documents)
    let time = try #require(sync.lastSettingsSyncAt)
    let storage = try #require(
      peer.defaults.persistentDomain(forName: peer.suite)?.first {
        $0.key.hasPrefix("syncPreferences.") && $0.value is Data
      }?.value as? Data)
    #expect(String(decoding: storage, as: UTF8.self).contains("仅密文设备名") == false)

    let prepared = try sync.prepare(documents, activitySyncedAt: nil)
    let outgoing = try #require(prepared)
    try sync.selectDestination("第二个目标", key: peer.key)
    #expect(sync.isEnabled == false)
    #expect(sync.devices.isEmpty)
    #expect(sync.lastSettingsSyncAt == nil)
    documents[peer.id] = outgoing
    #expect(throws: SyncPreferences.Failure.unverifiedPublication) {
      try sync.didPublish(documents)
    }
    #expect(throws: SyncPreferences.Failure.invalidLocalState) {
      try sync.selectDestination(Peer.destination, key: SymmetricKey(size: .bits256))
    }
    #expect(sync.isEnabled == false)
    try sync.selectDestination(Peer.destination, key: peer.key)
    #expect(sync.isEnabled)
    #expect(sync.lastSettingsSyncAt == time)
    #expect(sync.devices.map(\.name) == ["仅密文设备名"])
  }

  @Test func emptyOrMatchingDestinationInitializesWithoutAChoice() throws {
    let source = Peer()
    let follower = Peer()
    defer {
      source.clean()
      follower.clean()
    }
    var documents: [UUID: Data] = [:]
    let sync = try source.open()
    try seed(sync, in: &documents)
    let second = try follower.open()
    try seed(second, in: &documents)
    #expect(second.devices.count == 2)
  }

  @Test func intentCanStartSchedulingBeforeTheLocalKeyIsLoaded() throws {
    let peer = Peer()
    defer { peer.clean() }
    let sync = SyncPreferences(
      settings: peer.settings, deviceID: peer.id, deviceName: nil,
      defaults: peer.defaults)
    #expect(
      SyncPreferences.hasSavedState(Peer.destination, deviceID: peer.id, defaults: peer.defaults)
        == false)
    sync.selectDestination(Peer.destination)
    try sync.setEnabled(true)
    #expect(sync.wantsSync)
    #expect(
      SyncPreferences.hasSavedState(Peer.destination, deviceID: peer.id, defaults: peer.defaults))
    let reopened = SyncPreferences(
      settings: peer.settings, deviceID: peer.id, deviceName: nil,
      defaults: peer.defaults)
    reopened.selectDestination(Peer.destination)
    #expect(reopened.wantsSync)
    #expect(throws: SyncPreferences.Failure.noDestination) {
      try reopened.prepare([:], activitySyncedAt: nil)
    }
    try reopened.unlockDestination(key: peer.key)
    var documents: [UUID: Data] = [:]
    try exchange(reopened, in: &documents)
    #expect(reopened.lastSettingsSyncAt != nil)
  }

  @Test func returningToDestinationDoesNotUploadSettingsChangedInAnotherDestination() throws {
    let peer = Peer()
    defer { peer.clean() }
    let sync = try peer.open()
    peer.settings.appearance = .light
    var original: [UUID: Data] = [:]
    try seed(sync, in: &original)
    try sync.selectDestination("alternate", key: peer.key)
    peer.settings.appearance = .dark
    var alternate: [UUID: Data] = [:]
    try seed(sync, in: &alternate)
    try sync.selectDestination(Peer.destination, key: peer.key)
    try exchange(sync, in: &original)
    let conflict = try #require(sync.conflicts.first)
    #expect(conflict.field == .appearance)
    #expect(conflict.localValue == "dark")
    #expect(conflict.remoteValues.first?.value == "light")
    #expect(peer.settings.appearance == .dark)
  }

  @Test func unexpectedOwnSlotReplacementDoesNotPublishToAnUnknownTarget() throws {
    let peer = Peer()
    defer { peer.clean() }
    var documents: [UUID: Data] = [:]
    let sync = try peer.open()
    try seed(sync, in: &documents)
    let bytes = try #require(documents[peer.id])
    let decoded = try JSONSerialization.jsonObject(with: bytes)
    var document = try #require(decoded as? [String: Any])
    document["publication"] = UUID().uuidString
    let replacement = try JSONSerialization.data(withJSONObject: document)
    #expect(throws: SyncPreferences.Failure.incompleteSnapshot) {
      try sync.prepare([peer.id: replacement], activitySyncedAt: nil)
    }
    #expect(throws: SyncPreferences.Failure.incompleteSnapshot) {
      try sync.prepare([:], activitySyncedAt: nil)
    }
  }

  @Test func malformedSnapshotDoesNotApplySettingsOrAdvanceMetadata() throws {
    let peer = Peer()
    defer { peer.clean() }
    var documents: [UUID: Data] = [:]
    let sync = try peer.open()
    try seed(sync, in: &documents)
    let before = sync.devices
    let time = sync.lastSettingsSyncAt
    documents[UUID()] = Data("{}".utf8)
    #expect(throws: SyncPreferences.Failure.invalidDocument) {
      try sync.prepare(documents, activitySyncedAt: Date())
    }
    #expect(sync.devices == before)
    #expect(sync.lastSettingsSyncAt == time)
    #expect(sync.conflicts.isEmpty)
  }

  @Test func unchangedRoundAdvancesOnlyOnVerifiedReadbackAndDoesNotScheduleItself() throws {
    let peer = Peer()
    defer { peer.clean() }
    let sync = try peer.open()
    var documents: [UUID: Data] = [:]
    try seed(sync, in: &documents)
    let previous = try #require(sync.lastSettingsSyncAt)
    let scheduled = previous.addingTimeInterval(600)
    var requests = 0
    sync.onNeedsSync = { requests += 1 }
    let prepared = try sync.prepare(documents, activitySyncedAt: nil, now: scheduled)
    let bytes = try #require(prepared)
    #expect(throws: SyncPreferences.Failure.unverifiedPublication) {
      try sync.didPublish(documents)
    }
    #expect(sync.lastSettingsSyncAt == previous)
    sync.discardPrepared()
    let retry = try sync.prepare(
      documents, activitySyncedAt: nil, now: scheduled.addingTimeInterval(5))
    #expect(retry == bytes)
    documents[peer.id] = bytes
    try sync.didPublish(documents)
    #expect(sync.lastSettingsSyncAt == scheduled)
    #expect(sync.devices.first?.lastSettingsSyncAt == previous)
    #expect(requests == 0)

    try sync.setEnabled(false)
    try exchange(sync, in: &documents, activityTime: scheduled.addingTimeInterval(60))
    #expect(sync.lastSettingsSyncAt == scheduled)
    #expect(sync.devices.first?.lastSettingsSyncAt == scheduled)
  }

  @Test func reenableRecomparesEditsMadeWhileDisabled() throws {
    let left = Peer()
    let right = Peer()
    defer {
      left.clean()
      right.clean()
    }
    var documents: [UUID: Data] = [:]
    let (sync, other) = try joined(left, right, documents: &documents)
    try sync.setEnabled(false)
    left.settings.restSound = .rain
    right.settings.appearance = .dark
    try exchange(other, in: &documents)
    let resumed = try left.open()
    try resumed.setEnabled(true)
    try exchange(resumed, in: &documents)
    let first = try #require(resumed.firstChoice)
    #expect(Set(first.fields.map(\.field)) == [.appearance, .restSound])
    #expect(left.settings.appearance == .system)
    #expect(left.settings.restSound == .rain)
    try resumed.acceptFirst(first, selections: [.appearance: .device(right.id)])
    try exchange(resumed, in: &documents)
    #expect(left.settings.appearance == .dark)
    #expect(left.settings.restSound == .rain)
  }

  @Test func reinstallWithSameUUIDRecoversSlotHistoryAndRequiresChoice() throws {
    let original = Peer(name: "工作 Mac")
    let restored = Peer(id: original.id)
    defer {
      original.clean()
      restored.clean()
    }
    var documents: [UUID: Data] = [:]
    original.settings.appearance = .light
    restored.settings.appearance = .dark
    let publisher = try original.open()
    try seed(publisher, in: &documents)
    let reportedTime = try #require(publisher.lastSettingsSyncAt)
    try exchange(publisher, in: &documents)
    let sync = try restored.open()
    try sync.setEnabled(true)
    let prepared = try sync.prepare(documents, activitySyncedAt: nil)
    #expect(prepared == nil)
    #expect(sync.lastSettingsSyncAt == reportedTime)
    #expect(sync.devices.first?.name == "工作 Mac")
    let first = try #require(sync.firstChoice)
    #expect(first.fields.first?.remoteValues.first?.id == original.id)
    try sync.acceptFirst(first, selections: [.appearance: .device(original.id)])
    try exchange(sync, in: &documents)
    #expect(restored.settings.appearance == .light)
    #expect(sync.devices.first?.name == "工作 Mac")
  }

  @Test func openingSettingsDoesNotReplayJournalUntilAuthorizedAndAuthenticatedPrepare() throws {
    let source = Peer()
    let follower = Peer(recordJournal: true)
    defer {
      source.clean()
      follower.clean()
    }
    source.settings.appearance = .dark
    follower.settings.appearance = .light
    var documents: [UUID: Data] = [:]
    try seed(source.open(), in: &documents)
    let sync = try follower.open()
    try sync.setEnabled(true)
    try exchange(sync, in: &documents)
    try sync.acceptFirst(#require(sync.firstChoice), selections: [.appearance: .device(source.id)])
    try exchange(sync, in: &documents)
    // 重现已持久化回读结果、尚未写入 AppSettings 时进程退出的状态。
    let journal = try #require(follower.defaults.data(forKey: JournalDefaults.previous))
    let storage = try #require(follower.defaults.string(forKey: JournalDefaults.storage))
    follower.settings.syncPreferences = nil
    follower.settings.appearance = .light
    follower.defaults.set(journal, forKey: storage)
    let reopened = try follower.open()
    #expect(follower.settings.appearance == .light)
    #expect(throws: SyncPreferences.Failure.incompleteSnapshot) {
      try reopened.prepare([:], activitySyncedAt: nil)
    }
    #expect(follower.settings.appearance == .light)
    _ = try reopened.prepare(documents, activitySyncedAt: nil)
    #expect(follower.settings.appearance == .dark)

    follower.settings.syncPreferences = nil
    follower.settings.appearance = .light
    follower.defaults.set(journal, forKey: storage)
    let disabled = try follower.open()
    try disabled.setEnabled(false)
    try exchange(disabled, in: &documents, activityTime: Date())
    #expect(follower.settings.appearance == .light)
  }

  private func seed(_ sync: SyncPreferences, in documents: inout [UUID: Data]) throws {
    try sync.setEnabled(true)
    try exchange(sync, in: &documents)
    #expect(sync.firstChoice == nil)
    #expect(sync.lastSettingsSyncAt != nil)
  }

  private func exchange(
    _ sync: SyncPreferences, in documents: inout [UUID: Data], activityTime: Date? = nil
  ) throws {
    if let upload = try sync.prepare(documents, activitySyncedAt: activityTime) {
      documents[sync.deviceID] = upload
      try sync.didPublish(documents)
    }
  }

  private func joined(
    _ left: Peer, _ right: Peer, documents: inout [UUID: Data]
  ) throws -> (SyncPreferences, SyncPreferences) {
    left.settings.appearance = .system
    left.settings.menuBarLayout = .separate
    right.settings.appearance = left.settings.appearance
    right.settings.menuBarLayout = left.settings.menuBarLayout
    right.settings.restEnabled = left.settings.restEnabled
    right.settings.restSound = left.settings.restSound
    let first = try left.open()
    try seed(first, in: &documents)
    let second = try right.open()
    try seed(second, in: &documents)
    try exchange(first, in: &documents)
    try exchange(second, in: &documents)
    return (first, second)
  }
}

@MainActor
private struct Peer {
  static let destination = "sync-preferences-tests"
  let id: UUID
  let suite = "SyncPreferencesTests.\(UUID().uuidString)"
  let key = SymmetricKey(size: .bits256)
  let name: String?
  let defaults: UserDefaults
  let settings: AppSettings

  init(name: String? = nil, id: UUID = UUID(), recordJournal: Bool = false) {
    self.id = id
    self.name = name
    let defaults =
      recordJournal ? JournalDefaults(suiteName: suite)! : UserDefaults(suiteName: suite)!
    self.defaults = defaults
    settings = AppSettings(defaults: defaults)
  }

  func open() throws -> SyncPreferences {
    let sync = SyncPreferences(
      settings: settings, deviceID: id, deviceName: name, defaults: defaults)
    try sync.selectDestination(Self.destination, key: key)
    return sync
  }

  func clean() { defaults.removePersistentDomain(forName: suite) }
}

private final class JournalDefaults: UserDefaults {
  static let previous = "test.previousJournal"
  static let storage = "test.journalKey"

  override func set(_ value: Any?, forKey defaultName: String) {
    if defaultName.hasPrefix("syncPreferences."), value is Data {
      super.set(data(forKey: defaultName), forKey: Self.previous)
      super.set(defaultName, forKey: Self.storage)
    }
    super.set(value, forKey: defaultName)
  }
}
