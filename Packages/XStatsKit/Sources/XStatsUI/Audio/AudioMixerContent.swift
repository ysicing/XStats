// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import AudioControl
import Localization
import SwiftUI

/// 主窗口和菜单栏共享控件；读数刷新不会触发音量写入。
struct AudioMixerContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AudioDeviceSection(direction: .output)
        AudioDeviceSection(direction: .input)
        SectionCard(title: tr("应用音量"), hint: tr("应用音量支持 0–200%；高增益时自动限制峰值，不改变系统音量。")) {
            if !model.audio.supportsMixing {
                Text(tr("应用音量需要 macOS 14.4 或更新版本")).dsFont(.sm)
            } else if !model.audio.hasPermission {
                Text(tr("仅在本机处理声音，不录制或上传音频。开启后可独立调节正在播放声音的应用。"))
                    .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("开启应用音量")) { model.audio.authorizeMixing() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.audio.isWorking)
            } else if model.audio.snapshot.applications.isEmpty {
                Text(tr("暂无建立音频连接的应用")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
            } else {
                ForEach(model.audio.snapshot.applications) { app in
                    AudioApplicationRow(app: app)
                }
            }
        }
        if let error = model.audio.error {
            if model.audio.canRetryMixing { Button(tr("重试应用音频")) { model.audio.retryMixing() }.buttonStyle(.bordered).disabled(model.audio.isWorking) }
            Text(errorMessage(error)).dsFont(.sm).foregroundStyle(DS.Palette.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func errorMessage(_ error: AudioControlError) -> String {
        switch error {
        case .permissionRequired: tr("请在系统设置的屏幕与系统音频录制中允许 XStats，然后重新开启应用音量。")
        case .renderStalled: tr("应用音频未恢复，已停止自动重试。")
        case .routeChanged: tr("音频设备已变化，请重试。")
        case .unsupportedFormat: tr("当前输出格式不支持应用音量，请切换音频设备。")
        case .unsupported: tr("此设备不支持该控制。")
        case .unavailable, .hardware: tr("音频操作未完成，请重试。")
        }
    }
}

private struct AudioDeviceSection: View {
    let direction: AudioDirection
    @Environment(AppModel.self) private var model
    @State private var draft: Double?
    @State private var editing = false

    private var device: AudioDeviceInfo? { direction == .output ? model.audio.output : model.audio.input }
    private var title: String { direction == .output ? tr("输出设备") : tr("输入设备") }
    private var level: Double? { direction == .output ? device?.outputVolume : device?.inputVolume }
    private var muted: Bool { (direction == .output ? device?.outputMuted : device?.inputMuted) == true }
    private var canSetVolume: Bool { (direction == .output ? device?.canSetOutputVolume : device?.canSetInputVolume) == true }
    private var canSetMute: Bool { (direction == .output ? device?.canSetOutputMute : device?.canSetInputMute) == true }

    var body: some View {
        SectionCard(title: title) {
            let devices = model.audio.snapshot.devices.filter { direction == .output ? $0.hasOutput : $0.hasInput }
            if !devices.isEmpty {
                Picker(title, selection: Binding(get: { device?.id ?? 0 }, set: { model.audio.selectDevice($0, direction: direction) })) {
                    if device == nil { Text(title).tag(UInt32(0)) }
                    ForEach(devices) { Text(verbatim: $0.name).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.menu).disabled(model.audio.isWorking)
                if device != nil {
                    HStack {
                        Text(direction == .output ? tr("系统音量") : tr("输入音量")).dsFont(.sm)
                        Spacer()
                        if let level {
                            Text(verbatim: (draft ?? level).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                                .dsFont(.sm, weight: .medium).monospacedDigit()
                        }
                        if canSetMute {
                            MiniIconButton(systemName: muted ? "speaker.slash" : "speaker.wave.2", help: muted ? tr("取消静音") : tr("静音")) {
                                model.audio.toggleDeviceMute(direction)
                            }.disabled(model.audio.isWorking)
                        }
                    }
                    if let level, canSetVolume {
                        Slider(value: Binding(get: { draft ?? level }, set: {
                            draft = $0
                            model.audio.setDeviceLevel($0, direction: direction)
                        }), in: 0...1, onEditingChanged: { editing = $0 })
                        .controlSize(.small).tint(DS.Palette.primary).disabled(model.audio.isWorking)
                        .accessibilityLabel(direction == .output ? tr("系统音量") : tr("输入音量"))
                    } else {
                        Text(tr("此设备的音量由设备自身控制")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
            } else {
                Text(tr("没有可用音频设备")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .onChange(of: level) { _, _ in if !editing { draft = nil } }
        .onChange(of: device?.uid) { _, _ in draft = nil; editing = false }
        .onChange(of: model.audio.error) { _, error in if error != nil { draft = nil; editing = false } }
    }
}

private struct AudioApplicationRow: View {
    let app: AudioApplication
    @Environment(AppModel.self) private var model

    var body: some View {
        let volume = model.audio.volume(for: app)
        VStack(spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                Text(verbatim: app.name).dsFont(.sm, weight: .medium).lineLimit(1)
                if !app.isPlaying { Chip(text: tr("已暂停"), tone: .neutral) }
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: volume.level.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                    .dsFont(.sm).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                MiniIconButton(systemName: volume.isMuted ? "speaker.slash" : "speaker.wave.2", help: volume.isMuted ? tr("取消静音") : tr("静音")) {
                    model.audio.toggleAppMute(app)
                }
                if volume.needsProcessing || model.audio.outputRoutes[app.id] != nil {
                    MiniIconButton(systemName: "arrow.counterclockwise", help: tr("恢复原始音量与默认输出")) { model.audio.resetApp(app) }
                }
            }
            Slider(value: Binding(get: { volume.level }, set: { model.audio.setAppLevel($0, app: app) }), in: 0...2)
                .controlSize(.small).tint(DS.Palette.primary).accessibilityLabel(app.name)
            Picker(tr("应用输出设备"), selection: Binding(get: { model.audio.outputRoutes[app.id] ?? "" }, set: { model.audio.setAppOutput($0.isEmpty ? nil : $0, app: app) })) {
                Text(tr("系统默认输出")).tag("")
                if let selected = model.audio.outputRoutes[app.id], !model.audio.snapshot.devices.contains(where: { $0.uid == selected && $0.hasOutput }) {
                    Text(tr("设备不可用，使用系统默认")).tag(selected)
                }
                ForEach(model.audio.snapshot.devices.filter(\.hasOutput)) { device in Text(verbatim: device.name).tag(device.uid) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small)
        }
        .padding(.vertical, DS.Space.s1)
        .disabled(model.audio.isWorking)
    }
}
