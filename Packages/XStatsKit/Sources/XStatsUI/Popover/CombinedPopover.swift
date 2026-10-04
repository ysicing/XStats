import Localization
import Metrics
import SMC
import SwiftUI

/// 菜单栏合并为一个图标时点击弹出的面板：顶部一排标签切换“总览”与菜单栏里开启的各项。
/// 总览以两列指标卡片显示读数，网络、电池与 AI 使用整行；点卡片或标签进入现有详情。
struct CombinedPopoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.visibleMenuBarItems
        // 标签对应的项目在设置里被关掉后回到总览
        let tab = model.combinedPopoverTab.flatMap { items.contains($0) ? $0 : nil }

        PopoverFrame(width: DS.Size.combinedPopoverWidth) {
            VStack(spacing: DS.Space.s2) {
                if !items.isEmpty {
                    PopoverTabStrip(items: items, selection: tab) { model.combinedPopoverTab = $0 }
                }
                if let tab {
                    PopoverHeader(item: tab)
                } else {
                    OverviewPopoverHeader()
                }
            }
        } content: {
            if let tab {
                PopoverDetail(item: tab).id(tab)
            } else {
                OverviewPopover(items: items) { model.combinedPopoverTab = $0 }
            }
        }
    }
}

// MARK: - 标签

/// 顶部标签：总览 + 各项，苹果标准分段样式（灰色底槽、各段等宽、选中段品牌蓝），名称在悬停提示里
private struct PopoverTabStrip: View {
    let items: [MenuBarItem]
    let selection: MenuBarItem?
    let select: (MenuBarItem?) -> Void
    @Namespace private var namespace

    private static var radius: CGFloat { DS.Radius.md - DS.Space.s1 / 2 }

    var body: some View {
        HStack(spacing: 0) {
            segment(nil, symbol: overviewSymbol, title: tr("总览"))
            ForEach(items) { item in
                segment(item, symbol: item.symbol, title: item.popoverTitle)
            }
        }
        .background(DS.Palette.track, in: RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .dsSelectionAnimation(DS.Motion.quick, value: selection)
    }

    private func segment(_ item: MenuBarItem?, symbol: String, title: String) -> some View {
        let selected = item == selection
        return Button { select(item) } label: {
            Image(systemName: symbol)
                .font(.system(size: DS.TextSize.sm.rawValue, weight: .medium))
                .foregroundStyle(selected ? DS.Palette.onPrimary : DS.Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: DS.Size.segmentHeight + DS.Space.s1)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .fill(DS.Palette.primary)
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 总览的图标；主窗口“仪表盘”已经用了方格图标，这里换成仪表盘指针以示区别
private let overviewSymbol = "gauge.with.dots.needle.50percent"

private struct OverviewPopoverHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: overviewSymbol)
                    .font(.system(size: DS.TextSize.sm.rawValue, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: DS.Size.iconInline)
                Text(tr("状态总览"))
                    .dsFont(.base, weight: .semibold)
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            Spacer(minLength: DS.Space.s2)
            let page = PanelTab.overview
            MiniIconButton(systemName: page.symbol, help: tr("在主窗口打开“\(page.title)”")) { model.openMainWindow(page) }
            MiniIconButton(systemName: "gearshape", help: tr("设置")) { model.openSettings() }
        }
    }
}

// MARK: - 总览

private struct OverviewPopover: View {
    let items: [MenuBarItem]
    let open: (MenuBarItem) -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        if items.isEmpty {
            Card {
                Text(tr("菜单栏里还没有开启任何项目。"))
                    .dsFont(.sm)
                    .foregroundStyle(DS.Palette.textSecondary)
                Button(tr("选择显示项目")) { model.openMainWindow(.settingsMenuBar) }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
            }
        } else {
            let metrics = items.filter { $0 != .network && $0 != .battery && $0 != .aiUsage }
            // 项目数量有上限；直接布局全部卡片，让离屏测高与真实面板得到同样的高度。
            ForEach(Array(stride(from: 0, to: metrics.count, by: 2)), id: \.self) { index in
                WeightedRow {
                    OverviewMetricCard(item: metrics[index]) { open(metrics[index]) }
                    if index + 1 < metrics.count {
                        OverviewMetricCard(item: metrics[index + 1]) { open(metrics[index + 1]) }
                    } else {
                        Color.clear
                    }
                }
            }
            ForEach(items.filter { $0 == .network || $0 == .battery || $0 == .aiUsage }) { item in
                OverviewMetricCard(item: item) { open(item) }
            }
        }
        if model.showsOverviewProcesses { OverviewProcessesCard() }
        HStack(spacing: DS.Space.s2) {
            Button { model.openMainWindow(.keepAwake) } label: {
                Label(tr("防休眠"), systemImage: model.keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            if model.settings.cleanerEnabled {
                Button { model.openMainWindow(.cleaner) } label: {
                    Label(tr("清理"), systemImage: "sparkles").frame(maxWidth: .infinity)
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
            }
        }
    }
}

/// 数值、状态与走势保持固定层级，读数更新只重绘内容，不播放布局动画。
private struct OverviewMetricCard: View {
    let item: MenuBarItem
    let open: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let reading = OverviewReading(item: item, model: model)

        Button(action: open) {
            Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: item.symbol)
                    Text(item.popoverTitle)
                    Spacer(minLength: DS.Space.s1)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .dsFont(.xs, weight: .semibold)
                .foregroundStyle(hovering ? DS.Palette.primary : DS.Palette.textSecondary)
                .lineLimit(2)
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1 / 2) {
                    Text(verbatim: reading.value)
                        .dsFont(.xl, weight: .semibold)
                        .foregroundStyle(reading.tone == .neutral ? DS.Palette.textPrimary : reading.tone.color)
                    if let unit = reading.unit {
                        Text(verbatim: unit)
                            .dsFont(.xs, weight: .medium)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: reading.detail)
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .monospacedDigit()
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: DS.Space.s6, alignment: .topLeading)
                OverviewChart(chart: reading.chart)
                    .frame(height: DS.Space.s6)
            }
            .environment(\.isPopover, false)
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("查看\(item.popoverTitle)详情"))
        .accessibilityElement(children: .combine)
    }
}

private struct OverviewProcessesCard: View {
    @Environment(AppModel.self) private var model
    private static let rowCount = 3

    var body: some View {
        let processes = Array(model.store.processes.prefix(Self.rowCount))
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack {
                Text(tr("高占用进程")).dsFont(.xs, weight: .semibold)
                Spacer()
                MiniIconButton(systemName: "arrow.up.right", help: tr("打开进程监控")) { model.openProcessMonitor() }
            }
            .foregroundStyle(DS.Palette.textSecondary)
            ProcessList(count: processes.count, rowCount: Self.rowCount) { index in
                let process = processes[index]
                HStack(spacing: DS.Space.s2) {
                    ProcessNameLabel(icon: AppIconCache.shared.image(for: process), name: process.displayName)
                    Text(verbatim: Format.machineShare(process.cpu))
                        .dsFont(.xs, weight: .medium)
                        .frame(width: DS.Size.valueColumn, alignment: .trailing)
                    Text(verbatim: Format.bytes(process.memory))
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: DS.Size.valueColumn, alignment: .trailing)
                }
                .monospacedDigit()
            }
        }
    }
}

private struct OverviewChart: View {
    let chart: OverviewReading.Chart

    var body: some View {
        switch chart {
        case .bars(let values):
            BarHistoryChart(values: values, capacity: 20, height: DS.Space.s6)
        case .line(let values, let color):
            LineHistoryChart(values: values, capacity: 30, color: color, height: DS.Space.s6)
        case .rates(let upload, let download):
            DualLineChart(upload: upload, download: download, capacity: 30, height: DS.Space.s6)
        case .level(let fraction, let color):
            ProgressTrack(fraction: fraction, color: color, height: DS.Space.s2)
                .frame(maxHeight: .infinity)
        case .none:
            Color.clear
        }
    }
}

/// 每一项在总览里显示的内容
private struct OverviewReading {
    enum Chart {
        case bars([Double])
        case line([Double], Color)
        case rates(upload: [Double], download: [Double])
        case level(Double, Color)
        case none
    }

    var value = "—"
    var unit: String?
    var detail = ""
    var tone = Tone.neutral
    var chart = Chart.none

    @MainActor
    init(item: MenuBarItem, model: AppModel) {
        let store = model.store
        let fahrenheit = model.settings.useFahrenheit
        let temperature = { (group: TemperatureGroup) in
            store.sensors?.temperature(group).map { Format.temperature($0.maximum, fahrenheit: fahrenheit) }
        }

        switch item {
        case .cpu:
            chart = .bars(store.cpuTotal.elements)
            if let total = store.cpu?.total {
                setPercent(total)
                tone = Self.loadTone(total)
                detail = [loadLevel(total), temperature(.cpu)].compactMap { $0 }.joined(separator: " · ")
            }
        case .memory:
            chart = .line(store.memoryHistory.elements, DS.Palette.primary)
            if let memory = store.memory {
                setPercent(memory.usedFraction)
                tone = memory.pressure == .critical ? .error : memory.pressure == .warning ? .warning : .neutral
                // 压力正常时不占地方，偏高才写出来（数值同时变色）
                let usage = "\(Format.bytes(memory.used)) / \(Format.bytes(memory.total))"
                detail = memory.pressure == .normal ? usage : tr("压力 \(memory.pressure.title)") + " · " + usage
            }
        case .network:
            chart = .rates(upload: store.uploadHistory.elements, download: store.downloadHistory.elements)
            if let rate = store.network {
                let total = Format.menuBarRate(rate.uploadBytesPerSecond + rate.downloadBytesPerSecond)
                let parts = total.split(separator: " ", maxSplits: 1).map(String.init)
                value = parts.first ?? total
                unit = parts.count > 1 ? parts[1] : nil
                detail = "↑ \(Format.menuBarRate(rate.uploadBytesPerSecond))  ↓ \(Format.menuBarRate(rate.downloadBytesPerSecond))"
            }
        case .gpu:
            chart = .line(store.gpuHistory.elements, DS.Palette.secondary)
            if let gpu = store.gpu {
                setPercent(gpu.utilization)
                tone = Self.loadTone(gpu.utilization)
                detail = [loadLevel(gpu.utilization), temperature(.gpu)].compactMap { $0 }.joined(separator: " · ")
            }
        case .disk:
            if let disk = store.disk {
                setPercent(disk.usedFraction)
                chart = .level(disk.usedFraction, disk.usedFraction > 0.9 ? DS.Palette.warning : DS.Palette.primary)
                detail = tr("可用 \(Format.bytes(disk.available, base: .decimal))")
            }
        case .temperature:
            if let cpu = store.sensors?.temperature(.cpu) {
                value = Format.temperature(cpu.maximum, fahrenheit: fahrenheit)
                tone = Tone.forTemperature(cpu.maximum) == .primary ? .neutral : Tone.forTemperature(cpu.maximum)
                chart = .level(cpu.maximum / 100, Tone.forTemperature(cpu.maximum).color)
                // 状态行写 CPU 以外温度最高的一组
                let next = (store.sensors?.temperatures ?? [])
                    .filter { $0.group != .cpu }
                    .max { $0.maximum < $1.maximum }
                detail = next.map { "\($0.group.title) \(Format.temperature($0.maximum, fahrenheit: fahrenheit))" }
                    ?? tr("CPU 核心最高温度")
            }
        case .fan:
            let fans = store.sensors?.fans ?? []
            if let fastest = store.fastestFan {
                value = fans.contains(where: \.isStarting) ? tr("启动中…") : Int(fastest.current).formatted()
                unit = fans.contains(where: \.isStarting) ? nil : "RPM"
                let average = fans.map { $0.maximum > 0 ? $0.current / $0.maximum : 0 }.reduce(0, +) / Double(max(1, fans.count))
                chart = .level(average, DS.Palette.primary)
            }
            detail = fanStatusText(fans: fans, mode: model.fans.mode)
        case .battery:
            if let battery = store.battery {
                setPercent(battery.level)
                tone = battery.level <= 0.2 && !battery.isCharging ? .error : .neutral
                chart = .level(battery.level, battery.level <= 0.2 ? DS.Palette.error : battery.isCharging ? DS.Palette.primary : DS.Palette.success)
                // 充电中的时间是充满所需，其余是还能用多久，状态已经说明了是哪一种
                detail = [battery.stateText, battery.minutesRemaining.map { Format.duration(minutes: $0) }]
                    .compactMap { $0 }.joined(separator: " · ")
            } else if let lowest = model.bluetooth.lowest {
                // 没有电池的 Mac：与菜单栏一致，显示电量最低的蓝牙设备
                value = "\(lowest.percent)"
                unit = "%"
                tone = lowest.percent <= MenuBarReading.lowBluetoothPercent ? .error : .neutral
                chart = .level(Double(lowest.percent) / 100, tone == .error ? DS.Palette.error : DS.Palette.success)
                detail = lowest.label.isEmpty ? lowest.device.name : "\(lowest.device.name) · \(lowest.label)"
            } else {
                detail = tr("没有电池")
            }
        case .aiUsage:
            if !model.settings.aiUsageShowsLocalUsage {
                if let quota = MenuBarReading(model: model, items: [.aiUsage]).aiQuotas.min(by: { $0.remainingPercent < $1.remainingPercent }) {
                    value = AIUsageFormat.quotaPercent(remainingPercent: quota.window.remainingPercent,
                                                      showsRemaining: model.settings.aiQuotaShowsRemaining,
                                                      locale: L10n.locale, compact: true)
                    unit = ""
                    detail = quota.sourceName + " · " + tr(model.settings.aiQuotaShowsRemaining ? "剩余" : "已用")
                } else {
                    detail = tr("暂无额度数据")
                }
            } else if let tokens = model.aiUsage.todayTokens {
                // 与菜单栏、面板共用同一套缩写，同一个数字不能在三处显示成三种样子。
                value = UsageNumber.short(tokens, westernUnits: model.settings.aiUsageWesternUnits)
                unit = "Tokens"
                detail = "AI · " + tr("今天")
            } else {
                detail = model.settings.aiUsageEnabled ? tr("暂无本机用量数据") : tr("尚未启用")
            }
        }
    }

    private mutating func setPercent(_ fraction: Double) {
        value = "\(Int((fraction * 100).rounded()))"
        unit = "%"
    }

    private static func loadTone(_ value: Double) -> Tone {
        value >= 0.85 ? .error : value >= 0.6 ? .warning : .neutral
    }
}
