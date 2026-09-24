import Localization
import Metrics
import SMC
import SwiftUI

/// 菜单栏合并为一个图标时点击弹出的面板：顶部一排标签切换“总览”与菜单栏里开启的各项。
/// 总览每项一行（名称、状态、走势、主数值），点一行或点标签看该项的完整详情，与每项独立时的弹窗相同
struct CombinedPopoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.settings.orderedMenuBarItems
        // 标签对应的项目在设置里被关掉后回到总览
        let tab = model.combinedPopoverTab.flatMap { items.contains($0) ? $0 : nil }

        PopoverFrame {
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
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
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
            Image(systemName: overviewSymbol)
                .font(.system(size: DS.TextSize.sm.rawValue, weight: .semibold))
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: DS.Size.iconStandalone)
            Text(tr("状态总览"))
                .dsFont(.base, weight: .semibold)
                .foregroundStyle(DS.Palette.textPrimary)
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
            ForEach(items) { item in
                OverviewRow(item: item) { open(item) }
            }
        }
    }
}

/// 总览里的一行：左边名称与一句状态，中间是走势，右边是主数值；点一下进入这一项的详情
private struct OverviewRow: View {
    let item: MenuBarItem
    let open: () -> Void
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let reading = OverviewReading(item: item, model: model)

        Card {
            Button(action: open) {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: item.symbol)
                        .font(.system(size: DS.TextSize.sm.rawValue, weight: .medium))
                        .foregroundStyle(hovering ? DS.Palette.primary : DS.Palette.textSecondary)
                        .frame(width: DS.Size.iconStandalone)
                    VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                        Text(item.popoverTitle)
                            .dsFont(.sm, weight: .semibold)
                            .foregroundStyle(hovering ? DS.Palette.primary : DS.Palette.textPrimary)
                        Text(verbatim: reading.detail)
                            .dsFont(.xs)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .monospacedDigit()
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    OverviewChart(chart: reading.chart)
                        .frame(width: DS.Space.s12, height: DS.Space.s6)

                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1 / 2) {
                        Text(verbatim: reading.value)
                            .dsFont(.base, weight: .semibold)
                            .foregroundStyle(reading.tone == .neutral ? DS.Palette.textPrimary : reading.tone.color)
                        if let unit = reading.unit {
                            Text(verbatim: unit)
                                .dsFont(.xs, weight: .medium)
                                .foregroundStyle(DS.Palette.textSecondary)
                        }
                    }
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(minWidth: DS.Space.s12, alignment: .trailing)

                    Image(systemName: "chevron.right")
                        .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                        .foregroundStyle(hovering ? DS.Palette.primary : DS.Palette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(tr("查看\(item.popoverTitle)详情"))
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
                value = Int(fastest.current).formatted()
                unit = "RPM"
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
                if let quota = MenuBarReading(model: model).aiQuotas.first {
                    value = "\(quota.remainingPercent)"
                    unit = "%"
                    detail = quota.sourceName + " · " + tr("订阅额度")
                } else {
                    detail = tr("暂无额度数据")
                }
            } else if let tokens = model.aiUsage.todayTokens {
                // 与菜单栏、面板共用同一套缩写，同一个数字不能在三处显示成三种样子。
                value = UsageNumber.short(tokens)
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
