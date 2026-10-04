import Localization
import Metrics
import SMC
import SwiftUI

/// 合并与仅图标模式共用紧凑总览；详情在所属行下展开，关闭后释放视图与采样需求。
struct CombinedPopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        ScrollViewReader { scroll in
            PopoverFrame(width: DS.Size.combinedPopoverWidth) {
                HStack(spacing: DS.Space.s2) {
                    Text(tr("状态总览"))
                        .dsFont(.base, weight: .semibold)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Spacer()
                    if model.combinedPopoverTab != nil {
                        MiniIconButton(systemName: "chevron.up", help: tr("收起")) { model.combinedPopoverTab = nil }
                    }
                    MiniIconButton(systemName: "arrow.up.right", help: tr("在主窗口打开“\(PanelTab.overview.title)”")) {
                        model.openMainWindow(.overview)
                    }
                    MiniIconButton(systemName: "gearshape", help: tr("设置")) { model.openSettings() }
                }
            } content: {
                VStack(spacing: DS.Space.s2) {
                    if model.visibleMenuBarItems.isEmpty {
                        Card {
                            Text(tr("菜单栏里还没有开启任何项目。"))
                                .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
                            Button(tr("选择显示项目")) { model.openMainWindow(.settingsMenuBar) }
                                .buttonStyle(DSButtonStyle(kind: .secondary))
                        }
                    }
                    ForEach(model.visibleMenuBarItems) { item in
                        OverviewMetricRow(item: item).id(item)
                    }
                    if model.showsOverviewProcesses { OverviewProcessesCard() }
                }
                .id("overview-top")
            }
            .task(id: model.combinedPopoverTab) {
                guard !isSnapshot else { return }
                // 等展开内容进入布局后定位；快速切换会取消旧任务，不滚到过时的行。
                await Task.yield()
                guard !Task.isCancelled else { return }
                if let item = model.combinedPopoverTab { scroll.scrollTo(item, anchor: .top) }
                else { scroll.scrollTo("overview-top", anchor: .top) }
            }
        }
    }
}

private struct OverviewMetricRow: View {
    let item: MenuBarItem
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var expanded: Bool { model.combinedPopoverTab == item }

    var body: some View {
        let reading = OverviewReading(item: item, model: model)
        VStack(spacing: 0) {
            Button {
                // 高频菜单操作即时响应，数值与面板尺寸不参与弹簧动画。
                model.combinedPopoverTab = expanded ? nil : item
            } label: {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: reading.symbol)
                        .font(.system(size: DS.TextSize.base.rawValue, weight: .medium))
                        .foregroundStyle(DS.Palette.primary)
                        .frame(width: DS.Size.iconStandalone)
                    VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                            Text(reading.title).dsFont(.sm, weight: .semibold)
                                .foregroundStyle(DS.Palette.textPrimary)
                            if let location = reading.networkLocation {
                                let name = L10n.locale.localizedString(forRegionCode: location.code) ?? location.code
                                HStack(spacing: 0) {
                                    if location.style == .flag, FlagCache.shared.image(for: location.code) != nil {
                                        FlagImage(countryCode: location.code)
                                    } else {
                                        Text(verbatim: name)
                                            .dsFont(.xs)
                                            .foregroundStyle(DS.Palette.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                .help(name)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(tr("IP 归属地") + " · " + name)
                            }
                            Spacer(minLength: DS.Space.s1)
                            if item != .network && !expanded {
                                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1 / 2) {
                                    Text(verbatim: reading.value).dsFont(.base, weight: .semibold)
                                        .foregroundStyle(reading.tone == .neutral ? DS.Palette.textPrimary : reading.tone.color)
                                    if let unit = reading.unit, !unit.isEmpty {
                                        Text(verbatim: unit).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                                    }
                                }
                                .monospacedDigit()
                                .fixedSize(horizontal: true, vertical: false)
                            }
                        }
                        if !expanded {
                            Text(verbatim: reading.detail)
                                .dsFont(item == .network ? .sm : .xs)
                                .foregroundStyle(item == .network ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                                .monospacedDigit()
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if reading.hasChart && item != .network && !expanded {
                        OverviewChart(chart: reading.chart)
                            .frame(width: DS.Space.s12, height: DS.Space.s4)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.forward")
                        .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                        .frame(width: DS.Space.s3)
                }
                .padding(.horizontal, DS.Space.s3)
                .padding(.vertical, DS.Space.s2)
                .frame(minHeight: DS.Size.controlHeight + DS.Space.s4)
                .background(hovering ? DS.Palette.surfaceHover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(OverviewRowButtonStyle())
            .onHover { hovering = $0 }
            .help(expanded ? tr("收起") : tr("查看\(reading.title)详情"))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(expanded ? .isSelected : [])
            .accessibilityIdentifier("overview-row-\(item.rawValue)")
            if expanded {
                VStack(spacing: 0) {
                    PopoverHeader(item: item, showsTitle: false)
                    PopoverDetail(item: item)
                }
                .padding(.horizontal, DS.Space.s3)
                .padding(.bottom, DS.Space.s2)
            }
        }
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}

/// 按下只改变底色，避免缩放整行文字或延迟展开。
private struct OverviewRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? DS.Palette.surfaceHover : .clear)
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
        case .line(let values, let color):
            LineHistoryChart(values: values, capacity: 30, color: color, height: DS.Space.s4)
        case .level(let fraction, let color):
            ProgressTrack(fraction: fraction, color: color, height: DS.Space.s1)
                .frame(maxHeight: .infinity)
        case .none:
            EmptyView()
        }
    }
}

/// 每一项在总览里显示的内容
struct OverviewReading {
    enum Chart {
        case line([Double], Color)
        case level(Double, Color)
        case none
    }

    var title: String
    var symbol: String
    var value = "—"
    var unit: String?
    var detail = ""
    var tone = Tone.neutral
    var chart = Chart.none
    var networkLocation: (style: NetworkLocationStyle, code: String)?

    var hasChart: Bool {
        if case .none = chart { return false }
        return true
    }

    @MainActor
    init(item: MenuBarItem, model: AppModel) {
        title = item.popoverTitle
        symbol = item.symbol
        let store = model.store
        let fahrenheit = model.settings.useFahrenheit
        let temperature = { (group: TemperatureGroup) in
            store.sensors?.temperature(group).map { Format.temperature($0.maximum, fahrenheit: fahrenheit) }
        }

        switch item {
        case .display:
            value = model.displays.catalog.count.formatted(.number.locale(L10n.locale))
            detail = model.displays.catalog.map(\.name).joined(separator: " · ")
        case .cpu:
            chart = .line(store.cpuTotal.elements, DS.Palette.primary)
            if let total = store.cpu?.total {
                setPercent(total)
                tone = Self.loadTone(total)
                detail = [loadLevel(total), temperature(.cpu)].compactMap { $0 }.joined(separator: " · ")
            }
        case .memory:
            if let memory = store.memory {
                setPercent(memory.usedFraction)
                chart = .level(memory.usedFraction, memory.pressure == .critical ? DS.Palette.error : memory.pressure == .warning ? DS.Palette.warning : DS.Palette.secondary)
                tone = memory.pressure == .critical ? .error : memory.pressure == .warning ? .warning : .neutral
                // 压力正常时不占地方，偏高才写出来（数值同时变色）
                let usage = "\(Format.bytes(memory.used)) / \(Format.bytes(memory.total))"
                detail = memory.pressure == .normal ? usage : tr("压力 \(memory.pressure.title)") + " · " + usage
            }
        case .network:
            // 与菜单栏共用开关、地址族和缓存结果；总览只读，不触发额外公网查询。
            let menuReading = MenuBarReading(model: model, items: [.network])
            if menuReading.networkLocationStyle != .off, let code = menuReading.networkCountryCode {
                networkLocation = (menuReading.networkLocationStyle, code)
            }
            detail = "↑ —  ↓ —"
            if let rate = store.network {
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
            if store.battery == nil {
                title = tr("蓝牙设备")
                symbol = model.bluetooth.lowest?.device.kind.symbol ?? "dot.radiowaves.left.and.right"
            }
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
                if let devices = model.bluetooth.devices {
                    detail = devices.contains(where: \.isConnected) ? tr("不提供电量") : tr("没有已连接的蓝牙设备")
                } else {
                    detail = tr("正在查询…")
                }
            }
        case .aiUsage:
            // 与菜单栏一致：优先显示最紧张的订阅窗口，本机用量仍可在展开后查看。
            if let quota = MenuBarReading(model: model, items: [.aiUsage]).aiQuotas.min(by: { $0.remainingPercent < $1.remainingPercent }) {
                value = AIUsageFormat.quotaPercent(remainingPercent: quota.window.remainingPercent,
                                                  showsRemaining: model.settings.aiQuotaShowsRemaining,
                                                  locale: L10n.locale, compact: true)
                detail = quota.sourceName + " · " + quota.shortWindowName + " · "
                    + tr(model.settings.aiQuotaShowsRemaining ? "剩余" : "已用")
                if let percent = AIUsageFormat.quotaValue(remainingPercent: quota.window.remainingPercent,
                                                         showsRemaining: model.settings.aiQuotaShowsRemaining) {
                    chart = .level(percent / 100, DS.Palette.primary)
                }
            } else if !model.settings.aiUsageShowsLocalUsage {
                detail = tr("暂无额度数据")
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
