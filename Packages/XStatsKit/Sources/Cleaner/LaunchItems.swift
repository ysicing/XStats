import Foundation
import CoreFoundation
import Darwin
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
  public fileprivate(set) var details = Details()
  public fileprivate(set) var configurationIssue: ConfigurationIssue?
  fileprivate var configuration: Data?

  public struct Details: Sendable, Hashable {
    public fileprivate(set) var interval: Int?
    public fileprivate(set) var schedules: [Schedule] = []
    public fileprivate(set) var watchedPaths: [String] = []
    public fileprivate(set) var standardOutput: String?
    public fileprivate(set) var standardError: String?
  }

  public struct Schedule: Sendable, Hashable {
    public let month: Int?
    public let day: Int?
    public let weekday: Int?
    public let hour: Int?
    public let minute: Int?
  }

  public enum ConfigurationIssue: Error, Hashable, Sendable {
    case unreadable, tooLarge, invalidPlist, missingLabel
  }

  /// 构造展示数据，不读取文件；启停操作须使用扫描得到的配置快照。
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
  public var exitStatuses: [String: Int] = [:]

  public init(
    loaded: [String: Int?] = [:], disabled: [String: Bool] = [:],
    systemDisabled: [String: Bool] = [:], exitStatuses: [String: Int] = [:]
  ) {
    self.loaded = loaded
    self.disabled = disabled
    self.systemDisabled = systemDisabled
    self.exitStatuses = exitStatuses
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

  public func lastExitStatus(_ item: LaunchItem) -> Int? {
    guard item.configurationIssue == nil, isLoaded(item) else { return nil }
    return exitStatuses[item.label]
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
        guard !Task.isCancelled else { return nil }
        return scanItem(at: url, scope: scope)
      }
    }
    .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
  }

  static func scanItem(at url: URL, scope: LaunchItem.Scope) -> LaunchItem {
    do {
      let dictionary = try readConfiguration(at: url)
      if let item = item(from: dictionary, plist: url, scope: scope) { return item }
      throw LaunchItem.ConfigurationIssue.missingLabel
    } catch {
      var item = LaunchItem(
        label: url.lastPathComponent, plist: url, scope: scope, program: nil,
        runAtLoad: false, keepAlive: false, disabledInPlist: false)
      item.configurationIssue = error as? LaunchItem.ConfigurationIssue ?? .unreadable
      return item
    }
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
    var item = LaunchItem(
      label: label, plist: url, scope: scope, program: program,
      runAtLoad: plist["RunAtLoad"] as? Bool ?? false, keepAlive: keepAlive,
      disabledInPlist: plist["Disabled"] as? Bool ?? false)
    let calendar = plist["StartCalendarInterval"]
    let schedules =
      (calendar as? [[String: Any]]) ?? (calendar as? [String: Any]).map { [$0] } ?? []
    item.details = LaunchItem.Details(
      interval: integer(plist["StartInterval"], in: 1...Int.max),
      schedules: schedules.compactMap(schedule),
      watchedPaths: (plist["WatchPaths"] as? [String] ?? []).filter { !$0.isEmpty },
      standardOutput: logPath(plist["StandardOutPath"]),
      standardError: logPath(plist["StandardErrorPath"]))
    item.configuration = try? PropertyListSerialization.data(
      fromPropertyList: plist, format: .binary, options: 0)
    return item
  }

  private static func logPath(_ value: Any?) -> String? {
    guard let path = value as? String, path.hasPrefix("/"), !path.utf8.contains(0) else {
      return nil
    }
    return path.split(separator: "/").filter { $0 != "." }.elementsEqual(["dev", "null"])
      ? nil : path
  }

  private static func integer(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      let integer = Int(number.stringValue), range.contains(integer)
    else { return nil }
    return integer
  }

  private static func schedule(_ values: [String: Any]) -> LaunchItem.Schedule? {
    let month = integer(values["Month"], in: 1...12)
    let day = integer(values["Day"], in: 1...31)
    let weekday = integer(values["Weekday"], in: 0...7)
    let hour = integer(values["Hour"], in: 0...23)
    let minute = integer(values["Minute"], in: 0...59)
    guard values.count == [month, day, weekday, hour, minute].compactMap({ $0 }).count else {
      return nil
    }
    return .init(month: month, day: day, weekday: weekday, hour: hour, minute: minute)
  }

  private static func readConfiguration(at url: URL, followSymlinks: Bool = true) throws
    -> [String: Any]
  {
    let limit = 1_048_576
    let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | (followSymlinks ? 0 : O_NOFOLLOW)
    let descriptor = url.path.withCString { open($0, flags) }
    guard descriptor >= 0 else { throw LaunchItem.ConfigurationIssue.unreadable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var information = stat()
    guard fstat(descriptor, &information) == 0, information.st_mode & S_IFMT == S_IFREG else {
      throw LaunchItem.ConfigurationIssue.unreadable
    }
    guard information.st_size <= limit else { throw LaunchItem.ConfigurationIssue.tooLarge }
    let data = try handle.read(upToCount: limit + 1) ?? Data()
    guard data.count <= limit else { throw LaunchItem.ConfigurationIssue.tooLarge }
    guard
      let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else { throw LaunchItem.ConfigurationIssue.invalidPlist }
    return dictionary
  }

  private static func configurationsMatch(_ expected: Any, _ current: Any) -> Bool {
    switch (expected, current) {
    case (let expected as [String: Any], let current as [String: Any]):
      return expected.count == current.count
        && expected.allSatisfy { key, value in
          current[key].map { configurationsMatch(value, $0) } ?? false
        }
    case (let expected as [Any], let current as [Any]):
      return expected.count == current.count
        && zip(expected, current).allSatisfy { configurationsMatch($0, $1) }
    case (let expected as NSNumber, let current as NSNumber):
      // Foundation 数值相等会忽略布尔、整数和实数的 plist 类型差异。
      let realTypes = ["f", "d"]
      return CFGetTypeID(expected) == CFGetTypeID(current)
        && realTypes.contains(String(cString: expected.objCType))
          == realTypes.contains(String(cString: current.objCType))
        && expected.isEqual(to: current)
    default:
      guard let expected = expected as? NSObject, let current = current as? NSObject else {
        return false
      }
      return CFGetTypeID(expected) == CFGetTypeID(current) && expected.isEqual(current)
    }
  }

  /// 按当前分类读取域状态；系统域不复用用户域的加载列表。
  public static func status(scopes: [LaunchItem.Scope] = LaunchItem.Scope.allCases) -> LaunchStatus
  {
    var status = LaunchStatus()
    if scopes.contains(.user) || scopes.contains(.allUsers) {
      guard !Task.isCancelled else { return status }
      let listed = parseList(run(["list"]))
      status.loaded = listed.loaded
      status.exitStatuses = listed.exitStatuses
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
  static func parseList(_ output: String) -> LaunchStatus {
    var result = LaunchStatus()
    let lines = output.split(separator: "\n")
    guard lines.first?.split(separator: "\t") == ["PID", "Status", "Label"] else {
      return result
    }
    for line in lines.dropFirst() {
      let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard columns.count == 3, !columns[2].isEmpty else { continue }
      let pid = Int(columns[0])
      guard pid != nil || columns[0] == "-" else { continue }
      let label = String(columns[2])
      result.loaded[label] = .some(pid)
      result.exitStatuses[label] = Int(columns[1])
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
    setEnabled(enabled, item: item, runCommand: runStatus)
  }

  static func setEnabled(
    _ enabled: Bool, item: LaunchItem,
    runCommand: ([String]) -> (status: Int32, output: String)
  ) -> String? {
    guard item.scope == .user else { return tr("所有用户与系统级的启动项需要管理员权限，请在系统设置的登录项中管理") }
    guard let current = try? readConfiguration(at: item.plist, followSymlinks: false),
      let configuration = item.configuration,
      let expected = try? PropertyListSerialization.propertyList(from: configuration, format: nil)
        as? [String: Any],
      configurationsMatch(expected, current)
    else {
      return tr("服务已变化或不属于当前用户，请刷新后重试")
    }
    let domain = "gui/\(getuid())"
    let target = "\(domain)/\(item.label)"
    let overrideResult = runCommand([enabled ? "enable" : "disable", target])
    guard overrideResult.status == 0 else {
      return enabled ? tr("启用失败：\(overrideResult.output)") : tr("停用失败：\(overrideResult.output)")
    }
    let result = runCommand(
      enabled ? ["bootstrap", domain, item.plist.path] : ["bootout", target])
    guard result.status != 0 else { return nil }
    // 通用 I/O 错误也会返回 5，只有成功读取用户域并确认目标状态才能视为幂等成功。
    let status = runCommand(["list"])
    if status.status == 0,
      status.output.split(separator: "\n").first?.split(separator: "\t") == [
        "PID", "Status", "Label",
      ],
      (parseList(status.output).loaded[item.label] != nil) == enabled
    {
      return nil
    }
    return enabled ? tr("启用失败：\(result.output)") : tr("停用失败：\(result.output)")
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
