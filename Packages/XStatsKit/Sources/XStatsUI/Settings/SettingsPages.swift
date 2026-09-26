// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import HelperShared
import Localization
import Metrics
import SwiftUI

/// 主窗口里的设置页：与其他页面同样的滚动容器，打开时刷新登录项与辅助工具状态
struct SettingsTabPage<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: Content

    var body: some View {
        PageScroll { content }
            .onAppear {
                model.refreshLaunchAtLogin()
                model.helper.refreshStatus()
            }
    }
}

struct SettingsGroup<Content: View>: View {
    var caption: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            if let caption {
                Text(caption).dsFont(.xs, weight: .medium).foregroundStyle(DS.Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        }
    }
}

/// 分组内的一行，自带内边距与分隔线
struct GroupRow<Content: View>: View {
    var showsDivider = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if showsDivider { HairlineDivider() }
            content
                .padding(.horizontal, DS.Space.s4)
                .padding(.vertical, DS.Space.s3)
        }
    }
}

// MARK: - 通用

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        SettingsGroup {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("外观"), subtitle: tr("主窗口与弹窗的配色；菜单栏始终跟随系统")) {
                    SegmentedControl(selection: $settings.appearance,
                                     options: AppearanceMode.allCases.map { ($0, $0.title) })
                        .frame(width: DS.Size.sidebarWidth + DS.Space.s12)
                }
            }
            GroupRow {
                SettingRow(title: tr("登录时启动"), subtitle: model.launchAtLoginError ?? tr("开机后自动在菜单栏显示 XStats")) {
                    DSToggle(isOn: Binding(get: { model.launchAtLoginEnabled },
                                           set: { model.setLaunchAtLogin($0) }),
                             label: tr("登录时启动"))
                }
            }
            GroupRow {
                SettingRow(title: tr("在程序坞显示图标"), subtitle: tr("默认只在菜单栏运行；打开后，主窗口开着时图标出现在程序坞与 ⌘Tab 中")) {
                    DSToggle(isOn: $settings.showDockIcon, label: tr("在程序坞显示图标"))
                }
            }
            GroupRow {
                SettingRow(title: tr("刷新频率"), subtitle: tr("只显示菜单栏时的采样间隔；打开弹窗或主窗口时为 1 秒（进程页 2 秒）")) {
                    SegmentedControl(selection: $settings.refreshSeconds,
                                     options: AppSettings.refreshOptions.map { ($0, tr("\($0) 秒")) })
                        .frame(width: DS.Size.sidebarWidth + DS.Space.s12)
                }
            }
            GroupRow {
                SettingRow(title: tr("语言"), subtitle: tr("应用 UI 语言")) {
                    LanguagePicker(selection: $settings.language)
                        .help(tr("立即切换；显示器、应用名称等由系统提供的文字在下次启动时切换"))
                }
            }
            GroupRow {
                SettingRow(title: tr("温度单位")) {
                    SegmentedControl(selection: $settings.useFahrenheit, options: [(false, "°C"), (true, "°F")])
                        .frame(width: DS.Size.sidebarWidth / 2 + DS.Space.s6)
                }
            }
        }

        SettingsGroup(caption: tr("可选功能")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("番茄钟与护眼休息"),
                           subtitle: tr("专注计时、每日目标与多屏休息幕布；所有数据留在本机。"),
                           icon: "eye") {
                    HStack(spacing: DS.Space.s2) {
                        if settings.restEnabled { RestOptionsButton() }
                        DSToggle(isOn: $settings.restEnabled, label: tr("番茄钟与护眼休息"))
                    }
                }
            }
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("AI 用量与额度"),
                           subtitle: tr("自动检测 Codex / Claude 订阅额度；本地 Token 统计可单独关闭。"),
                           icon: "sparkles") {
                    DSToggle(isOn: $settings.aiUsageEnabled, label: tr("AI 用量与额度"))
                }
            }
            GroupRow {
                SettingRow(title: tr("菜单栏日历"),
                           subtitle: tr("独立显示日期，点击打开月历；不受指标合并布局影响"),
                           icon: "calendar") {
                    HStack(spacing: DS.Space.s2) {
                        if settings.calendarEnabled { CalendarOptionsButton() }
                        DSToggle(isOn: $settings.calendarEnabled, label: tr("菜单栏日历"))
                    }
                }
            }
        }

        HotKeySettings()
    }
}

// MARK: - 通知

struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let alerts = model.alerts

        if alerts.authorization == .denied {
            InfoBanner(icon: "bell.slash", text: tr("XStats 的通知被关闭了，打开的提醒不会显示。"), tone: .warning) {
                Button(tr("打开通知设置")) { alerts.openNotificationSettings() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
            }
        }

        SettingsGroup(caption: tr("发生这些状况时发送系统通知，点通知打开对应页面")) {
            ForEach(Array(AlertKind.allCases.enumerated()), id: \.element) { index, kind in
                GroupRow(showsDivider: index > 0) {
                    SettingRow(title: kind.title, subtitle: kind.detail, icon: kind.symbol) {
                        DSToggle(isOn: Binding(get: { settings.enabledAlerts.contains(kind) },
                                               set: { on in
                                                   if on { settings.enabledAlerts.insert(kind) } else { settings.enabledAlerts.remove(kind) }
                                               }),
                                 label: kind.title)
                    }
                }
                if kind == .cpuTemperature, settings.enabledAlerts.contains(.cpuTemperature) {
                    GroupRow {
                        SettingRow(title: tr("过热温度")) {
                            SegmentedControl(selection: $settings.alertCPUTemperature,
                                             options: AppSettings.alertTemperatureOptions.map {
                                                 ($0, Format.temperature(Double($0), fahrenheit: settings.useFahrenheit))
                                             })
                                .frame(width: DS.Size.sidebarWidth + DS.Space.s12)
                        }
                    }
                }
                if kind == .cpuLoad, settings.enabledAlerts.contains(.cpuLoad) {
                    GroupRow {
                        SettingRow(title: tr("占用高于")) {
                            SegmentedControl(selection: $settings.alertCPULoad,
                                             options: AppSettings.alertLoadOptions.map { ($0, "\($0)%") })
                                .frame(width: DS.Size.sidebarWidth + DS.Space.s6)
                        }
                    }
                }
            }
        }

        SettingsGroup {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("发送测试通知"), subtitle: alerts.authorization == .allowed ? tr("确认通知能正常显示") : tr("首次发送时系统会询问是否允许通知")) {
                    Button(tr("发送")) { alerts.sendTest() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
        }
        .onAppear { alerts.refreshAuthorization() }
    }
}

// MARK: - 诊断

struct DiagnosticsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let diagnostics = model.diagnostics

        SettingsGroup(caption: tr("反馈问题")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("导出诊断信息"),
                           subtitle: tr("打包版本、系统与辅助工具状态、主要设置、最近 3 天的运行日志和崩溃报告，反馈问题时附上；会去掉序列号、IP 与硬件地址")) {
                    Button(diagnostics.phase == .collecting ? tr("正在导出…") : tr("导出…")) { diagnostics.export(model: model) }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(diagnostics.phase == .collecting)
                }
            }
            switch diagnostics.phase {
            case .finished(let url):
                GroupRow {
                    InfoBanner(icon: "checkmark.circle.fill", text: tr("已导出 \(url.lastPathComponent)"), tone: .success) {
                        Button(tr("在访达中显示")) { diagnostics.reveal() }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                    }
                }
            case .failed(let message):
                GroupRow { InfoBanner(icon: "exclamationmark.triangle.fill", text: message, tone: .error) }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - 快捷键

struct HotKeySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings
        SettingsGroup(caption: tr("全局快捷键（在任何应用中都能使用，需要包含 ⌘、⌥ 或 ⌃）")) {
            ForEach(Array(HotKeyAction.allCases.enumerated()), id: \.element) { index, action in
                GroupRow(showsDivider: index > 0) {
                    SettingRow(title: action.title,
                               subtitle: model.hotKeyConflicts.contains(action) ? tr("这个快捷键已被其他应用或系统占用，请换一个") : nil) {
                        ShortcutRecorder(hotKey: Binding(get: { settings.hotKeys[action] },
                                                         set: { settings.hotKeys[action] = $0 }))
                    }
                }
            }
        }
    }
}

/// 点一下开始录制，按下组合键完成；Esc 取消，⌫ 清除
struct ShortcutRecorder: View {
    @Binding var hotKey: HotKey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: DS.Space.s1) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(verbatim: recording ? tr("按下快捷键…") : hotKey?.display ?? tr("录制快捷键"))
                    .dsFont(.sm, weight: hotKey == nil || recording ? .regular : .semibold)
                    .monospacedDigit()
                    .frame(minWidth: DS.Space.s16 + DS.Space.s12)
            }
            .buttonStyle(DSButtonStyle(kind: recording ? .primary : .secondary))
            if hotKey != nil && !recording {
                MiniIconButton(systemName: "xmark.circle.fill", help: tr("清除快捷键")) { hotKey = nil }
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53:   // Esc
                stop()
            case 51 where event.modifierFlags.intersection([.command, .option, .control]).isEmpty:   // Delete
                hotKey = nil
                stop()
            default:
                let candidate = HotKey(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                       key: event.charactersIgnoringModifiers ?? "")
                guard candidate.isValid else { NSSound.beep(); return nil }
                hotKey = candidate
                stop()
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - 菜单栏

struct MenuBarSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        MenuBarPreview()
        if settings.calendarEnabled { CalendarSettings() }

        SettingsGroup(caption: tr("布局")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("菜单栏图标"),
                           subtitle: settings.menuBarLayout == .separate
                               ? tr("每个指标一个图标，点击弹出该项详情")
                               : tr("所有指标合成一个图标，点击弹出状态总览，可切到各项详情")) {
                    SegmentedControl(selection: $settings.menuBarLayout,
                                     options: MenuBarLayout.allCases.map { ($0, $0.title) })
                        .frame(width: DS.Size.sidebarWidth + DS.Space.s6)
                }
            }
        }

        SettingsGroup(caption: tr("整体风格")) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s3), GridItem(.flexible(), spacing: DS.Space.s3)],
                      spacing: DS.Space.s3) {
                ForEach(MenuBarStyle.allCases) { style in
                    StyleCard(style: style, isSelected: settings.menuBarStyle == style) {
                        settings.menuBarStyle = style
                    }
                }
            }
            .padding(DS.Space.s3)
            HairlineDivider()
            Text(tr("整体风格套用到所有项目。想让某个项目不一样，在下面“显示项目”里给它单独选一种，比如 CPU 用圆环、风扇用数字。"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.s4)
                .padding(.vertical, DS.Space.s3)
        }

        SettingsGroup(caption: tr("显示项目")) {
            GroupRow(showsDivider: false) {
                InfoBanner(icon: "hand.draw",
                           text: tr("菜单栏里的图标可以调整顺序：按住 ⌘ 键拖动任意一个，松开后位置会一直保留。新开启的项目由系统安排位置，可能离其他图标较远，拖一下就能挪到一起。"))
            }
            ForEach(Array(MenuBarItem.allCases.enumerated()), id: \.element) { index, item in
                let moduleEnabled = item != .aiUsage || settings.aiUsageEnabled
                GroupRow {
                    VStack(alignment: .leading, spacing: DS.Space.s3) {
                        SettingRow(title: item.title,
                                   subtitle: moduleEnabled ? itemSubtitle(item) : tr("尚未启用"),
                                   icon: item.symbol) {
                            if moduleEnabled {
                                DSToggle(isOn: Binding(get: { settings.isEnabled(item) },
                                                       set: { settings.setEnabled(item, $0) }),
                                         label: item.title)
                            } else {
                                Button(tr("设置")) { settings.panelTab = .settingsGeneral }
                                    .buttonStyle(DSButtonStyle(kind: .secondary))
                            }
                        }
                        if moduleEnabled, settings.isEnabled(item) {
                            ItemStyleRow(item: item)
                            if !item.popoverSections.isEmpty { PopoverSectionPicker(item: item) }
                        }
                    }
                }
            }
        }

        SettingsGroup(caption: tr("其他")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("高负载时着色"), subtitle: tr("占用超过 85%（电池电量低于 20%）时数值与图形显示为红色")) {
                    DSToggle(isOn: $settings.colorizeHighLoad, label: tr("高负载时着色"))
                }
            }
            GroupRow {
                SettingRow(title: tr("蓝牙设备电量低时提示"),
                           subtitle: tr("键盘、鼠标、耳机等低于 20% 时，在菜单栏的电池项目旁显示该设备的图标与电量；需要开启电池项目")) {
                    DSToggle(isOn: $settings.bluetoothLowBatteryInMenuBar, label: tr("蓝牙设备电量低时提示"))
                }
            }
        }
    }

    /// 没有电池的 Mac 上，电池项目改为显示蓝牙设备电量
    private func itemSubtitle(_ item: MenuBarItem) -> String {
        item == .battery && model.store.battery == nil
            ? tr("这台 Mac 没有电池：菜单栏显示电量最低的蓝牙设备，弹窗只列蓝牙设备")
            : item.subtitle
    }

}

/// 单个项目自己的菜单栏风格：网速有自己的三种样式；其他项目默认跟随整体，也可以单独选一种。
/// 旁边用实时数据画出这一项现在在菜单栏里的样子，改了立刻能看到
private struct ItemStyleRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let item: MenuBarItem

    var body: some View {
        @Bindable var settings = model.settings
        HStack(spacing: DS.Space.s3) {
            Text(tr("菜单栏风格"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize()
            if item == .network {
                SegmentedControl(selection: $settings.networkStyle,
                                 options: NetworkMenuStyle.allCases.map { ($0, $0.title) })
                    .frame(width: DS.Size.sidebarWidth + DS.Space.s6)
            } else {
                let inheritedStyle = settings.menuBarStyle.resolved(for: item)
                Picker(tr("菜单栏风格"), selection: Binding(get: { settings.styleOverrides[item] },
                                                       set: { settings.setStyleOverride($0, for: item) })) {
                    Text(tr("跟随整体（\(inheritedStyle.title)）")).tag(MenuBarStyle?.none)
                    Divider()
                    ForEach(MenuBarStyle.options(for: item)) { style in
                        Text(style.title).tag(MenuBarStyle?.some(style))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            preview
            Spacer(minLength: 0)
        }
        .padding(.leading, DS.Size.iconStandalone + DS.Space.s3)
    }

    /// 这一项按当前风格、实时读数画出来的样子，底色跟随浅色 / 深色外观
    private var preview: some View {
        let settings = model.settings
        let image = MenuBarRenderer.image(reading: MenuBarReading(model: model), items: [item],
                                          style: { settings.style(for: $0) }, networkStyle: settings.networkStyle,
                                          colorizeHighLoad: settings.colorizeHighLoad, fahrenheit: settings.useFahrenheit)
        return Image(nsImage: MenuBarRenderer.preview(image, dark: colorScheme == .dark))
            .padding(.horizontal, DS.Space.s3)
            .frame(height: DS.Size.segmentHeight + DS.Space.s1)
            .background(DS.Palette.track, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .accessibilityLabel(tr("该项目在菜单栏里的实时效果"))
    }
}

/// 选择该项详情弹窗里显示哪些区块
private struct PopoverSectionPicker: View {
    @Environment(AppModel.self) private var model
    let item: MenuBarItem

    var body: some View {
        let settings = model.settings
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
            Text(tr("弹窗显示"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize()
            FlowLayout(spacing: DS.Space.s1) {
                ForEach(item.popoverSections) { section in
                    let visible = settings.isVisible(section)
                    SectionToggleChip(title: section.title, isOn: visible) {
                        settings.setVisible(section, !visible)
                    }
                }
            }
        }
        .padding(.leading, DS.Size.iconStandalone + DS.Space.s3)
    }
}

private struct SectionToggleChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(.system(size: DS.TextSize.xs.rawValue - DS.Space.s1 / 2, weight: .bold))
                Text(title).dsFont(.xs, weight: .medium)
            }
            .foregroundStyle(isOn ? DS.Palette.primary : DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.s2)
            .frame(height: DS.Size.segmentHeight)
            .background(isOn ? DS.Palette.primary.opacity(0.12) : hovering ? DS.Palette.surfaceHover : .clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm)
                .strokeBorder(isOn ? DS.Palette.primary.opacity(0.4) : DS.Palette.border, lineWidth: DS.Size.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct StyleCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let style: MenuBarStyle
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    /// 风扇标签比“0”宽，能直接看出两种双行风格的对齐差异。
    private var isStacked: Bool { style == .stacked || style == .stackedCenter }
    private var previewItems: [MenuBarItem] { isStacked ? [.cpu, .memory, .fan] : [.cpu, .memory, .gpu] }
    private var previewReading: MenuBarReading {
        guard isStacked else { return .sample }
        var reading = MenuBarReading.sample
        reading.fanRPM = 0
        return reading
    }

    var body: some View {
        let sample = MenuBarRenderer.image(reading: previewReading, items: previewItems,
                                           style: { _ in style }, networkStyle: model.settings.networkStyle,
                                           colorizeHighLoad: false, fahrenheit: model.settings.useFahrenheit)
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                // 预览按原尺寸显示，超出卡片宽度时等比缩小，保证各卡片对齐
                Image(nsImage: MenuBarRenderer.preview(sample, dark: colorScheme == .dark))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: sample.size.width, maxHeight: sample.size.height)
                    .padding(.horizontal, DS.Space.s2)
                    .frame(maxWidth: .infinity)
                    .frame(height: DS.Size.controlHeight + DS.Space.s2)
                    .background(DS.Palette.track, in: RoundedRectangle(cornerRadius: DS.Radius.sm))

                HStack(spacing: DS.Space.s1) {
                    Text(style.title).dsFont(.sm, weight: .semibold).foregroundStyle(DS.Palette.textPrimary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: DS.TextSize.sm.rawValue))
                            .foregroundStyle(DS.Palette.primary)
                    }
                }
                Text(style.detail)
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: DS.TextSize.xs.rawValue * 3, alignment: .topLeading)
            }
            .padding(DS.Space.s2)
            .background(hovering && !isSelected ? DS.Palette.surfaceHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md)
                .strokeBorder(isSelected ? DS.Palette.primary : DS.Palette.border,
                              lineWidth: isSelected ? DS.Size.chartLine : DS.Size.stroke))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MenuBarPreview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let image = MenuBarRenderer.image(for: model)
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(tr("当前效果（实时数据）")).dsFont(.xs, weight: .medium).foregroundStyle(DS.Palette.textSecondary)
            // 实时图标宽度会随启用的项目变化；并排时两张预览可能撑出设置页。
            VStack(spacing: DS.Space.s2) {
                preview(image: image, dark: false)
                preview(image: image, dark: true)
            }
        }
    }

    private func preview(image: NSImage, dark: Bool) -> some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack {
                    Spacer(minLength: DS.Space.s2)
                    Image(nsImage: MenuBarRenderer.preview(image, dark: dark))
                    Spacer(minLength: DS.Space.s2)
                }
                .frame(minWidth: geometry.size.width)
                .frame(height: DS.Size.controlHeight + DS.Space.s2)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: DS.Size.controlHeight + DS.Space.s2)
        .background(dark ? Color(nsColor: NSColor(hex: 0x1F2937)) : Color(nsColor: NSColor(hex: 0xE5E7EB)),
                    in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .accessibilityLabel(dark ? tr("深色菜单栏预览") : tr("浅色菜单栏预览"))
    }
}

// MARK: - 网络

struct NetworkSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        SettingsGroup(caption: tr("连接探测")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("定时探测网络"), subtitle: tr("网络详情打开时每秒 ping 一次，通了是绿格、不通是红格，显示最近 60 次")) {
                    DSToggle(isOn: $settings.probeEnabled, label: tr("定时探测网络"))
                }
            }
            GroupRow {
                SettingRow(title: tr("探测目标"), subtitle: tr("国内网络建议选阿里云或腾讯；选路由器只检测本地连接")) {
                    Picker(tr("探测目标"), selection: $settings.probeTarget) {
                        ForEach(ProbeTarget.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .disabled(!settings.probeEnabled)
            GroupRow {
                SettingRow(title: tr("后台低频探测"),
                           subtitle: tr("详情关闭时，菜单栏显示网络项期间每 \(NetworkController.backgroundProbeSeconds) 秒探测一次，打开详情就能看到最近的连接情况；关闭后只在打开详情时探测，更省电")) {
                    DSToggle(isOn: $settings.probeInBackground, label: tr("后台低频探测"))
                }
            }
            .disabled(!settings.probeEnabled)
        }

        SettingsGroup(caption: tr("公网 IP")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("查询公网 IP"),
                           subtitle: tr("打开网络详情时向 Cloudflare（1.1.1.1）或 ipify 查询一次公网地址，10 分钟内不重复请求；归属地、ASN、网络类型与纯净度由这台 Mac 直接向 cleanip.io 查询，只发送公网地址")) {
                    DSToggle(isOn: $settings.publicIPLookup, label: tr("查询公网 IP"))
                }
            }
        }

        InfoBanner(icon: "lock.shield", text: tr("修改 DNS 需要管理员权限：已安装辅助工具时直接修改，否则每次弹出系统授权框。"), tone: .neutral)
    }
}

// MARK: - 散热与防休眠

/// 放在“温度与风扇”页底部
struct FanSafetySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        SettingsGroup(caption: tr("风扇设置")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("安全温度"), subtitle: tr("自定义转速时，CPU 达到该温度自动恢复系统控制")) {
                    SegmentedControl(selection: $settings.fanSafetyTemperature,
                                     options: AppSettings.fanSafetyOptions.map { ($0, "\($0)°C") })
                        .frame(width: DS.Size.sidebarWidth + DS.Space.s12)
                }
            }
        }
    }
}

/// 放在“防休眠”页底部
struct LidBatterySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        SettingsGroup(caption: tr("合盖运行设置")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("电量下限"), subtitle: tr("使用电池且电量低于该值时，自动关闭合盖运行")) {
                    SegmentedControl(selection: $settings.lidModeBatteryFloor,
                                     options: AppSettings.batteryFloorOptions.map { ($0, "\($0)%") })
                        .frame(width: DS.Size.sidebarWidth + DS.Space.s12)
                }
            }
        }
    }
}

// MARK: - 辅助工具

struct HelperSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let helper = model.helper

        SettingsGroup {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("XStats 辅助工具"), subtitle: tr("以系统权限运行的后台服务，只接受本应用的请求"), icon: "lock.shield") {
                    StatusBadge(text: helper.status.title, tone: tone(helper.status))
                }
            }
            GroupRow {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    Text(tr("它只做这几件事")).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.textPrimary)
                    CapabilityLine(text: tr("设置风扇目标转速，或恢复系统自动控制"))
                    CapabilityLine(text: tr("开启 / 关闭“合盖不睡眠”（等同 pmset disablesleep）"))
                    CapabilityLine(text: tr("刷新 DNS 缓存、释放内存、为网络服务设置 DNS 服务器"))
                    CapabilityLine(text: tr("应用退出或断开连接时，自动恢复风扇与睡眠设置"))
                }
            }
            GroupRow {
                HStack(spacing: DS.Space.s2) {
                    switch helper.status {
                    case .notInstalled:
                        Button(tr("安装辅助工具")) { helper.install() }
                            .buttonStyle(DSButtonStyle(kind: .primary))
                    case .requiresApproval:
                        Button(tr("打开登录项设置")) { helper.openLoginItemsSettings() }
                            .buttonStyle(DSButtonStyle(kind: .primary))
                        Button(tr("卸载")) { Task { await helper.uninstall() } }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                    case .enabled:
                        Button(tr("卸载辅助工具")) { Task { await helper.uninstall() } }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                    case .unavailable:
                        EmptyView()
                    }
                    Button(tr("刷新状态")) { helper.refreshStatus() }
                        .buttonStyle(DSButtonStyle(kind: .ghost))
                    Spacer()
                }
                .disabled(helper.isWorking)
            }
        }

        if case .unavailable(let reason) = helper.status {
            InfoBanner(icon: "exclamationmark.triangle.fill", text: reason, tone: .error)
        }
        if helper.canInstall && helper.isOutdated {
            InfoBanner(icon: "arrow.triangle.2.circlepath", text: HelperClient.outdatedMessage, tone: .warning) {
                Button(tr("重新安装")) { Task { await helper.reinstall() } }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(helper.isWorking)
            }
        }
        if let error = helper.lastError {
            InfoBanner(icon: "exclamationmark.triangle.fill", text: error, tone: .error)
        }
        if CodeSigningInfo.currentTeamIdentifier() != nil {
            InfoBanner(icon: "checkmark.seal", text: tr("已使用 Developer ID 签名"), tone: .success)
        } else {
            InfoBanner(icon: "info.circle", text: HelperClient.signingMessage, tone: .neutral)
        }
    }

    private func tone(_ status: HelperClient.Status) -> Tone {
        switch status {
        case .enabled: .success
        case .requiresApproval: .warning
        case .notInstalled: .neutral
        case .unavailable: .error
        }
    }
}

private struct CapabilityLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            Image(systemName: "checkmark")
                .font(.system(size: DS.TextSize.xs.rawValue, weight: .bold))
                .foregroundStyle(DS.Palette.success)
            Text(text).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

// MARK: - 关于

struct AboutSettings: View {
    @State private var legalDocument: LegalDocument?

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? tr("开发版")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        SettingsGroup {
            GroupRow(showsDivider: false) {
                HStack(spacing: DS.Space.s4) {
                    AppGlyph(size: DS.Space.s12)
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        Text("XStats").dsFont(.lg, weight: .semibold).foregroundStyle(DS.Palette.textPrimary)
                        Text(verbatim: tr("版本 \(version)\(build.map { " (\($0))" } ?? "")"))
                            .dsFont(.sm)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    Spacer()
                }
            }
            GroupRow {
                Text(tr("在菜单栏掌握 Mac 状态；按需测速、控制风扇与清理空间，小组件和番茄钟助你保持专注。"))
                    .dsFont(.sm)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        UpdateSettings()
        DiagnosticsSettings()

        SettingsGroup(caption: tr("法律与隐私")) {
            GroupRow(showsDivider: false) {
                SettingRow(title: tr("服务条款"), subtitle: tr("了解 XStats 的使用条件与责任边界")) {
                    Button(tr("查看")) { legalDocument = .terms }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
            GroupRow {
                SettingRow(title: tr("隐私政策"), subtitle: tr("了解本机数据、联网功能与信息处理方式")) {
                    Button(tr("查看")) { legalDocument = .privacy }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
        }

        SettingsGroup(caption: tr("致谢")) {
            GroupRow {
                SettingRow(title: "gentpan/OpenStats", subtitle: tr("XStats 基于 OpenStats 开发，感谢原项目的开源贡献 · MIT License")) {
                    Button(tr("查看")) {
                        if let url = URL(string: "https://github.com/gentpan/OpenStats") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
            GroupRow(showsDivider: false) {
                SettingRow(title: "exelban/stats", subtitle: tr("SMC 通信与 Apple Silicon 风扇解锁流程移植自该项目 · MIT License")) {
                    Button(tr("查看")) {
                        if let url = URL(string: "https://github.com/exelban/stats") { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
        }
        .sheet(item: $legalDocument) { document in
            LegalDocumentSheet(document: document)
        }
    }
}
