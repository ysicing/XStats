// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

struct DisplayDetails: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SectionCard(title: tr("显示器"), trailing: {
            if model.settings.isModuleEnabled(.display) {
                RefreshButton(loading: model.displays.isRefreshing, help: tr("重新检测显示器控制")) {
                    Task { await model.displays.redetect() }
                }
            } else {
                Button(tr("启用 \(MonitoringModule.display.title)")) { model.settings.setModuleEnabled(.display, true) }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
            }
        }) {
            if !model.settings.isModuleEnabled(.display) {
                Text(tr("仅查看显示器信息，不读取或设置参数"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
            if model.displays.catalog.isEmpty {
                Text(tr("没有检测到显示器")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
            }
            // CG 编号会复用，按连接身份区分行，换屏后丢弃旧行的拖动草稿，避免写到新显示器。
            ForEach(model.displays.catalog, id: \.target) { display in
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    HStack {
                        Label(display.name, systemImage: display.isBuiltIn ? "laptopcomputer" : "display")
                            .dsFont(.sm, weight: .semibold)
                        Spacer(minLength: DS.Space.s1)
                        if display.isMain { Chip(text: tr("主显示器"), tone: .primary) }
                    }
                    Text(verbatim: display.summary).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if display.isBuiltIn {
                        Text(tr("内置显示器请在系统设置中调节")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    } else if model.settings.isModuleEnabled(.display) {
                        ForEach(DisplayControl.allCases, id: \.self) { control in
                            DisplayControlRow(display: display, control: control,
                                              result: model.displays.readings[display.id]?[control])
                        }
                    }
                }
                .padding(.vertical, DS.Space.s2)
            }
        }
    }
}

private struct DisplayControlRow: View {
    let display: DisplayInfo
    let control: DisplayControl
    let result: DDCResult?
    @Environment(AppModel.self) private var model
    @State private var draft: Double?
    @State private var submitting = false
    @State private var editing = false
    @State private var editingToken = UUID()

    private var value: DDCValue? {
        if case .value(let value) = result { return value }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack {
                Text(control.title).dsFont(.sm)
                Spacer()
                if let value {
                    Text(verbatim: (((editing || submitting) ? (draft ?? value.percent) : value.percent) / 100).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                        .dsFont(.sm, weight: .medium).monospacedDigit()
                } else {
                    Text(status).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                }
            }
            if value != nil {
                Slider(value: Binding(get: { draft ?? value?.percent ?? 0 }, set: { draft = $0 }), in: 0...100, onEditingChanged: { active in
                    editing = active
                    if active { model.displays.beginEditing(editingToken) }
                    else {
                        let proposed = draft ?? value?.percent ?? 0
                        submitting = true
                        Task {
                            await model.displays.write(proposed, control: control, display: display)
                            model.displays.endEditing(editingToken)
                            submitting = false
                            draft = nil
                        }
                    }
                })
                .controlSize(.small)
                .tint(DS.Palette.primary)
                .disabled(submitting || model.displays.isRefreshing || model.displays.isWriting || model.displays.isPaused || model.displays.isSettling)
                .accessibilityLabel(control.title)
                .help(tr("松开滑杆后应用到显示器"))
                .onChange(of: value?.percent) { _, percent in
                    if !editing && !submitting, percent != nil { draft = nil }
                }
                .onDisappear { model.displays.endEditing(editingToken) }
            }
        }
    }

    private var status: String {
        if model.displays.isPaused { return tr("已暂停") }
        if model.displays.isSettling { return tr("显示链路正在恢复…") }
        if model.displays.isRefreshing { return tr("正在检测…") }
        switch result {
        case .unsupported: return tr("显示器不支持此控制")
        case .unavailable: return tr("暂时无法读取，请检查 DDC/CI 与连接")
        case .timedOut: return tr("显示器响应超时")
        case .busy: return tr("显示器通信繁忙")
        case .unconfirmed: return tr("修改未确认，请重新检测")
        case .cancelled, .none: return tr("尚未检测")
        case .value: return ""
        }
    }
}

extension DisplayControl {
    var title: String {
        switch self {
        case .brightness: tr("亮度")
        case .contrast: tr("对比度")
        case .volume: tr("音量")
        }
    }
}
