// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

struct IslandFeatureSettings: View {
    @Environment(AppModel.self) private var model
    @State private var showsOptions = false

    var body: some View {
        @Bindable var settings = model.settings
        SettingRow(title: tr("灵动岛"), subtitle: tr("在屏幕顶部查看系统指标、AI 额度、电池与休息计时"),
                   icon: "capsule", badge: tr("测试")) {
            HStack(spacing: DS.Space.s3) {
                if settings.islandPreferences.enabled {
                    Button(tr("设置")) { showsOptions = true }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .popover(isPresented: $showsOptions, arrowEdge: .top) {
                            IslandOptionsPopover {
                                showsOptions = false
                                model.previewIsland()
                            }
                            .environment(model)
                        }
                }
                DSToggle(isOn: $settings.islandPreferences.enabled, label: tr("灵动岛"))
            }
        }
    }
}

struct IslandOptionsPopover: View {
    @Environment(AppModel.self) private var model
    @State private var screens = IslandDisplayChoice.connected
    var open: () -> Void = {}

    private var preferences: IslandPreferences {
        model.islandPreferences
    }

    private var availableContent: IslandPreferences {
        IslandPreferences().available(settings: model.settings, hasInternalBattery: model.store.hasInternalBattery)
    }

    var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                HStack {
                    Text(tr("灵动岛设置")).dsFont(.lg, weight: .semibold)
                    Spacer()
                    Button(tr("展开灵动岛"), action: open)
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(preferences.scenes.isEmpty)
                }
                SettingsGroup(caption: tr("显示内容")) {
                    GroupRow(showsDivider: false) {
                        option(tr("场景")) {
                            MainActorForEach(availableContent.scenes, id: \.rawValue) { scene in
                                Toggle(scene.title, isOn: sceneVisibility(scene))
                                    .toggleStyle(.checkbox)
                                    .disabled(settings.islandPreferences.normalized.scenes == [scene])
                            }
                        }
                    }
                    if settings.islandPreferences.normalized.scenes.contains(.system), !availableContent.systemMetrics.isEmpty {
                        GroupRow {
                            option(tr("系统指标")) {
                                MainActorForEach(availableContent.systemMetrics, id: \.self) { metric in
                                    Toggle(metric.title, isOn: metricVisibility(metric))
                                        .toggleStyle(.checkbox)
                                        .disabled(settings.islandPreferences.normalized.systemMetrics == [metric])
                                }
                                Text(tr("收起时显示首个已选指标。"))
                                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                            }
                        }
                    }
                }
                Text(tr("未启用的模块自动隐藏，重新启用后恢复选择。电池基础信息独立于能耗开关。"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if preferences.scenes.isEmpty {
                    Text(tr("当前没有可显示的内容，请启用相关模块或选择其他内容。"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingsGroup(caption: tr("显示")) {
                    GroupRow(showsDivider: false) {
                        option(tr("显示屏幕")) {
                            Picker(tr("显示屏幕"), selection: $settings.islandPreferences.display) {
                                Text(tr("自动选择屏幕")).tag("")
                                MainActorForEach(screens) { screen in
                                    Text(screen.title).tag(screen.id)
                                }
                                if !settings.islandPreferences.display.isEmpty,
                                   !screens.contains(where: { $0.id == settings.islandPreferences.display }) {
                                    Text(tr("未连接的显示器")).tag(settings.islandPreferences.display)
                                }
                            }
                            .labelsHidden()
                            Text(tr("自动优先使用内置屏幕；手动选择的屏幕断开时临时回退，重新连接后恢复。"))
                                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    GroupRow {
                        option(tr("显示样式")) {
                            Picker(tr("显示样式"), selection: $settings.islandPreferences.placement) {
                                MainActorForEach(IslandPlacement.allCases, id: \.self) { placement in
                                    Text(placement.title).tag(placement)
                                }
                            }
                            .labelsHidden()
                            Text(settings.islandPreferences.placement.hint)
                                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    GroupRow {
                        VStack(alignment: .leading, spacing: DS.Space.s2) {
                            Toggle(tr("自动关注"), isOn: $settings.islandPreferences.automaticFocus)
                            Text(tr("仅在收起时优先显示低电量或额度耗尽；展开后保持当前页面。"))
                                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !preferences.scenes.isEmpty {
                        GroupRow {
                            option(tr("默认场景")) {
                                Picker(tr("默认场景"), selection: Binding(get: { preferences.scene }, set: { settings.islandPreferences.scene = $0 })) {
                                    MainActorForEach(preferences.scenes, id: \.rawValue) { scene in
                                        Text(scene.title).tag(scene)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    }
                    GroupRow {
                        option(tr("展开尺寸")) {
                            Picker(tr("展开尺寸"), selection: $settings.islandPreferences.size) {
                                MainActorForEach(IslandSize.allCases, id: \.self) { size in
                                    Text(size.title).tag(size)
                                }
                            }
                            .labelsHidden()
                            if settings.islandPreferences.size == .custom {
                                dimension(tr("宽度"), value: $settings.islandPreferences.customWidth, range: 360...600)
                                dimension(tr("高度"), value: $settings.islandPreferences.customHeight, range: 300...480)
                            }
                        }
                    }
                    if settings.islandPreferences.placement == .floating {
                        GroupRow {
                            dimension(tr("与菜单栏的间距"), value: $settings.islandPreferences.topInset, range: 8...32)
                        }
                    }
                    GroupRow {
                        SettingRow(title: tr("全屏时隐藏")) {
                            DSToggle(isOn: $settings.islandPreferences.hideInFullscreen, label: tr("全屏时隐藏"))
                        }
                    }
                }
                SettingsGroup(caption: tr("交互")) {
                    GroupRow(showsDivider: false) {
                        option(tr("打开方式")) {
                            Picker(tr("打开方式"), selection: $settings.islandPreferences.opening) {
                                MainActorForEach(IslandOpening.allCases, id: \.self) { opening in
                                    Text(opening.title).tag(opening)
                                }
                            }
                            .labelsHidden()
                            if settings.islandPreferences.opening != .click {
                                delay(tr("悬停等待时间"), value: $settings.islandPreferences.hoverDelay, range: 0.1...1)
                            }
                            if settings.islandPreferences.opening == .hoverExpand {
                                delay(tr("移开后收起"), value: $settings.islandPreferences.closeDelay, range: 0.1...2)
                            }
                        }
                    }
                }
                Text(tr("收起时宽度随内容调整。点击展开后会保持打开。"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.s4)
        }
        .frame(width: 460, height: 560)
        .background(DS.Palette.background)
        .appLanguageEnvironment()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = IslandDisplayChoice.connected
        }
    }

    private func sceneVisibility(_ scene: IslandScene) -> Binding<Bool> {
        Binding(get: { model.settings.islandPreferences.normalized.scenes.contains(scene) }, set: { visible in
            // 从保存的选择编辑，临时隐藏的模块和硬件选项不能被顺带取消。
            var value = model.settings.islandPreferences
            value.setScene(scene, visible: visible)
            model.settings.islandPreferences = value
        })
    }

    private func metricVisibility(_ metric: IslandSystemMetric) -> Binding<Bool> {
        Binding(get: { model.settings.islandPreferences.normalized.systemMetrics.contains(metric) },
                set: { model.settings.islandPreferences.setMetric(metric, visible: $0) })
    }

    private func option<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(title).dsFont(.sm, weight: .medium)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dimension(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        option(title) {
            HStack {
                Slider(value: value, in: range, step: 1).accessibilityLabel(title)
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(0)).locale(L10n.locale)))
                    .monospacedDigit().dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }

    private func delay(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        option(title) {
            HStack {
                Slider(value: value, in: range, step: 0.05).accessibilityLabel(title)
                Text(tr("\(value.wrappedValue.formatted(.number.precision(.fractionLength(2)).locale(L10n.locale))) 秒"))
                    .monospacedDigit().dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
        }
    }
}
