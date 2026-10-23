// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import CoreFoundation
import Foundation
import Localization

public struct SystemCheckFinding: Sendable, Identifiable {
  public enum Status: Sendable { case normal, attention, optional, notApplicable, unchecked }

  public let id: String
  public let title: String
  public let status: Status
  public let isComplete: Bool
  public let detail: String
  public let evidence: [String]

  public init(
    id: String, title: String, status: Status, isComplete: Bool = true,
    detail: String, evidence: [String] = []
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.isComplete = isComplete
    self.detail = detail
    self.evidence = Array(evidence.prefix(20)).map { String($0.prefix(500)) }
  }
}

public enum SystemCheck {
  public enum PreferenceValue: Sendable {
    case bool(Bool)
    case unknown
  }

  @concurrent
  public static func local(home: String = NSHomeDirectory()) async throws -> [SystemCheckFinding] {
    try Task.checkCancellation()
    let launch = launchAgents(home: home)
    try Task.checkCancellation()
    let preferences = legacyOverrides(home: home)
    try Task.checkCancellation()
    return [launch, preferences, permissions(home: home)]
  }

  public static func launchAgents(home: String) -> SystemCheckFinding {
    let directory = URL(fileURLWithPath: home).appendingPathComponent("Library/LaunchAgents")
    let fm = FileManager.default
    var missing: [String] = []
    var incomplete = false
    let budget = ScanBudget(limits: ScanLimits(maxEntries: 2_000, maxDuration: 5))
    do {
      let files = try RuleCatalog.childrenIfExists(of: directory.path, budget: budget)
      for url in files where url.pathExtension == "plist" {
        try budget.visit()
        guard let plist = try? readPropertyList(url),
          let item = LaunchItems.item(from: plist, plist: url, scope: .user),
          let program = item.program, program.hasPrefix("/")
        else {
          incomplete = true
          continue
        }
        let target = URL(fileURLWithPath: program).standardizedFileURL
        if target.path.hasPrefix("/Volumes/"),
          let volume = target.pathComponents.dropFirst(2).first,
          !fm.fileExists(atPath: "/Volumes/" + volume)
        {
          incomplete = true
          continue
        }
        var targetInfo = stat()
        if target.path.withCString({ stat($0, &targetInfo) }) != 0 {
          if [ENOENT, ENOTDIR].contains(errno) {
            if missing.count < 20 { missing.append(item.label + " · " + target.path) }
          } else {
            incomplete = true
          }
        }
      }
    } catch { incomplete = true }
    return SystemCheckFinding(
      id: "launchAgents", title: tr("启动代理目标"),
      status: !missing.isEmpty ? .attention : incomplete ? .unchecked : .normal,
      isComplete: !incomplete, detail: tr("仅检查当前用户启动代理的绝对程序路径；不删除或停用。"),
      evidence: missing)
  }

  public static func legacyOverrides(home: String) -> SystemCheckFinding {
    var values: [String: PreferenceValue] = [:]
    for (file, keys) in [
      (".GlobalPreferences.plist", ["NSAppSleepDisabled"]),
      (
        "com.apple.frameworks.diskimages.plist",
        [
          "skip-verify", "skip-verify-locked", "skip-verify-remote",
        ]
      ),
    ] {
      let url = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences/" + file)
      do {
        let plist = try readPropertyList(url)
        for key in keys {
          if let value = plist[key] as? NSNumber,
            CFGetTypeID(value) == CFBooleanGetTypeID()
          {
            values[key] = .bool(value.boolValue)
          } else {
            values[key] = plist[key] == nil ? .bool(false) : .unknown
          }
        }
      } catch {
        let absent = ApplicationCacheCatalog.isMissingOrNotDirectory(error)
        for key in keys { values[key] = absent ? .bool(false) : .unknown }
      }
    }
    return legacyOverrides(values: values)
  }

  /// 描述符校验与读取针对同一个普通文件，避免大小检查后文件被替换或扩容。
  static func readPropertyList(_ url: URL) throws -> [String: Any] {
    let limit = 1_048_576
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size <= limit
    else { throw CocoaError(.fileReadUnknown) }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit,
      let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { throw CocoaError(.propertyListReadCorrupt) }
    return plist
  }

  public static func legacyOverrides(values: [String: PreferenceValue]) -> SystemCheckFinding {
    var enabled: [String] = []
    var complete = true
    for (key, value) in values {
      switch value {
      case .bool(true): enabled.append(key)
      case .bool(false): break
      case .unknown: complete = false
      }
    }
    return SystemCheckFinding(
      id: "legacyOverrides", title: tr("遗留偏好覆盖"),
      status: !enabled.isEmpty ? .attention : complete ? .normal : .unchecked,
      isComplete: complete, detail: tr("检查用户偏好文件中的 App Nap 和磁盘映像验证覆盖；不修改设置。"),
      evidence: enabled.sorted())
  }

  public static func permissions(home: String) -> SystemCheckFinding {
    var evidence: [String] = []
    var complete = true
    for suffix in ["", "/Library", "/Library/Preferences"] {
      let path = home + suffix
      var info = stat()
      guard path.withCString({ stat($0, &info) }) == 0 else {
        complete = false
        continue
      }
      if info.st_uid != getuid() || path.withCString({ access($0, W_OK) }) != 0 {
        evidence.append(path)
      }
    }
    return SystemCheckFinding(
      id: "permissions", title: tr("用户目录权限"),
      status: !evidence.isEmpty ? .attention : complete ? .normal : .unchecked,
      isComplete: complete, detail: tr("仅检查主目录、Library 和 Preferences 的所有者与可写性。"),
      evidence: evidence)
  }

  public static func homebrew(environment: CleanEnvironment) async throws -> SystemCheckFinding {
    try Task.checkCancellation()
    guard environment.isToolAvailable("brew") else {
      return SystemCheckFinding(
        id: "brewAutoremove", title: "Homebrew", status: .notApplicable,
        detail: tr("未安装 Homebrew"))
    }
    do {
      let result = try await environment.inspectTool("brew", ["autoremove", "--dry-run"])
      try Task.checkCancellation()
      guard result.status == 0 else {
        throw ToolExecutionError.failed(
          tool: "brew", status: result.status, output: "")
      }
      return SystemCheckFinding(
        id: "brewAutoremove", title: tr("Homebrew 依赖预览"), status: .optional,
        detail: tr("由 Homebrew 列出不再需要的依赖，仅供审阅。"),
        evidence: result.output.split(separator: "\n").prefix(20).map(String.init))
    } catch is CancellationError { throw CancellationError() } catch {
      return SystemCheckFinding(
        id: "brewAutoremove", title: tr("Homebrew 依赖预览"), status: .unchecked,
        isComplete: false, detail: tr("无法完成检查，请稍后重试。"))
    }
  }
}
