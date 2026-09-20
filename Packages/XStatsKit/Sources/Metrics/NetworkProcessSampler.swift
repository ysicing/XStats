import Darwin
import Foundation

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
    private var previous: [Int32: (download: UInt64, upload: UInt64)] = [:]
    private var previousTime: UInt64 = 0

    public init() {}

    public mutating func sample(limit: Int = 8) -> [NetworkProcessUsage] {
        guard let output = Self.runNettop() else { return [] }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
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
                results.append(NetworkProcessUsage(pid: pid, name: meta.bundle.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? meta.name,
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
        return merged.values
            .sorted { $0.download + $0.upload > $1.download + $1.upload }
            .prefix(limit)
            .map { $0 }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
