// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.
import NetworkObservation
import Localization
import SwiftUI

/// 功能页的本地导航状态，不写入偏好或设置备份。
enum FeatureSettingsTab: String, CaseIterable, Identifiable {
    case basic, optional
    var id: String { rawValue }
    var title: String { self == .basic ? tr("基础功能") : tr("可选功能") }
}

/// 分类选择与页面标题共用固定顶栏；键盘和辅助功能操作不等待内容过渡。
struct FeatureSettingsTabPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Picker(tr("功能"), selection: Binding(get: { model.featureSettingsTab }, set: { tab in
            DS.Motion.select { model.featureSettingsTab = tab }
        })) {
            ForEach(FeatureSettingsTab.allCases) { tab in Text(tab.title).tag(tab) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.regular)
        .fixedSize()
    }
}

/// 功能开关按两类展示；切换分类不改变任何功能或采样偏好。
struct FeatureSettings: View {
    @Environment(AppModel.self) private var model
    @State private var managesNetworkComponent = false
    @State private var enablesAfterComponentInstall = false

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            if isSnapshot {
                HStack {
                    Text(tr("功能")).dsFont(.sm, weight: .semibold)
                    Spacer()
                    FeatureSettingsTabPicker()
                }
                .padding(.horizontal, DS.Space.s3)
                .frame(height: DS.Size.windowHeader)
            }
            // 内容只做短淡入淡出，保持固定视口；选中状态、滚动起点与开关立即更新。
            SettingsTabPage {
                if model.featureSettingsTab == .basic { basicFeatures }
                else { optionalFeatures }
            }
            .id(model.featureSettingsTab)
            .transition(.opacity)
        }
        .padding(.top, isSnapshot ? 0 : DS.Space.s3)
        .dsSelectionAnimation(DS.Motion.usageSelection, value: model.featureSettingsTab)
        .sheet(isPresented: $managesNetworkComponent, onDismiss: { enablesAfterComponentInstall = false }) {
            NetworkComponentManagementView(onInstalled: {
                guard enablesAfterComponentInstall else { return }
                enablesAfterComponentInstall = false
                managesNetworkComponent = false
                model.enableNetworkObservation()
            }, onClose: { enablesAfterComponentInstall = false }).environment(model)
        }
        .onDisappear { enablesAfterComponentInstall = false }
    }

    private var basicFeatures: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text(tr("关闭功能会停止采集并移除菜单栏入口，已有历史保留。"))
                .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
                .frame(minHeight: DS.Size.controlHeight, alignment: .topLeading)
            SettingsGroup {
                ForEach(MonitoringModule.allCases.filter { $0 != .display }) { module in
                    GroupRow(showsDivider: module != .cpu) { MonitoringFeatureRow(module: module) }
                }
            }
            Text(tr("移出菜单栏不会关闭功能；系统小组件仍独立刷新。"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
    }

    private var optionalFeatures: some View {
        @Bindable var settings = model.settings
        return VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text(tr("按需启用工具，关闭后保留配置。"))
                .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
                .frame(minHeight: DS.Size.controlHeight, alignment: .topLeading)
            SettingsGroup {
                if #available(macOS 15, *) {
                    GroupRow(showsDivider: false) {
                        VStack(alignment: .leading, spacing: DS.Space.s2) {
                            SettingRow(title: tr("网络监视器"), subtitle: tr("只读查看应用的新连接，所有连接均放行。"), icon: "network") {
                                HStack(spacing: DS.Space.s3) {
                                    ViewThatFits(in: .horizontal) {
                                        Button { managesNetworkComponent = true } label: {
                                            HStack(spacing: DS.Space.s1) {
                                                Text(tr("管理组件"))
                                                if model.networkComponent.status?.update.phase == .available {
                                                    Image(systemName: "arrow.down.circle")
                                                        .foregroundStyle(DS.Palette.primary)
                                                        .accessibilityLabel(tr("网络组件有更新"))
                                                }
                                            }
                                        }
                                        .fixedSize()
                                        Button { managesNetworkComponent = true } label: {
                                            Image(systemName: model.networkComponent.status?.update.phase == .available ? "arrow.down.circle" : "gearshape")
                                        }
                                        .fixedSize()
                                        .accessibilityLabel(tr("管理组件"))
                                        .help(tr("管理组件"))
                                    }
                                    .buttonStyle(DSButtonStyle(kind: .secondary))
                                    DSToggle(isOn: Binding(get: { settings.networkConnectionsEnabled }, set: { enabled in
                                        if !enabled {
                                            enablesAfterComponentInstall = false
                                            settings.networkConnectionsEnabled = false
                                        } else if model.networkComponent.requiresInstallation {
                                            enablesAfterComponentInstall = true
                                            managesNetworkComponent = true
                                        } else { model.enableNetworkObservation() }
                                    }), label: tr("网络监视器"))
                                }
                            }
                            if let error = model.connectionMonitor.error {
                                Text(verbatim: error).dsFont(.xs).foregroundStyle(DS.Palette.error)
                                    .padding(.leading, DS.Size.iconStandalone + DS.Space.s3)
                            }
                        }
                    }
                }
                GroupRow(showsDivider: NetworkMonitorSupport.isAvailable) {
                    SettingRow(title: tr("进程"),
                               subtitle: tr("查看全部进程、搜索排序与结束进程。") + "\n"
                                   + tr("刷新进程列表会增加 CPU 等资源消耗。"),
                               icon: "list.bullet.rectangle") {
                        DSToggle(isOn: $settings.processesEnabled, label: tr("进程"))
                    }
                }
                GroupRow {
                    SettingRow(title: tr("卸载应用"), subtitle: tr("查看应用与残留文件，确认后移到废纸篓。"), icon: "trash") {
                        DSToggle(isOn: $settings.uninstallerEnabled, label: tr("卸载应用"))
                            .disabled(model.uninstaller.isRemoving)
                    }
                }
                GroupRow {
                    SettingRow(title: tr("清理"),
                               subtitle: tr("按需扫描缓存、日志与项目产物，清理前逐项确认。"),
                               icon: "eraser") {
                        DSToggle(isOn: $settings.cleanerEnabled, label: tr("清理"))
                    }
                }
            }
            SettingsGroup {
                GroupRow(showsDivider: false) {
                    VStack(alignment: .leading, spacing: DS.Space.s2) {
                        SettingRow(title: tr("AI 用量"),
                                   subtitle: tr("查看 Codex / Claude 的 Token 用量与订阅额度。"),
                                   icon: "sparkles") {
                            DSToggle(isOn: $settings.aiUsageEnabled, label: tr("AI 用量"))
                        }
                        FeatureMenuBarToggle(item: .aiUsage)
                            .padding(.leading, DS.Size.iconStandalone + DS.Space.s3)
                    }
                }
                GroupRow {
                    VStack(alignment: .leading, spacing: DS.Space.s2) {
                        SettingRow(title: tr("音频"), subtitle: tr("系统音量、音频设备与应用音量"), icon: "speaker.wave.2") {
                            DSToggle(isOn: $settings.audioEnabled, label: tr("音频"))
                        }
                        FeatureMenuBarToggle(item: .audio)
                            .padding(.leading, DS.Size.iconStandalone + DS.Space.s3)
                    }
                }
                GroupRow {
                    MonitoringFeatureRow(module: .display)
                }
            }
            SettingsGroup {
                GroupRow(showsDivider: false) {
                    SettingRow(title: tr("专注与护眼"),
                               subtitle: tr("专注计时、护眼休息与本机活动统计。"),
                               icon: "eye") {
                        HStack(spacing: DS.Space.s2) {
                            if settings.restEnabled { RestOptionsButton() }
                            DSToggle(isOn: $settings.restEnabled, label: tr("专注与护眼"))
                        }
                    }
                }
            }
            SettingsGroup {
                GroupRow(showsDivider: false) {
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
        }
    }

}

/// 功能启用与菜单栏展示分开控制，不再用文字重复陈述开关状态。
private struct MonitoringFeatureRow: View {
    @Environment(AppModel.self) private var model
    let module: MonitoringModule

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            SettingRow(title: module.title,
                       subtitle: module == .display ? tr("允许调节亮度、对比度和音量") : nil,
                       icon: module.symbol) {
                DSToggle(isOn: Binding(get: { model.settings.isModuleEnabled(module) }, set: { enabled in
                    model.settings.setModuleEnabled(module, enabled)
                }), label: tr("启用 \(module.title)"))
                .disabled(module == .thermal && model.fans.isApplying)
            }
            // 展示选项直接可见，使用复选框区别于右侧的功能启用开关。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.s4) { menuBarToggles }
                VStack(alignment: .leading, spacing: DS.Space.s2) { menuBarToggles }
            }
            .padding(.leading, DS.Size.iconStandalone + DS.Space.s3)
            if module == .thermal, let notice = model.fans.notice, model.fans.noticeIsError {
                Text(notice).dsFont(.xs).foregroundStyle(DS.Palette.error)
            }
        }
    }

    private var menuBarToggles: some View {
        ForEach(module.menuBarItems.filter { model.availableMenuBarItems.contains($0) }) { item in
            FeatureMenuBarToggle(item: item, showsItemName: module == .thermal)
        }
    }
}

/// 各功能共用的展示开关，移出菜单栏仍保留功能启用状态。
private struct FeatureMenuBarToggle: View {
    @Environment(AppModel.self) private var model
    let item: MenuBarItem
    var showsItemName = false

    var body: some View {
        Toggle(showsItemName ? tr("在菜单栏显示\(item.popoverTitle)") : tr("在菜单栏显示"), isOn: Binding(
            get: { model.settings.isEnabled(item) },
            set: { model.settings.setEnabled(item, $0) }))
            .toggleStyle(.checkbox)
            .dsFont(.xs)
            .accessibilityLabel(tr("在菜单栏显示\(item.popoverTitle)"))
            .help(item == .display ? tr("只显示信息，参数控制在功能设置中启用") : tr("加入菜单栏时会同时启用功能"))
    }
}

/// 保留关闭模块的导航入口，以明确说明状态和提供就地启用；不挂载旧数据视图。
struct DisabledMonitoringPage: View {
    @Environment(AppModel.self) private var model
    let module: MonitoringModule

    var body: some View {
        PageScroll {
            Card(padding: DS.Space.s4, spacing: DS.Space.s3) {
                Label(module.title, systemImage: module.symbol).dsFont(.lg, weight: .semibold)
                Text(tr("此功能已关闭，不再采集数据。启用后仅按展示、历史和提醒需求采集。"))
                    .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
                Button(tr("启用 \(module.title)")) { model.settings.setModuleEnabled(module, true) }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .fixedSize()
            }
        }
    }
}
