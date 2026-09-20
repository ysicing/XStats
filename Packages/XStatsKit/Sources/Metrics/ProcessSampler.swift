import Darwin
import Foundation

public struct ProcessSampler {
    private struct Identity: Hashable {
        let pid: Int32
        let startTime: UInt64
    }

    struct Meta {
        let name: String
        let path: String?
        let bundle: String?
    }

    private struct Counters {
        var cpuTime: UInt64
        var idleWakeups: UInt64
        var diskRead: UInt64
        var diskWrite: UInt64
    }

    private var previous: [Identity: Counters] = [:]
    private var previousTime: UInt64 = 0
    private var metaCache: [Identity: Meta] = [:]
    /// 其他用户进程的累计 CPU 时间（秒），来自 ps
    private var previousSystem: [Int32: Double] = [:]
    private var previousSystemDate: Date?
    private var userNames: [UInt32: String] = [:]

    private static let timebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    public init() {}

    /// 返回按 CPU 排序的进程。当前用户自己的进程读 proc_pid_rusage，数据最全；
    /// `includeSystem` 为真时再用 /bin/ps（系统自带、有 root 权限）补上其他用户与系统的进程，只有 CPU、内存与 CPU 时间。
    public mutating func sample(includeSystem: Bool = false) -> [ProcessUsage] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        guard count > 0 else { return [] }

        // CPU 时间与墙钟时间都用 mach 绝对时间单位，比值无需换算时基
        let now = mach_absolute_time()
        let elapsed = previousTime > 0 ? now - previousTime : 0
        let seconds = Double(elapsed) * Self.timebase / 1_000_000_000

        var counters: [Identity: Counters] = [:]
        var liveMeta: [Identity: Meta] = [:]
        var results: [ProcessUsage] = []
        var owned = Set<Int32>()
        results.reserveCapacity(count)

        for pid in pids.prefix(count) where pid > 0 {
            var info = rusage_info_v4()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard status == 0 else { continue }
            owned.insert(pid)

            let identity = Identity(pid: pid, startTime: info.ri_proc_start_abstime)
            let current = Counters(cpuTime: info.ri_user_time + info.ri_system_time, idleWakeups: info.ri_interrupt_wkups,
                                   diskRead: info.ri_diskio_bytesread, diskWrite: info.ri_diskio_byteswritten)
            counters[identity] = current

            let meta = metaCache[identity] ?? Self.meta(for: pid)
            liveMeta[identity] = meta

            var usage = ProcessUsage(pid: pid, name: meta.name, executablePath: meta.path,
                                     appBundlePath: meta.bundle, cpu: 0, memory: info.ri_phys_footprint)
            usage.cpuTime = Double(current.cpuTime) * Self.timebase / 1_000_000_000
            if elapsed > 0, let before = previous[identity] {
                if current.cpuTime >= before.cpuTime { usage.cpu = Double(current.cpuTime - before.cpuTime) / Double(elapsed) }
                if seconds > 0 {
                    usage.idleWakeups = Double(current.idleWakeups &- before.idleWakeups) / seconds
                    usage.diskRead = Double(current.diskRead >= before.diskRead ? current.diskRead - before.diskRead : 0) / seconds
                    usage.diskWrite = Double(current.diskWrite >= before.diskWrite ? current.diskWrite - before.diskWrite : 0) / seconds
                }
            }
            var task = proc_taskinfo()
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) == Int32(MemoryLayout<proc_taskinfo>.size) {
                usage.threads = Int(task.pti_threadnum)
            }
            var bsd = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) {
                usage.uid = bsd.pbi_uid
            } else {
                usage.uid = getuid()
            }
            usage.userName = userName(usage.uid)
            results.append(usage)
        }

        previous = counters
        previousTime = now
        metaCache = liveMeta

        if includeSystem {
            results += systemProcesses(excluding: owned)
        } else {
            previousSystem = [:]
            previousSystemDate = nil
        }

        results.sort { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
        return results
    }

    // MARK: 系统进程

    private mutating func systemProcesses(excluding owned: Set<Int32>) -> [ProcessUsage] {
        guard let output = Self.runPS() else { return [] }
        let now = Date()
        let interval = previousSystemDate.map { now.timeIntervalSince($0) } ?? 0
        var times: [Int32: Double] = [:]
        var results: [ProcessUsage] = []

        for entry in Self.parsePS(output) where !owned.contains(entry.pid) {
            times[entry.pid] = entry.cpuTime
            let name = URL(fileURLWithPath: entry.command).lastPathComponent
            var usage = ProcessUsage(pid: entry.pid, name: name.isEmpty ? entry.command : name,
                                     executablePath: entry.command.hasPrefix("/") ? entry.command : nil,
                                     appBundlePath: nil, cpu: 0, memory: entry.residentBytes)
            if interval > 0, let before = previousSystem[entry.pid], entry.cpuTime >= before {
                usage.cpu = (entry.cpuTime - before) / interval
            }
            usage.cpuTime = entry.cpuTime
            usage.uid = entry.uid
            usage.userName = userName(entry.uid)
            usage.isOwned = false
            results.append(usage)
        }
        previousSystem = times
        previousSystemDate = now
        return results
    }

    struct PSEntry: Equatable {
        let pid: Int32
        let uid: UInt32
        let cpuTime: Double
        let residentBytes: UInt64
        let command: String
    }

    /// 解析 `ps -axo pid=,uid=,time=,rss=,comm=`；命令路径里可能有空格，取前四列之后的全部内容
    static func parsePS(_ output: String) -> [PSEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5, let pid = Int32(fields[0]), let uid = UInt32(fields[1]),
                  let time = parseCPUTime(String(fields[2])), let rss = UInt64(fields[3]) else { return nil }
            return PSEntry(pid: pid, uid: uid, cpuTime: time, residentBytes: rss * 1024,
                           command: fields[4].trimmingCharacters(in: .whitespaces))
        }
    }

    /// ps 的 CPU 时间格式为 “分:秒.百分秒”，时间长时可能带小时 “时:分:秒.百分秒”
    static func parseCPUTime(_ text: String) -> Double? {
        let parts = text.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    private static func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,uid=,time=,rss=,comm="]
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

    private mutating func userName(_ uid: UInt32) -> String {
        if let cached = userNames[uid] { return cached }
        let name = getpwuid(uid).flatMap { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
        userNames[uid] = name
        return name
    }

    static func meta(for pid: pid_t) -> Meta {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(nullTerminated: pathBuffer) : nil

        var name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        if name.isEmpty {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            name = String(nullTerminated: nameBuffer)
        }

        // 取最外层 .app，辅助进程也能显示主应用图标
        let bundle = path.flatMap { path -> String? in
            guard let range = path.range(of: ".app/") else { return nil }
            return String(path[..<range.lowerBound]) + ".app"
        }
        return Meta(name: name.isEmpty ? "PID \(pid)" : name, path: path, bundle: bundle)
    }
}
