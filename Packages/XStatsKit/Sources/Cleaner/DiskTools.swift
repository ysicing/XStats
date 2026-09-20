import Foundation
import Localization

// MARK: - Time Machine 本地快照

/// Time Machine 在本机保留的快照。它们计入“可清除”空间，系统缺空间时会自动删，也可以手动清掉
public struct LocalSnapshot: Sendable, Equatable, Identifiable {
    public let name: String
    /// 形如 2026-09-14-120000，删除时用它指定快照
    public let identifier: String
    public let date: Date?

    public var id: String { name }
}

public enum LocalSnapshots {
    static let prefix = "com.apple.TimeMachine."
    static let suffix = ".local"

    /// 解析 `tmutil listlocalsnapshots /` 的输出
    public static func parse(_ output: String) -> [LocalSnapshot] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.timeZone = .current
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
            let identifier = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            return LocalSnapshot(name: name, identifier: identifier, date: formatter.date(from: identifier))
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// 列出启动盘上的本地快照；tmutil 只读列出不需要权限
    public static func list() -> [LocalSnapshot] {
        parse(ShellTool.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"]).output)
    }
}

// MARK: - 文件系统检查

public struct VolumeVerification: Sendable, Equatable {
    public let ok: Bool
    /// 一句话结论
    public let summary: String
    /// diskutil 的完整输出
    public let log: String
    public let date: Date

    public init(ok: Bool, summary: String, log: String, date: Date = Date()) {
        self.ok = ok
        self.summary = summary
        self.log = log
        self.date = date
    }
}

/// 用系统自带的 diskutil 做一次只读的文件系统检查，相当于“磁盘工具”里的急救但不修改任何东西。
/// 检查启动盘不需要管理员权限，通常几秒到几十秒
public enum VolumeVerifier {
    public static func verify(volume: String = "/") -> VolumeVerification {
        let result = ShellTool.run("/usr/sbin/diskutil", ["verifyVolume", volume])
        return interpret(status: result.status, output: result.output)
    }

    static func interpret(status: Int32, output: String) -> VolumeVerification {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let ok = status == 0 && lines.contains { $0.contains("appears to be OK") }
        let summary: String
        if ok {
            summary = tr("文件系统结构完好，没有发现错误")
        } else if let problem = lines.first(where: { $0.lowercased().contains("error") || $0.lowercased().contains("invalid") || $0.lowercased().contains("corrupt") }) {
            summary = tr("发现问题：\(problem)")
        } else if status != 0 {
            summary = tr("检查未能完成（退出码 \(status)）")
        } else {
            summary = tr("检查完成，但没有得到明确结论")
        }
        return VolumeVerification(ok: ok, summary: summary, log: output)
    }
}

// MARK: - 已装载的卷宗

public struct MountedVolume: Sendable, Equatable, Identifiable {
    public let url: URL
    public let name: String
    public let total: UInt64
    public let available: UInt64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isLocal: Bool

    public var id: String { url.path }
    public var used: UInt64 { total > available ? total - available : 0 }
    public var usedFraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

public enum MountedVolumes {
    /// 启动盘之外、访达里能看到的卷：外置硬盘、U 盘、镜像、网络共享
    public static func list() -> [MountedVolume] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                         .volumeIsRootFileSystemKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.volumeIsRootFileSystem != true, values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            return MountedVolume(url: url,
                                 name: values.volumeName ?? url.lastPathComponent,
                                 total: UInt64(total),
                                 available: UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)),
                                 isInternal: values.volumeIsInternal ?? false,
                                 isRemovable: values.volumeIsRemovable ?? false,
                                 isEjectable: values.volumeIsEjectable ?? false,
                                 isLocal: values.volumeIsLocal ?? true)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - 空间占用分析

public struct SpaceScanResult: Sendable, Equatable {
    public struct Folder: Sendable, Equatable, Identifiable {
        public let url: URL
        public let name: String
        public let bytes: UInt64
        public let items: Int
        public var id: String { url.path }
    }

    public struct File: Sendable, Equatable, Identifiable {
        public let url: URL
        public let bytes: UInt64
        public let modified: Date?
        public let isPackage: Bool
        public var id: String { url.path }
        public var name: String { url.lastPathComponent }
    }

    public let root: URL
    /// 根目录下每个一级条目，按大小降序
    public let folders: [Folder]
    /// 最大的文件（应用、照片图库等包按整体算一个），按大小降序
    public let largestFiles: [File]
    public let scannedItems: Int
    public let totalBytes: UInt64
    public let date: Date

    public init(root: URL, folders: [Folder], largestFiles: [File], scannedItems: Int, totalBytes: UInt64, date: Date) {
        self.root = root
        self.folders = folders
        self.largestFiles = largestFiles
        self.scannedItems = scannedItems
        self.totalBytes = totalBytes
        self.date = date
    }
}

public struct SpaceScanProgress: Sendable, Equatable {
    public var items: Int
    public var bytes: UInt64
    public var current: String

    public init(items: Int, bytes: UInt64, current: String) {
        self.items = items
        self.bytes = bytes
        self.current = current
    }
}

/// 扫描一个目录（默认家目录）：算出每个一级条目占多少，并找出最大的文件。
/// 用 fts 逐层遍历，比 FileManager 的枚举器快一个数量级；只读，不跟随符号链接、不跨越挂载点，
/// 没有权限的目录跳过。扫描在调用方的任务里进行，任务取消即停止
public enum SpaceScanner {
    public static let largestFileCount = 20
    /// 小于这个体积的文件不进“最大的文件”
    public static let largestFileFloor: UInt64 = 50_000_000
    static let progressEvery = 5_000
    /// 按整体算一个条目的包：应用、各种图库、工程与文档包
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "qlgenerator", "prefpane",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "band",
        "xcodeproj", "xcworkspace", "playground", "xcarchive", "dSYM",
        "pages", "numbers", "key", "rtfd", "scriv", "sparsebundle", "pvm", "vmwarevm", "utm", "pkg", "mpkg",
    ]

    public static func scan(root: URL = FileManager.default.homeDirectoryForCurrentUser,
                            progress: @Sendable (SpaceScanProgress) -> Void = { _ in }) throws -> SpaceScanResult {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .contentModificationDateKey]
        let entries = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [])) ?? []

        var folders: [SpaceScanResult.Folder] = []
        var candidates: [SpaceScanResult.File] = []
        var scanned = 0
        var totalBytes: UInt64 = 0

        func consider(_ file: SpaceScanResult.File) {
            guard file.bytes >= largestFileFloor else { return }
            if candidates.count < largestFileCount {
                candidates.append(file)
            } else if let smallest = candidates.indices.min(by: { candidates[$0].bytes < candidates[$1].bytes }),
                      candidates[smallest].bytes < file.bytes {
                candidates[smallest] = file
            }
        }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Task.checkCancellation()
            guard let values = try? entry.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            var bytes: UInt64 = 0
            var items = 0
            if values.isDirectory == true {
                let walked = try walk(entry, scannedBefore: scanned, bytesBefore: totalBytes, consider: consider, progress: progress)
                bytes = walked.bytes
                items = walked.items
            } else if values.isRegularFile == true {
                bytes = UInt64(values.totalFileAllocatedSize ?? 0)
                items = 1
                consider(SpaceScanResult.File(url: entry, bytes: bytes, modified: values.contentModificationDate, isPackage: false))
            } else {
                continue
            }
            scanned += items
            totalBytes += bytes
            folders.append(SpaceScanResult.Folder(url: entry, name: entry.lastPathComponent, bytes: bytes, items: items))
            progress(SpaceScanProgress(items: scanned, bytes: totalBytes, current: entry.lastPathComponent))
        }

        return SpaceScanResult(root: root,
                               folders: folders.sorted { $0.bytes > $1.bytes },
                               largestFiles: candidates.sorted { $0.bytes > $1.bytes },
                               scannedItems: scanned, totalBytes: totalBytes, date: Date())
    }

    /// 用 fts 遍历一个目录：返回占用与条目数；包整体作为一个候选，包里的文件不单独进候选
    private static func walk(_ directory: URL, scannedBefore: Int, bytesBefore: UInt64,
                             consider: (SpaceScanResult.File) -> Void,
                             progress: (SpaceScanProgress) -> Void) throws -> (bytes: UInt64, items: Int) {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(directory.path), nil]
        defer { free(argv[0]) }
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return (0, 0) }
        defer { fts_close(stream) }

        var bytes: UInt64 = 0
        var items = 0
        // 正在经过的包（最外层在前）；内层包的体积并入外层
        var packages: [(path: String, bytes: UInt64, modified: Date?)] = []
        let name = directory.lastPathComponent

        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            // 顶层目录本身不算条目
            if entry.pointee.fts_level == 0 { continue }
            switch info {
            case FTS_D:
                items += 1
                let path = String(cString: entry.pointee.fts_path)
                if isPackage(path) {
                    let stat = entry.pointee.fts_statp.pointee
                    packages.append((path, 0, Date(timeIntervalSince1970: TimeInterval(stat.st_mtimespec.tv_sec))))
                }
            case FTS_DP:
                let path = String(cString: entry.pointee.fts_path)
                if let last = packages.last, last.path == path {
                    packages.removeLast()
                    if packages.isEmpty {
                        consider(SpaceScanResult.File(url: URL(fileURLWithPath: path), bytes: last.bytes, modified: last.modified, isPackage: true))
                    } else {
                        packages[packages.count - 1].bytes += last.bytes
                    }
                }
            case FTS_F:
                items += 1
                let stat = entry.pointee.fts_statp.pointee
                let size = UInt64(max(0, stat.st_blocks)) * 512
                bytes += size
                if packages.isEmpty {
                    consider(SpaceScanResult.File(url: URL(fileURLWithPath: String(cString: entry.pointee.fts_path)), bytes: size,
                                                  modified: Date(timeIntervalSince1970: TimeInterval(stat.st_mtimespec.tv_sec)), isPackage: false))
                } else {
                    packages[packages.count - 1].bytes += size
                }
            default:
                // 符号链接、没权限的目录、读取出错的条目都跳过
                continue
            }
            if items % progressEvery == 0 {
                try Task.checkCancellation()
                progress(SpaceScanProgress(items: scannedBefore + items, bytes: bytesBefore + bytes, current: name))
            }
        }
        return (bytes, items)
    }

    static func isPackage(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return !ext.isEmpty && packageExtensions.contains(ext.lowercased()) || packageExtensions.contains(ext)
    }

    /// 能不能把扫描出来的文件移到废纸篓：必须在家目录里、不在 Library 里、路径里没有隐藏目录，
    /// 解析符号链接后仍然满足。不满足的只提供“在访达中显示”
    public static func canTrash(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let homePath = home.standardizedFileURL.path
        for candidate in [url.standardizedFileURL, url.resolvingSymlinksInPath().standardizedFileURL] {
            let path = candidate.path
            guard path.hasPrefix(homePath + "/") else { return false }
            let relative = path.dropFirst(homePath.count + 1)
            let components = relative.split(separator: "/")
            guard components.count >= 2 else { return false }
            guard components.first != "Library" else { return false }
            guard !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        }
        return true
    }

    /// 移到废纸篓（可恢复）；不允许的路径直接报错
    public static func trash(_ url: URL) throws {
        guard canTrash(url) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

// MARK: - 外部命令

enum ShellTool {
    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
