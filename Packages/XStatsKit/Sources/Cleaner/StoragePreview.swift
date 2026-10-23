// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Localization
import SQLite3

/// 独立、按需的存储审阅；只返回检查证据，不生成 CleanRule 或执行计划。
public enum StoragePreview {
  /// home 仅指定用户目录；生产入口仍审阅固定系统目录与本地卷。
  /// installedIdentifiers 为已加载的有限清单，nil 表示尚未检查应用数据归属。
  @concurrent
  public static func scan(
    home: String = NSHomeDirectory(), installedIdentifiers: Set<String>? = nil
  ) async throws -> [SystemCheckFinding] {
    try await scan(
      home: home, installedIdentifiers: installedIdentifiers,
      systemLibrary: URL(fileURLWithPath: "/Library"),
      localVolumes: localBackupVolumes,
      budget: ScanBudget(
        limits: ScanLimits(maxEntries: 20_000, maxDuration: 15, maxCandidates: 200)))
  }

  /// 系统目录和卷发现均显式注入；夹具不经过真实 /Library 或内核挂载表。
  @concurrent
  static func scan(
    home: String, installedIdentifiers: Set<String>?, systemLibrary: URL,
    localVolumes: @Sendable (ScanBudget) throws -> [URL], budget: ScanBudget
  ) async throws -> [SystemCheckFinding] {
    try Task.checkCancellation()
    // 有限清单只支持待审阅建议，先于体积扫描，避免大目录耗尽预算后始终无法检查。
    var findings = [
      try applicationDataReview(
        home: home, installedIdentifiers: installedIdentifiers, budget: budget)
    ]
    let root = URL(fileURLWithPath: home)
    for (id, title, path, quarantine) in [
      ("messages", tr("信息数据库"), "Library/Messages/chat.db", false),
      ("safariHistory", tr("Safari 历史数据库"), "Library/Safari/History.db", false),
      ("safariTopSites", tr("Safari 常用网站数据库"), "Library/Safari/TopSites.db", false),
      (
        "quarantine", tr("下载隔离记录"),
        "Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2", true
      ),
      (
        "notifications", tr("通知数据库"),
        "Library/Group Containers/group.com.apple.usernoted/db2/db", false
      ),
      ("coreduet", tr("使用记录数据库"), "Library/Application Support/Knowledge/knowledgeC.db", false),
    ] {
      try Task.checkCancellation()
      findings.append(
        databaseFinding(
          id: id, title: title, url: root.appendingPathComponent(path),
          quarantine: quarantine, budget: budget))
    }
    findings += try mailDatabases(home: home, budget: budget)

    // 固定路径来自 Mole 2ef974753572 的 clean/user.sh 与 clean/system.sh。
    // 不读取 HF_HOME 等重定向，不扩展为全盘发现；大目录预算不足时不发布部分大小。
    let groups: [(String, String, String, [URL])] = [
      (
        "systemCaches", tr("系统缓存与更新"),
        tr("仅审阅系统管理目录占用，不判断过期或可回收；更新状态未知。"),
        [
          systemLibrary.appendingPathComponent("Caches"),
          systemLibrary.appendingPathComponent("Updates"),
          root.appendingPathComponent("Library/Updates"),
        ]
      ),
      (
        "rosetta", tr("Rosetta 数据"),
        tr("仅审阅固定 Rosetta 缓存位置，不判断是否仍被系统使用。"),
        [
          systemLibrary.appendingPathComponent("Apple/usr/share/rosetta/rosetta_update_bundle"),
          root.appendingPathComponent("Library/Caches/com.apple.rosetta.update"),
        ]
      ),
      (
        "deviceBackups", tr("设备备份"),
        tr("备份是用户数据，不是固件或缓存；请在设备管理或空间分析中审阅。"),
        [root.appendingPathComponent("Library/Application Support/MobileSync/Backup")]
      ),
      (
        "virtualMachines", tr("虚拟机与虚拟磁盘"),
        tr("仅审阅固定虚拟机数据目录；使用与挂载状态未知，不判断闲置。请复用空间分析入口。"),
        [
          "Library/Containers/com.docker.docker/Data", ".lima", "OrbStack",
          "Library/Application Support/Claude/claude-code-vm",
        ].map { root.appendingPathComponent($0) }
      ),
      (
        "aiModels", tr("AI 模型数据"),
        tr("模型数据与虚拟磁盘分开审阅，不判断闲置；其他位置请复用 AI 数据专项或空间分析入口。"),
        [".lmstudio/models", ".cache/huggingface"].map { root.appendingPathComponent($0) }
      ),
      (
        "metadata", tr("Finder 元数据与最近项目"),
        tr("仅审阅主目录及桌面、文稿、下载目录顶层的 Finder 元数据和共享列表占用，不读取最近文档内容。"),
        ["", "Desktop/", "Documents/", "Downloads/"].map {
          root.appendingPathComponent($0 + ".DS_Store")
        } + [root.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")]
      ),
    ]
    for (id, title, detail, paths) in groups {
      try Task.checkCancellation()
      findings.append(
        storageGroup(id: id, title: title, detail: detail, paths: paths, budget: budget))
    }
    findings.append(try firmware(home: home, budget: budget))
    findings.append(try orbStack(home: home, budget: budget))
    do {
      try budget.check()
      findings.append(try timeMachine(volumes: localVolumes(budget), budget: budget))
    } catch {
      try Task.checkCancellation()
      findings.append(unknown(id: "timeMachine", title: tr("Time Machine 备份审阅"), paths: []))
    }
    try Task.checkCancellation()
    return findings
  }

  struct DatabaseObservation {
    let mainBytes: UInt64
    let freeBytes: UInt64
    let sidecarBytes: UInt64
    let recordCount: Int64?
    let isComplete: Bool
  }

  /// 仅解析主库的 100 字节文件头。空闲页是主库估算，不是当前逻辑库或可释放空间。
  static func database(
    at url: URL, countQuarantine: Bool = false, snapshotLimit: Int = 16 * 1024 * 1024,
    budget: ScanBudget
  ) throws -> DatabaseObservation {
    try budget.visitCandidate(url.path)
    let (header, before) = try readFile(url, limit: 100, prefixOnly: true, budget: budget)
    guard header.count == 100, header.prefix(16) == Data("SQLite format 3\0".utf8) else {
      throw ReviewError.invalidData
    }
    let rawPageSize = UInt64(header[16]) << 8 | UInt64(header[17])
    let pageSize = rawPageSize == 1 ? 65_536 : rawPageSize
    guard pageSize >= 512, pageSize <= 65_536, pageSize.nonzeroBitCount == 1 else {
      throw ReviewError.invalidData
    }
    let pages = word(header, at: 28)
    let freePages = word(header, at: 36)
    guard pages > 0, freePages <= pages,
      pages * pageSize == UInt64(before.size),
      word(header, at: 24) == word(header, at: 92),
      [1, 2].contains(header[18]), [1, 2].contains(header[19])
    else { throw ReviewError.invalidData }
    let sidecars = try ["-wal", "-shm", "-journal"].map {
      try information(URL(fileURLWithPath: url.path + $0), regularOnly: true, budget: budget)
    }
    var sidecarBytes: UInt64 = 0
    for information in sidecars.compactMap({ $0 }) {
      let sum = sidecarBytes.addingReportingOverflow(UInt64(information.size))
      guard !sum.overflow else { throw ReviewError.invalidData }
      sidecarBytes = sum.partialValue
    }
    // 即便 WAL 当前为空或已消失，WAL 模式主库也不能被描述成当前完整快照。
    var complete = header[18] == 1 && header[19] == 1 && sidecars.allSatisfy { $0 == nil }
    var count: Int64?
    if countQuarantine, complete {
      do {
        let (snapshot, snapshotInfo) = try readFile(
          url, limit: max(0, snapshotLimit), budget: budget)
        guard snapshotInfo == before else { throw ReviewError.changed }
        count = try quarantineCount(in: snapshot, budget: budget)
      } catch {
        try Task.checkCancellation()
        complete = false
      }
    }
    let after = try information(url, regularOnly: true, budget: budget)
    let afterSidecars = try ["-wal", "-shm", "-journal"].map {
      try information(URL(fileURLWithPath: url.path + $0), regularOnly: true, budget: budget)
    }
    if before != after || sidecars != afterSidecars {
      complete = false
      count = nil
    }
    return DatabaseObservation(
      mainBytes: UInt64(before.size), freeBytes: freePages * pageSize,
      sidecarBytes: sidecarBytes, recordCount: count, isComplete: complete)
  }

  /// SQLite 只接触内存副本，不打开源数据库，不会创建源库的 WAL/SHM。
  private static func quarantineCount(in snapshot: Data, budget: ScanBudget) throws -> Int64 {
    var bytes = snapshot
    return try bytes.withUnsafeMutableBytes { buffer in
      var database: OpaquePointer?
      guard
        sqlite3_open_v2(
          ":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
          nil
        ) == SQLITE_OK, let database
      else {
        sqlite3_close(database)
        throw ReviewError.invalidData
      }
      defer { sqlite3_close(database) }
      guard
        sqlite3_deserialize(
          database, "main", buffer.bindMemory(to: UInt8.self).baseAddress,
          Int64(buffer.count), Int64(buffer.count), UInt32(SQLITE_DESERIALIZE_READONLY)
        ) == SQLITE_OK
      else { throw ReviewError.invalidData }
      sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 1_048_576)
      sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 1024)
      sqlite3_limit(database, SQLITE_LIMIT_ATTACHED, 0)
      sqlite3_progress_handler(
        database, 500,
        { context in
          guard let context else { return 1 }
          let budget = Unmanaged<ScanBudget>.fromOpaque(context).takeUnretainedValue()
          return budget.interruption == nil ? 0 : 1
        }, Unmanaged.passUnretained(budget).toOpaque())
      try budget.check()
      var schema: OpaquePointer?
      defer { sqlite3_finalize(schema) }
      // 先验证真实表及有效根页，避免同名视图或虚拟表被误报为零条记录。
      let schemaQuery = """
        SELECT 1 FROM sqlite_schema
        WHERE name='LSQuarantineEvent' AND type='table' AND rootpage>0 LIMIT 1
        """
      guard sqlite3_prepare_v2(database, schemaQuery, -1, &schema, nil) == SQLITE_OK,
        sqlite3_stmt_readonly(schema) != 0, sqlite3_step(schema) == SQLITE_ROW,
        sqlite3_step(schema) == SQLITE_DONE
      else { throw ReviewError.invalidData }
      var statement: OpaquePointer?
      defer { sqlite3_finalize(statement) }
      // 只查询数量，绝不选择下载 URL 或其他事件字段。
      guard
        sqlite3_prepare_v2(
          database, "SELECT count(*) FROM LSQuarantineEvent", -1, &statement, nil
        ) == SQLITE_OK
      else {
        throw ReviewError.invalidData
      }
      try budget.check()
      guard sqlite3_stmt_readonly(statement) != 0, sqlite3_step(statement) == SQLITE_ROW,
        sqlite3_column_type(statement, 0) == SQLITE_INTEGER
      else { throw ReviewError.invalidData }
      let count = sqlite3_column_int64(statement, 0)
      guard count >= 0, sqlite3_step(statement) == SQLITE_DONE else {
        throw ReviewError.invalidData
      }
      try budget.check()
      return count
    }
  }

  private static func databaseFinding(
    id: String, title: String, url: URL, quarantine: Bool, budget: ScanBudget
  ) -> SystemCheckFinding {
    do {
      let value = try database(at: url, countQuarantine: quarantine, budget: budget)
      var evidence = [
        url.path,
        tr("主库 \(number(value.mainBytes)) 字节"),
        tr("主库空闲页估算 \(number(value.freeBytes)) 字节（不代表可回收空间）"),
        tr("附属文件 \(number(value.sidecarBytes)) 字节"),
      ]
      if let count = value.recordCount { evidence.append(tr("隔离记录 \(number(UInt64(count))) 条")) }
      return SystemCheckFinding(
        id: "storage." + id, title: title, status: .optional, isComplete: value.isComplete,
        detail: value.isComplete
          ? tr("只读估算，不执行数据库维护；不读取下载 URL。")
          : tr("仅有主库或部分证据；日志、并发变化或读取限制使当前数据库状态未知。"),
        evidence: evidence)
    } catch {
      return unknown(id: id, title: title, paths: [url])
    }
  }

  private static func mailDatabases(home: String, budget: ScanBudget) throws -> [SystemCheckFinding]
  {
    let root = URL(fileURLWithPath: home).appendingPathComponent("Library/Mail")
    var result: [SystemCheckFinding] = []
    do {
      for version in try directories(root, budget: budget)
      where version.lastPathComponent.range(of: #"^V[0-9]+$"#, options: .regularExpression) != nil {
        let data = version.appendingPathComponent("MailData")
        for database in try directories(data, budget: budget)
        where database.lastPathComponent == "Envelope Index" {
          result.append(
            databaseFinding(
              id: "mail." + version.lastPathComponent, title: tr("邮件索引数据库"),
              url: database, quarantine: false, budget: budget))
        }
      }
      if result.isEmpty { result.append(unknown(id: "mail", title: tr("邮件索引数据库"), paths: [root])) }
    } catch {
      try Task.checkCancellation()
      result.append(unknown(id: "mail", title: tr("邮件索引数据库"), paths: [root]))
    }
    return result
  }

  static func storageGroup(
    id: String, title: String, detail: String, paths: [URL], budget: ScanBudget
  ) -> SystemCheckFinding {
    var evidence: [String] = []
    var complete = true
    for path in paths {
      guard evidence.count < 20 else {
        complete = false
        break
      }
      do {
        try budget.visitCandidate(path.path)
        guard try information(path, budget: budget) != nil else { continue }
        let size = try allocatedSize(of: path, budget: budget)
        evidence.append(path.path + " · " + tr("占用 \(number(size)) 字节"))
      } catch {
        complete = false
        evidence.append(path.path + " · " + tr("大小未知"))
      }
    }
    return SystemCheckFinding(
      id: "storage." + id, title: title,
      status: complete ? (evidence.isEmpty ? .notApplicable : .optional) : .unchecked,
      isComplete: complete, detail: detail, evidence: evidence)
  }

  private static func firmware(home: String, budget: ScanBudget) throws -> SystemCheckFinding {
    var paths: [URL] = []
    do {
      for directory in [
        "iPhone Software Updates", "iPad Software Updates", "iPod Software Updates",
        "Apple TV Software Updates",
      ] {
        let root = URL(fileURLWithPath: home).appendingPathComponent("Library/iTunes/" + directory)
        for path in try directories(root, budget: budget)
        where path.pathExtension.lowercased() == "ipsw" {
          try budget.visitCandidate(path.path)
          paths.append(path)
        }
      }
    } catch {
      try Task.checkCancellation()
      return unknown(id: "firmware", title: tr("设备固件"), paths: paths)
    }
    return storageGroup(
      id: "firmware", title: tr("设备固件"),
      detail: tr("仅审阅 iTunes 固定目录中的 IPSW 固件，与设备备份分开；不判断是否仍有需要。"),
      paths: paths, budget: budget)
  }

  private static func orbStack(home: String, budget: ScanBudget) throws -> SystemCheckFinding {
    do {
      let groups = URL(fileURLWithPath: home).appendingPathComponent("Library/Group Containers")
      let paths = try directories(groups, budget: budget)
        .filter { $0.lastPathComponent.hasSuffix("dev.orbstack") }
        .map {
          let data = $0.appendingPathComponent("data")
          try budget.visitCandidate(data.path)
          return data
        }
      return storageGroup(
        id: "orbStack", title: tr("OrbStack 虚拟机数据"),
        detail: tr("仅审阅固定虚拟机数据目录；使用与挂载状态未知，不判断闲置。请复用空间分析入口。"),
        paths: paths, budget: budget)
    } catch {
      try Task.checkCancellation()
      return unknown(id: "orbStack", title: tr("OrbStack 虚拟机数据"), paths: [])
    }
  }

  /// 输入只是 UI 已加载的有限清单；名称像 Bundle ID 不能代替 metadata 的明确归属。
  static func applicationDataReview(
    home: String, installedIdentifiers: Set<String>?, budget: ScanBudget
  ) throws -> SystemCheckFinding {
    try Task.checkCancellation()
    let title = tr("应用数据归属审阅")
    guard let installedIdentifiers else {
      return SystemCheckFinding(
        id: "storage.orphans", title: title, status: .unchecked, isComplete: false,
        detail: tr("尚未加载应用清单，未检查应用数据归属；请复用选定应用的残留审阅。"))
    }
    let detail = tr("仅列有明确归属的待审阅项目：未在已加载应用清单中匹配，不代表卸载或孤儿；不是垃圾，不提供清理授权。")
    // 必须先处理全部输入保护 ID；预算不足时不能用截断清单产生未匹配建议。
    var installed = Set<String>()
    do {
      for identifier in installedIdentifiers {
        try budget.visit()
        guard AppUninstallIdentity.validIdentifier(identifier) != nil else {
          return SystemCheckFinding(
            id: "storage.orphans", title: title, status: .unchecked, isComplete: false,
            detail: detail)
        }
        installed.insert(protectedIdentifier(identifier))
      }
    } catch {
      try Task.checkCancellation()
      return SystemCheckFinding(
        id: "storage.orphans", title: title, status: .unchecked, isComplete: false,
        detail: detail)
    }
    var evidence: [String] = []
    var complete = true
    for (suffix, metadata, field) in [
      ("Library/Preferences", "", "CFBundleIdentifier"),
      (
        "Library/Containers", ".com.apple.containermanagerd.metadata.plist", "MCMMetadataIdentifier"
      ),
    ] {
      do {
        let root = URL(fileURLWithPath: home).appendingPathComponent(suffix)
        for candidate in try directories(root, budget: budget) {
          try budget.check()
          guard !metadata.isEmpty || candidate.pathExtension == "plist" else { continue }
          let identifier =
            metadata.isEmpty
            ? candidate.deletingPathExtension().lastPathComponent : candidate.lastPathComponent
          guard AppUninstallIdentity.validIdentifier(identifier) != nil else { continue }
          let protected = protectedIdentifier(identifier)
          guard !protected.hasPrefix("com.apple."), protected != "com.apple" else { continue }
          var matched = false
          for known in installed {
            try budget.visit()
            if protected == known || protected.hasPrefix(known + ".")
              || known.hasPrefix(protected + ".")
            {
              matched = true
              break
            }
          }
          guard !matched else { continue }
          let source = metadata.isEmpty ? candidate : candidate.appendingPathComponent(metadata)
          do {
            let (data, _) = try readFile(source, limit: 1_048_576, budget: budget)
            let plist =
              try PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any]
            try budget.check()
            guard plist?[field] as? String == identifier else { continue }
            guard evidence.count < 20 else {
              complete = false
              break
            }
            try budget.visitCandidate(candidate.path)
            evidence.append(identifier + " · " + candidate.path)
          } catch {
            try Task.checkCancellation()
            complete = false
          }
        }
      } catch {
        try Task.checkCancellation()
        complete = false
      }
    }
    try Task.checkCancellation()
    return SystemCheckFinding(
      id: "storage.orphans", title: title, status: complete ? .optional : .unchecked,
      isComplete: false, detail: detail,
      evidence: evidence)
  }

  /// group 与 Team ID 变体只用于扩大保护，不据此推断数据归属。
  private static func protectedIdentifier(_ identifier: String) -> String {
    var parts = identifier.split(separator: ".").map(String.init)
    if parts.first?.lowercased() == "group" { parts.removeFirst() }
    if let team = parts.first?.uppercased(), parts.count > 2, team.utf8.count == 10,
      team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) })
    {
      parts.removeFirst()
    }
    if parts.first?.lowercased() == "group" { parts.removeFirst() }
    return parts.joined(separator: ".").lowercased()
  }

  static func timeMachine(volumes: [URL], budget: ScanBudget) throws -> SystemCheckFinding {
    var evidence: [String] = []
    do {
      // 只看本地已挂载卷的旧式备份标记，不挂载卷、不扫描快照、不运行 tmutil。
      for volume in volumes {
        try budget.visitCandidate(volume.path)
        let descriptor = try openWithoutLinks(volume, budget: budget)
        defer { close(descriptor) }
        var filesystem = Darwin.statfs()
        guard fstatfs(descriptor, &filesystem) == 0,
          filesystem.f_flags & UInt32(MNT_LOCAL) != 0
        else { continue }
        let backup = volume.appendingPathComponent("Backups.backupdb")
        for machine in try directories(backup, budget: budget) {
          for item in try directories(machine, budget: budget)
          where item.lastPathComponent.lowercased().hasSuffix(".inprogress") {
            try budget.visitCandidate(item.path)
            if evidence.count < 20 { evidence.append(item.path) }
          }
        }
      }
    } catch { try Task.checkCancellation() }
    return SystemCheckFinding(
      id: "storage.timeMachine", title: tr("Time Machine 备份审阅"),
      status: .unchecked, isComplete: false,
      detail: tr("仅检查旧式本地备份标记，不能证明备份失败或已停止；请复用快照入口或 Time Machine 管理。"),
      evidence: evidence)
  }

  private static func localBackupVolumes(budget: ScanBudget) throws -> [URL] {
    try budget.check()
    // NOWAIT 只读内核挂载表；限制缓冲区，避免先打开可能阻塞的网络卷再判断类型。
    var mounts: [Darwin.statfs] = Array(repeating: Darwin.statfs(), count: 128)
    let count = mounts.withUnsafeMutableBufferPointer {
      getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<Darwin.statfs>.stride), MNT_NOWAIT)
    }
    guard count >= 0, Int(count) < mounts.count else { throw ReviewError.unsupported }
    var roots: [URL] = []
    for var mount in mounts.prefix(Int(count)) {
      try budget.visit()
      guard mount.f_flags & UInt32(MNT_LOCAL) != 0 else { continue }
      let path = withUnsafePointer(to: &mount.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
      }
      let root = URL(fileURLWithPath: path)
      guard root.deletingLastPathComponent().path == "/Volumes" else { continue }
      roots.append(root)
    }
    return roots
  }

  // MARK: - 有界、无链接的文件读取

  private enum ReviewError: Error { case invalidData, changed, unsupported }

  private struct FileInformation: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int64
    let modified: timespec
    let changed: timespec

    init(_ value: stat) {
      device = value.st_dev
      inode = value.st_ino
      size = value.st_size
      modified = value.st_mtimespec
      changed = value.st_ctimespec
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
        && lhs.modified.tv_sec == rhs.modified.tv_sec
        && lhs.modified.tv_nsec == rhs.modified.tv_nsec
        && lhs.changed.tv_sec == rhs.changed.tv_sec
        && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }
  }

  /// 每一层均以 openat + O_NOFOLLOW 打开，避免只检查叶子而穿过父目录链接。
  private static func openWithoutLinks(_ url: URL, budget: ScanBudget) throws -> Int32 {
    try budget.check()
    // standardizedFileURL 可能把 /private/var 改为 /var 系统别名；此处不得重新标准化或解析链接。
    // split 去掉尾部 "/"，只有中间组件要求目录，普通文件叶子不带 O_DIRECTORY。
    let path = url.path
    guard url.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0) else {
      throw ReviewError.unsupported
    }
    let parts = path.split(separator: "/").map(String.init)
    guard !parts.contains("."), !parts.contains("..") else { throw ReviewError.unsupported }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    do {
      for (index, part) in parts.enumerated() {
        try budget.visit()
        let flags =
          O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
          | (index < parts.count - 1 ? O_DIRECTORY : 0)
        let next = openat(descriptor, part, flags)
        guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        descriptor = next
      }
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  private static func information(
    _ url: URL, regularOnly: Bool = false, budget: ScanBudget
  ) throws -> FileInformation? {
    let descriptor: Int32
    do { descriptor = try openWithoutLinks(url, budget: budget) } catch let error as POSIXError
      where error.code == .ENOENT
    { return nil }
    defer { close(descriptor) }
    var value = stat()
    guard fstat(descriptor, &value) == 0, value.st_size >= 0,
      value.st_mode & S_IFMT == S_IFREG || (!regularOnly && value.st_mode & S_IFMT == S_IFDIR)
    else { throw ReviewError.unsupported }
    return FileInformation(value)
  }

  private static func readFile(
    _ url: URL, limit: Int, prefixOnly: Bool = false, budget: ScanBudget
  ) throws -> (Data, FileInformation) {
    let descriptor = try openWithoutLinks(url, budget: budget)
    defer { close(descriptor) }
    var before = stat()
    guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size >= 0, prefixOnly || before.st_size <= limit
    else { throw ReviewError.unsupported }
    let count = Int(min(before.st_size, Int64(limit)))
    var data = Data(count: count)
    try data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < count {
        try budget.visit()
        let read = pread(
          descriptor, buffer.baseAddress!.advanced(by: offset), min(65_536, count - offset),
          off_t(offset))
        if read < 0, errno == EINTR { continue }
        guard read > 0 else { throw ReviewError.changed }
        offset += read
      }
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, FileInformation(before) == FileInformation(after) else {
      throw ReviewError.changed
    }
    return (data, FileInformation(before))
  }

  private static func directories(_ url: URL, budget: ScanBudget) throws -> [URL] {
    let descriptor: Int32
    do { descriptor = try openWithoutLinks(url, budget: budget) } catch let error as POSIXError
      where error.code == .ENOENT
    { return [] }
    defer { close(descriptor) }
    var value = stat()
    guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else {
      throw ReviewError.unsupported
    }
    // 发现阶段消耗条目与时间预算；调用方筛选后再登记实际审阅候选。
    // 直接枚举已打开目录，避免 /dev/fd 的链接跳转。
    let children = try storageEntries(descriptor: descriptor, budget: budget)
      .filter { !$0.hasPrefix(".") }.map {
        try budget.check()
        return url.appendingPathComponent($0)
      }
    var after = stat()
    guard fstat(descriptor, &after) == 0, FileInformation(value) == FileInformation(after) else {
      throw ReviewError.changed
    }
    return children
  }

  static func allocatedSize(of url: URL, budget: ScanBudget) throws -> UInt64 {
    try budget.visitCandidate(url.path)
    let descriptor = try openWithoutLinks(url, budget: budget)
    defer { close(descriptor) }
    var identities = Set<String>()
    return try allocatedSize(
      descriptor: descriptor, depth: 0, identities: &identities, budget: budget)
  }

  private static func allocatedSize(
    descriptor: Int32, depth: Int, identities: inout Set<String>, budget: ScanBudget
  ) throws -> UInt64 {
    try budget.visit()
    var before = stat()
    guard depth <= 64, fstat(descriptor, &before) == 0 else { throw ReviewError.unsupported }
    let kind = before.st_mode & S_IFMT
    if kind == S_IFREG {
      // 与 scanAllocatedSize 相同的物理占用语义；直接 fstat 已打开对象，避免再走可替换路径。
      guard before.st_blocks >= 0, UInt64(before.st_blocks) <= UInt64.max / 512 else {
        throw ReviewError.invalidData
      }
      let identity = "\(before.st_dev):\(before.st_ino)"
      return identities.insert(identity).inserted ? UInt64(before.st_blocks) * 512 : 0
    }
    guard kind == S_IFDIR else { throw ReviewError.unsupported }
    var total: UInt64 = 0
    // children 会过滤隐藏文件，只用于可见候选发现；体积必须包含所有名称。
    for name in try storageEntries(descriptor: descriptor, budget: budget) {
      let next = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      defer { close(next) }
      let size = try allocatedSize(
        descriptor: next, depth: depth + 1, identities: &identities, budget: budget)
      let sum = total.addingReportingOverflow(size)
      guard !sum.overflow else { throw ReviewError.invalidData }
      total = sum.partialValue
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0, FileInformation(before) == FileInformation(after) else {
      throw ReviewError.changed
    }
    return total
  }

  private static func storageEntries(descriptor: Int32, budget: ScanBudget) throws -> [String] {
    try budget.check()
    let copy = dup(descriptor)
    guard copy >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard let directory = fdopendir(copy) else {
      let code = errno
      close(copy)
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
      try budget.check()
      errno = 0
      guard let entry = readdir(directory) else {
        guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        break
      }
      let name = withUnsafePointer(to: &entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
          String(validatingCString: $0)
        }
      }
      guard let name else { throw ReviewError.unsupported }
      guard name != ".", name != ".." else { continue }
      try budget.visit()
      names.append(name)
    }
    try budget.check()
    return names
  }

  private static func word(_ data: Data, at offset: Int) -> UInt64 {
    data[offset..<(offset + 4)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
  }

  private static func number(_ value: UInt64) -> String {
    value.formatted(.number.locale(L10n.locale))
  }

  private static func unknown(id: String, title: String, paths: [URL]) -> SystemCheckFinding {
    SystemCheckFinding(
      id: "storage." + id, title: title, status: .unchecked, isComplete: false,
      detail: tr("权限、路径、格式或扫描预算不足，结果未知；未执行任何修改。"),
      evidence: paths.prefix(20).map(\.path))
  }
}
