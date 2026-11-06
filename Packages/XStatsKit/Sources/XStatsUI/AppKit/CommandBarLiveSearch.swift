// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin
import Localization
import Metrics
import UniformTypeIdentifiers

enum CommandBarLiveRequest: Equatable {
  case files(String)
  case revealFiles(String)
  case processes(String)

  init?(_ query: String) {
    guard query.utf8.prefix(2049).count <= 2048, query.count <= 256 else { return nil }
    let words = query.split(maxSplits: 1, whereSeparator: \.isWhitespace)
    let argument =
      words.dropFirst().first.map(String.init)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    switch words.first?.lowercased() {
    case "open": self = .files(argument)
    case "find": self = .revealFiles(argument)
    case "kill": self = .processes(argument)
    default: return nil
    }
  }
}

@MainActor
final class CommandBarFileSearch {
  private var query: NSMetadataQuery?
  private var observers: [NSObjectProtocol] = []
  private var timeout: Task<Void, Never>?
  private var completion: (([AppCommand]) -> Void)?
  private var pinyinQuery: NSMetadataQuery?
  private var pinyinTask: Task<Void, Never>?
  private var generation = UUID()
  private var directResults: [AppCommand] = []
  private var pinyinResults: [AppCommand] = []
  private var pinyinIndex: CommandBarSearch?
  var isRunning: Bool { query != nil || pinyinQuery != nil || pinyinTask != nil }
  nonisolated static let limit = 50
  static let pinyinCandidateLimit = 5_000

  nonisolated static func supportsPinyin(_ text: String) -> Bool {
    text.utf8.contains { (65...90).contains($0) || (97...122).contains($0) }
      && text.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0)
          || "._-".unicodeScalars.contains($0)
      }
  }

  static func predicate(_ text: String) -> NSPredicate? {
    guard text.utf8.prefix(2049).count <= 2048, text.count <= 256 else { return nil }
    let terms = text.split(whereSeparator: \.isWhitespace)
    guard !terms.isEmpty,
      terms.contains(where: { $0.count >= 2 || $0.unicodeScalars.contains { !$0.isASCII } })
    else { return nil }
    let predicates = terms.map {
      NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, String($0))
    }
    // Spotlight 拒绝只有一个子项的 AND；单词查询必须直接传比较谓词。
    return predicates.count == 1
      ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
  }

  func start(_ text: String, completion: @escaping ([AppCommand]) -> Void) {
    stop(keepingPinyinIndex: true)
    guard let predicate = Self.predicate(text) else {
      completion([])
      return
    }
    let query = NSMetadataQuery()
    query.predicate = predicate
    query.searchScopes = [NSMetadataQueryUserHomeScope]
    query.sortDescriptors = [
      NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)
    ]
    query.valueListAttributes = [NSMetadataItemFSNameKey, NSMetadataItemContentTypeKey]
    self.query = query
    self.completion = completion
    if Self.supportsPinyin(text), pinyinIndex != nil {
      matchPinyin([], text: text)
    } else if Self.supportsPinyin(text) {
      let candidates = NSMetadataQuery()
      candidates.predicate = NSPredicate(format: "%K != %@", NSMetadataItemFSNameKey, "")
      let home = FileManager.default.homeDirectoryForCurrentUser
      candidates.searchScopes = ["Desktop", "Documents", "Downloads"].map {
        home.appendingPathComponent($0).path
      }
      candidates.sortDescriptors = query.sortDescriptors
      pinyinQuery = candidates
      let candidateIdentifier = ObjectIdentifier(candidates)
      observers.append(
        NotificationCenter.default.addObserver(
          forName: .NSMetadataQueryDidFinishGathering, object: candidates, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            guard self?.pinyinQuery.map(ObjectIdentifier.init) == candidateIdentifier else {
              return
            }
            self?.deliverPinyin(text)
          }
        })
      if !candidates.start() { pinyinQuery = nil }
    }
    let identifier = ObjectIdentifier(query)
    observers += [
      .NSMetadataQueryGatheringProgress, .NSMetadataQueryDidFinishGathering,
    ].map { name in
      NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) {
        [weak self] notification in
        let finished = notification.name == .NSMetadataQueryDidFinishGathering
        MainActor.assumeIsolated {
          guard self?.query.map(ObjectIdentifier.init) == identifier else { return }
          self?.deliver(finished: finished)
        }
      }
    }
    guard query.start() else {
      Log.app.error("Command bar metadata query could not start")
      stop()
      completion([])
      return
    }
    let generation = generation
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      guard !Task.isCancelled, self?.generation == generation else { return }
      self?.deliver(finished: true)
      self?.deliverPinyin(text)
    }
  }

  func stop(keepingPinyinIndex: Bool = false) {
    timeout?.cancel()
    timeout = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers = []
    query?.stop()
    query = nil
    pinyinQuery?.stop()
    pinyinQuery = nil
    pinyinTask?.cancel()
    pinyinTask = nil
    generation = UUID()
    directResults = []
    pinyinResults = []
    if !keepingPinyinIndex { pinyinIndex = nil }
    completion = nil
  }

  static func command(path: String, name: String, contentType: String?) -> AppCommand? {
    let components = path.split(separator: "/")
    guard path.hasPrefix("/"), !components.contains(where: { $0.hasPrefix(".") }),
      !components.contains("node_modules"), !components.contains(".build"),
      !components.dropLast().contains(where: { $0.hasSuffix(".app") })
    else { return nil }
    let directory = contentType == UTType.folder.identifier
    let url = URL(fileURLWithPath: path, isDirectory: directory)
    let suffix = url.pathExtension.uppercased()
    return AppCommand(
      id: "file.\(path)", title: name, symbol: directory ? "folder" : "doc",
      keywords: "", action: .openFile(url),
      subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
      badge: directory ? "文件夹" : (suffix.isEmpty ? "文件" : suffix))
  }

  private func deliver(finished: Bool) {
    guard let query else { return }
    query.disableUpdates()
    var commands: [AppCommand] = []
    // Spotlight 可能命中大量源码；每批只检查有界数量的元数据，不读取文件内容或图标。
    for index in 0..<min(query.resultCount, 500) {
      guard let item = query.result(at: index) as? NSMetadataItem,
        let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
        let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String,
        let command = Self.command(
          path: path, name: name,
          contentType: item.value(forAttribute: NSMetadataItemContentTypeKey) as? String)
      else { continue }
      commands.append(command)
      if commands.count >= Self.limit { break }
    }
    directResults = commands
    if finished || commands.count >= Self.limit {
      query.stop()
      self.query = nil
    } else {
      query.enableUpdates()
    }
    publish()
  }

  private func deliverPinyin(_ text: String) {
    guard let candidates = pinyinQuery else { return }
    candidates.disableUpdates()
    var commands: [AppCommand] = []
    for index in 0..<min(candidates.resultCount, Self.pinyinCandidateLimit) {
      guard let item = candidates.result(at: index) as? NSMetadataItem,
        let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
        let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String,
        name.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }),
        let command = Self.command(
          path: path, name: name,
          contentType: item.value(forAttribute: NSMetadataItemContentTypeKey) as? String)
      else { continue }
      commands.append(command)
    }
    candidates.stop()
    pinyinQuery = nil
    matchPinyin(commands, text: text)
  }

  private func matchPinyin(_ commands: [AppCommand], text: String) {
    let generation = generation
    let cachedIndex = pinyinIndex
    pinyinTask = Task { [weak self] in
      let worker = Task.detached(priority: .userInitiated) {
        let index =
          cachedIndex ?? CommandBarSearch(commands: commands, supportsParameterQueries: false)
        return (index, Array(index.results(for: text).prefix(Self.limit)))
      }
      let (index, matches) = await withTaskCancellationHandler {
        await worker.value
      } onCancel: {
        worker.cancel()
      }
      guard !Task.isCancelled, let self, self.generation == generation else { return }
      self.pinyinTask = nil
      self.pinyinIndex = index
      self.pinyinResults = matches
      self.publish()
    }
  }

  private func publish() {
    let directIDs = Set(directResults.map(\.id))
    completion?(
      Array(
        (directResults + pinyinResults.filter { !directIDs.contains($0.id) }).prefix(Self.limit)))
    if !isRunning {
      timeout?.cancel()
      timeout = nil
      observers.forEach(NotificationCenter.default.removeObserver)
      observers = []
    }
  }
}

@MainActor
enum CommandBarFileActions {
  static func open(_ url: URL, using application: URL) {
    NSWorkspace.shared.open(
      [url], withApplicationAt: application, configuration: .init()
    ) { _, error in
      guard let error else { return }
      let description = String(error.localizedDescription.prefix(1024))
      Task { @MainActor in
        Log.app.error("Command bar open with failed: \(description, privacy: .private)")
        let alert = NSAlert()
        alert.messageText = tr("无法打开项目")
        alert.informativeText = tr("项目可能已移动或不可用，请重新搜索后再试。")
        alert.runModal()
      }
    }
  }

  static func chooseApplication(for url: URL) {
    let picker = NSOpenPanel()
    picker.title = tr("打开方式")
    picker.allowedContentTypes = [.applicationBundle]
    picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    picker.allowsMultipleSelection = false
    picker.canChooseDirectories = false
    picker.begin { response in
      guard response == .OK, let application = picker.url else { return }
      open(url, using: application)
    }
  }

  static func confirmTrash(_ url: URL) {
    let alert = NSAlert()
    alert.messageText = tr("将“\(url.lastPathComponent)”移到废纸篓？")
    alert.alertStyle = .warning
    alert.addButton(withTitle: tr("取消"))
    alert.addButton(withTitle: tr("移到废纸篓"))
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    NSWorkspace.shared.recycle([url]) { _, error in
      guard let error else {
        Log.app.notice("Command bar moved selected file to Trash")
        return
      }
      let description = String(error.localizedDescription.prefix(1024))
      Task { @MainActor in
        Log.app.error("Command bar trash failed: \(description, privacy: .private)")
        let failure = NSAlert()
        failure.messageText = tr("无法移到废纸篓：\(description)")
        failure.runModal()
      }
    }
  }
}

struct CommandBarProcessTarget: Equatable, Sendable {
  struct Identity: Equatable, Sendable {
    let seconds: UInt64
    let microseconds: UInt64
    let uid: UInt32
    let parent: Int32

    static func read(_ pid: Int32) -> Self? {
      var info = proc_bsdinfo()
      guard
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
          == Int32(MemoryLayout<proc_bsdinfo>.size)
      else { return nil }
      return Self(
        seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec,
        uid: info.pbi_uid, parent: Int32(info.pbi_ppid))
    }
  }

  let process: ProcessUsage
  let identity: Identity
  let ports: [Int]

  func matches(_ query: String) -> Bool {
    query.split(whereSeparator: \.isWhitespace).allSatisfy { term in
      if term.hasPrefix(":") {
        return ports.contains { ":\($0)".hasPrefix(term) }
      }
      if term.utf8.allSatisfy({ (48...57).contains($0) }) {
        return String(process.pid) == term
      }
      return process.name.localizedStandardContains(String(term))
    }
  }

  func command(language: AppLanguage = L10n.language) -> AppCommand {
    let memory = process.memory.formatted(
      .byteCount(style: .memory).locale(Locale(identifier: language.resolved.languageCode)))
    var parts = ["PID \(process.pid)", memory]
    if !ports.isEmpty {
      parts.append(
        L10n.translate("监听", language: language) + " "
          + ports.map { ":\($0)" }.joined(separator: ", "))
    }
    return AppCommand(
      id: "process.\(process.pid).\(identity.seconds).\(identity.microseconds)",
      title: process.name, symbol: "terminal", keywords: "", action: .terminateProcess(self),
      subtitle: parts.joined(separator: " · "), badge: "进程")
  }

  static func snapshot(excluding: Set<Int32>) throws -> [Self] {
    var sampler = ProcessSampler()
    let processes = sampler.sample()
    try Task.checkCancellation()
    let ports = Dictionary(grouping: PortSampler.sample() ?? [], by: \.pid)
    try Task.checkCancellation()
    return processes.compactMap { process -> Self? in
      guard !Task.isCancelled, process.isOwned, process.uid == getuid(),
        process.pid > 1, process.pid != getpid(), !excluding.contains(process.pid),
        !ProcessActions.protectedNames.contains(process.name),
        let identity = Identity.read(process.pid), identity.uid == getuid(),
        identity.parent != getpid()
      else { return nil }
      var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
      guard proc_pidpath(process.pid, &pathBuffer, UInt32(pathBuffer.count)) > 0,
        process.executablePath
          == String(
            decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
        Identity.read(process.pid) == identity
      else { return nil }
      return Self(
        process: process, identity: identity,
        ports: Array(
          Set(
            (ports[process.pid] ?? []).filter {
              $0.state == .listening && $0.transport == .tcp
            }.map(\.localPort))
        ).sorted())
    }.sorted {
      if $0.ports.isEmpty != $1.ports.isEmpty { return !$0.ports.isEmpty }
      return ($0.process.memory, $0.process.pid) > ($1.process.memory, $1.process.pid)
    }
  }
}

enum CommandBarProcessActions {
  static func canTerminate(
    _ target: CommandBarProcessTarget, current: CommandBarProcessTarget.Identity?
  ) -> Bool {
    target.process.pid > 1 && target.process.pid != getpid()
      && target.process.uid == getuid() && target.identity.uid == getuid()
      && !ProcessActions.protectedNames.contains(target.process.name)
      && target.identity == current
  }

  @MainActor
  static func confirm(_ target: CommandBarProcessTarget, force: Bool = false) {
    let alert = NSAlert()
    alert.messageText = tr("结束“\(target.process.name)”（PID \(target.process.pid)）？")
    alert.informativeText = tr("会断开它占用的端口与连接，未保存的内容可能会丢失。强制退出会立即结束，不给应用保存的机会。")
    alert.alertStyle = .warning
    alert.addButton(withTitle: tr("取消"))
    alert.addButton(withTitle: tr(force ? "强制退出" : "结束进程"))
    guard alert.runModal() == .alertSecondButtonReturn else { return }
    let error = terminate(target, force: force)
    if let error {
      let failure = NSAlert()
      failure.messageText = error
      failure.runModal()
    }
  }

  @MainActor
  static func terminate(_ target: CommandBarProcessTarget, force: Bool) -> String? {
    guard canTerminate(target, current: .read(target.process.pid)) else {
      return tr("未找到目标进程，它可能已退出")
    }
    let sent: Bool
    var errorCode: Int32?
    if let app = NSRunningApplication(processIdentifier: target.process.pid) {
      sent = force ? app.forceTerminate() : app.terminate()
    } else {
      sent = kill(target.process.pid, force ? SIGKILL : SIGTERM) == 0
      if !sent { errorCode = errno }
    }
    if let errorCode {
      Log.app.error(
        "Command bar could not signal pid \(target.process.pid, privacy: .public), errno=\(errorCode, privacy: .public)"
      )
      return tr("结束 \(target.process.name) 失败：\(String(cString: strerror(errorCode)))")
    }
    Log.app.notice(
      "Command bar quit pid \(target.process.pid, privacy: .public), force=\(force, privacy: .public), sent=\(sent, privacy: .public)"
    )
    return sent ? nil : tr("应用拒绝退出，可以试试强制退出")
  }
}
