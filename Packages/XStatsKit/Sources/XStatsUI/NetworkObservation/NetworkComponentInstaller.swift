// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin
import Foundation
import Localization
import NetworkObservation
import Updates

public enum NetworkComponentInstallError: Error, LocalizedError, Equatable {
    case invalidArchive
    case untrustedComponent
    case runningComponent
    case installationInProgress
    case requiresAdministrator

    public var errorDescription: String? {
        switch self {
        case .runningComponent: tr("网络组件正在运行，请先停止查看。")
        case .invalidArchive: tr("网络组件压缩包无效。")
        case .untrustedComponent: tr("网络组件签名或公证校验失败。")
        case .installationInProgress: tr("网络组件正在安装，请稍候。")
        case .requiresAdministrator: tr("安装网络组件需要管理员账户。")
        }
    }
}

/// 只负责首次安装。已有组件由其自身的 Sparkle 管理更新，主应用不会替换它。
@MainActor
public final class NetworkComponentInstaller {
    public nonisolated static let componentURL = URL(fileURLWithPath: "/Applications/XStats Network Monitor.app", isDirectory: true)
    public nonisolated static let bundleIdentifier = "work.12306.xstats.networkmonitor"
    nonisolated private static let maximumDownload = 64 * 1024 * 1024
    private let destination: URL
    private let temporaryRoot: URL
    private let hostApp: URL
    private let dependencies: Dependencies
    private var installing = false

    struct Dependencies: Sendable {
        typealias Download = @Sendable (URL, Int, @escaping @Sendable (Double) -> Void) async throws -> Data
        var download: Download
        var command: @Sendable (String, [String], Int) async throws -> Data
        var teamIdentifier: @Sendable (URL) -> String?
        var isRunning: @MainActor @Sendable () -> Bool
        var archiveURL: URL?

        static var live: Self {
            Self(download: downloadGeography, command: NetworkComponentInstaller.runCommand,
                 teamIdentifier: UpdateInstaller.teamIdentifier,
                 isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: NetworkComponentInstaller.bundleIdentifier).isEmpty },
                 archiveURL: NetworkComponentInstaller.releaseURL(version: Bundle.main.object(forInfoDictionaryKey: "NetworkComponentVersion") as? String))
        }
    }

    /// 首次安装固定到主程序声明的兼容版本；已有组件仍由 Sparkle 独立更新。
    nonisolated static func releaseURL(version: String?) -> URL? {
        guard let version else { return nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
                && (part.count == 1 || part.first != "0")
        }) else { return nil }
        return URL(string: "https://c.ysicing.net/oss/apps/macOS/XStats/network-monitor/XStats-Network-Monitor-\(version)-AppleSilicon.zip")
    }

    public convenience init() {
        self.init(destination: Self.componentURL, temporaryRoot: FileManager.default.temporaryDirectory,
                  hostApp: Bundle.main.bundleURL, dependencies: .live)
    }

    init(destination: URL, temporaryRoot: URL, hostApp: URL, dependencies: Dependencies) {
        self.destination = destination
        self.temporaryRoot = temporaryRoot
        self.hostApp = hostApp
        self.dependencies = dependencies
    }

    /// 只读取 plist 和静态签名，不加载组件代码；开发临时签名不能视为可信安装。
    public static func isInstalled() async -> Bool {
        do {
            try await validateInstalled()
            return true
        } catch { return false }
    }

    /// 启动前重新验证固定路径的组件，拒绝伪造、临时签名和未公证的应用。
    public static func validateInstalled() async throws {
        try await validateBundle(at: componentURL, hostApp: Bundle.main.bundleURL, dependencies: .live)
    }

    /// 下载取消、验证失败或安装目标被占用时保留原组件，并清除本次临时文件。
    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !installing else { throw NetworkComponentInstallError.installationInProgress }
        installing = true
        defer { installing = false }
        try Task.checkCancellation()
        guard !dependencies.isRunning() else { throw NetworkComponentInstallError.runningComponent }
        try await Self.install(destination: destination, temporaryRoot: temporaryRoot, hostApp: hostApp,
                               dependencies: dependencies, progress: progress)
    }

    @concurrent
    private static func install(destination: URL, temporaryRoot: URL, hostApp: URL, dependencies: Dependencies,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try await validateBundle(at: destination, hostApp: hostApp, dependencies: dependencies)
            progress(1)
            return
        }
        let workspace = temporaryRoot.appendingPathComponent("xstats-network-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: workspace) }
        let archive = workspace.appendingPathComponent("component.zip")
        let expanded = workspace.appendingPathComponent("expanded", isDirectory: true)
        guard let downloadURL = dependencies.archiveURL else { throw NetworkComponentInstallError.untrustedComponent }
        let payload = try await dependencies.download(downloadURL, maximumDownload) { fraction in
            progress(min(0.7, max(0, fraction * 0.7)))
        }
        try Task.checkCancellation()
        guard payload.count <= maximumDownload else { throw NetworkComponentInstallError.invalidArchive }
        let entries = try NetworkComponentArchive.inspect(payload)
        try payload.write(to: archive, options: .atomic)
        // unzip 的完整性检测和链接内容读取都在展开前进行，不能先让 ditto 写入任意路径。
        _ = try await dependencies.command("/usr/bin/unzip", ["-t", archive.path], 4 * 1024 * 1024)
        for entry in entries where entry.isSymlink {
            try Task.checkCancellation()
            let bytes = try await dependencies.command("/usr/bin/unzip", ["-p", archive.path, entry.path], 4096)
            guard let target = String(data: bytes, encoding: .utf8) else { throw NetworkComponentInstallError.invalidArchive }
            try NetworkComponentArchive.validateSymlink(path: entry.path, target: target)
        }
        // unzip -t 只校验 CRC，可能接受伪造的展开大小；真正展开一次并丢弃输出，硬限总字节。
        _ = try await dependencies.command("/usr/bin/unzip", ["-p", archive.path], entries.reduce(0) { $0 + $1.expandedBytes })
        try manager.createDirectory(at: expanded, withIntermediateDirectories: true)
        _ = try await dependencies.command("/usr/bin/ditto", ["-x", "-k", archive.path, expanded.path], 64 * 1024)
        try Task.checkCancellation()
        let roots = try manager.contentsOfDirectory(atPath: expanded.path)
        guard roots == [componentURL.lastPathComponent] else { throw NetworkComponentInstallError.invalidArchive }
        let candidate = expanded.appendingPathComponent(componentURL.lastPathComponent, isDirectory: true)
        progress(0.8)
        try await validateBundle(at: candidate, hostApp: hostApp, dependencies: dependencies)
        // 固定下载地址可能已指向更新协议的组件；写入前拒绝，避免装上后无法使用也无法通过组件卸载。
        let metadata = try await NetworkComponentMetadata.load(at: candidate)
        guard let team = dependencies.teamIdentifier(hostApp), metadata.protocolVersion == NetworkObservationProtocol.version,
              metadata.controlMachService == NetworkObservationProtocol.controlServiceName(team: team) else {
            throw NetworkMonitorError.protocolMismatch
        }
        try Task.checkCancellation()
        guard await !dependencies.isRunning() else { throw NetworkComponentInstallError.runningComponent }
        // 在目标文件系统暂存，最后使用排他 rename；目标即使在检查后出现也不会被覆盖。
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".xstats-network-\(UUID().uuidString).app")
        defer { try? manager.removeItem(at: staged) }
        // 系统扩展要求组件位于 /Applications；标准账户无写权限时明确提示，不引入提权写入。
        do { try manager.copyItem(at: candidate, to: staged) }
        catch let error as CocoaError where error.code == .fileWriteNoPermission { throw NetworkComponentInstallError.requiresAdministrator }
        try Task.checkCancellation()
        try await validateBundle(at: staged, hostApp: hostApp, dependencies: dependencies)
        guard await !dependencies.isRunning() else { throw NetworkComponentInstallError.runningComponent }
        try Task.checkCancellation()
        let status = staged.path.withCString { source in
            destination.path.withCString { target in renamex_np(source, target, UInt32(RENAME_EXCL)) }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        progress(1)
    }

    @concurrent
    private static func validateBundle(at app: URL, hostApp: URL, dependencies: Dependencies) async throws {
        try Task.checkCancellation()
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: app.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw NetworkComponentInstallError.untrustedComponent }
            try validateExpandedTree(at: app)
            let plist = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"), options: .mappedIfSafe)
            guard plist.count <= 1024 * 1024,
                  let info = try PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any],
                  info["CFBundleIdentifier"] as? String == bundleIdentifier,
                  info["CFBundlePackageType"] as? String == "APPL",
                  let team = dependencies.teamIdentifier(hostApp), !team.isEmpty,
                  dependencies.teamIdentifier(app) == team else { throw NetworkComponentInstallError.untrustedComponent }
            _ = try await dependencies.command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], 64 * 1024)
            let assessment = try await dependencies.command("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=4", app.path], 64 * 1024)
            // 退出码为零也可能来自用户放行策略；首次下载必须确实通过 Developer ID 公证。
            guard String(decoding: assessment, as: UTF8.self).split(separator: "\n").contains("source=Notarized Developer ID") else {
                throw NetworkComponentInstallError.untrustedComponent
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw NetworkComponentInstallError.untrustedComponent }
    }

    /// 第二次检查实际文件，防御展开工具的实现差异；任何链接最终都必须留在该 bundle 内。
    nonisolated private static func validateExpandedTree(at app: URL) throws {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let enumerator = manager.enumerator(at: app, includingPropertiesForKeys: keys) else {
            throw NetworkComponentInstallError.invalidArchive
        }
        let root = app.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var count = 0, bytes = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                guard url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else {
                    throw NetworkComponentInstallError.invalidArchive
                }
            } else if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
            else if values.isDirectory != true { throw NetworkComponentInstallError.invalidArchive }
            guard count <= 8192, bytes <= 256 * 1024 * 1024 else { throw NetworkComponentInstallError.invalidArchive }
        }
    }

    /// 系统工具只在用户触发安装时运行，输出和时长有界；取消时仅终止本次启动的进程。
    @concurrent
    static func runCommand(_ executable: String, arguments: [String], limit: Int) async throws -> Data {
        try Task.checkCancellation()
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = executable == "/usr/bin/unzip" && arguments.first == "-p" ? FileHandle.nullDevice : pipe
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let reader = pipe.fileHandleForReading
        let capture = !(executable == "/usr/bin/unzip" && arguments.count == 2 && arguments.first == "-p")
        // 读取方独占句柄并负责关闭。超限时关闭管道，使解压工具停止写入；不暂存大展开内容。
        let outputTask = Task.detached(priority: .utility) {
            defer { try? reader.close() }
            var bytes = Data(), received = 0
            while let chunk = try reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                guard chunk.count <= limit - received else { throw NetworkComponentInstallError.invalidArchive }
                received += chunk.count
                if capture { bytes.append(chunk) }
            }
            return bytes
        }
        defer { outputTask.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw NetworkComponentInstallError.invalidArchive }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        let bytes = try await outputTask.value
        guard process.terminationStatus == 0 else { throw NetworkComponentInstallError.untrustedComponent }
        return bytes
    }
}

/// 只解析中央目录和对应本地头；不实现解压。拒绝 ZIP64、加密、多盘和路径歧义。
enum NetworkComponentArchive {
    struct Entry {
        var path: String
        var isSymlink: Bool
        var expandedBytes: Int
    }
    static func inspect(_ data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw NetworkComponentInstallError.invalidArchive }
        let start = max(0, data.count - 22 - 65535)
        guard let end = stride(from: data.count - 22, through: start, by: -1).first(where: {
            data.zipNumber($0, 4) == 0x06054b50 && $0 + 22 + Int(data.zipNumber($0 + 20, 2)) == data.count
        }) else { throw NetworkComponentInstallError.invalidArchive }
        let count = Int(data.zipNumber(end + 10, 2)), size = Int(data.zipNumber(end + 12, 4))
        var cursor = Int(data.zipNumber(end + 16, 4))
        guard data.zipNumber(end + 4, 2) == 0, data.zipNumber(end + 6, 2) == 0,
              data.zipNumber(end + 8, 2) == UInt32(count), count > 0, count <= 8192,
              cursor + size == end else { throw NetworkComponentInstallError.invalidArchive }
        let directoryStart = cursor
        var entries: [Entry] = [], names = Set<String>(), ranges: [Range<Int>] = [], bytes = 0
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor + 46 <= end, data.zipNumber(cursor, 4) == 0x02014b50 else { throw NetworkComponentInstallError.invalidArchive }
            let flags = data.zipNumber(cursor + 8, 2), method = data.zipNumber(cursor + 10, 2)
            let compressed = Int(data.zipNumber(cursor + 20, 4)), expanded = Int(data.zipNumber(cursor + 24, 4))
            let nameLength = Int(data.zipNumber(cursor + 28, 2)), extra = Int(data.zipNumber(cursor + 30, 2))
            let comment = Int(data.zipNumber(cursor + 32, 2)), local = Int(data.zipNumber(cursor + 42, 4))
            let next = cursor + 46 + nameLength + extra + comment
            guard next <= end, nameLength > 0, nameLength <= 4096,
                  flags & 1 == 0, method == 0 || method == 8, data.zipNumber(cursor + 34, 2) == 0,
                  let path = String(data: data[(cursor + 46)..<(cursor + 46 + nameLength)], encoding: .utf8) else {
                throw NetworkComponentInstallError.invalidArchive
            }
            try validatePath(path)
            let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).precomposedStringWithCanonicalMapping.lowercased()
            guard names.insert(normalized).inserted else { throw NetworkComponentInstallError.invalidArchive }
            let mode = data.zipNumber(cursor + 38, 4) >> 16, kind = mode & 0o170000
            // 发布 ZIP 来自系统 ditto 的 Unix 模式；拒绝没有可靠类型或依赖平台扩展的条目。
            guard data.zipNumber(cursor + 4, 2) >> 8 == 3,
                  kind == 0o100000 || kind == 0o040000 || kind == 0o120000 else { throw NetworkComponentInstallError.invalidArchive }
            let symlink = kind == 0o120000
            bytes += expanded
            guard bytes <= 256 * 1024 * 1024, expanded <= 128 * 1024 * 1024,
                  !symlink || (expanded <= 4096 && !path.hasSuffix("/")), local + 30 <= directoryStart,
                  data.zipNumber(local, 4) == 0x04034b50,
                  data.zipNumber(local + 6, 2) == flags, data.zipNumber(local + 8, 2) == method else {
                throw NetworkComponentInstallError.invalidArchive
            }
            let localName = Int(data.zipNumber(local + 26, 2)), localExtra = Int(data.zipNumber(local + 28, 2))
            let payloadStart = local + 30 + localName + localExtra
            guard localName == nameLength, payloadStart + compressed <= directoryStart,
                  data[(local + 30)..<(local + 30 + localName)] == data[(cursor + 46)..<(cursor + 46 + nameLength)] else {
                throw NetworkComponentInstallError.invalidArchive
            }
            // 仅接受时间戳和 Unix uid/gid 扩展；其他平台扩展可能引入第二份路径或文件类型。
            try validateExtra(data, range: (cursor + 46 + nameLength)..<(cursor + 46 + nameLength + extra))
            try validateExtra(data, range: (local + 30 + localName)..<payloadStart)
            ranges.append(local..<(payloadStart + compressed))
            entries.append(Entry(path: path, isSymlink: symlink, expandedBytes: expanded))
            cursor = next
        }
        guard cursor == end else { throw NetworkComponentInstallError.invalidArchive }
        let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<ordered.count where ordered[index].lowerBound < ordered[index - 1].upperBound {
            throw NetworkComponentInstallError.invalidArchive
        }
        // 不允许其他条目写到链接路径的下面，防止展开顺序影响实际目的地。
        for entry in entries where entry.isSymlink {
            let prefix = entry.path.precomposedStringWithCanonicalMapping.lowercased() + "/"
            guard !names.contains(where: { $0.hasPrefix(prefix) }) else { throw NetworkComponentInstallError.invalidArchive }
        }
        return entries
    }

    private static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first == "XStats Network Monitor.app", !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.contains("*"), !path.contains("?"), !path.contains("["), !path.contains("]"),
              parts.enumerated().allSatisfy({ index, part in
                  part != "." && part != ".." && (!part.isEmpty || index == parts.count - 1)
              }) else { throw NetworkComponentInstallError.invalidArchive }
    }

    static func validateSymlink(path: String, target: String) throws {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\"),
              !target.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NetworkComponentInstallError.invalidArchive
        }
        var parts = path.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard parts.count > 1 else { throw NetworkComponentInstallError.invalidArchive }
                parts.removeLast()
            } else { parts.append(String(part)) }
        }
        guard parts.count > 1 else { throw NetworkComponentInstallError.invalidArchive }
    }

    private static func validateExtra(_ data: Data, range: Range<Int>) throws {
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard offset + 4 <= range.upperBound else { throw NetworkComponentInstallError.invalidArchive }
            let kind = data.zipNumber(offset, 2), size = Int(data.zipNumber(offset + 2, 2))
            guard [UInt32(0x5855), 0x5455, 0x7855, 0x7875].contains(kind), offset + 4 + size <= range.upperBound else {
                throw NetworkComponentInstallError.invalidArchive
            }
            offset += 4 + size
        }
    }
}

private extension Data {
    func zipNumber(_ offset: Int, _ width: Int) -> UInt32 {
        var result: UInt32 = 0
        for index in 0..<width { result |= UInt32(self[offset + index]) << (8 * index) }
        return result
    }
}
