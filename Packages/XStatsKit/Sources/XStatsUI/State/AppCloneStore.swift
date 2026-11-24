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
  case chrome = "com.google.Chrome"
  case edge = "com.microsoft.edgemac"
  case brave = "com.brave.Browser"
  case arc = "company.thebrowser.Browser"
  case firefox = "org.mozilla.firefox"
  case torBrowser = "org.torproject.torbrowser"
  case visualStudioCode = "com.microsoft.VSCode"
  case cursor = "com.todesktop.230313mzl4w4u92"
  case zed = "dev.zed.Zed"
  case claude = "com.anthropic.claudefordesktop"
  case codex = "com.openai.codex"
  case chatGPT = "com.openai.chat"
  case workBuddy = "com.tencent.workbuddy.mac"
  case workBuddyAI = "com.workbuddy.workbuddy-ai"
  case gemini = "com.google.GeminiMacOS"
  case antigravity = "com.google.antigravity"
  case antigravityIDE = "com.google.antigravity-ide"
  case bilibili = "com.bilibili.bilibiliPC"
  case douyin = "com.bytedance.douyin.desktop"
  case neteaseMusic = "com.netease.163music"
  case steam = "com.valvesoftware.steam"

  var id: String { rawValue }

  var sourceIdentifiers: [String] {
    self == .telegramDesktop ? [rawValue, "com.tdesktop.Telegram"] : [rawValue]
  }

  var usesChromiumProxyArgument: Bool {
    switch self {
    case .chrome, .edge, .brave, .arc: true
    default: false
    }
  }

  func profileLaunchArguments(profile: URL) -> [String]? {
    switch self {
    case .brave: ["--user-data-dir=\(profile.path)"]
    case .firefox, .torBrowser: ["-profile", profile.path]
    case .visualStudioCode, .cursor:
      [
        "--user-data-dir", profile.appending(path: "UserData").path,
        "--extensions-dir", profile.appending(path: "Extensions").path,
        "--new-window",
      ]
    case .zed: ["--user-data-dir", profile.path]
    default: nil
    }
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

enum BrowserCloneProxy {
  static let filename = "browser-proxy"
  static let maxBytes = 300
  static let endpointPattern =
    #"\A(?:http|https|socks5)://(?:[A-Za-z0-9.-]+|\[[A-Fa-f0-9:.]+\]):[0-9]{1,5}\z"#
  static let bundleMetadata = [
    "XStatsBrowserProxyPattern": endpointPattern,
    "XStatsBrowserProxyFilename": filename,
  ]

  static let launcherHeader = #"""
    #import <Foundation/Foundation.h>
    #include <errno.h>
    #include <fcntl.h>
    #include <stdlib.h>
    #include <sys/stat.h>
    #include <unistd.h>

    static inline NSString *cloneProxyEndpoint(NSBundle *bundle) {
        NSDictionary *info = bundle.infoDictionary;
        NSString *filename = info[@"XStatsBrowserProxyFilename"];
        NSString *pattern = info[@"XStatsBrowserProxyPattern"];
        if (!filename || !pattern) return nil;
        NSURL *file = [bundle.bundleURL.URLByDeletingLastPathComponent
            URLByAppendingPathComponent:filename];
        int descriptor = open(file.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
        if (descriptor < 0) return errno == ENOENT ? @"" : nil;
        struct stat status;
        char buffer[\#(maxBytes + 1)];
        ssize_t size = -1;
        if (fstat(descriptor, &status) == 0 && S_ISREG(status.st_mode)) {
            do { size = read(descriptor, buffer, sizeof(buffer)); } while (size < 0 && errno == EINTR);
        }
        close(descriptor);
        if (size <= 0 || size >= (ssize_t)sizeof(buffer) || size != status.st_size) return nil;
        NSString *endpoint = [[NSString alloc] initWithBytes:buffer length:(NSUInteger)size encoding:NSUTF8StringEncoding];
        if (!endpoint || [endpoint rangeOfString:pattern
            options:NSRegularExpressionSearch].location == NSNotFound) return nil;
        NSURLComponents *components = [NSURLComponents componentsWithString:endpoint];
        NSInteger port = components.port.integerValue;
        return components.URL && port >= 1 && port <= 65535 ? endpoint : nil;
    }

    static inline NSDictionary<NSString *, NSString *> *cloneProxyEnvironment(NSString *endpoint) {
        return @{
            @"HTTP_PROXY": endpoint, @"HTTPS_PROXY": endpoint,
            @"http_proxy": endpoint, @"https_proxy": endpoint,
            @"NO_PROXY": @"localhost,127.0.0.1,*.local",
            @"no_proxy": @"localhost,127.0.0.1,*.local"
        };
    }
    """#

  static func accepts(_ endpoint: String) -> Bool {
    guard endpoint.utf8.count <= maxBytes,
      endpoint.range(of: endpointPattern, options: .regularExpression) != nil,
      let components = URLComponents(string: endpoint), components.url != nil,
      let port = components.port
    else { return false }
    return (1...65535).contains(port)
  }
}

actor AppCloneStore {
  enum Failure: Error, Equatable {
    case invalidClone, invalidSource, untrustedSource, running, unsupportedExecutable
    case buildInProgress
    case registrationTooLarge
    case invalidProxy, proxyRequiresUpdate
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
    try files.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    // 暂存目录清理与构建共用目录锁，避免另一个 XStats 进程误清理正在构建的分身。
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK { throw Failure.buildInProgress }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
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
    let profileArguments = clone.application.profileLaunchArguments(profile: profile)
    if let arguments = profileArguments {
      try await ProfileCloneLauncher.build(
        clone, source: source, candidate: candidate, arguments: arguments, stage: stage)
    } else {
      try await AppCloneBuilder.build(
        clone, source: source, candidate: candidate, profile: profile, stage: stage)
    }
    guard Self.hasIdentity(candidate, clone.bundleID) else { throw Failure.invalidClone }
    if updating {
      try await beforeReplacing()
      guard Self.hasIdentity(bundle, clone.bundleID) else { throw Failure.invalidClone }
    }
    if profileArguments == nil {
      try files.createDirectory(
        at: profile.appending(path: "Home/Library/Caches"), withIntermediateDirectories: true)
      try files.createDirectory(
        at: profile.appending(path: "Tmp"), withIntermediateDirectories: true)
    }
    if updating {
      if bundle.path != namedBundle.path {
        // 先迁移旧包的名称；后续交换失败时，旧版本仍可通过新路径打开。
        try files.moveItem(at: bundle, to: namedBundle)
      }
      try Self.swap(candidate, namedBundle)
    } else if let registration {
      if profileArguments != nil {
        try files.createDirectory(
          at: profile, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      }
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

  func profileIsInUse(_ clone: AppClone, sourcePIDs: [pid_t]) -> Bool {
    guard !sourcePIDs.isEmpty else { return false }
    let profile = root.appending(path: clone.id.uuidString).appending(path: "Data")
    guard
      clone.application.profileLaunchArguments(profile: profile) != nil
        || Self.bundleMetadata(bundleURL(clone))?["XStatsSourceIdentifier"] as? String
          == clone.application.rawValue
    else { return false }
    return ProfileCloneProcess.isUsingProfile(profile, pids: sourcePIDs)
  }

  func browserProxy(for clone: AppClone) throws -> String? {
    let file = try browserProxyFile(for: clone)
    let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var status = stat()
    guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
      let data = try handle.read(upToCount: BrowserCloneProxy.maxBytes + 1),
      let endpoint = String(data: data, encoding: .utf8), BrowserCloneProxy.accepts(endpoint)
    else { throw Failure.invalidProxy }
    return endpoint
  }

  func setBrowserProxy(_ endpoint: String?, for clone: AppClone) throws {
    let file = try browserProxyFile(for: clone)
    if let endpoint {
      guard BrowserCloneProxy.accepts(endpoint) else { throw Failure.invalidProxy }
      try Data(endpoint.utf8).write(to: file, options: .atomic)
    } else if unlink(file.path) != 0, errno != ENOENT {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  private func browserProxyFile(for clone: AppClone) throws -> URL {
    let bundle = bundleURL(clone)
    let directory = bundle.deletingLastPathComponent()
    guard Self.hasIdentity(bundle, clone.bundleID),
      (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
    else { throw Failure.invalidClone }
    guard let metadata = Self.bundleMetadata(bundle),
      metadata["XStatsBrowserProxyFilename"] as? String == BrowserCloneProxy.filename,
      metadata["XStatsBrowserProxyPattern"] as? String == BrowserCloneProxy.endpointPattern
    else { throw Failure.proxyRequiresUpdate }
    return directory.appending(path: BrowserCloneProxy.filename)
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
    bundleMetadata(url)?["CFBundleIdentifier"] as? String == bundleID
  }

  nonisolated private static func bundleMetadata(_ url: URL) -> [String: Any]? {
    guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
      return nil
    }
    let plist = url.appending(path: "Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
      let values = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { return nil }
    return values
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
