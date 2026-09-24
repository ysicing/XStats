import CryptoKit
import Darwin
import Foundation
import Localization
import Security

public enum UpdateError: Error, LocalizedError, Equatable {
    case download(String)
    case checksumMismatch
    case archive(String)
    case invalidBundle(String)
    case signature(String)
    case gatekeeper
    case install(String)

    public var errorDescription: String? {
        switch self {
        case .download(let reason): tr("下载失败：\(reason)")
        case .checksumMismatch: tr("安装包校验值与版本清单不一致，已放弃安装")
        case .archive(let reason): tr("解压失败：\(reason)")
        case .invalidBundle(let reason): tr("安装包内容不正确：\(reason)")
        case .signature(let reason): tr("签名校验未通过：\(reason)")
        case .gatekeeper: tr("新版本未通过 Apple 公证检查，已放弃安装")
        case .install(let reason): tr("替换应用失败：\(reason)")
        }
    }
}

/// 在线升级的各个步骤：下载 → 校验 sha256 → 解压 → 校验包名 / 版本 / 签名团队 / 公证 → 原地替换 → 重启
public enum UpdateInstaller {
    // MARK: 下载

    public static func download(_ url: URL, into directory: URL,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try await Downloader(destination: destination, progress: progress).run(url)
        return destination
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 解压

    /// ditto 解压，保留包内符号链接与扩展属性；返回解出的 .app
    public static func extractApp(from archive: URL, into directory: URL) throws -> URL {
        let output = directory.appendingPathComponent("extracted", isDirectory: true)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let result = run("/usr/bin/ditto", ["-x", "-k", archive.path, output.path])
        guard result.status == 0 else { throw UpdateError.archive(result.output) }
        let apps = (try? FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else { throw UpdateError.archive(tr("压缩包里应当只有一个 .app")) }
        return app
    }

    // MARK: 校验

    /// 包名、版本号、签名团队必须与预期一致，并通过严格签名校验与 Gatekeeper（公证）检查
    public static func verify(_ app: URL, bundleIdentifier: String, version: String, teamIdentifier: String,
                              architecture: UpdateArchitecture = .current) throws {
        guard let bundle = Bundle(url: app) else { throw UpdateError.invalidBundle(tr("无法读取")) }
        guard bundle.bundleIdentifier == bundleIdentifier else {
            throw UpdateError.invalidBundle(tr("包名是 \(bundle.bundleIdentifier ?? tr("空"))"))
        }
        let bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard bundleVersion == version else {
            throw UpdateError.invalidBundle(tr("版本是 \(bundleVersion ?? tr("空"))，清单写的是 \(version)"))
        }
        // Apple 芯片版与 Intel 版分开发布，装错了应用根本打不开
        guard bundle.executableArchitectures?.contains(where: { $0.intValue == architecture.executableArchitecture }) == true else {
            throw UpdateError.invalidBundle(tr("安装包不支持这台 Mac 的芯片"))
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            throw UpdateError.signature(tr("无法读取签名"))
        }
        let requirementText = "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess else {
            throw UpdateError.signature(tr("无法创建签名要求"))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw UpdateError.signature(tr("不是团队 \(teamIdentifier) 签名的完整应用（\(status)）"))
        }

        let assessment = run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path])
        guard assessment.status == 0, assessment.output.contains("accepted") else { throw UpdateError.gatekeeper }
    }

    /// 应用自身的签名团队；开发构建（未签名或临时签名）返回 nil
    public static func teamIdentifier(of app: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: 替换

    /// 旧版先改名为备份，再把新版移到原位置；移动失败时还原旧版。两者在同一卷上，改名是原子的。
    public static func replace(_ current: URL, with candidate: URL, backupDirectory: URL) throws {
        try stopWidgetExtension(in: current)
        let manager = FileManager.default
        let backup = backupDirectory.appendingPathComponent("previous-\(current.lastPathComponent)")
        try? manager.removeItem(at: backup)
        do {
            try manager.moveItem(at: current, to: backup)
        } catch {
            throw UpdateError.install(error.localizedDescription)
        }
        do {
            try manager.moveItem(at: candidate, to: current)
        } catch {
            try? manager.moveItem(at: backup, to: current)
            throw UpdateError.install(error.localizedDescription)
        }
        try? manager.removeItem(at: backup)
    }

    /// 仅结束属于这份应用的旧小组件进程，避免替换后 WidgetKit 继续向旧进程索取组件清单。
    public static func stopWidgetExtension(in app: URL) throws {
        let executable = app.appendingPathComponent("Contents/PlugIns/XStatsWidget.appex/Contents/MacOS/XStatsWidget").path
        var resolved = [CChar](repeating: 0, count: 4096)
        guard realpath(executable, &resolved) != nil else { return }
        let expectedPath = String(decoding: resolved.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let capacity = max(1, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count >= 0 else { throw UpdateError.install(tr("应用正在运行，请先退出")) }

        for pid in pids.prefix(Int(count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) == expectedPath else {
                continue
            }
            if kill(pid, SIGTERM) != 0 && errno != ESRCH {
                throw UpdateError.install(tr("应用正在运行，请先退出") + " (XStatsWidget)")
            }
            for _ in 0..<50 {
                if kill(pid, 0) != 0 { break }
                usleep(100_000)
            }
            if kill(pid, 0) == 0 {
                throw UpdateError.install(tr("应用正在运行，请先退出") + " (XStatsWidget)")
            }
        }
    }

    /// 当前用户能否直接改写应用所在目录（管理员账户对 /Applications 通常可以）
    public static func canReplaceInPlace(_ app: URL) -> Bool {
        let parent = app.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent) && FileManager.default.isWritableFile(atPath: app.path)
    }

    /// 等当前进程退出后重新打开应用。路径与 PID 作为位置参数传入，不拼进脚本
    public static func relaunch(_ app: URL, afterExitOf pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                             "xstats-relaunch", String(pid), app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    // MARK: 工具

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// 带进度的下载：系统把文件下载到临时位置，完成回调里立即移到目标位置
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(_ url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 15 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { self.continuation = continuation }
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            moveError = UpdateError.download(tr("服务器返回 \(response.statusCode)"))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error = error ?? moveError {
            let message = (error as? UpdateError)?.errorDescription ?? error.localizedDescription
            continuation?.resume(throwing: error as? UpdateError ?? UpdateError.download(message))
        } else {
            continuation?.resume()
        }
    }
}
