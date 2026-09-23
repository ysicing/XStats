import AppKit
import Localization
import Metrics
import SMC
import SwiftUI

private let heroGauge = DS.Space.s12 + DS.Space.s2

extension View {
    /// 详情图表高度：弹窗里紧凑，主窗口里放大
    @MainActor
    func detailChartHeight(_ isDetailPage: Bool) -> CGFloat {
        isDetailPage ? DS.Size.chartHeight * 3 : DS.Size.chartHeight
    }
}

private func loadTone(_ value: Double) -> Tone {
    value >= 0.85 ? .error : value >= 0.6 ? .warning : .primary
}

// MARK: - CPU

struct CPUPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        CPUHero()

        if isDetailPage {
            // 主窗口更宽：先是最直观的各核心圆环，再是热力图；核心分工与排队程度并排，按应用汇总占满一行
            card(.cpuCores)
            card(.cpuHeatmap)
            HStack(alignment: .top, spacing: DS.Space.s3) {
                card(.cpuClusters)
                card(.cpuLoadAverage)
            }
            card(.cpuApps)
        } else {
            ForEach(MenuBarItem.cpu.popoverSections.filter { model.settings.isVisible($0) }) { section in
                card(section)
            }
        }
    }

    @ViewBuilder
    private func card(_ section: PopoverSection) -> some View {
        let store = model.store
        let cpu = store.cpu
        let cores = Double(max(1, store.topology.logicalCores))

        switch section {
        // 各区块的解释都放在悬停提示里（标题旁的 ⓘ 或卡片内容），界面上只留数据
        case .cpuHeatmap:
            SectionCard(title: section.title,
                        hint: tr("每行一个核心（共 \(store.topology.logicalCores) 个），每列一次采样，颜色越深越忙；右侧粗条是此刻的占用"),
                        trailing: { HeatLegend() }) {
                CoreHeatmap(topology: store.topology, history: store.coreHistory.elements,
                            columns: isDetailPage ? 60 : 36,
                            rowHeight: isDetailPage ? DS.Space.s2 : DS.Space.s1 - DS.Size.stroke)
            }
        case .cpuCores:
            // 主窗口：每个核心一个圆环，中间写百分比，最直观；弹窗窄，用每核一根柱子的紧凑版（默认关闭，在设置里打开）
            if isDetailPage {
                SectionCard(title: section.title, hint: tr("此刻各核心的占用；超过 60% 变橙色、85% 变红色")) {
                    CoreRingGrid(topology: store.topology, perCore: cpu?.perCore ?? [])
                }
            } else {
                SectionCard(title: section.title, hint: tr("每根柱子一个核心，按核心类型着色")) {
                    CoreClusterBars(topology: store.topology, perCore: cpu?.perCore ?? [], byCluster: true)
                }
            }
        case .cpuClusters:
            SectionCard(title: section.title, hint: clusterExplanation(store.topology),
                        trailing: { Text(verbatim: store.topology.brand) }) {
                ForEach(store.topology.clusters) { cluster in
                    let average = CoreClusterBars.average(of: cluster, perCore: cpu?.perCore ?? []) ?? 0
                    ShareRow(label: tr("\(cluster.name) · \(cluster.coreIndices.count) 核"), value: Format.percent(average),
                             detail: store.power?.clusterFrequency[cluster.id].map { Format.frequency(megahertz: $0) },
                             fraction: average, color: DS.Palette.cluster(cluster.id))
                }
                if let busiest = busiestCore(store.topology, cpu?.perCore ?? []) {
                    InfoRow(label: tr("最忙的核心"), text: busiest)
                }
            }
        case .cpuLoadAverage:
            SectionCard(title: section.title,
                        hint: tr("平均负载除以核心数：小于 1 表示任务不用排队，大于 1 表示有任务在等 CPU"),
                        trailing: { Text(loadTrend(cpu?.loadAverage ?? [])) }) {
                let averages = cpu?.loadAverage ?? []
                ForEach(Array([tr("1 分钟"), tr("5 分钟"), tr("15 分钟")].enumerated()), id: \.offset) { index, label in
                    let value = averages[safe: index] ?? 0
                    ShareRow(label: label,
                             value: tr("每核 \((value / cores).formatted(.number.precision(.fractionLength(2))))"),
                             fraction: value / cores, color: loadTone(value / cores).color)
                }
            }
        case .cpuApps:
            SectionCard(title: section.title,
                        hint: tr("每个应用占整机 CPU 的比例：\(Format.logicalCores) 个核心全部跑满为 100%，与顶部的总占用是同一把尺子。鼠标悬停在数值上可以看按单核计的占用（活动监视器的算法）")) {
                AppUsageList(apps: AppUsage.group(store.processes).sorted { $0.cpu > $1.cpu },
                             rowCount: isDetailPage ? 10 : 6, metric: .cpu)
            }
        default:
            EmptyView()
        }
    }

    private func loadTrend(_ averages: [Double]) -> String {
        guard averages.count >= 3, averages[2] > 0 else { return "" }
        let change = averages[0] / averages[2]
        return change > 1.15 ? tr("负载在上升") : change < 0.85 ? tr("负载在下降") : tr("负载平稳")
    }

    /// 核心按 1…N 统一编号，与“各核心占用”里的圆环标签一致，括号里注明它属于哪一类
    private func busiestCore(_ topology: CPUTopology, _ perCore: [Double]) -> String? {
        guard let (index, value) = perCore.enumerated().max(by: { $0.element < $1.element }).map({ ($0.offset, $0.element) }),
              let cluster = topology.clusters.first(where: { $0.coreIndices.contains(index) }) else { return nil }
        return tr("核心 \(index + 1)（\(cluster.name)）· \(Format.percent(value))")
    }

    /// 用人话说明每类核心是干什么的，只有一类核心（Intel）时不显示
    private func clusterExplanation(_ topology: CPUTopology) -> String? {
        let roles = topology.clusters.sorted { $0.id < $1.id }.compactMap { cluster in
            cluster.role(in: topology).map { tr("\(cluster.name)：\($0)") }
        }
        guard !roles.isEmpty else { return nil }
        return tr("\(roles.joined(separator: " · "))。系统会自动分配任务，不用你操心")
    }
}

extension CPUCluster {
    /// 这类核心的分工：最高档最快、最低档最省电、中间档介于两者之间；只有一类核心时没有分工可言
    func role(in topology: CPUTopology) -> String? {
        let levels = topology.clusters.count
        guard levels > 1 else { return nil }
        if id == 0 { return tr("最快，重活优先交给它们") }
        if id == levels - 1 { return tr("更省电，负责后台和轻量任务") }
        return tr("速度与省电介于两者之间")
    }
}

/// 主窗口里的各核心占用：每个核心一个小圆环，中间写百分比，按核心类型分组，
/// 组名后面用一句话说明这类核心是干什么的；圆环颜色随占用变化，忙的核心一眼能看到
private struct CoreRingGrid: View {
    let topology: CPUTopology
    let perCore: [Double]

    private static let ring = DS.Space.s12 + DS.Space.s2
    private static let columns = [GridItem(.adaptive(minimum: DS.Space.s16 + DS.Space.s2), spacing: DS.Space.s2)]

    var body: some View {
        // 最快的一类在前
        let clusters = topology.clusters.sorted { $0.id < $1.id }
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            ForEach(clusters) { cluster in
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    if clusters.count > 1 {
                        // 这类核心是干什么的，悬停组名时再说
                        HStack(spacing: DS.Space.s1) {
                            RoundedRectangle(cornerRadius: DS.Radius.sm / 2).fill(DS.Palette.cluster(cluster.id))
                                .frame(width: DS.Size.barHeight, height: DS.Size.barHeight)
                            Text(verbatim: tr("\(cluster.name) · \(cluster.coreIndices.count) 个"))
                                .dsFont(.xs, weight: .medium)
                                .foregroundStyle(DS.Palette.textPrimary)
                        }
                        .help(optional: cluster.role(in: topology))
                    }
                    LazyVGrid(columns: Self.columns, alignment: .leading, spacing: DS.Space.s2) {
                        ForEach(cluster.coreIndices, id: \.self) { index in
                            let value = perCore[safe: index] ?? 0
                            VStack(spacing: DS.Space.s1) {
                                RingGauge(fraction: value, color: loadTone(value).color, size: Self.ring) {
                                    Text(verbatim: Format.percent(value))
                                        .dsFont(.xs, weight: .semibold)
                                        .monospacedDigit()
                                        .foregroundStyle(DS.Palette.textPrimary)
                                }
                                Text(verbatim: tr("核心 \(index + 1)"))
                                    .dsFont(.xs)
                                    .foregroundStyle(DS.Palette.textSecondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tr("各核心占用"))
    }
}

/// CPU 顶部：大号占用、状态、与 30 秒前相比的变化、CPU 温度（附离 100°C 的余量），
/// 下面是最近 1 / 3 / 5 分钟的走势线（主窗口里更高，带百分比刻度、参考线与时间轴）、峰值和用户 / 系统 / 空闲构成
private struct CPUHero: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        let store = model.store
        let cpu = store.cpu
        let total = cpu?.total ?? 0
        let history = store.cpuTotal.elements
        let temperature = store.sensors?.temperature(.cpu)
        let fahrenheit = model.settings.useFahrenheit
        // 走势按真实时间定位：最新一次采样在右边缘，往左铺满所选时长
        let duration = TimeInterval(model.settings.cpuChartSeconds)
        let end = store.cpuTimeline.elements.last?.date ?? Date()
        let timeline = store.cpuTimeline.elements.filter { $0.date >= end.addingTimeInterval(-duration) }

        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(alignment: .center, spacing: DS.Space.s3) {
                HeroValue(value: cpu.map { "\(Int(($0.total * 100).rounded()))" } ?? "—", unit: "%", size: .xxl)
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    StatusBadge(text: status(total), tone: total >= 0.85 ? .error : total >= 0.6 ? .warning : .success)
                    Text(verbatim: trend(history))
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .monospacedDigit()
                }
                Spacer(minLength: DS.Space.s2)
                if let temperature {
                    let hottest = temperature.maximum
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(tr("CPU 温度")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                        Text(verbatim: Format.temperature(hottest, fahrenheit: fahrenheit))
                            .dsFont(.base, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(Tone.forTemperature(hottest).color)
                        Text(verbatim: tr("余量 \(headroom(hottest, fahrenheit: fahrenheit))"))
                            .dsFont(.xs)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                    .help(tr("核心最高温度；余量是离 100°C 还差多少度，越接近 0 越可能因过热降频"))
                }
            }
            if isDetailPage {
                HStack(spacing: DS.Space.s2) {
                    PercentAxis(height: DS.Size.chartHeight * 2)
                    TimedLineChart(points: timeline, duration: duration, end: end, grid: true, height: DS.Size.chartHeight * 2)
                }
                HStack {
                    Text(verbatim: Self.clock(end.addingTimeInterval(-duration)))
                    Spacer()
                    Text(verbatim: Self.clock(end.addingTimeInterval(-duration / 2)))
                    Spacer()
                    Text(tr("现在"))
                }
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .monospacedDigit()
                .padding(.leading, PercentAxis.width + DS.Space.s2)
            } else {
                TimedLineChart(points: timeline, duration: duration, end: end, height: DS.Space.s8)
            }
            HStack {
                ChartDurationPicker()
                Spacer()
                Text(verbatim: tr("峰值 \(Format.percent(timeline.map(\.value).max() ?? 0))"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .monospacedDigit()
            }
            if let cpu {
                WaterlineBar(segments: [(cpu.user, DS.Palette.primary), (cpu.system, DS.Palette.secondary)],
                             total: 1, height: DS.Space.s2)
                HStack(spacing: DS.Space.s3) {
                    LegendItem(color: DS.Palette.primary, label: tr("用户"), value: Format.percent(cpu.user))
                    LegendItem(color: DS.Palette.secondary, label: tr("系统"), value: Format.percent(cpu.system))
                    LegendItem(color: DS.Palette.track, label: tr("空闲"), value: Format.percent(max(0, 1 - cpu.total)))
                }
            }
        }
    }

    private func status(_ total: Double) -> String {
        total >= 0.85 ? tr("满载") : total >= 0.6 ? tr("繁忙") : total >= 0.25 ? tr("适中") : tr("空闲")
    }

    /// 离 100°C 还差多少度；华氏制下按温差换算（差 45°C 即差 81°F）
    private func headroom(_ celsius: Double, fahrenheit: Bool) -> String {
        let degrees = max(0, 100 - celsius)
        return fahrenheit ? "\(Int((degrees * 9 / 5).rounded()))°F" : "\(Int(degrees.rounded()))°C"
    }

    /// 与大约 30 秒前（第 15 个采样之前）相比的变化
    private func trend(_ history: [Double]) -> String {
        guard history.count > 15, let now = history.last else { return tr("正在收集走势…") }
        let before = history[history.count - 16]
        let delta = Int(((now - before) * 100).rounded())
        if abs(delta) < 3 { return tr("与 30 秒前持平") }
        return delta > 0 ? tr("比 30 秒前高 \(delta)%") : tr("比 30 秒前低 \(-delta)%")
    }

    /// 时间轴刻度：走势只有几分钟，带秒才分得开；小时固定两位，零点前后宽度不变
    private static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: L10n.locale).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}

/// 走势时长 1 / 3 / 5 分钟：一行小字标签，选中的用品牌蓝加粗，不另占高度
private struct ChartDurationPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings
        HStack(spacing: DS.Space.s3) {
            ForEach(AppSettings.cpuChartOptions, id: \.self) { seconds in
                let selected = settings.cpuChartSeconds == seconds
                Button {
                    settings.cpuChartSeconds = seconds
                } label: {
                    Text(verbatim: tr("\(seconds / 60) 分钟"))
                        .dsFont(.xs, weight: selected ? .semibold : .regular)
                        .foregroundStyle(selected ? DS.Palette.primary : DS.Palette.textTertiary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .help(tr("走势图显示最近多长时间"))
        .accessibilityLabel(tr("走势时长"))
    }
}

/// 走势图左侧的 0–100% 刻度，位置与参考线对齐；最上、最下两个标签收进图表范围内，不压到相邻的行
private struct PercentAxis: View {
    static let width = DS.Space.s8 + DS.Space.s2
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let inset = DS.Size.chartLine
            let usable = proxy.size.height - inset * 2
            let half = DS.TextSize.xs.rawValue / 2 + DS.Size.stroke
            ForEach([1.0, 0.75, 0.5, 0.25, 0.0], id: \.self) { fraction in
                Text(verbatim: "\(Int(fraction * 100))%")
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: Self.width, alignment: .trailing)
                    .position(x: Self.width / 2, y: min(max(inset + usable * CGFloat(1 - fraction), half), proxy.size.height - half))
            }
        }
        .frame(width: Self.width, height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - 内存

struct MemoryPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        let settings = model.settings
        let store = model.store
        let memory = store.memory

        MemoryHero()

        ForEach(MenuBarItem.memory.popoverSections.filter { isDetailPage || settings.isVisible($0) }) { section in
            switch section {
            case .memoryWaterline:
                SectionCard(title: section.title, trailing: { Text(verbatim: memory.map { Format.bytes($0.total) } ?? "") }) {
                    if let memory {
                        let parts: [(String, UInt64, Color)] = [
                            ("App", memory.app, DS.Palette.primary),
                            (tr("联动"), memory.wired, DS.Palette.secondary),
                            (tr("压缩"), memory.compressed, DS.Palette.warning),
                            (tr("缓存"), memory.cached, DS.Palette.primarySoft),
                            (tr("空闲"), memory.free, DS.Palette.track),
                        ]
                        WaterlineBar(segments: parts.map { (Double($0.1), $0.2) }, total: Double(memory.total))
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s3), GridItem(.flexible())], spacing: DS.Space.s2) {
                            ForEach(parts, id: \.0) { part in
                                HStack(spacing: DS.Space.s1) {
                                    RoundedRectangle(cornerRadius: DS.Radius.sm / 2).fill(part.2)
                                        .frame(width: DS.Size.barHeight, height: DS.Size.barHeight)
                                    Text(part.0).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                                        .lineLimit(1)
                                        .layoutPriority(1)
                                    Spacer(minLength: DS.Space.s1)
                                    Text(verbatim: Format.bytes(part.1)).dsFont(.xs, weight: .medium).monospacedDigit()
                                        .foregroundStyle(DS.Palette.textPrimary)
                                }
                            }
                        }
                    }
                }
            case .memoryCompression:
                SectionCard(title: section.title) {
                    if let memory {
                        InfoRow(label: tr("压缩为你省下")) {
                            Text(verbatim: Format.bytes(memory.compressionSavings)).foregroundStyle(DS.Palette.success)
                        }
                        InfoRow(label: tr("压缩比"), text: memory.compressionRatio.map { "\($0.formatted(.number.precision(.fractionLength(1))))×" } ?? "—")
                        InfoRow(label: tr("交换区"), text: memory.swapTotal > 0
                                ? "\(Format.bytes(memory.swapUsed)) / \(Format.bytes(memory.swapTotal))" : tr("未使用"))
                        InfoRow(label: tr("换入 / 换出"), text: store.swapRate.map { "\(Format.menuBarRate($0.swapIn)) / \(Format.menuBarRate($0.swapOut))" } ?? "—")
                        if let rate = store.swapRate, rate.swapOut > 1024 * 1024 {
                            InfoBanner(icon: "exclamationmark.triangle.fill", text: tr("系统正在把内存写到磁盘，可能会变慢。可以关掉占用大的应用。"), tone: .warning)
                        }
                    }
                }
            case .memoryApps:
                SectionCard(title: section.title, trailing: { Text(tr("内存")) }) {
                    AppUsageList(apps: AppUsage.group(store.processes).sorted { $0.memory > $1.memory },
                                 rowCount: isDetailPage ? 10 : 6, metric: .memory, total: memory?.used)
                }
            default:
                EmptyView()
            }
        }
    }
}

/// 内存顶部：可用多少、压力状态、最近一分钟的压力走势
private struct MemoryHero: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let memory = store.memory

        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(alignment: .center, spacing: DS.Space.s3) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(tr("还可用")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    HeroValue(value: memory.map { availableNumber($0.available) } ?? "—", unit: "GB", size: .xxl)
                }
                Spacer(minLength: DS.Space.s2)
                VStack(alignment: .trailing, spacing: DS.Space.s1) {
                    StatusBadge(text: tr("压力\(memory?.pressure.title ?? "—")"), tone: tone(memory?.pressure))
                    Text(verbatim: memory.map { tr("已用 \(Format.bytes($0.used)) · \(Format.percent($0.usedFraction))") } ?? "")
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .monospacedDigit()
                }
            }
            PressureStrip(history: store.pressureHistory.elements)
            HStack {
                Text(tr("压力走势")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                Spacer()
                Text(tr("最近 60 秒")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    private func availableNumber(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)))
    }

    private func tone(_ pressure: MemoryPressure?) -> Tone {
        switch pressure {
        case .normal: .success
        case .warning: .warning
        case .critical: .error
        case nil: .neutral
        }
    }
}

// MARK: - 按应用汇总

/// 同一个应用的主进程与辅助进程合并计算
struct AppUsage: Identifiable {
    let id: String
    let name: String
    let bundlePath: String?
    var cpu: Double
    var memory: UInt64
    var processCount: Int
    /// 占用最高的那个进程，用于图标与 Apple 智能解释
    var representative: ProcessUsage

    @MainActor
    static func group(_ processes: [ProcessUsage]) -> [AppUsage] {
        var groups: [String: AppUsage] = [:]
        for process in processes {
            let key = process.appBundlePath ?? "pid-\(process.pid)"
            if var group = groups[key] {
                group.cpu += process.cpu
                group.memory += process.memory
                group.processCount += 1
                if process.memory > group.representative.memory { group.representative = process }
                groups[key] = group
            } else {
                let name = process.appBundlePath.map { AppNameCache.shared.name(forBundle: $0) } ?? process.displayName
                groups[key] = AppUsage(id: key, name: name, bundlePath: process.appBundlePath,
                                       cpu: process.cpu, memory: process.memory, processCount: 1, representative: process)
            }
        }
        return Array(groups.values)
    }
}

private struct AppUsageList: View {
    enum Metric { case cpu, memory }

    let apps: [AppUsage]
    let rowCount: Int
    let metric: Metric
    var total: UInt64?

    var body: some View {
        let visible = Array(apps.prefix(rowCount))
        // 横条以列表里最大的一项为满格，比较谁占得多
        let peak = visible.map { metric == .cpu ? $0.cpu : Double($0.memory) }.max() ?? 1
        if visible.isEmpty {
            Text(tr("正在统计…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
        ForEach(visible) { app in
            let value = metric == .cpu ? app.cpu : Double(app.memory)
            VStack(spacing: DS.Space.s1) {
                HStack(spacing: DS.Space.s2) {
                    AppIconCache.shared.image(bundlePath: app.bundlePath)
                        .resizable()
                        .frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
                    Text(verbatim: app.name)
                        .dsFont(.xs, weight: .medium)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(1)
                    if app.processCount > 1 {
                        Text(verbatim: tr("\(app.processCount) 个进程")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Spacer(minLength: DS.Space.s2)
                    Text(verbatim: valueText(app))
                        .dsFont(.xs, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(DS.Palette.textSecondary)
                        .help(optional: metric == .cpu ? tr("按单核满载为 100% 计：\(Format.coreShare(app.cpu))") : nil)
                }
                ProgressTrack(fraction: peak > 0 ? value / peak : 0, color: DS.Palette.primary, height: DS.Space.s1, showsTrack: false)
                    .padding(.leading, DS.Size.iconInline + DS.Space.s2)
            }
            .explainable(.init(app.representative))
        }
    }

    private func valueText(_ app: AppUsage) -> String {
        switch metric {
        case .cpu:
            // 占整机的比例；单核口径的数值放在悬停提示里
            return Format.machineShare(app.cpu)
        case .memory:
            guard let total, total > 0 else { return Format.bytes(app.memory) }
            return "\(Format.bytes(app.memory)) · \(Format.percent(Double(app.memory) / Double(total)))"
        }
    }
}

/// 标签 + 数值 + 横条
private struct ShareRow: View {
    let label: String
    let value: String
    /// 跟在数值后面的补充读数（如频率），用次要颜色，不抢主数值
    var detail: String?
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(spacing: DS.Space.s1) {
            InfoRow(label: label) {
                if let detail {
                    Text(verbatim: value)
                        + Text(verbatim: " · \(detail)").foregroundStyle(DS.Palette.textSecondary).fontWeight(.regular)
                } else {
                    Text(verbatim: value)
                }
            }
            ProgressTrack(fraction: fraction, color: color, height: DS.Space.s1 + DS.Space.s1 / 2)
        }
    }
}

extension View {
    /// 进程行右键菜单：用 Apple 智能解释
    @ViewBuilder
    func explainable(_ subject: ProcessExplainer.Subject) -> some View {
        if ProcessExplainer.isSupported {
            ExplainableRow(subject: subject) { self }
        } else {
            self
        }
    }
}

private struct ExplainableRow<Content: View>: View {
    let subject: ProcessExplainer.Subject
    @ViewBuilder var content: Content
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        content
            .contentShape(Rectangle())
            .contextMenu(isSnapshot ? nil : ContextMenu {
                Button(tr("用 AI 解释")) { model.explainProcess(subject) }
            })
    }
}

/// 标题栏里的“释放内存”：执行中显示进度，完成后短暂显示结果再恢复
struct PurgeMemoryButton: View {
    @Environment(AppModel.self) private var model
    @State private var result: MaintenanceController.Outcome?

    var body: some View {
        let maintenance = model.maintenance
        let running = maintenance.running == .purgeMemory
        Button {
            Task {
                await maintenance.run(.purgeMemory)
                result = maintenance.outcomes[.purgeMemory]
                try? await Task.sleep(for: .seconds(3))
                result = nil
            }
        } label: {
            HStack(spacing: DS.Space.s1) {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: result == nil ? "wind" : result!.isError ? "exclamationmark.triangle" : "checkmark")
                }
                Text(running ? tr("正在释放…") : result?.text ?? tr("释放内存")).lineLimit(1).fixedSize()
            }
            .foregroundStyle(result?.isError == true ? DS.Palette.error : result != nil ? DS.Palette.success : DS.Palette.textPrimary)
        }
        .buttonStyle(DSButtonStyle(kind: .secondary))
        .disabled(maintenance.running != nil)
        .help(tr("清理可回收的缓存内存（需要管理员授权或辅助工具）"))
    }
}

// MARK: - GPU

struct GPUPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        let settings = model.settings
        let store = model.store
        let gpu = store.gpu
        let temperature = store.sensors?.temperature(.gpu)

        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s3) {
                RingGauge(fraction: gpu?.utilization ?? 0, color: loadTone(gpu?.utilization ?? 0).color, size: heroGauge) {
                    Text(verbatim: gpu.map { Format.percent($0.utilization) } ?? "—")
                        .dsFont(.sm, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(DS.Palette.textPrimary)
                }
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    Text(verbatim: gpu?.name ?? "GPU")
                        .dsFont(.sm, weight: .semibold)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(1)
                    Text(verbatim: gpu?.coreCount.map { tr("\($0) 核图形处理器") } ?? tr("图形处理器"))
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer(minLength: 0)
                if let temperature {
                    Chip(text: Format.temperature(temperature.maximum, fahrenheit: settings.useFahrenheit),
                         icon: "thermometer.medium", tone: Tone.forTemperature(temperature.maximum))
                }
            }
        }

        ForEach(MenuBarItem.gpu.popoverSections.filter { isDetailPage || settings.isVisible($0) }) { section in
            switch section {
            case .gpuHistory:
                SectionCard(title: section.title, trailing: { Text(tr("最近 60 秒")) }) {
                    LineHistoryChart(values: store.gpuHistory.elements, color: DS.Palette.secondary, height: detailChartHeight(isDetailPage))
                }
            case .gpuDetails:
                SectionCard(title: section.title) {
                    InfoRow(label: tr("型号"), text: gpu?.name ?? "—")
                    InfoRow(label: tr("核心数"), text: gpu?.coreCount.map(String.init) ?? "—")
                    InfoRow(label: tr("平均温度"), text: temperature.map { Format.temperature($0.average, fahrenheit: settings.useFahrenheit) } ?? "—")
                    InfoRow(label: tr("最高温度"), text: temperature.map { Format.temperature($0.maximum, fahrenheit: settings.useFahrenheit) } ?? "—")
                }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - 温度与风扇

struct ThermalPopover: View {
    let item: MenuBarItem
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        let settings = model.settings
        let store = model.store
        let cpu = store.sensors?.temperature(.cpu)
        let fans = store.sensors?.fans ?? []

        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(alignment: .center, spacing: DS.Space.s3) {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    Text(tr("CPU 最高")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    HeroValue(value: cpu.map { Format.temperature($0.maximum, fahrenheit: settings.useFahrenheit) } ?? "—")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    Text(tr("风扇")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    HeroValue(value: store.fastestFan.map { Int($0.current).formatted() } ?? "—", unit: fans.isEmpty ? nil : "RPM")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        ForEach(item.popoverSections.filter { isDetailPage || settings.isVisible($0) }) { section in
            switch section {
            case .thermalSensors:
                SectionCard(title: section.title, trailing: { Text(tr("最高 / 平均")) }) {
                    let temperatures = store.sensors?.temperatures ?? []
                    if temperatures.isEmpty {
                        Text(tr("正在读取传感器…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    }
                    ForEach(temperatures) { summary in
                        VStack(spacing: DS.Space.s1) {
                            InfoRow(label: summary.group.title) {
                                Text(verbatim: "\(Format.temperature(summary.maximum, fahrenheit: settings.useFahrenheit)) / \(Format.temperature(summary.average, fahrenheit: settings.useFahrenheit))")
                            }
                            ProgressTrack(fraction: summary.maximum / DS.Thermal.scaleMax,
                                          color: Tone.forTemperature(summary.maximum).color,
                                          height: DS.Space.s1)
                        }
                    }
                }
            case .thermalFans:
                SectionCard(title: section.title, trailing: { Text(fanStatusText(fans: fans, mode: model.fans.mode)) }) {
                    if fans.isEmpty {
                        Text(tr("未检测到风扇")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    } else {
                        ForEach(fans) { fan in
                            VStack(spacing: DS.Space.s1) {
                                InfoRow(label: tr("风扇 \(fan.id + 1)"), text: Format.rpm(fan.current))
                                ProgressTrack(fraction: fan.maximum > 0 ? fan.current / fan.maximum : 0, height: DS.Space.s1)
                            }
                        }
                        HStack(spacing: DS.Space.s1) {
                            ForEach([FanController.Mode.automatic, .cooling, .maximum]) { mode in
                                ChipButton(title: mode.title, isSelected: model.fans.mode == mode) {
                                    model.requestFanMode(mode)
                                }
                            }
                        }
                    }
                }
            case .thermalPower:
                SectionCard(title: section.title, trailing: { Text(store.power?.system.map(Format.watts) ?? "—") }) {
                    PowerRows(power: store.power, history: store.powerHistory.elements, compact: true)
                }
            default:
                EmptyView()
            }
        }
    }
}

/// 固件只记录“手动 / 自动”，无法区分是谁设置的：XStats 未下发时即为其他程序（如 Stats、Mole）
@MainActor
func fanStatusText(fans: [FanState], mode: FanController.Mode) -> String {
    if fans.isEmpty { return tr("未检测到风扇") }
    guard fans.contains(where: \.isManual) else { return tr("由 macOS 调节") }
    return mode == .automatic ? tr("其他程序手动控制") : tr("XStats 控制中")
}

/// 功耗明细：整机、电源输入、电池、GPU，附整机功耗走势
struct PowerRows: View {
    let power: PowerReading?
    let history: [Double]
    var compact = false

    var body: some View {
        if let power, power.system != nil || power.gpu != nil {
            if history.count > 1 {
                LineHistoryChart(values: history, maxValue: max(history.max() ?? 0, 10) * 1.2,
                                 color: DS.Palette.warning, height: compact ? DS.Size.tileChart : DS.Size.chartHeight)
            }
            if let system = power.system { InfoRow(label: tr("整机"), text: Format.watts(system)) }
            if let adapter = power.adapter { InfoRow(label: tr("电源输入"), text: Format.watts(adapter)) }
            if let battery = power.battery {
                // PPBR 为正表示电池在放电供电，接通电源时是充电功率
                InfoRow(label: power.adapter == nil ? tr("电池放电") : tr("电池充电"), text: Format.watts(abs(battery)))
            }
            if let gpu = power.gpu { InfoRow(label: "GPU", text: Format.watts(gpu)) }
            Text(tr("由 SMC 与系统能耗统计读取；新款芯片不提供可靠的 CPU 单独功耗"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(tr("这台 Mac 不提供功耗读数")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
    }
}
