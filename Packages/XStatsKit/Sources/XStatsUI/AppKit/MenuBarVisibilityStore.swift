// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Darwin

/// macOS 27 的应用显示列表格式参考 Tuck 的公开研究；这里只修改已存在的第三方应用开关。
/// 未识别的字段和系统条目原样保留，未知结构明确失败，不能把读取失败当成空配置写回。
struct MenuBarApplicationList {
  private var rows: [Any]
  let states: [String: Bool]

  init(data: Data) throws {
    guard data.count <= 64 * 1024,
      let rows = try PropertyListSerialization.propertyList(from: data, format: nil) as? [Any],
      rows.count.isMultiple(of: 2)
    else { throw MenuBarVisibilityError.invalidFormat }
    var states: [String: Bool] = [:]
    for index in stride(from: 0, to: rows.count, by: 2) {
      guard let key = rows[index] as? [String: Any] else {
        throw MenuBarVisibilityError.invalidFormat
      }
      guard let bundle = key["bundle"] as? [String: Any] else { continue }
      guard let id = bundle["_0"] as? String, !id.isEmpty,
        let value = rows[index + 1] as? [String: Any],
        let allowed = value["isAllowed"] as? NSNumber,
        CFGetTypeID(allowed) == CFBooleanGetTypeID(),
        states.updateValue(allowed.boolValue, forKey: id) == nil
      else { throw MenuBarVisibilityError.invalidFormat }
    }
    self.rows = rows
    self.states = states
  }

  func updating(_ changes: [String: Bool]) throws -> Data {
    guard changes.keys.allSatisfy({ states[$0] != nil }) else {
      throw MenuBarVisibilityError.missingApplication
    }
    var updated = rows
    for index in stride(from: 0, to: updated.count, by: 2) {
      guard let key = updated[index] as? [String: Any],
        let bundle = key["bundle"] as? [String: Any],
        let id = bundle["_0"] as? String, let allowed = changes[id],
        var value = updated[index + 1] as? [String: Any]
      else { continue }
      value["isAllowed"] = allowed
      updated[index + 1] = value
    }
    return try PropertyListSerialization.data(
      fromPropertyList: updated, format: .binary, options: 0)
  }
}

enum MenuBarVisibilityError: Error {
  case accessDenied, invalidFormat, missingApplication, changed, verificationFailed, processFailed
}

/// 所有系统读写和恢复日志都在同一串行队列中完成。退出恢复排在已开始的写入之后；
/// 不占用主线程，不因取消 UI 任务而遗留一半写入，也不启动后台轮询。
struct MenuBarVisibilityStore: Sendable {
  struct Client: Sendable {
    var read: @Sendable () throws -> Data
    var write: @Sendable (Data) throws -> Void
  }

  static let fileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(
      "Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist"
    )
  static let journalURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/XStats/menu-bar-visibility-recovery.json")

  private let client: Client
  private let journal: URL
  private let queue = DispatchQueue(
    label: "work.12306.xstats.menu-bar-visibility", qos: .userInitiated)
  var hasRecoveryRecord: Bool { FileManager.default.fileExists(atPath: journal.path) }

  init(client: Client = .live, journal: URL = Self.journalURL) {
    self.client = client
    self.journal = journal
  }

  func read() async throws -> [String: Bool] {
    try await perform { try MenuBarApplicationList(data: client.read()).states }
  }

  func collapse(_ identifiers: Set<String>, ownBundleID: String) async throws {
    try await perform {
      try restoreJournal()
      guard !identifiers.isEmpty,
        identifiers.allSatisfy({
          !$0.hasPrefix("com.apple.") && $0 != ownBundleID && !$0.hasPrefix(ownBundleID + ".")
        })
      else { throw MenuBarVisibilityError.missingApplication }
      let original = try client.read()
      let list = try MenuBarApplicationList(data: original)
      guard identifiers.allSatisfy({ list.states[$0] != nil }) else {
        throw MenuBarVisibilityError.missingApplication
      }
      // 原本由系统或用户隐藏的应用不属于本次恢复范围。
      let changed = identifiers.filter { list.states[$0] == true }
      guard !changed.isEmpty else { return }
      let changes = Dictionary(uniqueKeysWithValues: changed.map { ($0, false) })
      let updated = try list.updating(changes)
      try FileManager.default.createDirectory(
        at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
      // 先持久化恢复记录，再操作系统；崩溃或写入结果不明时下次启动仍可恢复。
      try JSONEncoder().encode(changed.sorted()).write(to: journal, options: .atomic)
      try write(updated, replacing: original, expecting: changes)
    }
  }

  func restore() async throws {
    try await perform { try restoreJournal() }
  }

  private func restoreJournal() throws {
    guard hasRecoveryRecord else { return }
    let size = try journal.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? .max
    guard size <= 64 * 1024 else { throw MenuBarVisibilityError.invalidFormat }
    let data = try Data(contentsOf: journal)
    guard data.count <= 64 * 1024 else { throw MenuBarVisibilityError.invalidFormat }
    let identifiers = try JSONDecoder().decode([String].self, from: data)
    guard identifiers.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("com.apple.") }) else {
      throw MenuBarVisibilityError.invalidFormat
    }
    let original = try client.read()
    let list = try MenuBarApplicationList(data: original)
    let changes = Dictionary(
      uniqueKeysWithValues: Set(identifiers).compactMap { id in
        list.states[id] == false ? (id, true) : nil
      })
    if !changes.isEmpty {
      try write(list.updating(changes), replacing: original, expecting: changes)
    }
    // 删除已卸载应用的记录；不重新创建系统条目。失败时保留整个日志供重试。
    try FileManager.default.removeItem(at: journal)
  }

  private func write(_ data: Data, replacing original: Data, expecting changes: [String: Bool])
    throws
  {
    guard try client.read() == original else { throw MenuBarVisibilityError.changed }
    try client.write(data)
    let confirmed = try MenuBarApplicationList(data: client.read()).states
    guard changes.allSatisfy({ confirmed[$0.key] == $0.value }) else {
      throw MenuBarVisibilityError.verificationFailed
    }
  }

  private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws
    -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result { try operation() }) }
    }
  }
}

extension MenuBarVisibilityStore.Client {
  static let live = preferences(at: MenuBarVisibilityStore.fileURL)

  static func preferences(at fileURL: URL) -> Self {
    let domain = fileURL.deletingPathExtension().path
    return Self(
      read: {
        let data = try runDefaults(["export", domain, "-"])
        guard
          let root = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any],
          let list = root["trackedApplications"] as? Data
        else { throw MenuBarVisibilityError.accessDenied }
        return list
      },
      write: { data in
        guard data.count <= 64 * 1024 else { throw MenuBarVisibilityError.invalidFormat }
        // 仅写一个键，避免导入整个域覆盖 Control Center 的其他偏好。
        let hex = data.map { String(format: "%02x", $0) }.joined()
        _ = try runDefaults(["write", domain, "trackedApplications", "-data", hex])
      })
  }

  private static func runDefaults(_ arguments: [String]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    try? pipe.fileHandleForWriting.close()
    // 仅终止本次创建的子进程，给退出恢复一个确定的等待上限。
    let deadline = DispatchWorkItem {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: deadline)
    defer {
      deadline.cancel()
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
      try? pipe.fileHandleForReading.close()
    }
    var output = Data()
    while let part = try pipe.fileHandleForReading.read(upToCount: 16 * 1024), !part.isEmpty {
      guard output.count + part.count <= 2 * 1024 * 1024 else {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        throw MenuBarVisibilityError.invalidFormat
      }
      output.append(part)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw MenuBarVisibilityError.processFailed }
    return output
  }
}
