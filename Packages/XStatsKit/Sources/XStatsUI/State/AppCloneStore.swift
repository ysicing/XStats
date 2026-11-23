// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

enum CloneApplication: String, CaseIterable, Identifiable, Codable, Sendable {
  case weChat = "com.tencent.xinWeChat"
  case qq = "com.tencent.qq"
  case lark = "com.electron.lark"
  case telegram = "ru.keepcoder.Telegram"
  case telegramDesktop = "org.telegram.desktop"
  case weCom = "com.tencent.WeWorkMac"

  var id: String { rawValue }

  var sourceIdentifiers: [String] {
    self == .telegramDesktop ? [rawValue, "com.tdesktop.Telegram"] : [rawValue]
  }
}

struct AppClone: Codable, Identifiable, Equatable, Sendable {
  let id: UUID
  let number: UInt64
  let application: CloneApplication
  let name: String

  var bundleID: String { "\(application.rawValue).xstatsclone.\(number)" }
  var engineName: String { "XStats\(number)" }
}

actor AppCloneStore {
  enum Failure: Error, Equatable {
    case invalidClone, invalidSource, untrustedSource, running, unsupportedExecutable
    case commandFailed(String)
  }

  nonisolated let root: URL

  init(root: URL = URL.applicationSupportDirectory.appending(path: "XStats/AppClones")) {
    self.root = root.resolvingSymlinksInPath()
  }

  nonisolated func bundleURL(_ clone: AppClone) -> URL {
    root.appending(path: clone.id.uuidString).appending(path: "\(clone.engineName).app")
  }

  func list() throws -> [AppClone] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
    ).compactMap { directory in
      guard let id = UUID(uuidString: directory.lastPathComponent),
        let data = try? Data(contentsOf: directory.appending(path: "clone.json")),
        data.count <= 4096,
        let clone = try? JSONDecoder().decode(AppClone.self, from: data), clone.id == id,
        Self.hasIdentity(bundleURL(clone), clone.bundleID)
      else { return nil }
      return clone
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func build(
    _ clone: AppClone, source: URL, updating: Bool,
    beforeReplacing: @Sendable () async throws -> Void = {}
  ) async throws {
    guard source.isFileURL,
      clone.application.sourceIdentifiers.contains(where: { Self.hasIdentity(source, $0) }),
      !source.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    else { throw Failure.invalidSource }
    let files = FileManager.default
    let directory = root.appending(path: clone.id.uuidString)
    let bundle = bundleURL(clone)
    let stage = root.appending(path: ".stage-\(UUID().uuidString)")
    if updating {
      guard Self.hasIdentity(bundle, clone.bundleID) else { throw Failure.invalidClone }
    }
    try files.createDirectory(
      at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: stage) }
    let profile = directory.appending(path: "Data")
    if !updating {
      try files.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    var installed = false
    defer {
      if !updating && !installed { try? files.removeItem(at: directory) }
    }

    let candidate = stage.appending(path: bundle.lastPathComponent)
    try await AppCloneBuilder.build(
      clone, source: source, candidate: candidate, profile: profile, stage: stage)
    guard Self.hasIdentity(candidate, clone.bundleID) else { throw Failure.invalidClone }
    if updating {
      try await beforeReplacing()
      guard Self.hasIdentity(bundle, clone.bundleID) else { throw Failure.invalidClone }
      let result = candidate.withUnsafeFileSystemRepresentation { newPath in
        bundle.withUnsafeFileSystemRepresentation { oldPath in
          guard let newPath, let oldPath else { return false }
          return renamex_np(newPath, oldPath, UInt32(RENAME_SWAP)) == 0
        }
      }
      guard result else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } else {
      try files.createDirectory(
        at: profile.appending(path: "Home/Library/Caches"), withIntermediateDirectories: true)
      try files.createDirectory(
        at: profile.appending(path: "Tmp"), withIntermediateDirectories: true)
      try JSONEncoder().encode(clone).write(
        to: directory.appending(path: "clone.json"), options: .atomic)
      try files.moveItem(at: candidate, to: bundle)
    }
    installed = true
  }

  func moveToTrash(_ clone: AppClone) throws {
    let bundle = bundleURL(clone)
    guard Self.hasIdentity(bundle, clone.bundleID) else { throw Failure.invalidClone }
    try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
  }

  nonisolated static func hasIdentity(_ url: URL, _ bundleID: String) -> Bool {
    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
      return false
    }
    let plist = url.appending(path: "Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
      let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return false }
    return values["CFBundleIdentifier"] as? String == bundleID
  }

  static func run(_ executable: String, _ arguments: [String], stage: URL) async throws {
    let output = stage.appending(path: UUID().uuidString)
    try Data().write(to: output)
    let file = try FileHandle(forUpdating: output)
    defer {
      try? file.close()
      try? FileManager.default.removeItem(at: output)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = [
      "HOME": stage.path, "TMPDIR": stage.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
    ]
    process.currentDirectoryURL = stage
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = file
    process.standardError = file
    let status: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    guard status == 0 else {
      try file.seek(toOffset: 0)
      let detail = String(decoding: try file.read(upToCount: 512) ?? Data(), as: UTF8.self)
      throw Failure.commandFailed("\(executable): \(status): \(detail)")
    }
  }
}
