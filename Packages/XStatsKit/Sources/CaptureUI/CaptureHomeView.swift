// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import AVKit
import CaptureCore
import Localization

struct CaptureHomeView: View {
    @ObservedObject var controller: CaptureController
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("XStats Capture").font(.title2.weight(.semibold))
                    Text(tr("截图标注与屏幕录制"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if controller.host == .standalone {
                    Button { showingSettings.toggle() } label: {
                        Image(systemName: "gearshape").font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .help(tr("设置"))
                    .accessibilityLabel(tr("设置"))
                    .popover(isPresented: $showingSettings, arrowEdge: .top) {
                        CaptureSettingsView(controller: controller)
                    }
                }
            }

            Picker(tr("截图与录屏"), selection: $controller.captureAction) {
                Label(tr("截图"), systemImage: "camera").tag(CaptureRequest.Action.screenshot)
                Label(tr("录屏"), systemImage: "record.circle").tag(CaptureRequest.Action.record)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.large)
            .disabled(controller.busy)

            VStack(alignment: .leading, spacing: 12) {
                Text(tr("捕获范围")).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(CaptureMode.allCases) { mode in
                        CaptureTargetButton(mode: mode, selected: controller.mode == mode) {
                            controller.mode = mode
                        }
                    }
                }.disabled(controller.busy)
            }

            VStack(alignment: .leading, spacing: 14) {
                if controller.captureAction == .record {
                    HStack(spacing: 24) {
                        Toggle(isOn: $controller.systemAudio) {
                            Label(tr("系统声音"), systemImage: "speaker.wave.2")
                        }
                        Toggle(isOn: $controller.microphone) {
                            Label(tr("麦克风"), systemImage: "mic")
                        }
                    }
                    .toggleStyle(.checkbox).disabled(controller.busy)
                    if controller.mode == .window, controller.systemAudio {
                        Text(tr("窗口模式只录制所选 App 的声音。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(tr(controller.captureAction == .record
                        ? "选择范围后，倒计时 3 秒开始录制。" : "截图后可标注、复制或保存。"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { controller.begin(controller.captureAction) } label: {
                    Label(primaryTitle, systemImage: controller.captureAction == .record ? "record.circle" : "camera")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(controller.busy)
            }

            if let error = controller.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if controller.permissionError != nil {
                        Button(tr("打开隐私设置")) { controller.openPrivacySettings() }
                    }
                }
            }
            if controller.hasRecordingMedia {
                ViewThatFits(in: .horizontal) {
                    HStack { recoveryActions }
                    VStack(alignment: .leading, spacing: 8) { recoveryActions }
                }
            }
            Label(tr("内容仅保存在本机"), systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(28).frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.layoutDirection, L10n.language.isRightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.locale, L10n.locale)
        .onAppear { controller.fitHomeWindow() }
        .onChange(of: controller.captureAction) { _, action in
            if action == .record, !controller.busy {
                controller.systemAudio = true
                controller.microphone = false
            }
            controller.fitHomeWindow()
        }
        .onChange(of: controller.mode) { controller.fitHomeWindow() }
        .onChange(of: controller.systemAudio) { controller.fitHomeWindow() }
        .onChange(of: controller.error) { controller.fitHomeWindow() }
        .onChange(of: controller.hasRecordingMedia) { controller.fitHomeWindow() }
        .onChange(of: controller.language) { controller.fitHomeWindow() }
    }

    private var primaryTitle: String {
        switch (controller.captureAction, controller.mode) {
        case (.record, .region): tr("录制区域")
        case (.record, .window): tr("录制窗口")
        case (.record, .display): tr("录制屏幕")
        case (_, .region): tr("截取区域")
        case (_, .window): tr("截取窗口")
        case (_, .display): tr("截取屏幕")
        }
    }

    @ViewBuilder private var recoveryActions: some View {
        Button(tr("录屏预览")) { controller.recoverRecordingPreview() }
        Button(tr("在访达中显示原始片段")) { controller.revealMedia() }
        Button(tr("丢弃")) { controller.discardRecording() }
    }
}

private struct CaptureTargetButton: View {
    let mode: CaptureMode
    let selected: Bool
    let action: () -> Void
    private var symbol: String {
        switch mode {
        case .region: "rectangle.dashed"
        case .window: "macwindow"
        case .display: "display"
        }
    }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 24))
                    .accessibilityHidden(true)
                Text(mode.title).font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 70)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RecordingControlView: View {
    @ObservedObject var controller: CaptureController
    var body: some View {
        let title: String
        if controller.countdown > 0 {
            title = controller.countdown.formatted(.number.locale(L10n.locale))
        } else if controller.needsStopRetry {
            title = tr("录制未能停止，请重试。")
        } else {
            title = tr(controller.paused ? "录制已暂停" : "正在录制")
        }
        return VStack(spacing: 14) {
            Text(title)
                .font(.title2.monospacedDigit())
                .fixedSize(horizontal: false, vertical: true)
            if let error = controller.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if controller.countdown > 0 {
                    Button(tr("取消")) { controller.cancelCountdown() }
                } else {
                    if controller.canPauseRecording {
                        Button(tr(controller.paused ? "继续" : "暂停")) { controller.togglePause() }
                    }
                    Button(tr("停止"), systemImage: "stop.fill") { controller.stopRecording() }
                }
            }.disabled(controller.transitioning)
        }.padding(24).frame(maxWidth: .infinity)
    }
}

struct RecordingPreviewView: View {
    @ObservedObject var controller: CaptureController
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let player = controller.player { CaptureVideoPlayer(player: player).frame(minHeight: 320) }
            HStack {
                Text(tr("开始时间"))
                Slider(value: $controller.trimStart, in: 0...max(0.01, controller.duration - 0.01)).disabled(controller.exporting).onChange(of: controller.trimStart) { controller.seekTrim() }
                Text(controller.trimStart.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))).monospacedDigit()
            }
            HStack {
                Text(tr("结束时间"))
                Slider(value: $controller.trimEnd, in: 0.01...max(0.01, controller.duration)).disabled(controller.exporting).onChange(of: controller.trimEnd) { controller.seekTrim() }
                Text(controller.trimEnd.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))).monospacedDigit()
            }
            if let error = controller.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button(tr("在访达中显示原始片段")) { controller.revealMedia() }
                Spacer()
                if controller.exporting {
                    ProgressView().controlSize(.small)
                    Button(tr("取消导出")) { controller.cancelExport() }
                } else {
                    Button(tr("导出 MP4")) { controller.exportRecording() }.disabled(controller.trimStart >= controller.trimEnd)
                }
            }
        }.padding(20).frame(minWidth: 650, minHeight: 470)
    }
}

/// Use AVKit's native view directly; the SwiftUI VideoPlayer overlay can fail
/// while initializing runtime metadata on newer macOS releases.
private struct CaptureVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player = nil
    }
}
