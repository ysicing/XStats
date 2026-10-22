import Foundation
import Localization

/// 一个 launchd 启动项（LaunchAgents / LaunchDaemons 里的 plist）
public struct LaunchItem: Sendable, Identifiable, Hashable {
  public enum Scope: String, Sendable, CaseIterable {
    /// ~/Library/LaunchAgents：只对当前用户生效，可以直接启用或停用
    case user
    /// /Library/LaunchAgents：所有用户登录时运行
    case allUsers
    /// /Library/LaunchDaemons：以 root 在后台运行
    case system

    public var title: String {
      switch self {
      case .user: tr("当前用户")
      case .allUsers: tr("所有用户")
      case .system: tr("系统服务")
      }
    }

    public var directory: String {
      switch self {
      case .user: NSHomeDirectory() + "/Library/LaunchAgents"
      case .allUsers: "/Library/LaunchAgents"
      case .system: "/Library/LaunchDaemons"
      }
    }
  }

  public var id: String { plist.path }
  public let label: String
  public let plist: URL
  public let scope: Scope
  /// 可执行文件路径（Program 或 ProgramArguments 的第一项）
  public let program: String?
  public let runAtLoad: Bool
  public let keepAlive: Bool
  /// 在 plist 里被标记为 Disabled
  public let disabledInPlist: Bool

  /// 构造一个已解析的启动项目；不读取文件或执行 launchctl。
  public init(
    label: String, plist: URL, scope: Scope, program: String?, runAtLoad: Bool,
    keepAlive: Bool, disabledInPlist: Bool
  ) {
    self.label = label
    self.plist = plist
    self.scope = scope
    self.program = program
    self.runAtLoad = runAtLoad
    self.keepAlive = keepAlive
    self.disabledInPlist = disabledInPlist
  }

  /// 可执行文件所在的 .app（用于显示图标和名称）
  public var appBundlePath: String? {
    guard let program, let range = program.range(of: ".app/") else { return nil }
    return String(program[..<range.lowerBound]) + ".app"
  }
}

/// launchd 中的运行状态
public struct LaunchStatus: Sendable, Equatable {
  public var loaded: [String: Int?] = [:]
  public var disabled: [String: Bool] = [:]
  public var systemDisabled: [String: Bool] = [:]

  public init(
    loaded: [String: Int?] = [:], disabled: [String: Bool] = [:],
    systemDisabled: [String: Bool] = [:]
  ) {
    self.loaded = loaded
    self.disabled = disabled
    self.systemDisabled = systemDisabled
  }

  public func isDisabled(_ item: LaunchItem) -> Bool {
    let domain = item.scope == .system ? systemDisabled : disabled
    return domain[item.label] ?? item.disabledInPlist
  }

  public func pid(_ item: LaunchItem) -> Int? {
    item.scope == .system ? nil : loaded[item.label] ?? nil
  }

  public func isLoaded(_ item: LaunchItem) -> Bool {
    item.scope != .system && loaded[item.label] != nil
  }
}

public enum LaunchItems {
  public static func scan(scopes: [LaunchItem.Scope] = LaunchItem.Scope.allCases) -> [LaunchItem] {
    scopes.flatMap { scope -> [LaunchItem] in
      guard !Task.isCancelled else { return [] }
      let directory = URL(fileURLWithPath: scope.directory)
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil)) ?? []
      return files.filter { $0.pathExtension == "plist" }.compactMap { url in
        guard !Task.isCancelled, let data = try? Data(contentsOf: url),
          let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        else { return nil }
        return item(from: dictionary, plist: url, scope: scope)
      }
    }
    .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
  }

  static func item(from plist: [String: Any], plist url: URL, scope: LaunchItem.Scope)
    -> LaunchItem?
  {
    guard let label = plist["Label"] as? String, !label.isEmpty else { return nil }
    let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
    let keepAlive: Bool = {
      if let flag = plist["KeepAlive"] as? Bool { return flag }
      return plist["KeepAlive"] is [String: Any]
    }()
    return LaunchItem(
      label: label, plist: url, scope: scope, program: program,
      runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
      disabledInPlist: plist["Disabled"] as? Bool ?? false)
  }

  /// 按当前分类读取域状态；系统域不复用用户域的加载列表。
  public static func status(scopes: [LaunchItem.Scope] = LaunchItem.Scope.allCases) -> LaunchStatus
  {
    var status = LaunchStatus()
    if scopes.contains(.user) || scopes.contains(.allUsers) {
      guard !Task.isCancelled else { return status }
      status.loaded = parseList(run(["list"]))
      guard !Task.isCancelled else { return status }
      status.disabled = parseDisabled(run(["print-disabled", "gui/\(getuid())"]))
    }
    if scopes.contains(.system) {
      guard !Task.isCancelled else { return status }
      // 用户域与系统域可存在相同标签，不能把用户进程或停用状态套到守护进程上。
      status.systemDisabled = parseDisabled(run(["print-disabled", "system"]))
    }
    return status
  }

  /// `launchctl list`：PID、状态、标签，PID 为“-”表示已加载但没有在运行
  static func parseList(_ output: String) -> [String: Int?] {
    var result: [String: Int?] = [:]
    for line in output.split(separator: "\n").dropFirst() {
      let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard columns.count >= 3 else { continue }
      result[String(columns[2])] = Int(columns[0])
    }
    return result
  }

  /// `launchctl print-disabled`：`"标签" => enabled / disabled`
  static func parseDisabled(_ output: String) -> [String: Bool] {
    var result: [String: Bool] = [:]
    for line in output.split(separator: "\n") {
      let parts = line.components(separatedBy: "=>")
      guard parts.count == 2 else { continue }
      let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(
        in: CharacterSet(charactersIn: "\""))
      let state = parts[1].trimmingCharacters(in: .whitespaces)
      guard !label.isEmpty else { continue }
      result[label] = state.hasPrefix("disabled") || state == "true"
    }
    return result
  }

  /// 停用：写入 launchd 的停用记录并卸载，不删除 plist，随时可以重新启用。只处理当前用户的启动项
  public static func setEnabled(_ enabled: Bool, item: LaunchItem) -> String? {
    guard item.scope == .user else { return tr("所有用户与系统级的启动项需要管理员权限，请在系统设置的登录项中管理") }
    let domain = "gui/\(getuid())"
    let target = "\(domain)/\(item.label)"
    if enabled {
      _ = run(["enable", target])
      let result = runStatus(["bootstrap", domain, item.plist.path])
      // 已经加载时返回 5 / 37，不算失败
      return [0, 5, 37].contains(result.status) ? nil : tr("启用失败：\(result.output)")
    } else {
      _ = run(["disable", target])
      let result = runStatus(["bootout", target])
      // 没有加载时返回 3 / 113，不算失败
      return [0, 3, 36, 113].contains(result.status) ? nil : tr("停用失败：\(result.output)")
    }
  }

  private static func run(_ arguments: [String]) -> String {
    runStatus(arguments).output
  }

  private static func runStatus(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }
}
