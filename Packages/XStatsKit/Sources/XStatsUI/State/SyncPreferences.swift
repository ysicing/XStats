// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Observation
import OSLog

/// 合并已由上层认证和解密的全量设备文档。调度器串行执行读、写、回读，并丢弃旧目标的结果。
@MainActor
@Observable
public final class SyncPreferences {
  public enum Field: String, CaseIterable, Codable, Hashable, Sendable {
    case appearance, menuBarLayout, restSound, restEnabled

    fileprivate func accepts(_ value: String) -> Bool {
      switch self {
      case .appearance: AppearanceMode(rawValue: value) != nil
      case .menuBarLayout: MenuBarLayout(rawValue: value) != nil
      case .restSound: RestSound(rawValue: value).map { $0 != .custom } ?? false
      case .restEnabled: value == "true" || value == "false"
      }
    }
  }

  public struct Device: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String?
    public let lastActivitySyncAt: Date?
    public let lastSettingsSyncAt: Date?
  }

  public struct RemoteValue: Equatable, Identifiable, Sendable {
    public var id: UUID { deviceID }
    public let deviceID: UUID
    public let value: String
  }

  public struct Choice: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let field: Field
    public var localValue: String? {
      field.accepts(snapshot.local) ? snapshot.local : nil
    }
    public var remoteValues: [RemoteValue] {
      snapshot.heads.map { RemoteValue(deviceID: $0.key, value: $0.value.value) }
        .sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
    }
    fileprivate let snapshot: PreferenceSnapshot
  }

  public struct FirstChoice: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let fields: [Choice]
  }

  public enum Selection: Equatable, Sendable {
    case local
    case device(UUID)
  }

  public enum Failure: Error, Equatable {
    case noDestination, staleChoice, invalidSelection, invalidDocument, incompleteSnapshot
    case unverifiedPublication, invalidLocalState, sequenceExhausted
  }

  public let deviceID: UUID
  public private(set) var devices: [Device] = []
  public private(set) var isEnabled = false
  public private(set) var selectedFields: Set<Field> = []
  public private(set) var lastSettingsSyncAt: Date?
  public private(set) var firstChoice: FirstChoice?
  public private(set) var conflicts: [Choice] = []

  /// 初次选择尚未完成时，仍需要由调度器读取远端。
  public var wantsSync: Bool { isEnabled }
  @ObservationIgnored public var onNeedsSync: (() -> Void)?

  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let deviceName: String?
  private(set) var selectedID: String?
  @ObservationIgnored private var destination: Destination?
  @ObservationIgnored private var state = LocalState()
  @ObservationIgnored private var firstSnapshots: [Field: PreferenceSnapshot]?
  @ObservationIgnored private var firstSelections: [Field: Selection]?
  @ObservationIgnored private var resolutions: [Field: Selection] = [:]
  @ObservationIgnored private var prepared: Data?
  @ObservationIgnored private(set) var applyingRemote = false
  private let logger = Logger(subsystem: "work.12306.xstats", category: "SyncPreferences")

  public init(
    settings: AppSettings, deviceID: UUID, deviceName: String?, defaults: UserDefaults = .standard
  ) {
    self.settings = settings
    self.deviceID = deviceID
    self.deviceName = deviceName
    self.defaults = defaults
    settings.syncPreferences = self
  }

  public static func hasSavedState(
    _ id: String, deviceID: UUID, defaults: UserDefaults
  ) -> Bool {
    let storage = Destination.storageKey(for: id, deviceID: deviceID)
    return defaults.object(forKey: storage) != nil || defaults.bool(forKey: storage + ".enabled")
  }

  /// 选择目标后即可启停调度。设备、基线和待确认交易在本机加密密钥可用时恢复。
  public func selectDestination(_ id: String) {
    guard selectedID != id else { return }
    clearDestination()
    selectedID = id
    install(LocalState(enabled: defaults.bool(forKey: intentKey(id))))
  }

  public func unlockDestination(key: SymmetricKey) throws {
    guard let selectedID else { throw Failure.noDestination }
    try selectDestination(selectedID, key: key)
  }

  /// id 由上层稳定标识存储位置、账户及数据集。key 是本机密钥。
  public func selectDestination(_ id: String, key: SymmetricKey) throws {
    let next = Destination(id: id, deviceID: deviceID, key: key)
    if destination?.storageKey == next.storageKey, destination?.key == next.key { return }
    var restored: LocalState
    if let data = defaults.data(forKey: next.storageKey) {
      do {
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: next.key)
        restored = try JSONDecoder().decode(LocalState.self, from: plaintext)
        guard restored.schema == LocalState().schema else { throw Failure.invalidLocalState }
      } catch {
        logger.error("无法验证设置同步本机状态")
        throw Failure.invalidLocalState
      }
    } else {
      restored = LocalState()
    }
    let saved = restored
    let changedBeforeUnlock = defaults.bool(forKey: intentKey(id) + ".revoked")
    // 已保存的勾选范围以加密状态为准；仅在解锁前显式切换整组时采用调度开关。
    if changedBeforeUnlock || restored.selection == nil {
      restored.enabled = defaults.object(forKey: intentKey(id)) as? Bool ?? restored.enabled
    }
    if changedBeforeUnlock, restored.enabled { restored.selection = Set(Field.allCases) }
    if !restored.enabled || changedBeforeUnlock {
      restored.stopSettingsSync()
    }
    if let parked = restored.parked {
      for (field, value) in parked
      where restored.fields.contains(field) && value != localValue(field) {
        restored.review.insert(field)
      }
      restored.parked = nil
    }
    if restored != saved { try persist(restored, at: next) }
    if selectedID != id { try parkDestination() }
    prepared = nil
    clearChoices()
    selectedID = id
    destination = next
    install(restored)
    defaults.set(restored.enabled, forKey: intentKey(id))
    defaults.removeObject(forKey: intentKey(id) + ".revoked")
  }

  public func clearDestination() {
    do { try parkDestination() } catch {
      logger.error("无法停放设置同步本机状态")
    }
    prepared = nil
    clearChoices()
    selectedID = nil
    destination = nil
    install(LocalState())
  }

  public func setEnabled(_ enabled: Bool) throws {
    guard let selectedID else { throw Failure.noDestination }
    guard enabled != isEnabled else { return }
    if destination != nil {
      try setSelectedFields(enabled ? Set(Field.allCases) : [])
      return
    }
    var next = state
    next.enabled = enabled
    defaults.set(true, forKey: intentKey(selectedID) + ".revoked")
    install(next)
    defaults.set(enabled, forKey: intentKey(selectedID))
    onNeedsSync?()
  }

  public func setSelectedFields(_ fields: Set<Field>) throws {
    guard let selectedID, destination != nil else { throw Failure.noDestination }
    guard fields != selectedFields else { return }
    let removed = selectedFields.subtracting(fields)
    let added = fields.subtracting(selectedFields)
    var next = state
    next.enabled = !fields.isEmpty
    next.selection = fields
    next.joining = state.awaitingConfirmation.intersection(fields).union(added)
    next.initialized = next.joining?.isEmpty == true && next.enabled
    if !removed.isEmpty, var pending = next.pending {
      pending.revokedFields = (pending.revokedFields ?? []).union(removed)
      next.pending = pending
    }
    next.review.subtract(removed)
    for field in removed {
      next.edits[field] = nil
      next.application[field] = nil
    }
    if fields.isEmpty { next.stopSettingsSync() }
    try save(next)
    defaults.set(next.enabled, forKey: intentKey(selectedID))
    prepared = nil
    clearChoices()
    onNeedsSync?()
  }

  public func acceptFirst(_ choice: FirstChoice, selections: [Field: Selection] = [:]) throws {
    guard prepared == nil, choice.id == firstChoice?.id else { throw Failure.staleChoice }
    guard Set(selections.keys).isSubset(of: Set(choice.fields.map(\.field))) else {
      throw Failure.invalidSelection
    }
    for field in choice.fields {
      _ = try selectedValue(selections[field.field] ?? .local, from: field)
    }
    if state.pending != nil {
      var next = state
      next.pending?.cancelled = true
      try save(next)
    }
    firstSelections = selections
    onNeedsSync?()
  }

  public func resolve(_ choice: Choice, using selection: Selection) throws {
    guard prepared == nil, conflicts.contains(where: { $0.id == choice.id }) else {
      throw Failure.staleChoice
    }
    _ = try selectedValue(selection, from: choice)
    if state.pending != nil {
      var next = state
      next.pending?.cancelled = true
      try save(next)
    }
    resolutions[choice.field] = selection
    onNeedsSync?()
  }

  public func cancelFirst() throws {
    try setSelectedFields(selectedFields.subtracting(state.awaitingConfirmation))
  }

  /// 传输失败时撤销内存中的完成权限。下一次全读仍可核实上次写入是否到达。
  public func discardPrepared() { prepared = nil }

  func forgetDevice(_ id: UUID) throws {
    guard id != deviceID else { throw ActivitySyncFailure.cannotRemoveLocalDevice }
    var next = state
    next.devices.removeAll { $0.id == id }
    var affected = Set<Field>()
    var withdrawn = next.withdrawnOwnVersions ?? [:]
    for field in Field.allCases {
      if var previous = next.firstReview?[field], previous.removeValue(forKey: id) != nil {
        next.firstReview?[field] = previous.isEmpty ? nil : previous
        affected.insert(field)
      }
      if let action = next.application[field],
        action.snapshot.heads.values.contains(where: { $0.clock[id] != nil })
      {
        next.application[field] = nil
        affected.insert(field)
        if action.explicit, let own = action.snapshot.heads[deviceID],
          own != next.baseline[field]?.heads[deviceID], own.value != localValue(field)
        {
          withdrawn[field] = own
        }
      }
      if conflicts.contains(where: { $0.field == field && $0.snapshot.heads[id] != nil }) {
        next.review.remove(field)
        affected.insert(field)
      }
    }
    if var pending = next.pending {
      let revoked = Set(
        Field.allCases.filter { field in
          let inputHeads = pending.inputs?[field]?.heads
          let actionHeads = pending.actions[field]?.snapshot.heads
          // 旧队列没有写前快照时，只能用已发布候选的因果时钟识别来源。
          let legacyReference =
            pending.inputs == nil && actionHeads?.values.contains { $0.clock[id] != nil } == true
          return inputHeads?[id] != nil || pending.initial?[field]?.heads[id] != nil
            || actionHeads?[id] != nil || pending.round?.expected[field]?.heads[id] != nil
            || legacyReference
        })
      if !revoked.isEmpty {
        // 保留原始字节用于认证可能已到达的写入，同时撤销受影响字段的确认和应用权限。
        pending.revokedFields = (pending.revokedFields ?? []).union(revoked)
        affected.formUnion(revoked)
        for field in revoked {
          if let action = pending.actions.removeValue(forKey: field), action.explicit,
            let own = action.snapshot.heads[deviceID],
            own != pending.inputs?[field]?.heads[deviceID],
            own != next.baseline[field]?.heads[deviceID],
            own.value != localValue(field)
          {
            withdrawn[field] = own
          }
          pending.inputs?[field] = nil
        }
        next.pending = pending
      }
    }
    if next.firstReview?.isEmpty == true { next.firstReview = nil }
    next.withdrawnOwnVersions = withdrawn.isEmpty ? nil : withdrawn
    try save(next)
    prepared = nil
    if firstSnapshots?.contains(where: { affected.contains($0.key) || $0.value.heads[id] != nil })
      == true
    {
      firstChoice = nil
      firstSnapshots = nil
      firstSelections = nil
    }
    for field in affected { resolutions[field] = nil }
    conflicts.removeAll { affected.contains($0.field) }
  }

  public func cancel() throws {
    if state.pending != nil || !state.application.isEmpty {
      var next = state
      next.pending?.cancelled = true
      reviewUnfinishedActions(in: &next)
      try save(next)
    }
    prepared = nil
    clearChoices()
  }

  private func reviewUnfinishedActions(in next: inout LocalState) {
    if let pending = next.pending {
      for (field, action) in pending.actions
      where next.fields.contains(field) && !next.awaitingConfirmation.contains(field) {
        if action.explicit || action.value != localValue(field) { next.review.insert(field) }
      }
    }
    next.review.formUnion(next.application.keys)
    next.application = [:]
  }

  /// 捕获两次交换之间改回原值的编辑，由现有频率或手动同步调度交换。
  func recordLocalChange(_ field: Field) {
    guard selectedFields.contains(field), !applyingRemote, destination != nil else { return }
    var next = state
    next.edits[field] = UUID()
    do { try save(next) } catch {
      logger.error("无法保存设置本机修改")
    }
  }

  /// 返回需写入本机设备槽位的明文。nil 表示该次全读无需上传。
  public func prepare(
    _ documents: [UUID: Data], activitySyncedAt: Date?, now: Date = Date(),
    minimumStatusInterval: TimeInterval = 0
  ) throws -> Data? {
    guard destination != nil else { throw Failure.noDestination }
    prepared = nil
    let records = try decode(documents)
    let own = records[deviceID]
    if own == nil, state.ownDigest != nil {
      // 缺失的槽位无法证明旧发布已到达，转回复核并沿用基线与序列号重新注册。
      var reset = state
      reset.ownDigest = nil
      reviewUnfinishedActions(in: &reset)
      if let pending = reset.pending {
        var firstReview = reset.firstReview ?? [:]
        for (field, action) in pending.actions
        where action.explicit && reset.awaitingConfirmation.contains(field) {
          // 即使原候选从目录消失，仍须重新确认首次选择。
          if firstReview[field] == nil { firstReview[field] = [:] }
        }
        if !firstReview.isEmpty { reset.firstReview = firstReview }
      }
      reset.pending = nil
      try save(reset)
    }
    if isEnabled { try finishApplication(in: records) }
    if let pending = state.pending, documents[deviceID] == pending.bytes {
      try finishPublication(pending, records: records)
    }
    let statusActivityTime = activitySyncedAt.flatMap { date in
      guard minimumStatusInterval > 0, let previous = own?.device.lastActivitySyncAt,
        date >= previous, date.timeIntervalSince(previous) < minimumStatusInterval
      else { return date }
      return nil
    }
    let snapshots = snapshots(in: records)
    // 偏好输入未变化时保留已确认的写入，活动回执可随下一轮更新。
    if let pending = state.pending, !pending.cancelled, pending.revokedFields == nil,
      pending.inputs == snapshots,
      pending.actions.values.contains(where: \.explicit) || activitySyncedAt == nil
        || (try? JSONDecoder().decode(Document.self, from: pending.bytes))?.device
          .lastActivitySyncAt
          == activitySyncedAt
    {
      prepared = pending.bytes
      return pending.bytes
    }
    var next = state
    next.pending = nil
    next.ownDigest = documents[deviceID].map { Data(SHA256.hash(data: $0)) }
    next.devices = deviceList(records)
    if next.lastSettingsSyncAt == nil { next.lastSettingsSyncAt = own?.device.lastSettingsSyncAt }

    var targets: [Field: String] = [:]
    var writes: Set<Field> = []
    var explicit: Set<Field> = []
    let joining = state.awaitingConfirmation
    var initial: Set<Field> = []
    if !joining.isEmpty {
      updateFirstChoice(snapshots)
      if firstChoice == nil || firstSelections != nil {
        initial = joining
        for field in joining {
          guard let snapshot = snapshots[field], field.accepts(snapshot.local) else { continue }
          let value: String?
          if let choice = firstChoice?.fields.first(where: { $0.field == field }) {
            value = try selectedValue(firstSelections?[field] ?? .local, from: choice)
            explicit.insert(field)
          } else {
            value = snapshot.local
          }
          targets[field] = value
          // 加入者可直接沿用已有的因果版本；重复写同值会与真正的并发编辑产生假冲突。
          if snapshot.heads.isEmpty || snapshot.heads.values.contains(where: { $0.value != value })
          {
            writes.insert(field)
          }
        }
      }
    }
    if isEnabled {
      updateConflicts(snapshots)
      for field in selectedFields.subtracting(joining) {
        guard let snapshot = snapshots[field], field.accepts(snapshot.local) else { continue }
        if let conflict = conflicts.first(where: { $0.field == field }) {
          guard let selection = resolutions[field],
            let value = try selectedValue(selection, from: conflict)
          else { continue }
          targets[field] = value
          writes.insert(field)
          explicit.insert(field)
        } else if locallyChanged(field, snapshot) {
          targets[field] = snapshot.local
          writes.insert(field)
        } else if let value = snapshot.heads.values.first?.value,
          state.baseline[field] != Baseline(value: value, heads: snapshot.heads)
        {
          targets[field] = value
        }
      }
    }

    let metadata = Device(
      id: deviceID, name: deviceName ?? own?.device.name,
      lastActivitySyncAt: statusActivityTime ?? own?.device.lastActivitySyncAt,
      lastSettingsSyncAt: next.lastSettingsSyncAt ?? own?.device.lastSettingsSyncAt)
    // 重新注册时恢复仍有效的本机版本，避免其他设备丢失已确认的设置。
    let ownFields = own?.fields.filter { state.withdrawnOwnVersions?[$0.key] != $0.value }
    let restoredFields = snapshots.filter { !joining.contains($0.key) }.compactMapValues {
      $0.heads[deviceID]
    }
    var outbound = Document(device: metadata, fields: ownFields ?? restoredFields)
    for field in Field.allCases where writes.contains(field) {
      guard let snapshot = snapshots[field], let value = targets[field] else { continue }
      var clock = state.baseline[field]?.clock ?? [:]
      for version in snapshot.heads.values { clock.merge(version.clock, uniquingKeysWith: max) }
      if let previous = own?.fields[field] ?? outbound.fields[field] {
        clock.merge(previous.clock, uniquingKeysWith: max)
      }
      let counter = max(next.sequence, clock[deviceID, default: 0])
      guard counter < UInt64.max else { throw Failure.sequenceExhausted }
      next.sequence = counter + 1
      clock[deviceID] = next.sequence
      outbound.fields[field] = PreferenceVersion(value: value, clock: clock)
    }

    // 设备槽位只宣告上一轮已认证的时间；本轮准备时间随计划持久化，回读成功才生效。
    let completeRound =
      isEnabled && conflicts.allSatisfy { explicit.contains($0.field) }
      && joining == initial
    let statusDue =
      state.lastSettingsSyncAt.map {
        now < $0 || now.timeIntervalSince($0) >= minimumStatusInterval
      } ?? true
    let publishes =
      (completeRound && statusDue) || !initial.isEmpty || !writes.isEmpty || !targets.isEmpty
      || own?.device != metadata || own?.fields != ownFields
    var projected = records
    if publishes { projected[deviceID] = outbound }
    let expected = self.snapshots(in: projected)
    var actions: [Field: Action] = [:]
    for (field, value) in targets {
      guard let snapshot = expected[field] else { continue }
      actions[field] = Action(snapshot: snapshot, value: value, explicit: explicit.contains(field))
    }
    if publishes {
      let bytes = try JSONEncoder().encode(outbound)
      guard bytes.count <= ActivitySyncRemotePath.maximumMetadataBytes - ActivitySyncCipher.overhead
      else { throw Failure.invalidDocument }
      next.pending = Pending(
        bytes: bytes, actions: actions,
        initial: initial.isEmpty ? nil : expected.filter { initial.contains($0.key) },
        inputs: snapshots,
        round: completeRound ? Round(preparedAt: now, expected: expected) : nil)
      try save(next)
      prepared = bytes
      return bytes
    }
    try save(next)
    return nil
  }

  /// 上层完成本机槽位写入后，传入再次全读、认证及解密的结果。
  public func didPublish(_ verifiedDocuments: [UUID: Data]) throws {
    guard let prepared, verifiedDocuments[deviceID] == prepared,
      let pending = state.pending, pending.bytes == prepared
    else { throw Failure.unverifiedPublication }
    let records = try decode(verifiedDocuments)
    try finishPublication(pending, records: records)
    self.prepared = nil
  }

  private func finishPublication(_ pending: Pending, records: [UUID: Document]) throws {
    var next = state
    next.pending = nil
    next.ownDigest = Data(SHA256.hash(data: pending.bytes))
    next.devices = deviceList(records)
    next.withdrawnOwnVersions = next.withdrawnOwnVersions?.filter {
      records[deviceID]?.fields[$0.key] == $0.value
    }
    if next.withdrawnOwnVersions?.isEmpty == true { next.withdrawnOwnVersions = nil }
    let current = snapshots(in: records)
    let revoked = pending.revokedFields ?? []
    let initial = pending.initial?.filter { !revoked.contains($0.key) }
    let joining = initial.map { Set($0.keys) } ?? []
    let mayApply = isEnabled && !pending.cancelled
    let joined =
      mayApply && !joining.isEmpty && initial == current.filter { joining.contains($0.key) }
    var accepted: [Field: Action] = [:]
    for (field, action) in pending.actions
    where selectedFields.contains(field) && !revoked.contains(field) {
      let mayApplyField = mayApply && (!joining.contains(field) || joined)
      if mayApplyField, action.snapshot == current[field] {
        accepted[field] = action
      } else if mayApplyField, !action.explicit, let snapshot = current[field],
        snapshot.local == action.value, snapshot.edit == action.snapshot.edit,
        let published = action.snapshot.heads[deviceID],
        records[deviceID]?.fields[field] == published,
        pending.inputs?[field]?.heads[deviceID] != published,
        snapshot.heads.values.allSatisfy({ $0.clock.covers(published.clock) })
      {
        // 后继版本已经看过本机写入，下一轮应按远端更新处理。
        next.baseline[field] = Baseline(value: action.value, heads: [deviceID: published])
        next.edits[field] = nil
      } else if action.explicit || pending.cancelled {
        next.review.insert(field)
      }
    }
    if let initial = pending.initial, pending.cancelled || !revoked.isEmpty {
      var firstReview = next.firstReview ?? [:]
      for (field, action) in pending.actions
      where action.explicit && initial[field] != nil
        && (pending.cancelled || revoked.contains(field))
      {
        guard let inputs = pending.inputs?[field] else { continue }
        firstReview[field, default: [:]].merge(inputs.heads) { _, version in version }
      }
      if !firstReview.isEmpty { next.firstReview = firstReview }
    }
    if joined {
      next.joining = state.awaitingConfirmation.subtracting(joining)
      next.initialized = next.joining?.isEmpty == true
      for field in joining { next.firstReview?[field] = nil }
    }
    if mayApply, revoked.isEmpty, joining.isEmpty || joined, let round = pending.round,
      round.expected == current
    {
      next.lastSettingsSyncAt = round.preparedAt
    }
    next.application = accepted
    let firstReviewChanged = next.firstReview != state.firstReview
    try save(next)
    if firstReviewChanged { firstSnapshots = nil }
    if mayApply { try finishApplication(in: records) }
    if joined {
      firstChoice = nil
      firstSnapshots = nil
      firstSelections = nil
    }
    if isEnabled {
      updateConflicts(snapshots(in: records))
      updateFirstChoice(snapshots(in: records))
    }
  }

  private func finishApplication(in records: [UUID: Document]) throws {
    guard !state.application.isEmpty else { return }
    applyingRemote = true
    defer { applyingRemote = false }
    var next = state
    let current = snapshots(in: records)
    for field in selectedFields {
      guard let action = state.application[field] else { continue }
      guard current[field]?.heads == action.snapshot.heads,
        state.edits[field] == action.snapshot.edit,
        localValue(field) == action.snapshot.local || localValue(field) == action.value
      else {
        next.review.insert(field)
        continue
      }
      apply(action.value, to: field)
      next.baseline[field] = Baseline(value: action.value, heads: action.snapshot.heads)
      next.edits[field] = nil
      next.review.remove(field)
    }
    next.application = [:]
    try save(next)
  }

  private func updateFirstChoice(_ snapshots: [Field: PreferenceSnapshot]) {
    let joining = state.awaitingConfirmation
    let inputs = snapshots.filter { joining.contains($0.key) }
    guard firstSnapshots != inputs else { return }
    firstSnapshots = inputs
    firstSelections = nil
    let fields = Field.allCases.compactMap { field -> Choice? in
      guard let snapshot = inputs[field], field.accepts(snapshot.local) else { return nil }
      if var previous = state.firstReview?[field] {
        // 已到达的本机版本可能覆盖了用户取消前看到的候选。
        previous.merge(snapshot.heads) { _, version in version }
        if previous[deviceID]?.value == snapshot.local { previous[deviceID] = nil }
        return Choice(
          field: field,
          snapshot: PreferenceSnapshot(local: snapshot.local, edit: snapshot.edit, heads: previous))
      }
      guard snapshot.heads.values.contains(where: { $0.value != snapshot.local }) else {
        return nil
      }
      return Choice(field: field, snapshot: snapshot)
    }
    firstChoice = fields.isEmpty ? nil : FirstChoice(fields: fields)
  }

  private func updateConflicts(_ snapshots: [Field: PreferenceSnapshot]) {
    let previous = conflicts
    let enrolled = selectedFields.subtracting(state.awaitingConfirmation)
    conflicts = Field.allCases.compactMap { field in
      guard enrolled.contains(field), let snapshot = snapshots[field],
        field.accepts(snapshot.local)
      else {
        resolutions[field] = nil
        return nil
      }
      let changed = locallyChanged(field, snapshot)
      let baseline = state.baseline[field]?.clock ?? [:]
      let unseen = snapshot.heads.filter { author, version in
        author != deviceID && !baseline.covers(version.clock)
      }
      let diverged =
        changed
        ? unseen.values.contains { $0.value != snapshot.local }
        : Set(snapshot.heads.values.map(\.value)).count > 1
      guard diverged || state.review.contains(field) else {
        resolutions[field] = nil
        return nil
      }
      if let choice = previous.first(where: { $0.field == field && $0.snapshot == snapshot }) {
        return choice
      }
      resolutions[field] = nil
      return Choice(field: field, snapshot: snapshot)
    }
  }

  private func locallyChanged(_ field: Field, _ snapshot: PreferenceSnapshot) -> Bool {
    snapshot.edit != nil || snapshot.local != state.baseline[field]?.value
  }

  private func selectedValue(_ selection: Selection, from choice: Choice) throws -> String? {
    switch selection {
    case .local:
      return choice.localValue
    case .device(let device):
      guard choice.localValue != nil, let version = choice.snapshot.heads[device] else {
        throw Failure.invalidSelection
      }
      return version.value
    }
  }

  private func snapshots(in records: [UUID: Document]) -> [Field: PreferenceSnapshot] {
    var result: [Field: PreferenceSnapshot] = [:]
    for field in selectedFields {
      // 离线设备若仍有槽位可继续参与合并。已删除的槽位只保留基线中的因果时钟。
      var versions =
        state.baseline[field]?.heads.filter { author, version in
          author == deviceID
            ? state.withdrawnOwnVersions?[field] != version
            : records[author]?.fields[field] != nil
        } ?? [:]
      for (author, document) in records {
        guard let version = document.fields[field] else { continue }
        if author == deviceID, state.withdrawnOwnVersions?[field] == version { continue }
        if let known = versions[author], known.clock.covers(version.clock) { continue }
        versions[author] = version
      }
      // 版本的字段级向量仅覆盖写入者已看到的版本。同值并发的向量继续保留。
      let heads = versions.filter { _, version in
        !versions.values.contains { $0.clock != version.clock && $0.clock.covers(version.clock) }
      }
      result[field] = PreferenceSnapshot(
        local: localValue(field), edit: state.edits[field], heads: heads)
    }
    return result
  }

  private func decode(_ documents: [UUID: Data]) throws -> [UUID: Document] {
    var records: [UUID: Document] = [:]
    for (author, bytes) in documents {
      guard
        bytes.count <= ActivitySyncRemotePath.maximumMetadataBytes - ActivitySyncCipher.overhead,
        let document = try? JSONDecoder().decode(Document.self, from: bytes),
        document.schema == 1, document.device.id == author,
        document.device.name.map({ name in
          !name.isEmpty && name.utf8.count <= 1024
            && name.rangeOfCharacter(from: .controlCharacters) == nil
        }) ?? true,
        document.fields.allSatisfy({ field, version in
          field.accepts(version.value) && version.clock[author, default: 0] > 0
            && version.clock.count <= ActivitySyncRemotePath.maximumMetadataEntries
            && version.clock.values.allSatisfy { $0 > 0 }
        })
      else { throw Failure.invalidDocument }
      records[author] = document
    }
    if let own = documents[deviceID], state.ownDigest != nil || state.pending != nil,
      Data(SHA256.hash(data: own)) != state.ownDigest
    {
      guard own == state.pending?.bytes else {
        throw Failure.incompleteSnapshot
      }
    }
    return records
  }

  private func deviceList(_ records: [UUID: Document]) -> [Device] {
    records.values.map(\.device).sorted { $0.id.uuidString < $1.id.uuidString }
  }

  private func localValue(_ field: Field) -> String {
    switch field {
    case .appearance: settings.appearance.rawValue
    case .menuBarLayout: settings.menuBarLayout.rawValue
    case .restSound: settings.restSound.rawValue
    case .restEnabled: String(settings.restEnabled)
    }
  }

  private func apply(_ value: String, to field: Field) {
    guard value != localValue(field) else { return }
    switch field {
    case .appearance:
      if let mode = AppearanceMode(rawValue: value) { settings.appearance = mode }
    case .menuBarLayout:
      if let layout = MenuBarLayout(rawValue: value) { settings.menuBarLayout = layout }
    case .restSound:
      if let sound = RestSound(rawValue: value), sound != .custom { settings.restSound = sound }
    case .restEnabled:
      settings.restEnabled = value == "true"
    }
  }

  private func clearChoices() {
    firstChoice = nil
    firstSnapshots = nil
    firstSelections = nil
    conflicts = []
    resolutions = [:]
  }

  private func intentKey(_ id: String) -> String {
    Destination.storageKey(for: id, deviceID: deviceID) + ".enabled"
  }

  private func parkDestination() throws {
    guard destination != nil else { return }
    var next = state
    let enrolled = next.fields.subtracting(next.awaitingConfirmation)
    if !enrolled.isEmpty {
      // AppSettings 是全局的。跨目标期间变化的字段必须复核后才能写回原目标。
      next.parked = Dictionary(
        uniqueKeysWithValues: enrolled.map { ($0, localValue($0)) })
    }
    next.pending?.cancelled = true
    try save(next)
  }

  private func save(_ next: LocalState) throws {
    guard let destination else { throw Failure.noDestination }
    guard next != state else { return }
    try persist(next, at: destination)
    install(next)
  }

  private func persist(_ next: LocalState, at destination: Destination) throws {
    let plaintext = try JSONEncoder().encode(next)
    guard let ciphertext = try AES.GCM.seal(plaintext, using: destination.key).combined
    else { throw Failure.invalidLocalState }
    defaults.set(ciphertext, forKey: destination.storageKey)
  }

  private func install(_ next: LocalState) {
    state = next
    if devices != next.devices { devices = next.devices }
    if isEnabled != next.enabled { isEnabled = next.enabled }
    if selectedFields != next.fields { selectedFields = next.fields }
    if lastSettingsSyncAt != next.lastSettingsSyncAt {
      lastSettingsSyncAt = next.lastSettingsSyncAt
    }
  }

  private struct Destination {
    let storageKey: String
    let key: SymmetricKey

    init(id: String, deviceID: UUID, key: SymmetricKey) {
      let device = Data(deviceID.uuidString.utf8)
      let scope = Data(SHA256.hash(data: Data(id.utf8)))
      storageKey = Self.storageKey(for: id, deviceID: deviceID)
      self.key = HKDF<SHA256>.deriveKey(
        inputKeyMaterial: key, salt: scope, info: Data("XStats.SyncPreferences.v1/".utf8) + device,
        outputByteCount: 32)
    }

    static func storageKey(for id: String, deviceID: UUID) -> String {
      let scope = Data(SHA256.hash(data: Data(id.utf8))).base64EncodedString()
      return "syncPreferences.\(deviceID.uuidString).\(scope)"
    }
  }

  private struct Document: Codable {
    var schema = 1
    var publication = UUID()
    let device: Device
    var fields: [Field: PreferenceVersion]
  }

  private struct Baseline: Codable, Equatable {
    let value: String
    let heads: [UUID: PreferenceVersion]
    var clock: [UUID: UInt64] {
      heads.values.reduce(into: [:]) { $0.merge($1.clock, uniquingKeysWith: max) }
    }
  }

  private struct Action: Codable, Equatable {
    let snapshot: PreferenceSnapshot
    let value: String
    let explicit: Bool
  }

  private struct Pending: Codable, Equatable {
    let bytes: Data
    var actions: [Field: Action]
    let initial: [Field: PreferenceSnapshot]?
    var inputs: [Field: PreferenceSnapshot]?
    let round: Round?
    var cancelled = false
    var revokedFields: Set<Field>?
  }

  private struct Round: Codable, Equatable {
    let preparedAt: Date
    let expected: [Field: PreferenceSnapshot]
  }

  private struct LocalState: Codable, Equatable {
    var schema = 1
    var enabled = false
    var initialized = false
    var selection: Set<Field>?
    var joining: Set<Field>?
    var sequence: UInt64 = 0
    var baseline: [Field: Baseline] = [:]
    var ownDigest: Data?
    var edits: [Field: UUID] = [:]
    var review: Set<Field> = []
    var firstReview: [Field: [UUID: PreferenceVersion]]?
    var parked: [Field: String]?
    var devices: [Device] = []
    var lastSettingsSyncAt: Date?
    // 写前保留版本号及计划；仅回读命中同一份文档后才转入本机应用。
    var pending: Pending?
    var application: [Field: Action] = [:]
    // 已撤销的选择若写入了本机槽位，回读仍验真，但该版本不能重新成为候选。
    var withdrawnOwnVersions: [Field: PreferenceVersion]?

    var fields: Set<Field> { enabled ? selection ?? Set(Field.allCases) : [] }
    var awaitingConfirmation: Set<Field> { joining ?? (initialized ? [] : fields) }

    mutating func stopSettingsSync() {
      initialized = false
      joining = nil
      pending?.cancelled = true
      application = [:]
      edits = [:]
      review = []
    }
  }
}

private struct PreferenceSnapshot: Codable, Equatable, Sendable {
  let local: String
  let edit: UUID?
  let heads: [UUID: PreferenceVersion]
}

private struct PreferenceVersion: Codable, Equatable, Sendable {
  let value: String
  let clock: [UUID: UInt64]
}

extension Dictionary where Key == UUID, Value == UInt64 {
  fileprivate func covers(_ other: Self) -> Bool {
    other.allSatisfy { self[$0.key, default: 0] >= $0.value }
  }
}
