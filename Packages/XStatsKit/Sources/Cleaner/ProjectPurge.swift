// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Localization

public struct ProjectPurgeItem: Identifiable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let project: URL
    public let root: URL
    public let bytes: UInt64
    public let isRecent: Bool
    public let isCloud: Bool
    public let isWorktree: Bool
    fileprivate let identity: Identity
    fileprivate let parentIdentity: Identity
    fileprivate let rootIdentity: Identity
    fileprivate let latestModification: Date
}

public struct ProjectPurgeScan: Sendable {
    public let items: [ProjectPurgeItem]
    public let failedRoots: [URL]
    /// 含 `.git`、部署密钥或被 Git 跟踪的文件，确认不能清理
    public let protectedCount: Int
    /// 检查超时、读取失败或无法确认 Git 状态，按不确定保留
    public let unverifiedCount: Int
    /// 未安装 Xcode 命令行工具：Git 仓库内的产物无法确认是否被跟踪，全部保留
    public let developerToolsMissing: Bool

    init(items: [ProjectPurgeItem], failedRoots: [URL], protectedCount: Int = 0,
         unverifiedCount: Int = 0, developerToolsMissing: Bool = false) {
        self.items = items
        self.failedRoots = failedRoots
        self.protectedCount = protectedCount
        self.unverifiedCount = unverifiedCount
        self.developerToolsMissing = developerToolsMissing
    }

    /// 清理后只去掉已移到废纸篓的项，不必整体重扫
    public func removing(_ ids: Set<String>) -> ProjectPurgeScan {
        ProjectPurgeScan(items: items.filter { !ids.contains($0.id) }, failedRoots: failedRoots,
                         protectedCount: protectedCount, unverifiedCount: unverifiedCount,
                         developerToolsMissing: developerToolsMissing)
    }
}

public struct ProjectPurgeReport: Sendable {
    public var trashedCount = 0
    public var trashedBytes: UInt64 = 0
    public var trashedIDs: Set<String> = []
    public var skippedCount = 0
    public var failures: [String] = []
}

private struct Identity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

/// 按需扫描项目内可重建产物；与通用缓存规则分开，避免一次勾选清理所有项目。
public enum ProjectPurge {
    private static let targetNames: Set<String> = [
        "node_modules", "target", "build", "dist", "venv", ".venv", ".pytest_cache", ".mypy_cache",
        ".tox", ".nox", ".ruff_cache", ".gradle", ".terragrunt-cache", "__pycache__", ".next",
        ".nuxt", ".output", "vendor", "bin", "obj", ".turbo", ".parcel-cache", ".dart_tool",
        ".zig-cache", "zig-out", ".angular", ".svelte-kit", ".astro", "coverage", "DerivedData",
        "Pods", ".cxx", ".expo", ".build",
    ]
    private static let projectMarkers = [
        "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "pom.xml",
        "build.gradle", "terragrunt.hcl", "Gemfile", "composer.json", "pubspec.yaml", "Package.swift",
        "Makefile", "build.zig", "build.zig.zon", ".git",
    ]
    private static let excludedContainers: Set<String> = [
        ".git", "Library", ".Trash", "Applications", "Movies", "Music", "Pictures", "Public",
    ]
    private static let cacheTag = "Signature: 8a477f597d28d172789f06886806bc55"
    private static let age: TimeInterval = 7 * 86_400

    /// Mole 的默认根目录及自动发现的项目位置；无法验证的已存在路径会在扫描结果中报出。
    public static func defaultSearchRoots(home: String = NSHomeDirectory()) -> [URL] {
        let homeURL = URL(fileURLWithPath: home, isDirectory: true)
        let names = ["www", "dev", "Projects", "GitHub", "Code", "Workspace", "Repos", "Development",
                     "Library/CloudStorage", ".codex/worktrees", ".claude/worktrees"]
        let manager = FileManager.default
        var roots = names.map { homeURL.appendingPathComponent($0) }.filter { manager.fileExists(atPath: $0.path) }
        if let children = try? manager.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            for child in children where !child.lastPathComponent.hasPrefix(".") && !excludedContainers.contains(child.lastPathComponent) {
                if hasProjects(inside: child, depth: 2) { roots.append(child) }
            }
        }
        return uniqueRoots(roots)
    }

    /// 用户从目录选择器添加时规范化路径；扫描时仍会单独处理随后卸载或失联的目录。
    public static func validatedAdditionalRoot(_ url: URL, home: String = NSHomeDirectory()) -> URL? {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
        guard isAllowedAdditionalPath(normalized, home: URL(fileURLWithPath: home)),
              identity(of: normalized) != nil else { return nil }
        return normalized
    }

    /// APFS 路径大小写或别名不同，也不能把同一个目录添加两次。
    public static func sameRoot(_ first: URL, _ second: URL) -> Bool {
        if let firstID = identity(of: first), let secondID = identity(of: second) {
            return firstID == secondID
        }
        return first.standardizedFileURL.resolvingSymlinksInPath().path
            == second.standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func scan(home: String = NSHomeDirectory(), now: Date = Date(),
                            configuredRoots: [URL]? = nil) async -> ProjectPurgeScan {
        await scan(home: home, now: now, configuredRoots: configuredRoots, developerTools: nil)
    }

    /// `developerTools` 为 nil 时检测本机；测试可指定有无 Xcode 命令行工具
    static func scan(home: String, now: Date, configuredRoots: [URL]?, developerTools: Bool?) async -> ProjectPurgeScan {
        await withTaskGroup(of: ProjectPurgeScan.self) { group in
            group.addTask(priority: .utility) {
                await scanRoots(home: home, now: now, configuredRoots: configuredRoots, developerTools: developerTools)
            }
            return await group.next() ?? ProjectPurgeScan(items: [], failedRoots: [])
        }
    }

    public static func clean(_ scan: ProjectPurgeScan, selected: Set<String>) async -> ProjectPurgeReport {
        await clean(scan, selected: selected, trash: { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }, log: CleanLog())
    }

    static func clean(_ scan: ProjectPurgeScan, selected: Set<String>,
                      trash: @escaping @Sendable (URL) throws -> Void,
                      log: CleanLog? = nil, developerTools: Bool? = nil) async -> ProjectPurgeReport {
        await withTaskGroup(of: ProjectPurgeReport.self) { group in
            group.addTask(priority: .utility) {
                var report = ProjectPurgeReport()
                let chosen = scan.items.filter { selected.contains($0.id) }
                let gitAvailable = developerTools ?? developerToolsInstalled()
                for item in chosen {
                    if Task.isCancelled { break }
                    guard identitiesMatch(item), isContained(item.url, in: item.root),
                          isProject(item.project), isTarget(item.url, parent: item.url.deletingLastPathComponent()),
                          case .contents(let bytes, let latest) = inspect(item.url, deadline: Date().addingTimeInterval(10)),
                          latest <= item.latestModification else {
                        report.skippedCount += 1
                        log?.record(url: item.url, ruleID: "projects.purge", bytes: item.bytes,
                                      action: "skip", detail: "safety check")
                        continue
                    }
                    // 批量清理期间可能发生 git add；内容检查完成后逐项复核，不能复用批次开始时的状态。
                    let tracking = trackingStates(for: [(item.url, item.project)], gitAvailable: gitAvailable)
                    guard !Task.isCancelled, tracking[item.url.path] == .untracked,
                          identitiesMatch(item), isContained(item.url, in: item.root),
                          isTarget(item.url, parent: item.url.deletingLastPathComponent()) else {
                        report.skippedCount += 1
                        log?.record(url: item.url, ruleID: "projects.purge", bytes: item.bytes,
                                      action: "skip", detail: "path or tracking changed")
                        continue
                    }
                    do {
                        try trash(item.url)
                        report.trashedCount += 1
                        report.trashedBytes += bytes
                        report.trashedIDs.insert(item.id)
                        log?.record(url: item.url, ruleID: "projects.purge", bytes: bytes,
                                      action: "trash", detail: nil)
                    } catch {
                        report.failures.append(tr("\(item.url.lastPathComponent)：\(error.localizedDescription)"))
                        log?.record(url: item.url, ruleID: "projects.purge", bytes: item.bytes,
                                      action: "fail", detail: error.localizedDescription)
                    }
                }
                return report
            }
            return await group.next() ?? ProjectPurgeReport()
        }
    }

    /// 同时最多扫描 3 个目录：一个大目录不会耗尽其余目录的时间，也不至于让磁盘读写互相争抢。
    private static func scanRoots(home: String, now: Date, configuredRoots: [URL]?, developerTools: Bool?) async -> ProjectPurgeScan {
        let roots: [URL]
        if let configuredRoots {
            let homeURL = URL(fileURLWithPath: home, isDirectory: true)
            roots = uniqueRoots(configuredRoots.filter { isAllowedAdditionalPath($0, home: homeURL) })
        } else {
            roots = defaultSearchRoots(home: home)
        }
        let gitAvailable = developerTools ?? developerToolsInstalled()
        let overallDeadline = Date().addingTimeInterval(120)
        var results = [RootScan?](repeating: nil, count: roots.count)
        await withTaskGroup(of: (Int, RootScan?).self) { group in
            var next = 0
            func startNext() {
                guard next < roots.count else { return }
                let index = next
                next += 1
                group.addTask(priority: .utility) {
                    let deadline = min(overallDeadline, Date().addingTimeInterval(45))
                    guard !Task.isCancelled, Date() < deadline else { return (index, nil) }
                    return (index, scanRoot(roots[index], home: home, now: now, deadline: deadline, gitAvailable: gitAvailable))
                }
            }
            for _ in 0..<3 { startNext() }
            for await (index, result) in group {
                results[index] = result
                startNext()
            }
        }
        var items: [ProjectPurgeItem] = []
        var failedRoots: [URL] = []
        var protected = 0, unverified = 0
        var toolsMissing = false
        for (root, result) in zip(roots, results) {
            guard let result else { failedRoots.append(root); continue }
            items += result.items
            protected += result.protected
            unverified += result.unverified
            toolsMissing = toolsMissing || result.developerToolsMissing
        }
        var seenItems = Set<String>()
        items = items.filter { seenItems.insert($0.url.resolvingSymlinksInPath().path).inserted }
        // 占用最大的项目排在前面，组内按单项大小排序
        var projectBytes: [String: UInt64] = [:]
        for item in items { projectBytes[item.project.path, default: 0] &+= item.bytes }
        items.sort { lhs, rhs in
            let left = projectBytes[lhs.project.path] ?? 0, right = projectBytes[rhs.project.path] ?? 0
            if lhs.project.path != rhs.project.path {
                return left == right ? lhs.project.path < rhs.project.path : left > right
            }
            return lhs.bytes > rhs.bytes
        }
        return ProjectPurgeScan(items: items, failedRoots: failedRoots, protectedCount: protected,
                                unverifiedCount: unverified, developerToolsMissing: toolsMissing)
    }

    private static func uniqueRoots(_ roots: [URL]) -> [URL] {
        var identities = Set<Identity>()
        var unresolvedPaths = Set<String>()
        return roots.filter { root in
            // 无法验证的根仍交给扫描阶段报告；同一个缺失路径只报告一次。
            guard let id = identity(of: root) else {
                return unresolvedPaths.insert(root.standardizedFileURL.path).inserted
            }
            return identities.insert(id).inserted
        }
    }

    private static func isAllowedAdditionalPath(_ url: URL, home: URL) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.pathComponents.contains(".."),
              !url.path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        // 下载目录内的应用也有 package.json 和运行依赖，应用包及其内部路径不能作为项目根。
        guard !url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.contains(where: {
            $0.lowercased().hasSuffix(".app")
        }) else { return false }
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
        guard !["/", "/Users", "/Volumes", "/private", "/var", homePath, homePath + "/Library"].contains(path) else {
            return false
        }
        for systemRoot in ["/System", "/Applications", "/Library", "/usr", "/bin", "/sbin", "/dev"] {
            if path == systemRoot || path.hasPrefix(systemRoot + "/") { return false }
        }
        guard !url.pathComponents.contains(where: { targetNames.contains($0) || $0 == ".Trash" || $0 == ".git" }) else {
            return false
        }
        // 应用数据与编辑器扩展里也有 package.json，但不是用户项目，清掉其中的 dist/ 会损坏它们。
        // 家目录的资源库只允许云盘；隐藏目录只允许 Agent 工作树。
        var relative: [String]?
        for prefix in Set([homePath, home.standardizedFileURL.path]) where path.hasPrefix(prefix + "/") {
            relative = String(path.dropFirst(prefix.count + 1)).split(separator: "/").map(String.init)
        }
        guard let relative else { return !url.standardizedFileURL.pathComponents.contains { $0.hasPrefix(".") } }
        let rest = relative.dropFirst(2)
        if relative.first == "Library" {
            return relative.count >= 2 && ["CloudStorage", "Mobile Documents"].contains(relative[1])
                && !rest.contains { $0.hasPrefix(".") }
        }
        if let first = relative.first, first.hasPrefix(".") {
            return [".codex", ".claude"].contains(first) && relative.count >= 2 && relative[1] == "worktrees"
                && !rest.contains { $0.hasPrefix(".") }
        }
        return !relative.contains { $0.hasPrefix(".") }
    }

    private struct RootScan: Sendable {
        var items: [ProjectPurgeItem] = []
        var protected = 0
        var unverified = 0
        var developerToolsMissing = false
    }

    private struct Candidate {
        let url: URL
        let project: URL
        let identity: Identity
        let parentIdentity: Identity
        let rootIdentity: Identity
        let bytes: UInt64
        let latest: Date
    }

    private static func scanRoot(_ root: URL, home: String, now: Date, deadline: Date, gitAvailable: Bool) -> RootScan? {
        guard identity(of: root) != nil else { return nil }
        let manager = FileManager.default
        var stack: [(url: URL, depth: Int, project: URL?)] = [(root, 0, isProject(root) ? root : nil)]
        var candidates: [Candidate] = []
        var result = RootScan()
        while let frame = stack.popLast() {
            if Task.isCancelled || Date() >= deadline { return nil }
            guard let children = try? manager.contentsOfDirectory(at: frame.url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return nil }
            for child in children {
                if Task.isCancelled || Date() >= deadline { return nil }
                guard isDirectoryWithoutLink(child), child.pathExtension.lowercased() != "app" else { continue }
                let name = child.lastPathComponent
                let eligibleArtifact = isTarget(child, parent: frame.url)
                if eligibleArtifact, let project = frame.project {
                    guard isContained(child, in: root),
                          let targetIdentity = identity(of: child),
                          let parentIdentity = identity(of: frame.url),
                          let rootIdentity = identity(of: root) else {
                        result.unverified += 1
                        continue
                    }
                    switch inspect(child, deadline: min(deadline, Date().addingTimeInterval(10))) {
                    case .empty: break
                    case .authored: result.protected += 1
                    case .unreadable: result.unverified += 1
                    case .contents(let bytes, let latest):
                        candidates.append(Candidate(url: child, project: project, identity: targetIdentity,
                                                    parentIdentity: parentIdentity, rootIdentity: rootIdentity,
                                                    bytes: bytes, latest: latest))
                    }
                    continue
                }
                // 依赖目录即使没有可确认的项目所有者，也不能被当作项目容器继续向下搜索。
                if eligibleArtifact || targetNames.contains(name) { continue }
                if excludedContainers.contains(name) || name.hasPrefix(".") || frame.depth >= 5 { continue }
                stack.append((child, frame.depth + 1, isProject(child) ? child : frame.project))
            }
        }
        let tracking = trackingStates(for: candidates.map { ($0.url, $0.project) }, gitAvailable: gitAvailable)
        let physicalHomePrefix = URL(fileURLWithPath: home).resolvingSymlinksInPath().path + "/"
        let lexicalHomePrefix = URL(fileURLWithPath: home).path + "/"
        for candidate in candidates {
            switch tracking[candidate.url.path] ?? .unknown {
            case .tracked: result.protected += 1; continue
            case .unknown:
                result.unverified += 1
                if !gitAvailable { result.developerToolsMissing = true }
                continue
            case .untracked: break
            }
            let physicalPath = candidate.url.resolvingSymlinksInPath().path
            let relative: String
            if physicalPath.hasPrefix(physicalHomePrefix) {
                relative = String(physicalPath.dropFirst(physicalHomePrefix.count))
            } else if candidate.url.path.hasPrefix(lexicalHomePrefix) {
                relative = String(candidate.url.path.dropFirst(lexicalHomePrefix.count))
            } else {
                relative = ""
            }
            result.items.append(ProjectPurgeItem(
                url: candidate.url, project: candidate.project, root: root, bytes: candidate.bytes,
                isRecent: candidate.latest > now.addingTimeInterval(-age),
                isCloud: relative.hasPrefix("Library/CloudStorage/") || relative.hasPrefix("Library/Mobile Documents/"),
                isWorktree: relative.hasPrefix(".codex/worktrees/") || relative.hasPrefix(".claude/worktrees/"),
                identity: candidate.identity, parentIdentity: candidate.parentIdentity,
                rootIdentity: candidate.rootIdentity, latestModification: candidate.latest))
        }
        return result
    }

    private static func isProject(_ directory: URL) -> Bool {
        projectMarkers.contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    private static func hasProjects(inside directory: URL, depth: Int) -> Bool {
        guard isDirectoryWithoutLink(directory), directory.pathExtension.lowercased() != "app",
              !targetNames.contains(directory.lastPathComponent) else { return false }
        if isProject(directory) { return true }
        guard depth > 0, let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return children.contains { child in
            !child.lastPathComponent.hasPrefix(".") && !excludedContainers.contains(child.lastPathComponent)
                && !targetNames.contains(child.lastPathComponent)
                && hasProjects(inside: child, depth: depth - 1)
        }
    }

    private static func isTarget(_ url: URL, parent: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "vendor" { return FileManager.default.fileExists(atPath: parent.appendingPathComponent("composer.json").path) }
        if name == "bin" {
            let hasProject = ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? [])
                .contains { $0.hasSuffix(".csproj") || $0.hasSuffix(".fsproj") || $0.hasSuffix(".vbproj") }
            return hasProject && (FileManager.default.fileExists(atPath: url.appendingPathComponent("Debug").path)
                                  || FileManager.default.fileExists(atPath: url.appendingPathComponent("Release").path))
        }
        if targetNames.contains(name) { return true }
        let tag = url.appendingPathComponent("CACHEDIR.TAG")
        guard FileManager.default.fileExists(atPath: tag.path),
              let values = try? tag.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        guard let handle = try? FileHandle(forReadingFrom: tag) else { return false }
        defer { try? handle.close() }
        let prefix = try? handle.read(upToCount: cacheTag.utf8.count)
        return prefix == Data(cacheTag.utf8)
    }

    private enum Inspection {
        case contents(bytes: UInt64, latest: Date)
        /// 没有占用空间，不值得列出
        case empty
        /// 含 `.git` 或部署密钥等手写内容
        case authored
        /// 超时或读取失败，无法确认
        case unreadable
    }

    private static func inspect(_ url: URL, deadline: Date) -> Inspection {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                         .contentModificationDateKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory == true,
              values.isSymbolicLink != true,
              let directoryModified = values.contentModificationDate else { return .unreadable }
        var latest = directoryModified
        var bytes: UInt64 = 0
        var failed = false
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in failed = true; return false }) else { return .unreadable }
        while let entry = enumerator.nextObject() as? URL {
            if Task.isCancelled || Date() >= deadline { return .unreadable }
            let name = entry.lastPathComponent
            if name == ".git" || name.hasSuffix("-keypair.json") { return .authored }
            guard let file = try? entry.resourceValues(forKeys: keys) else { return .unreadable }
            if file.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard let modified = file.contentModificationDate else { return .unreadable }
            if modified > latest { latest = modified }
            if file.isRegularFile == true {
                let size = UInt64(max(0, file.totalFileAllocatedSize ?? file.fileAllocatedSize ?? 0))
                let (sum, overflow) = bytes.addingReportingOverflow(size)
                bytes = overflow ? UInt64.max : sum
            }
        }
        if failed { return .unreadable }
        return bytes > 0 ? .contents(bytes: bytes, latest: latest) : .empty
    }

    private enum Tracking { case untracked, tracked, unknown }

    /// 按仓库分组，每个仓库只运行一次 `git ls-files`（每批最多 200 个路径）。键为产物的路径。
    private static func trackingStates(for targets: [(url: URL, project: URL)], gitAvailable: Bool) -> [String: Tracking] {
        var states: [String: Tracking] = [:]
        var byRepository: [String: [(url: URL, relative: String)]] = [:]
        for target in targets {
            var repository = target.project
            while repository.path != "/" && !FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git").path) {
                repository.deleteLastPathComponent()
            }
            guard repository.path != "/" else { states[target.url.path] = .untracked; continue }
            let prefix = repository.path + "/"
            guard gitAvailable, target.url.path.hasPrefix(prefix) else { states[target.url.path] = .unknown; continue }
            byRepository[repository.path, default: []].append((target.url, String(target.url.path.dropFirst(prefix.count))))
        }
        for (repository, entries) in byRepository {
            for start in stride(from: 0, to: entries.count, by: 200) {
                if Task.isCancelled { return states }
                let batch = Array(entries[start..<min(start + 200, entries.count)])
                guard let tracked = trackedFiles(in: repository, paths: batch.map(\.relative)) else {
                    for entry in batch { states[entry.url.path] = .unknown }
                    continue
                }
                let relatives = Set(batch.map(\.relative))
                var trackedTargets = Set<String>()
                for file in tracked {
                    // 找出这个被跟踪文件属于哪个产物目录：逐级比对它的上级路径
                    var components = file.split(separator: "/", omittingEmptySubsequences: false)
                    while !components.isEmpty {
                        let candidate = components.joined(separator: "/")
                        if relatives.contains(candidate) { trackedTargets.insert(candidate); break }
                        components.removeLast()
                    }
                }
                for entry in batch { states[entry.url.path] = trackedTargets.contains(entry.relative) ? .tracked : .untracked }
            }
        }
        return states
    }

    /// 返回这些路径下被 Git 跟踪的文件；失败或超时返回 nil
    private static func trackedFiles(in repository: String, paths: [String]) -> [String]? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-git-\(UUID())")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.fsmonitor=false", "-C", repository, "ls-files", "--cached", "-z", "--"] + paths
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] { environment.removeValue(forKey: key) }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        process.environment = environment
        guard wait(for: process, timeout: 10) == 0,
              let data = try? Data(contentsOf: output) else { return nil }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 运行子进程并限时等待；超时先 terminate 再 SIGKILL。返回退出码，启动失败或超时返回 nil
    private static func wait(for process: Process, timeout: TimeInterval) -> Int32? {
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline && !Task.isCancelled {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        }
        return process.terminationStatus
    }

    /// 没有 Xcode 或命令行工具时，/usr/bin/git 只是占位程序，调用会弹出安装对话框。
    /// `xcode-select -p` 不会弹窗：未安装时直接以非零状态退出。
    static func developerToolsInstalled(xcodeSelect: String = "/usr/bin/xcode-select") -> Bool {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-xcode-select-\(UUID())")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return false }
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcodeSelect)
        process.arguments = ["-p"]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        guard wait(for: process, timeout: 3) == 0, let data = try? Data(contentsOf: output) else { return false }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && FileManager.default.isExecutableFile(atPath: path + "/usr/bin/git")
    }

    private static func identity(of url: URL) -> Identity? {
        guard isDirectoryWithoutLink(url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Identity(device: device.uint64Value, inode: inode.uint64Value)
    }

    private static func isDirectoryWithoutLink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func identitiesMatch(_ item: ProjectPurgeItem) -> Bool {
        identity(of: item.root) == item.rootIdentity
            && identity(of: item.url.deletingLastPathComponent()) == item.parentIdentity
            && identity(of: item.url) == item.identity
    }

    private static func isContained(_ item: URL, in root: URL) -> Bool {
        let physicalRoot = root.resolvingSymlinksInPath().path
        let physicalItem = item.resolvingSymlinksInPath().path
        return physicalItem.hasPrefix(physicalRoot + "/")
    }
}
