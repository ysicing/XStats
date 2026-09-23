import AppKit
import Localization
import Metrics
import SMC
import SwiftUI

struct OverviewPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScroll {
            HealthHeader()
            WeightedRow {
                CPUTile()
                GPUTile()
                MemoryTile()
            }
            WeightedRow {
                DiskTile()
                NetworkTile()
                FanTile()
            }
            // 窄卡片与上方单列同宽：宽卡占两列
            WeightedRow(weights: model.store.battery != nil ? [2, 1] : [1]) {
                CoreLoadCard()
                if model.store.battery != nil { BatteryCard() }
            }
            WeightedRow(weights: [2, 1]) {
                TopProcessesCard()
                QuickActionsCard()
            }
        }
    }
}

/// 一行卡片：按权重分配宽度（窗口变宽时同比放大），高度取最高的一张，其余撑满
struct WeightedRow: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat

    init(weights: [CGFloat] = [], spacing: CGFloat = DS.Space.s3) {
        self.weights = weights
        self.spacing = spacing
    }

    private func widths(total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let resolved = (0..<count).map { $0 < weights.count ? weights[$0] : 1 }
        let sum = resolved.reduce(0, +)
        // 以权重之和为列数，[2, 1] 的窄卡与三列布局的单列同宽
        let columns = sum
        let unit = (total - spacing * (columns - 1)) / columns
        return resolved.map { unit * $0 + spacing * ($0 - 1) }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? DS.Size.panelWidth
        let columnWidths = widths(total: width, count: subviews.count)
        let height = zip(subviews, columnWidths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(total: bounds.width, count: subviews.count)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

// MARK: - 健康度与徽章

struct HealthReport {
    let score: Int
    let summary: String
    let tone: Tone

    @MainActor
    init(store: MetricsStore) {
        var issues: [(penalty: Int, text: String)] = []
        if let cpu = store.cpu {
            if cpu.total >= 0.9 { issues.append((20, tr("CPU 负载很高"))) } else if cpu.total >= 0.75 { issues.append((10, tr("CPU 负载偏高"))) }
        }
        switch store.memory?.pressure {
        case .critical: issues.append((30, tr("内存压力严重")))
        case .warning: issues.append((15, tr("内存压力偏高")))
        default: break
        }
        if let hottest = store.sensors?.temperature(.cpu)?.maximum {
            if hottest >= DS.Thermal.hot { issues.append((20, tr("CPU 温度过高"))) } else if hottest >= 85 { issues.append((10, tr("CPU 温度偏高"))) }
        }
        if let disk = store.disk {
            if disk.usedFraction >= 0.95 { issues.append((15, tr("磁盘空间不足"))) } else if disk.usedFraction >= 0.9 { issues.append((8, tr("磁盘空间偏紧"))) }
        }
        if let health = store.battery?.health, health < 0.8 { issues.append((5, tr("电池健康度下降"))) }

        score = max(0, 100 - issues.reduce(0) { $0 + $1.penalty })
        summary = issues.max { $0.penalty < $1.penalty }?.text ?? tr("各项指标正常")
        tone = score >= 85 ? .success : score >= 60 ? .warning : .error
    }
}

private struct HealthHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let report = HealthReport(store: store)

        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(alignment: .center, spacing: DS.Space.s3) {
                Image(systemName: report.tone == .success ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: DS.TextSize.xl.rawValue, weight: .semibold))
                    .foregroundStyle(report.tone.color)
                Text(verbatim: "\(report.score)")
                    .dsFont(.xxl, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(report.summary)
                    .dsFont(.base, weight: .medium)
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer()
            }
            FlowLayout(spacing: DS.Space.s2) {
                Chip(text: chipName(store.topology.brand), icon: "apple.logo")
                Chip(text: Format.bytes(ProcessInfo.processInfo.physicalMemory).replacingOccurrences(of: ".0 ", with: " "))
                Chip(text: store.system.osVersion)
                if let boot = store.system.bootDate {
                    Chip(text: tr("已运行 ") + Format.uptime(since: boot))
                }
                Chip(text: shortModel(store.system.modelName))
            }
        }
        .padding(.horizontal, DS.Space.s1)
    }

    /// “Apple M5 Max” → “M5 Max”，前面配 Apple 标志
    private func chipName(_ brand: String) -> String {
        brand.hasPrefix("Apple ") ? String(brand.dropFirst("Apple ".count)) : brand
    }

    /// “MacBook Pro (16-inch, M5 Max)” → “MacBook Pro 16 英寸”
    private func shortModel(_ name: String) -> String {
        guard let open = name.firstIndex(of: "(") else { return name }
        let base = name[..<open].trimmingCharacters(in: .whitespaces)
        let details = name[open...].dropFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let inch = details.first(where: { $0.hasSuffix("-inch") }) {
            return tr("\(base) \(inch.dropLast("-inch".count)) 英寸")
        }
        return base
    }
}

// MARK: - 指标卡片

func loadLevel(_ value: Double) -> String {
    value < 0.3 ? tr("低负载") : value < 0.7 ? tr("中等负载") : tr("高负载")
}

private func splitRate(_ text: String) -> (String, String) {
    let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
    return (parts.first ?? text, parts.count > 1 ? parts[1] : "")
}

private struct CPUTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let total = store.cpu?.total ?? 0
        let temperature = store.sensors?.temperature(.cpu)
        let load = store.cpu?.loadAverage.first.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—"

        MetricTile(icon: "cpu", title: "CPU",
                   chip: temperature.map { Format.temperature($0.maximum, fahrenheit: model.settings.useFahrenheit) },
                   chipTone: temperature.map { Tone.forTemperature($0.maximum) } ?? .neutral,
                   value: store.cpu == nil ? "—" : "\(Int((total * 100).rounded()))", unit: "%") {
            BarHistoryChart(values: store.cpuTotal.elements, capacity: 20, height: DS.Size.tileChart)
        } footer: {
            Text(verbatim: tr("\(loadLevel(total)) · 负载 \(load)/\(store.topology.logicalCores)"))
        }
    }
}

private struct GPUTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let utilization = store.gpu?.utilization ?? 0
        let temperature = store.sensors?.temperature(.gpu)

        MetricTile(icon: "display", title: "GPU",
                   chip: temperature.map { Format.temperature($0.maximum, fahrenheit: model.settings.useFahrenheit) },
                   chipTone: temperature.map { Tone.forTemperature($0.maximum) } ?? .neutral,
                   value: store.gpu == nil ? "—" : "\(Int((utilization * 100).rounded()))", unit: "%") {
            LineHistoryChart(values: store.gpuHistory.elements, capacity: 30, color: DS.Palette.secondary, height: DS.Size.tileChart)
        } footer: {
            Text(verbatim: [loadLevel(utilization), store.gpu?.coreCount.map { tr("\($0) 核") }].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

private struct MemoryTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let memory = model.store.memory

        MetricTile(icon: "memorychip", title: tr("内存"),
                   chip: memory.map { tr("压力 \($0.pressure.title)") },
                   chipTone: memory.map { tone($0.pressure) } ?? .neutral,
                   value: memory.map { "\(Int(($0.usedFraction * 100).rounded()))" } ?? "—", unit: "%") {
            LineHistoryChart(values: model.store.memoryHistory.elements, capacity: 30, height: DS.Size.tileChart)
        } footer: {
            Text(verbatim: memory.map { "\(Format.bytes($0.used)) / \(Format.bytes($0.total))" } ?? "—")
        }
    }

    private func tone(_ pressure: MemoryPressure) -> Tone {
        switch pressure {
        case .normal: .success
        case .warning: .warning
        case .critical: .error
        }
    }
}

private struct DiskTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let disk = model.store.disk

        MetricTile(icon: "internaldrive", title: tr("磁盘"),
                   chip: disk.map { Format.bytes($0.total, base: .decimal).replacingOccurrences(of: ".0 ", with: " ") },
                   value: disk.map { "\(Int(($0.usedFraction * 100).rounded()))" } ?? "—", unit: "%") {
            VStack {
                Spacer()
                ProgressTrack(fraction: disk?.usedFraction ?? 0,
                              color: (disk?.usedFraction ?? 0) > 0.9 ? DS.Palette.warning : DS.Palette.primary,
                              height: DS.Space.s3)
                Spacer()
            }
        } footer: {
            Text(verbatim: disk.map { tr("可用 \(Format.bytes($0.available, base: .decimal))") } ?? "—")
        }
    }
}

private struct NetworkTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.store
        let rate = store.network
        let total = splitRate(Format.menuBarRate((rate?.downloadBytesPerSecond ?? 0) + (rate?.uploadBytesPerSecond ?? 0)))

        MetricTile(icon: "network", title: tr("网络"),
                   chip: store.networkInterface.map { shortInterface($0) },
                   value: rate == nil ? "—" : total.0, unit: rate == nil ? nil : total.1) {
            DualLineChart(upload: store.uploadHistory.elements, download: store.downloadHistory.elements,
                          capacity: 30, height: DS.Size.tileChart)
        } footer: {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "arrow.up").foregroundStyle(Color(nsColor: DS.NetworkPalette.upload))
                Text(verbatim: rate.map { Format.menuBarRate($0.uploadBytesPerSecond) } ?? "—")
                Image(systemName: "arrow.down").foregroundStyle(Color(nsColor: DS.NetworkPalette.download))
                Text(verbatim: rate.map { Format.menuBarRate($0.downloadBytesPerSecond) } ?? "—")
            }
            .fontWeight(.medium)
        }
    }

    private func shortInterface(_ info: NetworkInterfaceInfo) -> String {
        info.displayName == tr("VPN 隧道") ? "VPN" : info.displayName
    }
}

private struct FanTile: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let fans = model.store.sensors?.fans ?? []
        let fastest = model.store.fastestFan
        // 以最高转速为 100%，比“最低到最高”的区间比例更直观
        let average = fans.isEmpty ? 0 : fans.map { $0.maximum > 0 ? $0.current / $0.maximum : 0 }.reduce(0, +) / Double(fans.count)

        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "fan").font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                Text(tr("风扇")).dsFont(.xs, weight: .semibold)
                Spacer(minLength: DS.Space.s1)
                if !fans.isEmpty { Chip(text: tr("转速 \(Format.percent(average))")) }
            }
            .foregroundStyle(DS.Palette.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1 / 2) {
                Text(verbatim: fastest.map { Int($0.current).formatted() } ?? "—")
                    .dsFont(.xl, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(verbatim: "RPM").dsFont(.xs, weight: .medium).foregroundStyle(DS.Palette.textSecondary)
            }

            Text(fanStatusText(fans: fans, mode: model.fans.mode))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(height: DS.Size.tileChart / 2, alignment: .center)

            HStack(spacing: DS.Space.s1) {
                ForEach([FanController.Mode.automatic, .cooling, .maximum]) { mode in
                    ChipButton(title: mode.title, isSelected: model.fans.mode == mode) {
                        model.requestFanMode(mode)
                    }
                }
            }
            .disabled(fans.isEmpty)
        }
    }
}

// MARK: - 核心负载

private struct CoreLoadCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cpu = model.store.cpu
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "square.grid.3x3.fill").font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                Text(tr("核心负载")).dsFont(.xs, weight: .semibold)
                Spacer()
                LegendItem(color: DS.Palette.primary, label: tr("用户"), value: cpu.map { Format.percent($0.user) } ?? "—")
                LegendItem(color: DS.Palette.secondary, label: tr("系统"), value: cpu.map { Format.percent($0.system) } ?? "—")
            }
            .foregroundStyle(DS.Palette.textSecondary)
            CoreClusterBars(topology: model.store.topology, perCore: cpu?.perCore ?? [], barHeight: DS.Space.s12 + DS.Space.s4)
        }
    }
}

// MARK: - 电池

private struct BatteryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let battery = model.store.battery {
            let tone: Tone = battery.level < 0.2 ? .error : battery.isCharging ? .primary : .success
            Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: battery.isCharging ? "battery.100.bolt" : "battery.75")
                        .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                    Text(tr("电池")).dsFont(.xs, weight: .semibold)
                    Spacer(minLength: DS.Space.s1)
                    if let health = battery.health {
                        Chip(text: tr("健康 \(Format.percent(health))"), tone: health < 0.8 ? .warning : .neutral)
                    }
                }
                .foregroundStyle(DS.Palette.textSecondary)

                HStack(alignment: .center, spacing: DS.Space.s2) {
                    VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                        Text(verbatim: Format.percent(battery.level))
                            .dsFont(.xl, weight: .semibold)
                            .monospacedDigit()
                            .foregroundStyle(DS.Palette.textPrimary)
                        Text(battery.stateText)
                            .dsFont(.xs, weight: .medium)
                            .foregroundStyle(DS.Palette.textSecondary)
                        if let watts = battery.adapterWatts, battery.isPluggedIn {
                            Label { Text(verbatim: "\(watts)W") } icon: { Image(systemName: "bolt.fill") }
                                .dsFont(.xs, weight: .medium)
                                .foregroundStyle(DS.Palette.warning)
                        }
                    }
                    Spacer(minLength: 0)
                    RingGauge(fraction: battery.level, color: tone.color, size: DS.Space.s12 + DS.Space.s2) {
                        Image(systemName: "laptopcomputer")
                            .font(.system(size: DS.TextSize.sm.rawValue, weight: .medium))
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }

                Text(verbatim: detailText(battery))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func detailText(_ battery: BatteryStatus) -> String {
        var parts: [String] = []
        if let minutes = battery.minutesRemaining {
            parts.append(battery.isCharging ? tr("\(Format.duration(minutes: minutes))后充满") : tr("剩余 \(Format.duration(minutes: minutes))"))
        }
        if let cycles = battery.cycleCount { parts.append(tr("循环 \(cycles) 次")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 高占用进程

private struct TopProcessesCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    private static let rowCount = 5

    var body: some View {
        let processes = Array(model.store.processes.prefix(Self.rowCount))

        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "chart.bar.fill").font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                Text(tr("高占用进程")).dsFont(.xs, weight: .semibold)
                Spacer()
                Text("CPU").dsFont(.xs, weight: .medium).frame(width: DS.Size.valueColumn, alignment: .trailing)
                    .help(tr("占整机 CPU 的比例：\(Format.logicalCores) 个核心全部跑满为 100%"))
                Text(tr("内存")).dsFont(.xs, weight: .medium).frame(width: DS.Size.valueColumn, alignment: .trailing)
                Color.clear.frame(width: DS.Size.iconInline)
            }
            .foregroundStyle(DS.Palette.textSecondary)

            // 数据到达前用等高占位行，避免面板高度变化
            ForEach(0..<max(0, Self.rowCount - processes.count), id: \.self) { _ in
                PlaceholderLine()
                    .frame(height: DS.TextSize.sm.rawValue * 1.25)
            }
            ForEach(processes) { process in
                HStack(spacing: DS.Space.s2) {
                    AppIconCache.shared.image(for: process)
                        .resizable()
                        .frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
                    Text(process.displayName)
                        .dsFont(.sm, weight: .medium)
                        .foregroundStyle(DS.Palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.s2)
                    Text(verbatim: Format.machineShare(process.cpu))
                        .dsFont(.sm, weight: .medium)
                        .foregroundStyle(cpuTone(process.cpu).color)
                        .help(tr("按单核满载为 100% 计：\(Format.coreShare(process.cpu))"))
                        .frame(width: DS.Size.valueColumn, alignment: .trailing)
                    Text(verbatim: Format.bytes(process.memory))
                        .dsFont(.sm)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: DS.Size.valueColumn, alignment: .trailing)
                    moreButton(process)
                }
                .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private func moreButton(_ process: ProcessUsage) -> some View {
        let icon = Image(systemName: "ellipsis")
            .font(.system(size: DS.TextSize.xs.rawValue, weight: .bold))
            .foregroundStyle(DS.Palette.textTertiary)
            .frame(width: DS.Size.iconInline)
        if isSnapshot {
            icon
        } else {
            Menu {
                if let path = process.appBundlePath ?? process.executablePath {
                    Button(tr("在访达中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Button(tr("拷贝 PID \(String(process.pid))")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(process.pid), forType: .string)
                }
                if ProcessExplainer.isSupported {
                    Button(tr("用 Apple 智能解释")) { model.explainProcess(.init(process)) }
                }
                Divider()
                Button(tr("查看全部进程")) { model.settings.panelTab = .processes }
            } label: {
                icon
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: DS.Size.iconInline)
        }
    }

    /// 按占整机的比例着色：一个进程吃掉整机一半算很高，四分之一算偏高（`value` 是单核口径）
    private func cpuTone(_ value: Double) -> Tone {
        let share = value / Double(Format.logicalCores)
        return share >= 0.5 ? .error : share >= 0.25 ? .warning : .neutral
    }
}

// MARK: - 快捷开关

private struct QuickActionsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let keepAwake = model.keepAwake
        let fans = model.fans
        Card(padding: DS.Space.s3, spacing: 0) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "switch.2").font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                Text(tr("快捷开关")).dsFont(.xs, weight: .semibold)
            }
            .foregroundStyle(DS.Palette.textSecondary)
            .padding(.bottom, DS.Space.s1)

            QuickToggleRow(icon: "cup.and.saucer", title: tr("防休眠"),
                           detail: keepAwake.isActive ? tr("保持唤醒") : tr("按系统休眠"),
                           isOn: Binding(get: { keepAwake.isActive },
                                         set: { value in Task { await keepAwake.setActive(value) } }))
            HairlineDivider()
            QuickToggleRow(icon: "laptopcomputer", title: tr("合盖运行"),
                           detail: keepAwake.lidClosedActive ? tr("继续运行") : tr("合盖睡眠"),
                           isOn: Binding(get: { keepAwake.lidClosedRequested },
                                         set: { model.requestLidMode($0) }))
            HairlineDivider()
            QuickToggleRow(icon: "fan", title: tr("散热模式"),
                           detail: fans.mode == .automatic ? tr("系统调节") : tr("\(fans.mode.title)中"),
                           isOn: Binding(get: { fans.mode != .automatic },
                                         set: { model.requestFanMode($0 ? .cooling : .automatic) }))
        }
    }
}

/// 快捷开关的一行：图标、名称与当前状态，右侧开关
private struct QuickToggleRow: View {
    let icon: String
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: icon)
                .font(.system(size: DS.TextSize.sm.rawValue, weight: .medium))
                .foregroundStyle(isOn ? DS.Palette.primary : DS.Palette.textSecondary)
                .frame(width: DS.Size.iconStandalone)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                Text(detail).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: DS.Space.s2)
            DSToggle(isOn: $isOn, label: title)
        }
        .padding(.vertical, DS.Space.s2)
    }
}

struct PlaceholderLine: View {
    var body: some View {
        RoundedRectangle(cornerRadius: DS.Radius.sm)
            .fill(DS.Palette.track)
            .frame(height: DS.Size.barHeight)
    }
}
