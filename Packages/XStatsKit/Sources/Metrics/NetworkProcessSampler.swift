import Darwin
import Foundation

private final class LockedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func store(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func load() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public struct NetworkProcessUsage: Sendable, Equatable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    public let appBundlePath: String?
    public var download: Double     // 字节 / 秒
    public var upload: Double
}

/// 各进程的网络速率。系统没有公开接口，读取 /usr/bin/nettop 的累计字节数并与上次比较。
/// 只在网络详情打开时运行，每次约 40 ms。
public struct NetworkProcessSampler: Sendable {
    private static let nettopLock = NSLock()
    private var previous: [Int32: (download: UInt64, upload: UInt64)] = [:]
    private var previousTime: UInt64 = 0
    private var lastResults: [NetworkProcessUsage] = []

    public init() {}

    public mutating func sample(limit: Int = 8) -> [NetworkProcessUsage] {
        sample(output: Self.runNettop(), now: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), limit: limit)
    }

    /// 将 `nettop` 的累计值换算成区间速率。读取失败时保留上次结果，避免界面短暂清空。
    mutating func sample(output: String?, now: UInt64, limit: Int = 8) -> [NetworkProcessUsage] {
        guard let output else { return lastResults }
        let seconds = previousTime > 0 ? Double(now - previousTime) / 1_000_000_000 : 0
        let totals = Self.parse(output)

        var results: [NetworkProcessUsage] = []
        if seconds > 0 {
            for (pid, entry) in totals {
                guard let before = previous[pid] else { continue }
                let download = entry.download >= before.download ? Double(entry.download - before.download) / seconds : 0
                let upload = entry.upload >= before.upload ? Double(entry.upload - before.upload) / seconds : 0
                guard download + upload > 0 else { continue }
                let meta = ProcessSampler.meta(for: pid)
                let processName = meta.name == "PID \(pid)" ? entry.name : meta.name
                results.append(NetworkProcessUsage(pid: pid, name: meta.bundle.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? processName,
                                                   appBundlePath: meta.bundle, download: download, upload: upload))
            }
        }
        previous = totals.mapValues { ($0.download, $0.upload) }
        previousTime = now

        // 同一应用的多个进程合并为一行
        var merged: [String: NetworkProcessUsage] = [:]
        for usage in results {
            let key = usage.appBundlePath ?? "\(usage.pid)"
            if var existing = merged[key] {
                existing.download += usage.download
                existing.upload += usage.upload
                merged[key] = existing
            } else {
                merged[key] = usage
            }
        }
        let ranked = merged.values
            .sorted { $0.download + $0.upload > $1.download + $1.upload }
            .prefix(limit)
            .map { $0 }
        lastResults = ranked
        return ranked
    }

    /// 解析 `nettop -P -L 1 -x -J bytes_in,bytes_out` 的 CSV：`进程名.PID,入字节,出字节,`
    static func parse(_ output: String) -> [Int32: (name: String, download: UInt64, upload: UInt64)] {
        var result: [Int32: (name: String, download: UInt64, upload: UInt64)] = [:]
        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3,
                  let dot = columns[0].lastIndex(of: "."),
                  let pid = Int32(columns[0][columns[0].index(after: dot)...]),
                  let download = UInt64(columns[1]),
                  let upload = UInt64(columns[2]) else { continue }
            result[pid] = (String(columns[0][..<dot]), download, upload)
        }
        return result
    }

    private static func runNettop() -> String? {
        nettopLock.lock()
        defer { nettopLock.unlock() }
        guard !Task.isCancelled else { return nil }
        return run(path: "/usr/bin/nettop", arguments: ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"], timeout: 5)
    }

    /// 同步运行短命令并持续排空 stdout；超时后先 TERM、再 KILL，避免 `nettop` 挂住采样循环。
    static func run(path: String, arguments: [String], timeout: TimeInterval) -> String? {
        guard !Task.isCancelled else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let output = LockedProcessOutput()
        let drain = DispatchGroup()
        drain.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drain.leave() }
            // 旧的 readDataToEndOfFile() 在超时关闭 pipe 时可能抛出无法由 Swift 捕获的 NSException。
            // throwing API 会把同一竞争转换成普通 I/O 错误，失败时由调用方按无采样结果处理。
            guard let data = try? pipe.fileHandleForReading.readToEnd() else { return }
            output.store(data)
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForWriting.closeFile()
            drain.wait()
            return nil
        }

        let timeoutNanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
        let deadline = DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        var stopped = false
        var exited = false
        while !exited {
            if Task.isCancelled {
                stopped = true
                break
            }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                stopped = true
                break
            }
            let slice = min(deadline - now, 50_000_000)
            exited = terminated.wait(timeout: .now() + .nanoseconds(Int(slice))) == .success
        }

        if stopped {
            if process.isRunning { process.terminate() }
            exited = terminated.wait(timeout: .now() + 0.5) == .success
            if !exited {
                kill(process.processIdentifier, SIGKILL)
                exited = terminated.wait(timeout: .now() + 0.5) == .success
            }
        }
        guard exited else {
            pipe.fileHandleForReading.closeFile()
            return nil
        }
        process.waitUntilExit()
        guard drain.wait(timeout: .now() + 0.5) == .success else {
            pipe.fileHandleForReading.closeFile()
            return nil
        }

        guard !stopped, process.terminationStatus == 0,
              let data = output.load() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
