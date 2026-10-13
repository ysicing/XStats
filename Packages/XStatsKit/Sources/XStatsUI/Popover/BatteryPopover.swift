import AppKit
import Localization
import Metrics
import SwiftUI

/// 电池详情：电量与充电状态、最近 24 小时电量曲线、功耗、应用 CPU 能耗、健康度，以及蓝牙设备的当前或最近电量。
/// 没有内置电池的 Mac 仍显示功耗、应用能耗、温度与蓝牙设备。
struct BatteryPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        let settings = model.settings
        let store = model.store
        let battery = store.battery

        if battery != nil || !isDetailPage { BatteryHero(battery: battery) }

        ForEach(MenuBarItem.battery.popoverSections.filter { isDetailPage || settings.isVisible($0) }) { section in
            switch section {
            case .batteryHistory:
                if battery != nil && !isDetailPage {
                    BatteryHistorySection()
                }
            case .batteryPower:
                let power = SectionCard(title: section.title, trailing: { Text(tr("最近 60 秒")) }) {
                    PowerRows(power: store.power, history: store.powerHistory.elements, compact: !isDetailPage)
                }
                if isDetailPage && battery != nil {
                    if settings.isModuleEnabled(.battery) {
                        EnergyCardRow {
                            power
                        } trailing: {
                            BatteryHistorySection()
                        }
                    } else {
                        BatteryHistorySection()
                    }
                } else if settings.isModuleEnabled(.battery) {
                    power
                }
            case .batteryApps:
                if settings.isModuleEnabled(.battery) {
                    if isDetailPage {
                        EnergyCardRow {
                            BatteryAppEnergySection(reading: store.appEnergy)
                        } trailing: {
                            TemperatureCard()
                        }
                    } else {
                        BatteryAppEnergySection(reading: store.appEnergy)
                    }
                }
            case .thermalSensors:
                if settings.isModuleEnabled(.battery) && !isDetailPage { TemperatureCard() }
            case .batteryHealth:
                if let battery, !isDetailPage {
                    BatteryHealthSection(battery: battery)
                }
            case .batteryBluetooth:
                if isDetailPage && settings.isModuleEnabled(.battery) {
                    EnergyCardRow {
                        SleepAssertionsSection(processes: model.sleepAssertions.processes, isUnavailable: model.sleepAssertions.isUnavailable)
                    } trailing: {
                        BluetoothSection()
                    }
                } else {
                    BluetoothSection()
                }
            default:
                EmptyView()
            }
        }
    }
}

/// 能耗页的成对卡片共用宽度边界，避免测量回写尺寸；窄窗口自然退回单列。
private struct EnergyCardRow<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DS.Space.s3) {
                leading.frame(minWidth: DS.Size.popoverWidth, idealWidth: DS.Size.popoverWidth, maxWidth: .infinity)
                trailing.frame(minWidth: DS.Size.popoverWidth, idealWidth: DS.Size.popoverWidth, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                leading
                trailing
            }
        }
    }
}

private struct BatteryAppEnergySection: View {
    let reading: AppEnergyReading?

    var body: some View {
        SectionCard(title: tr("App 能耗"), trailing: {
            Text(tr("CPU 能耗"))
        }) {
            if let reading, !reading.isAvailable {
                Text(tr("暂时无法读取 App 能耗"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            } else if let reading, reading.interval != nil {
                InfoRow(label: tr("合计"), text: energyText(reading.totalWatts))
                if reading.apps.isEmpty {
                    Text(tr("当前没有明显的 CPU 耗电活动"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                }
                ForEach(reading.apps) { app in
                    VStack(spacing: DS.Space.s1) {
                        HStack(spacing: DS.Space.s2) {
                            AppIconCache.shared.image(bundlePath: app.bundlePath)
                                .resizable().frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
                            Text(verbatim: app.bundlePath.map { AppNameCache.shared.name(forBundle: $0) } ?? app.name)
                                .dsFont(.xs, weight: .medium).lineLimit(1)
                            Spacer(minLength: DS.Space.s2)
                            Text(verbatim: energyText(app.watts))
                                .dsFont(.xs).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                        }
                        ProgressTrack(fraction: app.watts / max(reading.apps.first?.watts ?? 0, 0.000001),
                                      color: DS.Palette.warning, height: DS.Space.s1, showsTrack: false)
                            .padding(.leading, DS.Size.iconInline + DS.Space.s2)
                    }
                }
            } else {
                Text(tr("正在统计…"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    private func energyText(_ watts: Double) -> String {
        if watts < 1 {
            return "\((watts * 1000).formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))) mW"
        }
        return "\(watts.formatted(.number.precision(.fractionLength(2)).locale(L10n.locale))) W"
    }
}

// MARK: - 顶部

private struct BatteryHero: View {
    let battery: BatteryStatus?
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            if let battery {
                if isDetailPage {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DS.Space.s6) {
                            chargeSummary(battery).frame(minWidth: DS.Size.popoverWidth, maxWidth: .infinity)
                            healthSummary(battery).frame(minWidth: DS.Size.popoverWidth, maxWidth: .infinity)
                        }
                        VStack(alignment: .leading, spacing: DS.Space.s3) {
                            chargeSummary(battery)
                            HairlineDivider()
                            healthSummary(battery)
                        }
                    }
                } else {
                    chargeSummary(battery)
                }
            } else {
                HStack(spacing: DS.Space.s3) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: DS.TextSize.lg.rawValue))
                        .foregroundStyle(DS.Palette.textSecondary)
                    VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                        Text(tr("这台 Mac 没有电池")).dsFont(.sm, weight: .semibold).foregroundStyle(DS.Palette.textPrimary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func chargeSummary(_ battery: BatteryStatus) -> some View {
        let tone: Tone = battery.level <= 0.2 ? .error : battery.isCharging ? .primary : .success
        return HStack(spacing: DS.Space.s3) {
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
    }

    private func healthSummary(_ battery: BatteryStatus) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack {
                Text(PopoverSection.batteryHealth.title)
                    .dsFont(.xs, weight: .semibold).foregroundStyle(DS.Palette.textSecondary)
                Spacer(minLength: DS.Space.s2)
                BatterySettingsButton()
            }
            HStack(spacing: DS.Space.s6) {
                VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                    Text(tr("健康度")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    Text(verbatim: battery.health.map { Format.percent($0) } ?? "—")
                        .dsFont(.sm, weight: .semibold).monospacedDigit()
                        .foregroundStyle(battery.health.map { $0 < 0.8 ? DS.Palette.warning : DS.Palette.textPrimary } ?? DS.Palette.textPrimary)
                }
                .help(tr("健康度是现在充满时的容量与出厂容量之比，低于 80% 时苹果建议更换电池"))
                .accessibilityElement(children: .combine)
                .accessibilityHint(tr("健康度是现在充满时的容量与出厂容量之比，低于 80% 时苹果建议更换电池"))
                VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                    Text(tr("循环次数")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    Text(verbatim: battery.cycleCount.map { $0.formatted(.number.locale(L10n.locale)) } ?? "—")
                        .dsFont(.sm, weight: .semibold).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
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
            } else if model.settings.isModuleEnabled(.battery) {
                Text(tr("还没有足够的记录。菜单栏显示电池或打开这个页面时，每分钟记录一次电量"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.settings.isModuleEnabled(.battery) {
                Text(tr("电量记录已暂停，已有历史保留"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
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
                BatterySettingsButton()
            }
        }
    }
}

private struct BatterySettingsButton: View {
    var body: some View {
        Button(tr("系统电池设置…")) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        .buttonStyle(DSButtonStyle(kind: .ghost))
    }
}

/// 系统服务单独展开，避免把屏幕、音频和接力的正常请求混入应用主列表。
struct SleepAssertionsSection: View {
    let processes: [SleepBlockingProcess]?
    var isUnavailable = false

    var body: some View {
        Card {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: DS.TextSize.sm.rawValue))
                    .frame(width: DS.Space.s6, height: DS.Space.s6)
                    .background(DS.Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                    .accessibilityHidden(true)
                Text(tr("阻止睡眠")).dsFont(.sm, weight: .semibold)
            }
            .foregroundStyle(DS.Palette.warning)
            if isUnavailable {
                Text(tr("暂时无法读取睡眠阻止信息")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            } else if let processes {
                let apps = processes.filter { !$0.isSystemService }
                let services = processes.filter { $0.isSystemService }
                if apps.isEmpty {
                    Text(tr("没有 App 阻止 Mac 进入睡眠"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                }
                ForEach(apps.prefix(8)) { process in SleepAssertionRow(process: process) }
                if apps.count > 8 {
                    Text(tr("另有 \((apps.count - 8).formatted(.number.locale(L10n.locale))) 项")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                }
                if !services.isEmpty {
                    DisclosureGroup {
                        ForEach(services.prefix(8)) { process in SleepAssertionRow(process: process) }
                        if services.count > 8 {
                            Text(tr("另有 \((services.count - 8).formatted(.number.locale(L10n.locale))) 项")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                        }
                    } label: {
                        Text(tr("\(services.count.formatted(.number.locale(L10n.locale))) 个系统服务正在阻止睡眠"))
                            .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
            } else {
                Text(tr("正在读取…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }
}

private struct SleepAssertionRow: View {
    let process: SleepBlockingProcess

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            AppIconCache.shared.image(bundlePath: process.bundlePath)
                .resizable().frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
            VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                Text(verbatim: process.bundlePath.map { AppNameCache.shared.name(forBundle: $0) } ?? process.name)
                    .dsFont(.xs, weight: .medium).lineLimit(1)
                if !process.reason.isEmpty {
                    Text(verbatim: process.reason).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(2).help(process.reason)
                }
            }
            Spacer(minLength: DS.Space.s2)
            Chip(text: process.preventsSystemSleep ? tr("系统") : tr("屏幕"), tone: .warning)
                .help(process.preventsSystemSleep ? tr("阻止系统闲置睡眠") : tr("阻止屏幕闲置关闭"))
        }
        .accessibilityElement(children: .combine)
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

/// 电量色只用于图标与进度条；数字保持正文颜色，便于在浅色背景上阅读。
private func bluetoothBatteryColor(percent: Int, connected: Bool) -> Color {
    guard connected else { return DS.Palette.textTertiary }
    switch percent {
    case ...20: return DS.Palette.error
    case ...50: return DS.Palette.warning
    default: return DS.Palette.success
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
                    HStack(spacing: DS.Space.s1) {
                        Text(verbatim: device.name)
                            .dsFont(.xs, weight: .medium)
                            .foregroundStyle(device.isConnected ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                            .lineLimit(1)
                        if layout == .parts && device.isConnected && device.isCharging == true {
                            chargingSymbol
                        }
                    }
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
            let charging = device.isConnected && device.isCharging == true
            HStack(spacing: DS.Space.s1) {
                batteryPercent(battery)
                Image(systemName: batterySymbol(for: battery.percent))
                    .font(.system(size: DS.TextSize.sm.rawValue))
                    .foregroundStyle(bluetoothBatteryColor(percent: battery.percent, connected: device.isConnected))
                    .overlay {
                        if charging {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 7, weight: .black))
                                .foregroundStyle(DS.Palette.textPrimary)
                                .offset(x: -1)
                        }
                    }
                    .help(charging ? tr("充电中") : tr("电量"))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(charging ? tr("充电中") : tr("电量"))
            }
        } else {
            Text(device.isConnected ? tr("不提供电量") : tr("未连接"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .lineLimit(1)
        }
    }

    private var chargingSymbol: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
            .foregroundStyle(DS.Palette.primary)
            .help(tr("充电中"))
            .accessibilityLabel(tr("充电中"))
    }

    private func batterySymbol(for percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0"
        case ..<38: "battery.25"
        case ..<63: "battery.50"
        case ..<88: "battery.75"
        default: "battery.100"
        }
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
                              color: bluetoothBatteryColor(percent: battery.percent, connected: device.isConnected),
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
