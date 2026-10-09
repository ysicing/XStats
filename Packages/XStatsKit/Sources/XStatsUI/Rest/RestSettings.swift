// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI
import UniformTypeIdentifiers

/// 保留现有偏好与备份值；界面统一呈现为“休息后自动开始下一轮”。
public enum RestRunMode: String, CaseIterable, Identifiable, Sendable {
    case single, cycle, workday
    public var id: String { rawValue }
}

enum RestPrimaryAction: CaseIterable, Hashable {
    case startFocus, startNextRound, pause, resume

    var title: String {
        switch self {
        case .startFocus: tr("开始专注")
        case .startNextRound: tr("开始下一轮")
        case .pause: tr("暂停")
        case .resume: tr("继续")
        }
    }
}

public enum RestHUDStyle: String, CaseIterable, Identifiable, Sendable {
    // hourglass 保留为已保存偏好的标识，界面改为更清晰的时间与进度条。
    case countdown, ring, hourglass

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .countdown: tr("数字倒计时")
        case .ring: tr("进度圆环")
        case .hourglass: tr("进度条")
        }
    }

    var symbol: String {
        switch self {
        case .countdown: "numbersign"
        case .ring: "circle.dotted.circle"
        case .hourglass: "rectangle.bottomthird.inset.filled"
        }
    }

    var next: Self {
        switch self {
        case .countdown: .ring
        case .ring: .hourglass
        case .hourglass: .countdown
        }
    }
}

/// 与菜单栏日历一致：功能页只保留模块开关，详细选项由独立弹出层承载。
struct RestOptionsButton: View {
    @State private var isPresented = false

    var body: some View {
        Button(tr("设置")) { isPresented = true }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                RestOptionsPopover()
            }
    }
}

struct RestOptionsPopover: View {
    @Environment(AppModel.self) private var model
    @State private var soundPreviewFailed = false
    @State private var selectsAudio = false
    @State private var importsAudio = false
    @State private var audioImportError: String?
    @State private var importTask: Task<Void, Never>?
    private let audioStore = RestCustomAudioStore()
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        @Bindable var settings = model.settings

        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                SettingsGroup(caption: tr("专注")) {
                    GroupRow(showsDivider: false) {
                        SettingRow(title: tr("专注时长")) {
                            Picker(tr("专注时长"), selection: $settings.restWorkMinutes) {
                                ForEach(AppSettings.restWorkOptions, id: \.self) { minutes in
                                    Text(tr("\(minutes) 分钟")).tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .fixedSize()
                            .frame(width: 160, alignment: .trailing)
                        }
                    }
                    GroupRow {
                        SettingRow(title: tr("轮间休息"), subtitle: tr("每轮专注结束后的休息。")) {
                            Picker(tr("轮间休息"), selection: $settings.restBreakMinutes) {
                                ForEach(AppSettings.restBreakOptions, id: \.self) { minutes in
                                    Text(tr("\(minutes) 分钟")).tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .fixedSize()
                            .frame(width: 160, alignment: .trailing)
                        }
                    }
                    GroupRow {
                        SettingRow(title: tr("长休息"), subtitle: tr("每完成 4 轮专注后进入长休")) {
                            Picker(tr("长休息"), selection: $settings.restLongBreakMinutes) {
                                ForEach(AppSettings.restLongBreakOptions, id: \.self) { minutes in
                                    Text(tr("\(minutes) 分钟")).tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .fixedSize()
                            .frame(width: 160, alignment: .trailing)
                        }
                    }
                    GroupRow {
                        SettingRow(title: tr("休息后自动开始下一轮"), subtitle: tr("关闭时，休息结束后由你开始下一轮。")) {
                            DSToggle(isOn: $settings.restAutomaticallyStartsNextRound, label: tr("休息后自动开始下一轮"))
                        }
                    }
                    GroupRow {
                        SettingRow(title: tr("每日目标")) {
                            Picker(tr("每日目标"), selection: $settings.restDailyGoal) {
                                ForEach(AppSettings.restDailyGoalOptions, id: \.self) { count in
                                    Text(tr("\(count) 轮")).tag(count)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .fixedSize()
                            .frame(width: 160, alignment: .trailing)
                        }
                    }
                    GroupRow {
                        SettingRow(title: tr("休息声音"), subtitle: tr("试听 5 秒后自动停止")) {
                            HStack(spacing: DS.Space.s2) {
                                if settings.restSound != .off && (settings.restSound != .custom || settings.restCustomAudio != nil) {
                                    Button {
                                        if model.rest.isPreviewingSound { model.rest.stopSoundPreview() }
                                        else { soundPreviewFailed = !model.rest.startSoundPreview() }
                                    } label: {
                                        Image(systemName: model.rest.isPreviewingSound ? "stop.fill" : "play.fill")
                                            .font(.system(size: 11, weight: .semibold))
                                            .frame(width: 24, height: 24)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .accessibilityLabel(tr(model.rest.isPreviewingSound ? "停止试听" : "试听"))
                                    .help(tr(model.rest.isPreviewingSound ? "停止试听" : "试听"))
                                    .disabled(!model.rest.canPreviewSound)
                                }
                                Picker(tr("休息声音"), selection: $settings.restSound) {
                                    ForEach(RestSound.allCases) { sound in
                                        Text(sound.title).tag(sound)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .controlSize(.small)
                                .fixedSize()
                            }
                            .frame(width: 160, alignment: .trailing)
                        }
                    }
                    if settings.restSound == .custom {
                        GroupRow {
                            SettingRow(title: tr("音频文件"), subtitle: settings.restCustomAudio?.displayName ?? tr("选择本地音频，休息时循环播放。")) {
                                Button(tr(importsAudio ? "正在导入…" : settings.restCustomAudio == nil ? "选择文件…" : "更换文件…")) {
                                    model.rest.stopSoundPreview()
                                    selectsAudio = true
                                }
                                .controlSize(.small).disabled(importsAudio)
                            }
                        }
                    }
                    GroupRow {
                        SettingRow(title: tr("迷你 HUD 样式")) {
                            Picker(tr("迷你 HUD 样式"), selection: $settings.restHUDStyle) {
                                ForEach(RestHUDStyle.allCases) { style in
                                    Text(style.title).tag(style)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .fixedSize()
                            .frame(width: 160, alignment: .trailing)
                        }
                    }
                }
                WellnessPreferencesSettings()
            }
            .padding(DS.Space.s4)
        }
        // 真实弹层限制在屏幕内；截图使用完整内容，避免只验证被裁掉的第一屏。
        .frame(width: 480)
        .frame(height: isSnapshot ? nil : min(680, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 120)))
        .fixedSize(horizontal: false, vertical: isSnapshot)
        .background(DS.Palette.background)
        .appLanguageEnvironment()
        .onChange(of: model.settings.restSound) { model.rest.stopSoundPreview() }
        .onDisappear { model.rest.stopSoundPreview(); importTask?.cancel() }
        .fileImporter(isPresented: $selectsAudio, allowedContentTypes: [.audio]) { result in
            guard case let .success(url) = result else { return }
            importsAudio = true
            importTask?.cancel()
            importTask = Task {
                defer { importsAudio = false; importTask = nil }
                do {
                    let audio = try await audioStore.importAudio(from: url)
                    // 离开设置或在导入期间改选其他声音时，不发布过期的选择。
                    guard !Task.isCancelled, settings.restSound == .custom else {
                        try? await audioStore.remove(audio)
                        return
                    }
                    let previous = settings.restCustomAudio
                    settings.restCustomAudio = audio
                    settings.restSound = .custom
                    model.rest.syncSound()
                    // 先发布可用的新副本再清理上一份，不影响取消或失败时继续使用原音频。
                    if let previous { try? await audioStore.remove(previous) }
                } catch is CancellationError {
                    // 离开设置取消导入，原有选项和文件保持有效。
                } catch RestCustomAudioStore.Failure.tooLarge {
                    audioImportError = tr("请选择不超过 50 MB 的音频文件。")
                } catch {
                    audioImportError = tr("无法读取该音频，请选择 MP3、M4A、WAV 或 AIFF 文件。")
                }
            }
        }
        .alert(tr("无法导入音频"), isPresented: Binding(get: { audioImportError != nil }, set: { if !$0 { audioImportError = nil } })) {
            Button(tr("完成"), role: .cancel) {}
        } message: { Text(audioImportError ?? "") }
        .alert(tr("无法播放声音"), isPresented: $soundPreviewFailed) {
            Button(tr("完成"), role: .cancel) {}
        } message: {
            Text(tr("请检查音频输出设备后重试。"))
        }
    }
}
