// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import AudioControl
import Localization
import SwiftUI

/// 控件即时跟随输入；异步状态只作明确反馈，不移动正在操作的内容。
struct AudioMixerContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isPopover) private var isPopover

    var body: some View {
        if isPopover {
            AudioDeviceSection(direction: .output)
            AudioDeviceSection(direction: .input)
        } else {
            HStack(alignment: .top, spacing: DS.Space.s3) {
                AudioDeviceSection(direction: .output).frame(maxWidth: .infinity)
                AudioDeviceSection(direction: .input).frame(maxWidth: .infinity)
            }
        }
        SectionCard(title: tr("应用音量"), hint: tr("应用音量支持 0–200%；高增益时自动限制峰值，不改变系统音量。")) {
            if !model.audio.supportsMixing {
                Text(tr("应用音量需要 macOS 14.4 或更新版本")).dsFont(.sm)
            } else if !model.audio.appVolumeEnabled {
                Text(tr("仅在本机处理声音，不录制或上传音频。开启后可独立调节正在播放声音的应用。"))
                    .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.s2) {
                    Button(tr("开启应用音量")) { model.audio.authorizeMixing() }
                        .buttonStyle(.borderedProminent).disabled(model.audio.isWorking)
                    if model.audio.isAuthorizing { AudioSwitchingFeedback(text: tr("正在请求音频权限…")) }
                }
            } else if model.audio.snapshot.applications.isEmpty {
                Text(tr("暂无建立音频连接的应用")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
            } else {
                ForEach(model.audio.snapshot.applications) { app in AudioApplicationRow(app: app) }
            }
        }
        if let error = model.audio.error {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Label(errorMessage(error), systemImage: "exclamationmark.triangle")
                    .dsFont(.sm).foregroundStyle(DS.Palette.error).fixedSize(horizontal: false, vertical: true)
                if model.audio.canRetryMixing {
                    Button(tr("重试应用音频")) { model.audio.retryMixing() }.buttonStyle(.bordered).disabled(model.audio.isWorking)
                }
            }
        }
    }
    private func errorMessage(_ error: AudioControlError) -> String {
        switch error {
        case .permissionRequired: tr("请在系统设置的屏幕与系统音频录制中允许 XStats，然后重新开启应用音量。")
        case .renderStalled: tr("应用音频未恢复，已停止自动重试。")
        case .routeChanged: tr("音频设备已变化，请重试。")
        case .unsupportedFormat: tr("当前输出格式不支持应用音量，请切换音频设备。")
        case .unsupported: tr("此设备不支持该控制。")
        case .bluetoothUnavailable: tr("蓝牙未开启，请在系统设置中开启蓝牙。")
        case .bluetoothPermissionRequired: tr("请在系统设置的隐私与安全性中允许 XStats 使用蓝牙。")
        case .bluetoothConnectionFailed: tr("无法连接蓝牙设备，请确认设备已开启且在附近，然后重试。")
        case .bluetoothAudioUnavailable: tr("蓝牙音频未就绪，请确认设备支持所选的输入或输出，然后重试。")
        case .unavailable, .hardware: tr("音频操作未完成，请重试。")
        }
    }
}

private struct AudioSwitchingFeedback: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: DS.Space.s1) {
            if reduceMotion { Image(systemName: "hourglass").accessibilityHidden(true) }
            else { ProgressView().controlSize(.mini).accessibilityHidden(true) }
            Text(text).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
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
    private var volumeTitle: String { direction == .output ? tr("系统音量") : tr("输入音量") }
    private var level: Double? { direction == .output ? device?.outputVolume : device?.inputVolume }
    private var muted: Bool { (direction == .output ? device?.outputMuted : device?.inputMuted) == true }
    private var canSetVolume: Bool { (direction == .output ? device?.canSetOutputVolume : device?.canSetInputVolume) == true }
    private var canSetMute: Bool { (direction == .output ? device?.canSetOutputMute : device?.canSetInputMute) == true }
    private var muteLabel: String {
        if direction == .input { return muted ? tr("取消麦克风静音") : tr("静音麦克风") }
        return muted ? tr("取消输出静音") : tr("静音输出")
    }
    var body: some View {
        SectionCard(title: title) {
            let devices = model.audio.snapshot.devices.filter { direction == .output ? $0.hasOutput : $0.hasInput }
            let paired = model.audio.bluetoothDevices.filter { candidate in
                guard direction == .output ? candidate.hasOutput : candidate.hasInput else { return false }
                // HAL 端点先出现、切换稍后完成；保留待处理选项，避免 Picker 的 selection 暂时失去标签。
                if model.audio.switchingDevice == direction, model.audio.connectingBluetooth == candidate.id { return true }
                return !devices.contains(where: { candidate.matches($0, direction: direction) })
            }
            if !devices.isEmpty || !paired.isEmpty {
                Picker(title, selection: Binding(get: {
                    if model.audio.switchingDevice == direction, let id = model.audio.connectingBluetooth { return "bluetooth:\(id)" }
                    return device.map { "audio:\($0.id)" } ?? ""
                }, set: { selection in
                    if selection.hasPrefix("bluetooth:") { model.audio.connectBluetooth(String(selection.dropFirst(10)), direction: direction) }
                    else if let id = UInt32(selection.dropFirst(6)) { model.audio.selectDevice(id, direction: direction) }
                })) {
                    if device == nil { Text(title).tag("") }
                    ForEach(devices) { Text(verbatim: $0.name).tag("audio:\($0.id)") }
                    if !paired.isEmpty {
                        Divider()
                        ForEach(paired) { candidate in
                            if model.audio.switchingDevice == direction, model.audio.connectingBluetooth == candidate.id {
                                Text(verbatim: candidate.name).tag("bluetooth:\(candidate.id)")
                            } else { Text(tr("\(candidate.name) · 未连接")).tag("bluetooth:\(candidate.id)") }
                        }
                    }
                }.labelsHidden().pickerStyle(.menu).disabled(model.audio.isWorking)
                if model.audio.switchingDevice == direction {
                    if let id = model.audio.connectingBluetooth, let paired = model.audio.bluetoothDevices.first(where: { $0.id == id }) {
                        AudioSwitchingFeedback(text: tr("正在连接“\(paired.name)”…"))
                    } else { AudioSwitchingFeedback(text: tr("正在切换设备…")) }
                }
                if device != nil {
                    HStack(spacing: DS.Space.s2) {
                        Text(volumeTitle).dsFont(.sm)
                        Spacer(minLength: DS.Space.s1)
                        if let level {
                            Text(verbatim: (draft ?? level).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                                .dsFont(.sm, weight: .medium).monospacedDigit().accessibilityHidden(canSetVolume)
                                .accessibilityLabel(volumeTitle)
                                .accessibilityValue((draft ?? level).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                        }
                        if canSetMute {
                            MiniIconButton(systemName: AudioControlPresentation.muteSymbol(direction, muted: muted), help: muteLabel) {
                                model.audio.toggleDeviceMute(direction)
                            }.disabled(model.audio.isWorking)
                        }
                    }
                    if muted { Text(tr("已静音")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary) }
                    if let level, canSetVolume {
                        Slider(value: Binding(get: { draft ?? level }, set: { draft = $0; model.audio.setDeviceLevel($0, direction: direction) }),
                               in: 0...1, onEditingChanged: { editing = $0 })
                            .controlSize(.small).tint(muted ? DS.Palette.textSecondary : DS.Palette.primary)
                            .disabled(model.audio.isWorking).accessibilityLabel(volumeTitle)
                            .accessibilityValue((draft ?? level).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                    } else {
                        Text(tr("此设备的音量由设备自身控制")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    }
                }
            } else { Text(tr("没有可用音频设备")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary) }
        }
        .onChange(of: level) { _, _ in if !editing { draft = nil } }
        .onChange(of: device?.uid) { _, _ in draft = nil; editing = false }
        .onChange(of: model.audio.error) { _, error in if error != nil { draft = nil; editing = false } }
    }
}

struct AudioApplicationRow: View {
    let app: AudioApplication
    @Environment(AppModel.self) private var model
    @State private var icon: NSImage?
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.isPopover) private var isPopover

    var body: some View {
        let volume = model.audio.volume(for: app)
        let resettable = volume.needsProcessing || model.audio.outputRoutes[app.id] != nil
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s2) {
                Group {
                    if isSnapshot, let url = app.bundleURL { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable() }
                    else if let icon { Image(nsImage: icon).resizable() }
                    else { Image(systemName: "app.fill").resizable().foregroundStyle(DS.Palette.textSecondary) }
                }.frame(width: 20, height: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: app.name).dsFont(.sm, weight: .medium).lineLimit(1)
                    if volume.isMuted { Text(tr("已静音")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary) }
                    else if !app.isPlaying { Text(tr("已暂停")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary) }
                }
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: volume.level.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                    .dsFont(.sm, weight: .medium).monospacedDigit()
                    .foregroundStyle(volume.isMuted ? DS.Palette.textSecondary : volume.level > 1 ? DS.Palette.warning : DS.Palette.textPrimary)
                    .fixedSize().accessibilityHidden(true)
                HStack(spacing: DS.Space.s1) {
                    MiniIconButton(systemName: volume.isMuted ? "speaker.slash" : "speaker.wave.2",
                                   help: volume.isMuted ? tr("取消“\(app.name)”静音") : tr("静音“\(app.name)”")) { model.audio.toggleAppMute(app) }
                    // 始终保留重置槽位；调整音量后静音按钮不改位置。
                    MiniIconButton(systemName: "arrow.counterclockwise", help: tr("恢复“\(app.name)”的原始音量与默认输出")) {
                        model.audio.resetApp(app)
                    }.disabled(!resettable).opacity(resettable ? 1 : 0.4)
                }
            }
            Slider(value: Binding(get: { volume.level }, set: { model.audio.setAppLevel($0, app: app) }), in: 0...2)
                .controlSize(.small).tint(volume.isMuted ? DS.Palette.textSecondary : volume.level > 1 ? DS.Palette.warning : DS.Palette.primary)
                .accessibilityLabel(tr("\(app.name) 音量"))
                .accessibilityValue(volume.level.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
            ZStack {
                HStack {
                    Text(verbatim: Double(0).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                    Spacer()
                    Text(verbatim: Double(2).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                }
                Text(tr("\(Double(1).formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))) · 原始音量"))
                    .fontWeight(.medium)
            }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).accessibilityHidden(true)
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "speaker.wave.2").foregroundStyle(DS.Palette.textSecondary).accessibilityHidden(true)
                Picker(tr("\(app.name) 输出设备"), selection: Binding(get: { model.audio.outputRoutes[app.id] ?? "" }, set: {
                    model.audio.setAppOutput($0.isEmpty ? nil : $0, app: app)
                })) {
                    Text(tr("系统默认输出")).tag("")
                    if let selected = model.audio.outputRoutes[app.id], !model.audio.snapshot.devices.contains(where: { $0.uid == selected && $0.hasOutput }) {
                        Text(tr("设备不可用，使用系统默认")).tag(selected)
                    }
                    ForEach(model.audio.snapshot.devices.filter(\.hasOutput)) { Text(verbatim: $0.name).tag($0.uid) }
                }.labelsHidden().pickerStyle(.menu).controlSize(.small)
            }.dsFont(.xs)
            Group {
                if app.isPlaying && model.audio.pendingOutputApps.contains(app.id) { AudioSwitchingFeedback(text: tr("正在切换输出…")) }
                else if model.audio.failedOutputApps.contains(app.id) {
                    Text(tr("输出切换未完成，请重试。")).dsFont(.xs).foregroundStyle(DS.Palette.error).lineLimit(1)
                        .help(tr("输出切换未完成，请重试。"))
                } else { Text(" ").dsFont(.xs).accessibilityHidden(true) }
            }.frame(minHeight: DS.Size.iconInline)

        }
        .padding(.vertical, isPopover ? DS.Space.s1 : DS.Space.s2).disabled(model.audio.isWorking)
        .task(id: app.bundleURL) {
            // 系统图标只在连接身份变化时加载，避免 Slider 热路径反复读文件。
            icon = app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        }
    }
}

enum AudioControlPresentation {
    static func muteSymbol(_ direction: AudioDirection, muted: Bool) -> String {
        direction == .input ? (muted ? "mic.slash" : "mic") : (muted ? "speaker.slash" : "speaker.wave.2")
    }
}
