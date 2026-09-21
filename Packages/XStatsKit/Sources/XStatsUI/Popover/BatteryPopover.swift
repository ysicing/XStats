import AppKit
import Localization
import Metrics
import SwiftUI

/// 电池详情：电量与充电状态、最近 24 小时电量曲线、功耗、健康度，以及蓝牙设备的当前或最近电量。
/// 没有电池的 Mac（mini、Studio、iMac）只显示蓝牙设备
struct BatteryPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        let settings = model.settings
        let store = model.store
        let battery = store.battery

        BatteryHero(battery: battery)

        ForEach(MenuBarItem.battery.popoverSections.filter { isDetailPage || settings.isVisible($0) }) { section in
            switch section {
            case .batteryHistory:
                if battery != nil {
                    BatteryHistorySection()
                }
            case .batteryPower:
                if battery != nil {
                    SectionCard(title: section.title, trailing: { Text(tr("最近 60 秒")) }) {
                        PowerRows(power: store.power, history: store.powerHistory.elements, compact: !isDetailPage)
                    }
                }
            case .batteryHealth:
                if let battery {
                    BatteryHealthSection(battery: battery)
                }
            case .batteryBluetooth:
                BluetoothSection()
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - 顶部

private struct BatteryHero: View {
    let battery: BatteryStatus?
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            if let battery {
                let tone: Tone = battery.level <= 0.2 ? .error : battery.isCharging ? .primary : .success
                HStack(spacing: DS.Space.s3) {
                    RingGauge(fraction: battery.level, color: tone.color, size: DS.Space.s12 + DS.Space.s2) {
                        Image(systemName: battery.isCharging ? "bolt.fill" : "laptopcomputer")
                            .font(.system(size: DS.TextSize.sm.rawValue, weight: .medium))
                            .foregroundStyle(battery.isCharging ? DS.Palette.primary : DS.Palette.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                        HeroValue(value: Format.percent(battery.level))
                        Text(battery.stateText)
                            .dsFont(.xs, weight: .medium)
                            .foregroundStyle(DS.Palette.textSecondary)
                        if let minutes = battery.minutesRemaining {
                            Text(battery.isCharging ? tr("\(Format.duration(minutes: minutes))后充满") : tr("还能用 \(Format.duration(minutes: minutes))"))
                                .dsFont(.xs)
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: DS.Space.s1) {
                        if let watts = battery.adapterWatts, battery.isPluggedIn {
                            Chip(text: "\(watts) W", icon: "bolt.fill", tone: .warning)
                        }
                        if let temperature = model.store.sensors?.temperature(.battery) {
                            Chip(text: Format.temperature(temperature.maximum, fahrenheit: model.settings.useFahrenheit),
                                 icon: "thermometer.medium", tone: Tone.forTemperature(temperature.maximum))
                        }
                    }
                }
            } else {
                HStack(spacing: DS.Space.s3) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: DS.TextSize.lg.rawValue))
                        .foregroundStyle(DS.Palette.textSecondary)
                    VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                        Text(tr("这台 Mac 没有电池")).dsFont(.sm, weight: .semibold).foregroundStyle(DS.Palette.textPrimary)
                        Text(tr("这里显示已配对蓝牙配件，以及最近 30 分钟内读到的电量"))
                            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

extension BatteryStatus {
    /// 充电中 / 已充满 / 电源供电 / 电池供电
    var stateText: String {
        if isCharging { return tr("充电中") }
        if isPluggedIn { return isFullyCharged ? tr("已充满") : tr("电源供电") }
        return tr("电池供电")
    }
}

// MARK: - 电量历史

/// 最近 24 小时的电量曲线，来自本机历史库；打开期间每 5 分钟重新读一次
private struct BatteryHistorySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        let values = model.history.batteryPoints.compactMap(\.battery)
        SectionCard(title: PopoverSection.batteryHistory.title, trailing: { Text(tr("最近 24 小时")) }) {
            if values.count > 1 {
                LineHistoryChart(values: values, capacity: values.count, maxValue: 1, color: DS.Palette.success,
                                 grid: isDetailPage, height: detailChartHeight(isDetailPage))
            } else {
                Text(tr("还没有足够的记录。菜单栏显示电池或打开这个页面时，每分钟记录一次电量"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            while !Task.isCancelled {
                model.history.loadBattery()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }
}

// MARK: - 健康

private struct BatteryHealthSection: View {
    let battery: BatteryStatus
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionCard(title: PopoverSection.batteryHealth.title) {
            InfoRow(label: tr("健康度")) {
                Text(verbatim: battery.health.map { Format.percent($0) } ?? "—")
                    .foregroundStyle(battery.health.map { $0 < 0.8 ? DS.Palette.warning : DS.Palette.textPrimary } ?? DS.Palette.textPrimary)
            }
            InfoRow(label: tr("循环次数"), text: battery.cycleCount.map(String.init) ?? "—")
            if let temperature = model.store.sensors?.temperature(.battery) {
                InfoRow(label: tr("电池温度"), text: Format.temperature(temperature.maximum, fahrenheit: model.settings.useFahrenheit))
            }
            InfoRow(label: tr("电源"), text: battery.isPluggedIn
                    ? tr("电源适配器\(battery.adapterWatts.map { " · \($0)W" } ?? "")")
                    : tr("电池供电"))
            Text(tr("健康度是现在充满时的容量与出厂容量之比，低于 80% 时苹果建议更换电池"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(tr("系统电池设置…")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .ghost))
            }
        }
    }
}

// MARK: - 蓝牙设备

/// 蓝牙设备的当前或最近电量；弹窗打开期间每分钟刷新，也可以手动刷新
private struct BluetoothSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let bluetooth = model.bluetooth
        SectionCard(title: PopoverSection.batteryBluetooth.title, trailing: {
            if let updatedAt = bluetooth.updatedAt {
                Text(verbatim: updatedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: L10n.locale)))
            }
            RefreshButton(loading: bluetooth.isReading, help: tr("重新读取蓝牙设备电量")) { bluetooth.refresh() }
        }) {
            BluetoothDeviceList(devices: bluetooth.devices)
        }
    }
}

/// 蓝牙设备电量列表：本机信息页与电池弹窗共用；暂时断开的设备以灰色显示最近读数
enum BluetoothDeviceRowLayout: Equatable {
    case compact
    case parts

    init(batteryCount: Int) {
        self = batteryCount > 1 ? .parts : .compact
    }
}

struct BluetoothDeviceList: View {
    let devices: [BluetoothDevice]?

    var body: some View {
        if let devices {
            if devices.isEmpty {
                Text(tr("没有已连接的蓝牙设备")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
            ForEach(devices) { device in
                BluetoothDeviceRow(device: device)
            }
        } else {
            Text(tr("正在读取…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
    }
}

private struct BluetoothDeviceRow: View {
    let device: BluetoothDevice

    private var layout: BluetoothDeviceRowLayout {
        BluetoothDeviceRowLayout(batteryCount: device.batteries.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(alignment: .center, spacing: DS.Space.s2) {
                Image(systemName: device.kind.symbol)
                    .font(.system(size: DS.TextSize.sm.rawValue))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: DS.Size.iconStandalone)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: device.name)
                        .dsFont(.xs, weight: .medium)
                        .foregroundStyle(device.isConnected ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                        .lineLimit(1)
                    if layout == .parts, let lastSeenText {
                        Text(lastSeenText)
                            .dsFont(.xs)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: DS.Space.s2)
                if layout == .compact {
                    if let lastSeenText, let lastSeen = device.lastSeen {
                        Text(verbatim: lastSeen.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: L10n.locale)))
                            .dsFont(.xs)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .help(lastSeenText)
                            .accessibilityLabel(lastSeenText)
                    }
                    compactValue
                }
            }

            if layout == .parts {
                HStack(alignment: .top, spacing: DS.Space.s2) {
                    ForEach(device.batteries, id: \.label) { battery in
                        BluetoothBatteryPart(device: device, battery: battery)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, DS.Size.iconStandalone + DS.Space.s2)
                .frame(maxWidth: DS.Size.popoverWidth - DS.Size.iconStandalone - DS.Space.s6,
                       alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var lastSeenText: String? {
        guard !device.isConnected, let lastSeen = device.lastSeen else { return nil }
        return tr("上次更新：\(lastSeen.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: L10n.locale)))")
    }

    @ViewBuilder
    private var compactValue: some View {
        if let battery = device.batteries.first {
            HStack(spacing: DS.Space.s1) {
                batteryTrack(battery)
                    .frame(width: DS.Space.s8)
                batteryPercent(battery)
            }
        } else {
            Text(device.isConnected ? tr("不提供电量") : tr("未连接"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .lineLimit(1)
        }
    }

    private func batteryTrack(_ battery: (label: String, percent: Int)) -> some View {
        ProgressTrack(fraction: Double(battery.percent) / 100,
                      color: device.isConnected
                          ? (battery.percent <= 20 ? DS.Palette.error : DS.Palette.success)
                          : DS.Palette.textTertiary,
                      height: DS.Space.s1 + DS.Space.s1 / 2)
            .accessibilityHidden(true)
    }

    private func batteryPercent(_ battery: (label: String, percent: Int)) -> some View {
        Text(verbatim: "\(battery.percent)%")
            .dsFont(.xs, weight: .medium)
            .foregroundStyle(device.isConnected ? DS.Palette.textPrimary : DS.Palette.textTertiary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct BluetoothBatteryPart: View {
    let device: BluetoothDevice
    let battery: (label: String, percent: Int)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
            Text(verbatim: battery.label)
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .lineLimit(1)
            HStack(spacing: DS.Space.s1) {
                ProgressTrack(fraction: Double(battery.percent) / 100,
                              color: device.isConnected
                                  ? (battery.percent <= 20 ? DS.Palette.error : DS.Palette.success)
                                  : DS.Palette.textTertiary,
                              height: DS.Space.s1 + DS.Space.s1 / 2)
                    .frame(minWidth: DS.Space.s4, maxWidth: .infinity)
                    .accessibilityHidden(true)
                Text(verbatim: "\(battery.percent)%")
                    .dsFont(.xs, weight: .medium)
                    .foregroundStyle(device.isConnected ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
