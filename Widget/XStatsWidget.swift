import Metrics
import SwiftUI
import WidgetData
import WidgetKit

// 桌面小组件：在自己的沙盒进程里直接读取 CPU、内存、磁盘与电池，不依赖主应用是否运行。
// 刷新频率由系统决定（通常每 5 到 15 分钟），适合“看一眼”，实时数据仍以菜单栏为准。

struct SystemEntry: TimelineEntry {
    let date: Date
    let cpu: Double?
    let memory: Double?
    let memoryPressure: MemoryPressure?
    let disk: Double?
    let diskFree: UInt64?
    let battery: Double?
    let charging: Bool

    static let placeholder = SystemEntry(date: .now, cpu: 0.18, memory: 0.62, memoryPressure: .normal,
                                         disk: 0.41, diskFree: 1_200_000_000_000, battery: 0.86, charging: false)
}

struct SystemProvider: TimelineProvider {
    func placeholder(in context: Context) -> SystemEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (SystemEntry) -> Void) {
        completion(context.isPreview ? .placeholder : Self.read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemEntry>) -> Void) {
        let entry = Self.read()
        completion(Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(5 * 60))))
    }

    /// CPU 占用需要两次采样，间隔半秒
    static func read() -> SystemEntry {
        var sampler = CPUSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 0.5)
        let cpu = sampler.sample()
        let memory = MemorySampler().sample()
        let disk = DiskSampler.sample()
        let battery = BatterySampler.sample()
        return SystemEntry(date: .now, cpu: cpu?.total, memory: memory?.usedFraction, memoryPressure: memory?.pressure,
                           disk: disk?.usedFraction, diskFree: disk?.available,
                           battery: battery?.level, charging: battery?.isCharging ?? false)
    }
}

// MARK: - 视图

private enum Palette {
    static let primary = Color(light: 0x2563EB, dark: 0x3B82F6)
    static let success = Color(light: 0x16A34A, dark: 0x22C55E)
    static let warning = Color(light: 0xD97706, dark: 0xF59E0B)
    static let error = Color(light: 0xDC2626, dark: 0xF87171)
    static let textPrimary = Color(light: 0x111827, dark: 0xF3F4F6)
    static let textSecondary = Color(light: 0x6B7280, dark: 0x9CA3AF)
    static let track = Color.primary.opacity(0.08)
    static let background = Color(light: 0xFFFFFF, dark: 0x0B0B0D)

    static func load(_ fraction: Double) -> Color {
        fraction >= 0.85 ? error : fraction >= 0.6 ? warning : primary
    }
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

private func percent(_ value: Double?) -> String {
    value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
}

private struct Gauge: View {
    let title: String
    let value: Double?
    var color: Color?
    var size: CGFloat = 56

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Palette.track, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: min(1, max(0, value ?? 0)))
                    .stroke(color ?? Palette.load(value ?? 0), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(percent(value))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(width: size, height: size)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.textSecondary)
        }
    }
}

private struct BarRow: View {
    let title: String
    let value: Double?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                Spacer()
                Text(detail).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(Palette.textPrimary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(Palette.load(value ?? 0)).frame(width: proxy.size.width * min(1, max(0, value ?? 0)))
                }
            }
            .frame(height: 6)
        }
    }
}

struct SystemWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SystemEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium: medium
            default: small
            }
        }
        .containerBackground(Palette.background, for: .widget)
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.primary)
            Text("XStats").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textPrimary)
            Spacer()
            Text(entry.date, style: .time).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack {
                Gauge(title: "CPU", value: entry.cpu, size: 48)
                Spacer()
                Gauge(title: "内存", value: entry.memory, color: pressureColor, size: 48)
            }
            BarRow(title: "磁盘", value: entry.disk, detail: percent(entry.disk))
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack {
                Gauge(title: "CPU", value: entry.cpu)
                Spacer()
                Gauge(title: "内存", value: entry.memory, color: pressureColor)
                Spacer()
                Gauge(title: "磁盘", value: entry.disk)
                if let battery = entry.battery {
                    Spacer()
                    Gauge(title: entry.charging ? "充电中" : "电池", value: battery,
                          color: battery <= 0.2 ? Palette.error : Palette.success)
                }
            }
            if let free = entry.diskFree {
                Text("磁盘可用 \(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file))")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private var pressureColor: Color {
        switch entry.memoryPressure {
        case .critical: Palette.error
        case .warning: Palette.warning
        default: Palette.primary
        }
    }
}

struct SystemWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKind.system, provider: SystemProvider()) { entry in
            SystemWidgetView(entry: entry)
        }
        .configurationDisplayName("系统概览")
        .description("CPU、内存、磁盘与电池。每隔几分钟刷新一次。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct XStatsWidgets: WidgetBundle {
    var body: some Widget {
        SystemWidget()
        CalendarWidget()
        MonthCalendarWidget()
        TomorrowWorkWidget()
        AIQuotaWidget()
        TodayTokensWidget()
        IPPurityWidget()
        PublicIPWidget()
    }
}
