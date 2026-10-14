// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import AVKit
import CaptureCore
import Localization

struct CaptureHomeView: View {
    @ObservedObject var controller: CaptureController
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("XStats Capture").font(.title.bold())
            Text(tr("截图标注与屏幕录制，内容仅保存在本机。")).foregroundStyle(.secondary)
            Picker(tr("捕获范围"), selection: $controller.mode) {
                ForEach(CaptureMode.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Toggle(tr("系统声音"), isOn: $controller.systemAudio)
                Toggle(tr("麦克风"), isOn: $controller.microphone)
            }
            if controller.mode == .window, controller.systemAudio {
                Text(tr("窗口模式只录制所选 App 的声音。")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(tr("截图"), systemImage: "camera") { controller.begin(.screenshot) }
                Button(tr("录屏"), systemImage: "record.circle") { controller.begin(.record) }
            }.controlSize(.large).disabled(controller.busy)
            if let error = controller.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                if controller.permissionError != nil { Button(tr("打开隐私设置")) { controller.openPrivacySettings() } }
            }
            if controller.hasRecordingMedia {
                HStack {
                    Button(tr("录屏预览")) { controller.recoverRecordingPreview() }
                    Button(tr("在访达中显示原始片段")) { controller.revealMedia() }
                    Button(tr("丢弃")) { controller.discardRecording() }
                }
            }
            Divider()
            Toggle(tr("常驻菜单栏"), isOn: $controller.resident)
                .onChange(of: controller.resident) { controller.applyResidentMode() }
            Text(tr("关闭后按需退出；常驻时可使用全局快捷键。")).font(.caption).foregroundStyle(.secondary)
            if controller.resident {
                HStack {
                    Text(tr("截图快捷键")); Spacer()
                    CaptureShortcutRecorder(value: controller.screenshotKey) { controller.setShortcut($0, for: .screenshot) }
                }
                HStack {
                    Text(tr("录屏快捷键")); Spacer()
                    CaptureShortcutRecorder(value: controller.recordingKey) { controller.setShortcut($0, for: .record) }
                }
                if controller.shortcutConflict { Text(tr("快捷键已被占用，请更换。")).font(.caption).foregroundStyle(.red) }
            }
            Picker(tr("语言"), selection: $controller.language) {
                ForEach(AppLanguage.allCases, id: \.rawValue) { Text($0 == .system ? tr("自动检测") : $0.nativeName).tag($0) }
            }.onChange(of: controller.language) { controller.applyLanguage() }
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 490, minHeight: 460)
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
