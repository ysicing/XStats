// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreFoundation
import CoreServices
import Darwin
import Foundation
import Localization

/// 由独立手动入口发起的配置检查；不修复文件、不申请授权、不解析最近文档书签。
public enum ConfigurationPreview {
  @concurrent
  public static func scan(
    environment: CleanEnvironment = CleanEnvironment(runningBundleIdentifiers: { [] })
  ) async throws -> [SystemCheckFinding] {
    try await scan(environment: environment, sources: Sources(home: environment.home))
  }

  /// P4 的独立只读状态审阅；不生成 CleanRule 或可清理候选。
  @concurrent
  public static func savedState(
    environment: CleanEnvironment = CleanEnvironment(runningBundleIdentifiers: { [] })
  ) async throws -> SystemCheckFinding {
    try Task.checkCancellation()
    let limits = environment.scanLimits
    let budget = ScanBudget(
      limits: ScanLimits(
        maxEntries: min(2_000, limits.maxEntries),
        maxDuration: min(20, limits.maxDuration),
        maxCandidates: min(500, limits.maxCandidates)))
    let root = URL(fileURLWithPath: environment.home)
      .appendingPathComponent("Library/Saved Application State")
    var evidence: [String] = []
    var complete = true
    do {
      if try missing(root, environment: environment) {
        return SystemCheckFinding(
          id: "savedState", title: tr("应用保存状态审阅"), status: .notApplicable,
          detail: tr("未找到当前用户的 Saved Application State 目录。"))
      }
      let entries = try RuleCatalog.children(
        of: root.path, budget: budget, countCandidates: false)
      for url in entries where url.pathExtension == "savedState" {
        try budget.check()
        guard !CleanupExclusions.overlaps(url, paths: environment.excludedPaths),
          AppUninstaller.isUnredirected(url, home: environment.home)
        else {
          complete = false
          continue
        }
        var before = stat()
        guard url.path.withCString({ lstat($0, &before) }) == 0 else {
          complete = false
          continue
        }
        guard before.st_mode & S_IFMT == S_IFDIR else { continue }
        let owner = url.deletingPathExtension()
        guard !savedStateOwnerIsRunning(owner, environment: environment) else {
          if evidence.count < 20 {
            evidence.append(url.lastPathComponent + " · " + tr("运行中的应用，未计量"))
          }
          continue
        }
        // 固定 Mole base.sh:162 为 30 天；只以目录 mtime 筛选，不读取恢复状态内容。
        let modified =
          Double(before.st_mtimespec.tv_sec)
          + Double(before.st_mtimespec.tv_nsec) / 1e9
        guard environment.now().timeIntervalSince1970 - modified > 30 * 86_400 else { continue }
        try budget.visitCandidate(url.standardizedFileURL.path)
        do {
          let size = try CleanEngine.scanAllocatedSize(of: url) { try budget.visit() }
          try budget.check()
          var after = stat()
          guard url.path.withCString({ lstat($0, &after) }) == 0,
            before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            after.st_mode & S_IFMT == S_IFDIR,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            AppUninstaller.isUnredirected(url, home: environment.home),
            !savedStateOwnerIsRunning(owner, environment: environment)
          else {
            complete = false
            continue
          }
          if evidence.count < 20 {
            evidence.append(url.lastPathComponent + " · " + String(size) + " B")
          }
        } catch { complete = false }
      }
    } catch { complete = false }
    try Task.checkCancellation()
    return SystemCheckFinding(
      id: "savedState", title: tr("应用保存状态审阅"),
      status: complete ? .optional : .unchecked, isComplete: complete,
      detail: tr("只审阅超过 30 天的直接 savedState 目录，跳过运行应用；仅展示完整计量占用，不判断可安全丢弃，不提供清理。"),
      evidence: evidence)
  }

  private static func savedStateOwnerIsRunning(
    _ owner: URL, environment: CleanEnvironment
  ) -> Bool {
    let identifiers = environment.runningBundleIdentifiers()
    let names = environment.runningApplicationNames()
    if CleanEngine.owningApp(of: owner, running: identifiers, names: names) != nil { return true }
    let shortName = owner.lastPathComponent.split(separator: ".").last.map(String.init) ?? ""
    return names.contains { shortName.caseInsensitiveCompare($0) == .orderedSame }
  }

  /// 测试替换系统范围与授权预检，避免 fixture 检查触及真实用户数据。
  struct Sources: Sendable {
    var applicationDirectories: [URL]
    var periodicLogs: [String]
    var loginItems: @Sendable (TimeInterval) throws -> [LoginItem]

    init(home: String) {
      applicationDirectories = [
        URL(fileURLWithPath: home).appendingPathComponent("Applications"),
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
      ]
      periodicLogs = ["/var/log/daily.out", "/var/log/weekly.out", "/var/log/monthly.out"]
      loginItems = ConfigurationPreview.readLoginItems
    }
  }

  @concurrent
  static func scan(
    environment: CleanEnvironment, sources: Sources
  ) async throws -> [SystemCheckFinding] {
    try Task.checkCancellation()
    let limits = environment.scanLimits
    let budget = ScanBudget(
      limits: ScanLimits(
        maxEntries: min(2_000, limits.maxEntries),
        maxDuration: min(20, limits.maxDuration),
        maxCandidates: min(500, limits.maxCandidates)))
    var findings = [
      propertyLists(environment: environment, sharedLists: false, budget: budget),
      propertyLists(environment: environment, sharedLists: true, budget: budget),
      finderPreferences(environment: environment, budget: budget),
    ]
    try Task.checkCancellation()
    findings.append(try await spotlight(environment: environment, sources: sources, budget: budget))
    findings.append(
      try await spotlightRules(
        environment: environment, sources: sources, budget: budget))
    findings.append(try await periodic(environment: environment, sources: sources, budget: budget))
    findings.append(
      try await loginItems(environment: environment, sources: sources, budget: budget))
    try Task.checkCancellation()
    return findings
  }

  private enum InspectionError: Error { case unsafe, unavailable, output }
  private enum PlistHealth { case parsed, malformed, unreadable }

  private struct PlistSummary {
    var parsed = 0
    var complete = true
    var evidence: [String] = []
  }

  private static func propertyLists(
    environment: CleanEnvironment, sharedLists: Bool, budget: ScanBudget
  ) -> SystemCheckFinding {
    // Mole maintenance.sh:7-135 / tasks.sh:1324；有意不递归 Preferences 或整个数据目录。
    let relativeDirectories =
      sharedLists
      ? ["Library/Application Support/com.apple.sharedfilelist"]
      : ["Library/Preferences", "Library/Preferences/ByHost"]
    var summary = PlistSummary()
    for relative in relativeDirectories {
      let directory = URL(fileURLWithPath: environment.home).appendingPathComponent(relative)
      do {
        try budget.check()
        if try missing(directory, environment: environment) { continue }
        let children = try RuleCatalog.children(
          of: directory.path, budget: budget, countCandidates: false)
        for url in children {
          try budget.check()
          let name = url.lastPathComponent
          if sharedLists {
            // 最近文档是用户数据；即使以后扩展层级也必须维持此保护。
            guard !name.contains("ApplicationRecentDocuments") else { continue }
            guard ["sfl2", "sfl3", "sfl4"].contains(url.pathExtension) else {
              var info = stat()
              if url.path.withCString({ lstat($0, &info) }) == 0,
                info.st_mode & S_IFMT == S_IFDIR
              {
                summary.complete = false
              }
              continue
            }
          } else {
            guard url.pathExtension == "plist",
              !name.hasPrefix("com.apple."), !name.hasPrefix(".GlobalPreferences"),
              name != "loginwindow.plist"
            else { continue }
          }
          guard !CleanupExclusions.overlaps(url, paths: environment.excludedPaths),
            AppUninstaller.isUnredirected(url, home: environment.home)
          else {
            summary.complete = false
            continue
          }
          try budget.visitCandidate(url.standardizedFileURL.path)
          switch lintPropertyList(url) {
          case .parsed: summary.parsed += 1
          case .malformed:
            if summary.evidence.count < 19 {
              summary.evidence.append(relative + "/" + name)
            }
          case .unreadable: summary.complete = false
          }
          try budget.check()
        }
      } catch {
        summary.complete = false
      }
    }
    let hasMalformed = !summary.evidence.isEmpty
    summary.evidence.insert(tr("已解析文件：\(summary.parsed)"), at: 0)
    return SystemCheckFinding(
      id: sharedLists ? "sharedFileLists" : "preferencePlists",
      title: sharedLists ? tr("共享文件列表格式") : tr("偏好文件格式"),
      status: hasMalformed ? .attention : summary.complete ? .normal : .unchecked,
      isComplete: summary.complete,
      detail: sharedLists
        ? tr("仅检查共享列表根目录的 sfl2、sfl3、sfl4 文件格式；跳过最近文档，不解档或解析书签。")
        : tr("仅解析 Preferences 与 ByHost 顶层的非受保护 plist；不判断偏好内容是否正确。"),
      evidence: summary.evidence)
  }

  /// 健康检查接受所有合法 plist 根类型；字典读取接口无法区分合法数组与损坏文件。
  /// OpenStep 的无引号单词也是合法字符串，不能仅凭它看似普通文本就判为损坏。
  /// 不使用 NSKeyedUnarchiver，避免共享列表中的对象和书签被实例化或解析。
  private static func lintPropertyList(_ url: URL) -> PlistHealth {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return .unreadable }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    let limit = 1_048_576
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size >= 0, info.st_size <= limit
    else { return .unreadable }
    let data: Data
    do {
      data = try handle.read(upToCount: limit + 1) ?? Data()
      guard data.count <= limit else { return .unreadable }
    } catch { return .unreadable }
    do {
      _ = try PropertyListSerialization.propertyList(from: data, format: nil)
      return .parsed
    } catch { return .malformed }
  }

  private static func finderPreferences(
    environment: CleanEnvironment, budget: ScanBudget
  ) -> SystemCheckFinding {
    let keys = ["DSDontWriteNetworkStores", "DSDontWriteUSBStores"]
    var evidence: [String] = []
    var complete = true
    do {
      try budget.visit()
      let url = URL(fileURLWithPath: environment.home)
        .appendingPathComponent("Library/Preferences/com.apple.desktopservices.plist")
      let plist =
        try missing(url, environment: environment)
        ? [:] : SystemCheck.readPropertyList(url)
      for key in keys {
        guard let value = plist[key] else {
          evidence.append(key + " = default")
          continue
        }
        guard let number = value as? NSNumber,
          CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
          complete = false
          continue
        }
        evidence.append(key + (number.boolValue ? " = true" : " = false"))
      }
    } catch { complete = false }
    return SystemCheckFinding(
      id: "finderMetadata", title: tr("Finder 外置卷元数据偏好"),
      status: complete ? .optional : .unchecked, isComplete: complete,
      detail: tr("只读用户保存的网络盘与 USB .DS_Store 偏好；默认值或关闭不表示故障，不代表卷上现有文件状态。"),
      evidence: evidence)
  }

  private static func spotlight(
    environment: CleanEnvironment, sources: Sources, budget: ScanBudget
  ) async throws -> SystemCheckFinding {
    var evidence: [String] = []
    do {
      let status = try await inspect(
        "mdutil", ["-s", "/"], environment: environment, budget: budget)
      let lines = status.output.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces).lowercased()
      }
      guard lines.count == 2, lines[0] == "/:" else { throw InspectionError.output }
      if lines.contains("indexing disabled.") || lines.contains("indexing and searching disabled.")
      {
        return SystemCheckFinding(
          id: "spotlightIndex", title: tr("Spotlight 索引与有限查询"), status: .notApplicable,
          detail: tr("启动卷 Spotlight 索引已关闭；未发起搜索，也不建议重建。"))
      }
      guard lines.contains("indexing enabled.") else { throw InspectionError.output }
      evidence.append(tr("启动卷报告索引已启用"))
      var queried = false
      for root in sources.applicationDirectories {
        try budget.check()
        if try missingApplicationDirectory(root, environment: environment) { continue }
        let start = ContinuousClock.now
        let result = try await inspect(
          "mdfind",
          ["-onlyin", root.path, "-count", "kMDItemContentType == 'com.apple.application-bundle'"],
          environment: environment, budget: budget)
        guard let count = unsignedInteger(result.output) else { throw InspectionError.output }
        let duration = start.duration(to: ContinuousClock.now)
        queried = true
        evidence.append(root.lastPathComponent + " · " + String(count))
        // 仅一次有界查询，不把耗时推断为索引损坏或重建依据。
        if duration > .seconds(3) { evidence.append(tr("有限查询超过 3 秒；单次结果不能判断索引故障")) }
      }
      guard queried else { throw InspectionError.unavailable }
      return SystemCheckFinding(
        id: "spotlightIndex", title: tr("Spotlight 索引与有限查询"), status: .optional,
        detail: tr("只查询声明的应用目录并返回计数；成功或零结果均不能证明索引完整，不执行重建。"),
        evidence: evidence)
    } catch is CancellationError { throw CancellationError() } catch {
      try Task.checkCancellation()
      return SystemCheckFinding(
        id: "spotlightIndex", title: tr("Spotlight 索引与有限查询"), status: .unchecked,
        isComplete: false,
        detail: tr("索引状态或有限查询证据不足；工具缺失、权限、超时和异常输出均不视为正常。"),
        evidence: evidence)
    }
  }

  private static func spotlightRules(
    environment: CleanEnvironment, sources: Sources, budget: ScanBudget
  ) async throws -> SystemCheckFinding {
    var evidence: [String] = []
    var complete = true
    var unresolved = false
    do {
      try budget.visit()
      let url = URL(fileURLWithPath: environment.home)
        .appendingPathComponent("Library/Preferences/com.apple.spotlight.plist")
      let plist =
        try missing(url, environment: environment)
        ? [:] : SystemCheck.readPropertyList(url)
      let rawRules = plist["EnabledPreferenceRules"]
      guard rawRules == nil || rawRules is [String] else { throw InspectionError.output }
      let rules = rawRules as? [String] ?? []
      guard rules.count <= 100 else { throw InspectionError.output }
      let identifiers = rules.filter {
        !$0.hasPrefix("System.") && !$0.hasPrefix("com.apple.")
      }
      if !identifiers.isEmpty {
        let owners = try applicationIdentifiers(
          environment: environment, sources: sources, budget: budget)
        for identifier in Set(identifiers).sorted() {
          try budget.visit()
          guard isBundleIdentifier(identifier) else {
            complete = false
            continue
          }
          if owners.contains(identifier) {
            if evidence.count < 20 { evidence.append(identifier + " · " + tr("已找到本地应用")) }
          } else {
            // 有限目录库存和 Spotlight 空结果均不能排除其他卷、其他位置或未索引的副本。
            unresolved = true
            complete = false
            if evidence.count < 20 {
              evidence.append(identifier + " · " + tr("有限范围内未确认归属，不能判定失效"))
            }
          }
        }
      }
    } catch is CancellationError { throw CancellationError() } catch {
      try Task.checkCancellation()
      complete = false
    }
    return SystemCheckFinding(
      id: "spotlightRules", title: tr("Spotlight 搜索规则归属"),
      status: complete ? .normal : unresolved ? .optional : .unchecked,
      isComplete: complete,
      detail: tr("保留 System 与 Apple 规则；仅核对应用目录两层内的 bundle 标识，未确认归属不等于孤儿规则。"),
      evidence: evidence)
  }

  private static func applicationIdentifiers(
    environment: CleanEnvironment, sources: Sources, budget: ScanBudget
  ) throws -> Set<String> {
    var identifiers = Set<String>()
    for root in sources.applicationDirectories {
      try budget.check()
      if try missingApplicationDirectory(root, environment: environment) { continue }
      let children = try RuleCatalog.children(
        of: root.path, budget: budget, countCandidates: false)
      var applications: [URL] = []
      for child in children {
        try budget.check()
        guard AppUninstaller.isUnredirected(child, home: root.path) else { continue }
        if child.pathExtension == "app" {
          try budget.visitCandidate(child.standardizedFileURL.path)
          applications.append(child)
        } else if AppUninstaller.isDirectoryWithoutSymlink(child) {
          let nested = try RuleCatalog.children(
            of: child.path, budget: budget, countCandidates: false)
          for app in nested where app.pathExtension == "app" {
            try budget.visitCandidate(app.standardizedFileURL.path)
            applications.append(app)
          }
        }
      }
      for app in applications {
        try budget.visit()
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard !CleanupExclusions.overlaps(info, paths: environment.excludedPaths),
          AppUninstaller.isUnredirected(info, home: root.path),
          let plist = try? SystemCheck.readPropertyList(info),
          let identifier = plist["CFBundleIdentifier"] as? String,
          isBundleIdentifier(identifier)
        else { continue }
        identifiers.insert(identifier)
      }
    }
    return identifiers
  }

  private static func periodic(
    environment: CleanEnvironment, sources: Sources, budget: ScanBudget
  ) async throws -> SystemCheckFinding {
    try Task.checkCancellation()
    guard environment.isToolAvailable("periodic") else {
      return SystemCheckFinding(
        id: "periodicRecords", title: tr("周期维护记录"), status: .notApplicable,
        detail: tr("当前系统未提供 periodic 工具；不根据系统版本推测维护状态。"))
    }
    var evidence: [String] = []
    var complete = true
    var stale = false
    for path in sources.periodicLogs {
      do {
        let result = try await inspect(
          "stat", ["-f", "%HT:%m", path], environment: environment, budget: budget)
        let fields = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
          .split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[0] == "Regular File",
          let timestamp = UInt64(fields[1]),
          Double(timestamp) <= environment.now().timeIntervalSince1970
        else { throw InspectionError.output }
        let age = environment.now().timeIntervalSince1970 - Double(timestamp)
        stale = stale || age >= 7 * 86_400
        evidence.append(URL(fileURLWithPath: path).lastPathComponent + " · " + String(timestamp))
      } catch is CancellationError { throw CancellationError() } catch {
        try Task.checkCancellation()
        complete = false
      }
    }
    if sources.periodicLogs.isEmpty { complete = false }
    return SystemCheckFinding(
      id: "periodicRecords", title: tr("周期维护记录"),
      status: !complete ? .unchecked : stale ? .optional : .normal,
      isComplete: complete,
      detail: tr("只读 daily、weekly、monthly 记录的修改时间；超过 7 天仅供审阅，记录新鲜也不能证明维护成功。"),
      evidence: evidence)
  }

  struct LoginItem: Sendable {
    let name: String
    let path: String
  }

  /// Mole tasks.sh:1593 的同一独立来源；SystemEvents.sdef 定义 logi、pnam、ppth。
  /// 直接读取文本属性，既不执行脚本，也不将路径转换为 alias 或挂载外部卷。
  private static func readLoginItems(timeout: TimeInterval) throws -> [LoginItem] {
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
    guard let descriptor = target.aeDesc else { throw InspectionError.unavailable }
    // AppleEvents.h：false 不请求同意；目标未运行时返回 procNotFound，不启动 System Events。
    guard
      AEDeterminePermissionToAutomateTarget(
        descriptor, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), false) == noErr
    else { throw InspectionError.unavailable }
    let items = NSAppleEventDescriptor.record()
    items.setDescriptor(
      NSAppleEventDescriptor(typeCode: 0x6c6f_6769), forKeyword: AEKeyword(keyAEDesiredClass))
    items.setDescriptor(
      NSAppleEventDescriptor(enumCode: OSType(formAbsolutePosition)),
      forKeyword: AEKeyword(keyAEKeyForm))
    guard
      let all = NSAppleEventDescriptor(
        descriptorType: DescType(typeAbsoluteOrdinal), data: Data([0x61, 0x6c, 0x6c, 0x20]))
    else { throw InspectionError.output }
    items.setDescriptor(all, forKeyword: AEKeyword(keyAEKeyData))
    items.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
    guard let itemSpecifier = items.coerce(toDescriptorType: DescType(typeObjectSpecifier)) else {
      throw InspectionError.output
    }
    let properties = NSAppleEventDescriptor.record()
    properties.setDescriptor(
      NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
    properties.setDescriptor(
      NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
    properties.setDescriptor(
      NSAppleEventDescriptor(typeCode: 0x7041_4c4c), forKeyword: AEKeyword(keyAEKeyData))
    properties.setDescriptor(itemSpecifier, forKeyword: AEKeyword(keyAEContainer))
    guard let propertySpecifier = properties.coerce(toDescriptorType: DescType(typeObjectSpecifier))
    else {
      throw InspectionError.output
    }
    let event = NSAppleEventDescriptor(
      eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
      targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(propertySpecifier, forKeyword: AEKeyword(keyDirectObject))
    let options = NSAppleEventDescriptor.SendOptions(
      rawValue:
        UInt(kAEWaitReply | kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent))
    let reply = try event.sendEvent(options: options, timeout: timeout)
    return try loginItemSnapshot(reply)
  }

  static func loginItemSnapshot(_ reply: NSAppleEventDescriptor) throws -> [LoginItem] {
    if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)) {
      guard error.descriptorType == DescType(typeSInt32), error.int32Value == 0 else {
        throw InspectionError.output
      }
    }
    guard let list = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
      list.descriptorType == DescType(typeAEList), list.numberOfItems <= 100,
      list.data.count <= 65_536
    else { throw InspectionError.output }
    var items: [LoginItem] = []
    for index in 0..<list.numberOfItems {
      guard let record = list.atIndex(index + 1),
        record.descriptorType == DescType(typeAERecord),
        let nameValue = record.forKeyword(0x706e_616d),
        let pathValue = record.forKeyword(0x7070_7468),
        [DescType(typeUnicodeText), DescType(typeUTF8Text), DescType(typeChar)]
          .contains(nameValue.descriptorType),
        [DescType(typeUnicodeText), DescType(typeUTF8Text), DescType(typeChar)]
          .contains(pathValue.descriptorType),
        let name = nameValue.stringValue, let path = pathValue.stringValue,
        !name.isEmpty, name.count <= 500, path.count <= 2048,
        ![name, path].contains(where: {
          $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        })
      else { throw InspectionError.output }
      items.append(LoginItem(name: name, path: path))
    }
    return items
  }

  private static func loginItems(
    environment: CleanEnvironment, sources: Sources, budget: ScanBudget
  ) async throws -> SystemCheckFinding {
    var evidence: [String] = []
    var missingTarget = false
    do {
      try budget.check()
      let remaining = ContinuousClock.now.duration(to: budget.deadline)
      let timeout = min(
        5,
        Double(remaining.components.seconds)
          + Double(remaining.components.attoseconds) / 1e18)
      guard timeout > 0 else { throw InspectionError.unavailable }
      let items = try sources.loginItems(timeout)
      guard items.count <= 100 else { throw InspectionError.output }
      for item in items {
        try budget.visit()
        let name = item.name
        let path = item.path
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // 只核对声明的本地应用目录；不探测网络、未挂载卷或任意登录脚本路径。
        guard path.hasPrefix("/"), !path.hasPrefix("/Volumes/"),
          sources.applicationDirectories.contains(where: {
            url.path.hasPrefix($0.path + "/")
              && AppUninstaller.isUnredirected(url.deletingLastPathComponent(), home: $0.path)
          }),
          !CleanupExclusions.overlaps(url, paths: environment.excludedPaths)
        else {
          if evidence.count < 20 { evidence.append(name + " · " + tr("目标未在本次范围内核对")) }
          continue
        }
        var info = stat()
        if url.path.withCString({ lstat($0, &info) }) == 0 {
          if info.st_mode & S_IFMT == S_IFLNK {
            if evidence.count < 20 { evidence.append(name + " · " + tr("目标未在本次范围内核对")) }
          } else if evidence.count < 20 {
            evidence.append(name + " · " + tr("记录目标存在"))
          }
        } else if [ENOENT, ENOTDIR].contains(errno) {
          missingTarget = true
          if evidence.count < 20 { evidence.append(name + " · " + tr("记录目标不存在，可能已移动")) }
        } else {
          if evidence.count < 20 { evidence.append(name + " · " + tr("目标未在本次范围内核对")) }
        }
      }
      return SystemCheckFinding(
        id: "loginItems", title: tr("登录项目独立来源"),
        status: missingTarget ? .attention : .optional, isComplete: false,
        detail: tr("仅在已有自动化权限时只读 System Events 登录项目；不含现代后台项目，不以启动代理替代，不判断应用已卸载。"),
        evidence: evidence)
    } catch is CancellationError { throw CancellationError() } catch {
      try Task.checkCancellation()
      return SystemCheckFinding(
        id: "loginItems", title: tr("登录项目独立来源"), status: .unchecked, isComplete: false,
        detail: tr("登录项目来源未授权、未运行或读取失败；不弹出授权，不将未知状态视为空列表。"),
        evidence: evidence)
    }
  }

  private static func isBundleIdentifier(_ identifier: String) -> Bool {
    let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
    return identifier.utf8.count <= 255 && parts.count >= 2
      && parts.allSatisfy { part in
        !part.isEmpty
          && part.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0)
              || (48...57).contains($0) || $0 == 45
          }
      }
  }

  private static func unsignedInteger(_ output: String) -> UInt64? {
    let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return UInt64(value)
  }

  /// 每个父路径先校验再检查缺失，不能把重定向或无权限伪装成对象不存在。
  private static func missing(_ url: URL, environment: CleanEnvironment) throws -> Bool {
    guard !CleanupExclusions.overlaps(url, paths: environment.excludedPaths) else {
      throw InspectionError.unsafe
    }
    let home = URL(fileURLWithPath: environment.home).standardizedFileURL
    guard url.path.hasPrefix(home.path + "/") else { throw InspectionError.unsafe }
    var current = home
    for component in url.path.dropFirst(home.path.count + 1).split(separator: "/") {
      current.appendPathComponent(String(component))
      var info = stat()
      if current.path.withCString({ lstat($0, &info) }) != 0 {
        if errno == ENOENT { return true }
        throw InspectionError.unavailable
      }
      guard info.st_mode & S_IFMT != S_IFLNK else { throw InspectionError.unsafe }
    }
    return false
  }

  private static func missingApplicationDirectory(
    _ url: URL, environment: CleanEnvironment
  ) throws -> Bool {
    guard !CleanupExclusions.overlaps(url, paths: environment.excludedPaths) else {
      throw InspectionError.unsafe
    }
    if url.path.hasPrefix(URL(fileURLWithPath: environment.home).standardizedFileURL.path + "/") {
      return try missing(url, environment: environment)
    }
    var info = stat()
    guard url.path.withCString({ lstat($0, &info) }) == 0 else {
      if errno == ENOENT { return true }
      throw InspectionError.unavailable
    }
    guard info.st_mode & S_IFMT == S_IFDIR else { throw InspectionError.unsafe }
    return false
  }

  private static func inspect(
    _ tool: String, _ arguments: [String], environment: CleanEnvironment, budget: ScanBudget
  ) async throws -> ToolRunResult {
    try Task.checkCancellation()
    try budget.visit()
    guard environment.isToolAvailable(tool) else { throw InspectionError.unavailable }
    // inspectTool 超限会拒绝整个输出；外层共享截止时间限制整次深入检查。
    let deadline = min(budget.deadline, ContinuousClock.now + .seconds(5))
    let result = try await withThrowingTaskGroup(of: ToolRunResult.self) { group in
      group.addTask { try await environment.inspectTool(tool, arguments) }
      group.addTask {
        try await ContinuousClock().sleep(until: deadline)
        throw InspectionError.unavailable
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw InspectionError.unavailable }
      return result
    }
    try Task.checkCancellation()
    try budget.check()
    // 配置查询采用比通用检查更小的解析预算，拒绝意外庞大的工具输出。
    guard result.status == 0, result.output.utf8.count < 8192 else {
      throw InspectionError.output
    }
    return result
  }
}
