import Foundation
import Localization

public struct History<Element: Sendable>: Sendable {
    public let capacity: Int
    public private(set) var elements: [Element] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        elements.reserveCapacity(self.capacity)
    }

    public mutating func append(_ element: Element) {
        if elements.count == capacity { elements.removeFirst() }
        elements.append(element)
    }
}

public enum Format {
    public enum ByteBase: Sendable {
        case binary   // 内存：1 GB = 1024³，与活动监视器一致
        case decimal  // 磁盘：1 GB = 1000³，与访达一致
    }

    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// 逻辑核心数（性能核与能效核合计），进程 CPU 换算成整机占比时用
    public static let logicalCores = max(1, ProcessInfo.processInfo.activeProcessorCount)

    /// 进程 CPU 按单核满载为 100% 的写法（活动监视器、top 的算法），多线程进程可以超过 100%。例：99.5%
    public static func coreShare(_ value: Double) -> String {
        "\((max(0, value) * 100).formatted(.number.precision(.fractionLength(1))))%"
    }

    /// 进程 CPU 占整机的比例：全部核心跑满为 100%，和系统总占用是同一把尺子。`value` 是单核口径。
    /// 小于 0.1% 但不为 0 时写 “<0.1%”，不把正在跑的进程显示成 0
    public static func machineShare(_ value: Double) -> String {
        let share = max(0, value) / Double(logicalCores) * 100
        if share > 0, share < 0.05 { return "<0.1%" }
        return "\(share.formatted(.number.precision(.fractionLength(1))))%"
    }

    public static func bytes(_ value: UInt64, base: ByteBase = .binary) -> String {
        bytes(Double(value), base: base)
    }

    public static func bytes(_ value: Double, base: ByteBase = .binary) -> String {
        let step: Double = base == .binary ? 1024 : 1000
        var amount = max(0, value)
        var index = 0
        while amount >= step, index < units.count - 1 {
            amount /= step
            index += 1
        }
        if index == 0 { return "\(Int(amount)) B" }
        let digits = amount >= 100 ? 0 : 1
        return "\(amount.formatted(.number.precision(.fractionLength(digits)))) \(units[index])"
    }

    /// 菜单栏网速：保留完整单位，数字最多 3 位，宽度稳定
    /// 例：512 B/s、12 KB/s、154 KB/s、1.2 MB/s、12 MB/s、1.1 GB/s
    public static func menuBarRate(_ bytesPerSecond: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = max(0, bytesPerSecond)
        var index = 0
        // 超过 999 就进位，避免出现 1023 KB/s 这种 4 位数
        while value >= 999.5, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        let text = index >= 2 && value < 9.95
            ? value.formatted(.number.precision(.fractionLength(1)))
            : String(Int(value.rounded()))
        return "\(text) \(units[index])"
    }

    /// 测速用的带宽：按 1000 进位，单位与运营商、测速站一致
    /// 例：820 kbps、95.3 Mbps、1.21 Gbps
    public static func bandwidth(_ bitsPerSecond: Double) -> String {
        let units = ["bps", "kbps", "Mbps", "Gbps"]
        var value = max(0, bitsPerSecond)
        guard value >= 1 else { return "0 bps" }
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return "\(value.formatted(.number.precision(.fractionLength(digits)))) \(units[index])"
    }

    public static func percent(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }

    public static func temperature(_ celsius: Double, fahrenheit: Bool = false) -> String {
        fahrenheit ? "\(Int((celsius * 9 / 5 + 32).rounded()))°F" : "\(Int(celsius.rounded()))°C"
    }

    public static func watts(_ value: Double) -> String {
        value < 10 ? "\(value.formatted(.number.precision(.fractionLength(1)))) W" : "\(Int(value.rounded())) W"
    }

    /// 频率：MHz 输入，1000 以上显示为 GHz
    public static func frequency(megahertz value: Double) -> String {
        value >= 1000 ? "\((value / 1000).formatted(.number.precision(.fractionLength(2)))) GHz" : "\(Int(value.rounded())) MHz"
    }

    public static func rpm(_ value: Double) -> String {
        "\(Int(value.rounded())) RPM"
    }

    public static func duration(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return tr("\(rest) 分钟")
        case (_, 0): return tr("\(hours) 小时")
        default: return tr("\(hours) 小时 \(rest) 分钟")
        }
    }

    /// CPU 时间：不到 1 分钟显示“12.34 秒”，不到 1 小时“12:34”，更长“1:02:03”
    public static func cpuTime(_ seconds: Double) -> String {
        let total = max(0, seconds)
        if total < 60 { return tr("\(total.formatted(.number.precision(.fractionLength(2)))) 秒") }
        let whole = Int(total)
        let hours = whole / 3600, minutes = whole % 3600 / 60, secs = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    public static func uptime(since date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        let days = minutes / (60 * 24)
        let hours = (minutes / 60) % 24
        if days > 0 { return hours > 0 ? tr("\(days) 天 \(hours) 小时") : tr("\(days) 天") }
        if hours > 0 { return tr("\(hours) 小时") }
        return tr("\(minutes) 分钟")
    }
}
