// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import OSLog

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
  static let launcherIDPrefix = "application.clone."
  let id: UUID
  let number: UInt64
  let application: CloneApplication
  let name: String

  var bundleID: String { "\(application.rawValue).xstatsclone.\(number)" }
  var engineName: String { "XStats\(number)" }

  var bundleFilename: String {
    var stem = name.replacingOccurrences(of: "/", with: "／")
      .replacingOccurrences(of: ":", with: "：")
    if stem.hasPrefix(".") { stem.replaceSubrange(stem.startIndex...stem.startIndex, with: "．") }
    stem = stem.precomposedStringWithCanonicalMapping
    while stem.utf8.count > 240 { stem.removeLast() }
    return "\(stem.isEmpty ? engineName : stem).app"
  }
}

actor AppCloneStore {
  enum Failure: Error, Equatable {
    case invalidClone, invalidSource, untrustedSource, running, unsupportedExecutable
    case registrationTooLarge
    case commandFailed(String)
  }

  private static let registrationLimit = 4096
  private let logger = Logger(subsystem: "work.12306.xstats.app", category: "AppClones")
  nonisolated let root: URL

  init(root: URL = URL.applicationSupportDirectory.appending(path: "XStats/AppClones")) {
    self.root = root.resolvingSymlinksInPath()
  }

  nonisolated func bundleURL(_ clone: AppClone) -> URL {
    let directory = root.appending(path: clone.id.uuidString)
    let named = directory.appending(path: clone.bundleFilename)
    let legacy = directory.appending(path: "\(clone.engineName).app")
    return Self.hasIdentity(named, clone.bundleID) || !Self.hasIdentity(legacy, clone.bundleID)
      ? named : legacy
  }

  func list() throws -> [AppClone] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
    ).compactMap { directory in
      try Task.checkCancellation()
      let registration = directory.appending(path: "clone.json")
      guard let id = UUID(uuidString: directory.lastPathComponent),
        (try? registration.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
        let handle = try? FileHandle(forReadingFrom: registration)
      else { return nil }
      defer { try? handle.close() }
      guard let data = try? handle.read(upToCount: Self.registrationLimit + 1),
        data.count <= Self.registrationLimit,
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
    let registration = updating ? nil : try JSONEncoder().encode(clone)
    if let registration, registration.count > Self.registrationLimit {
      throw Failure.registrationTooLarge
    }
    guard source.isFileURL,
      clone.application.sourceIdentifiers.contains(where: { Self.hasIdentity(source, $0) }),
      !source.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/")
    else { throw Failure.invalidSource }
    let files = FileManager.default
    // 控制器同一时间只允许一个分身操作，清理时没有其他构建占用这些目录。
    cleanInterruptedBuilds()
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

    let namedBundle = directory.appending(path: clone.bundleFilename)
    let candidate = stage.appending(path: clone.bundleFilename)
    try await AppCloneBuilder.build(
      clone, source: source, candidate: candidate, profile: profile, stage: stage)
    guard Self.hasIdentity(candidate, clone.bundleID) else { throw Failure.invalidClone }
    if updating {
      try await beforeReplacing()
      guard Self.hasIdentity(bundle, clone.bundleID) else { throw Failure.invalidClone }
      if bundle.path != namedBundle.path {
        // 先迁移旧包的名称；后续交换失败时，旧版本仍可通过新路径打开。
        try files.moveItem(at: bundle, to: namedBundle)
      }
      try Self.swap(candidate, namedBundle)
    } else if let registration {
      try files.createDirectory(
        at: profile.appending(path: "Home/Library/Caches"), withIntermediateDirectories: true)
      try files.createDirectory(
        at: profile.appending(path: "Tmp"), withIntermediateDirectories: true)
      try files.moveItem(at: candidate, to: bundle)
      // 最后写入登记文件，确保中断时未完成的目录仍能被识别为残留。
      try registration.write(
        to: directory.appending(path: "clone.json"), options: .atomic)
    }
    installed = true
  }

  private func cleanInterruptedBuilds() {
    let files = FileManager.default
    guard files.fileExists(atPath: root.path) else { return }
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    do {
      for directory in try files.contentsOfDirectory(
        at: root, includingPropertiesForKeys: Array(keys))
      where directory.lastPathComponent.hasPrefix(".stage-")
        || UUID(uuidString: directory.lastPathComponent) != nil
      {
        do {
          let values = try directory.resourceValues(forKeys: keys)
          guard values.isDirectory == true, values.isSymbolicLink == false else { continue }
          do {
            _ = try files.attributesOfItem(atPath: directory.appending(path: "clone.json").path)
            continue
          } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
          {
            try files.removeItem(at: directory)
          }
        } catch {
          logger.error(
            "Interrupted clone build cleanup failed: \(String(describing: error).prefix(512), privacy: .private)"
          )
        }
      }
    } catch {
      logger.error(
        "Clone build directory listing failed: \(String(describing: error).prefix(512), privacy: .private)"
      )
    }
  }

  private static func swap(_ candidate: URL, _ bundle: URL) throws {
    try candidate.withUnsafeFileSystemRepresentation { newPath in
      try bundle.withUnsafeFileSystemRepresentation { oldPath in
        guard let newPath, let oldPath else { throw Failure.invalidClone }
        guard renamex_np(newPath, oldPath, UInt32(RENAME_SWAP)) == 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
      }
    }
  }

  func moveToTrash(_ clone: AppClone) throws {
    let bundle = bundleURL(clone)
    guard Self.hasIdentity(bundle, clone.bundleID) else { throw Failure.invalidClone }
    try FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
  }

  func moveToTrashIncludingData(
    _ clone: AppClone,
    moveToTrash: @Sendable (URL) throws -> Void = {
      try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    }
  ) throws {
    let directory = root.appending(path: clone.id.uuidString)
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    guard let values = try? directory.resourceValues(forKeys: keys),
      values.isDirectory == true, values.isSymbolicLink == false,
      Self.hasIdentity(bundleURL(clone), clone.bundleID)
    else { throw Failure.invalidClone }
    try moveToTrash(directory)
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
