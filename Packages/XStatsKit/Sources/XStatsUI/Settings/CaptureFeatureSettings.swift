// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureUI
import Localization
import SwiftUI

struct CaptureFeatureSettings: View {
    @ObservedObject private var integration: XStatsCapture
    @ObservedObject private var workspace: CaptureWorkspace
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var detailsExpanded = false

    init(integration: XStatsCapture = .shared) {
        self.integration = integration
        workspace = integration.embedded
    }

    private var subtitle: String {
        guard integration.prefersStandalone else { return tr("截图、图片标注与录屏。") }
        return tr(integration.standaloneApplicationURL == nil
                  ? "未找到独立版，可改用内置版。" : "正在使用独立版。")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            SettingRow(title: "XStats Capture", subtitle: subtitle, icon: "camera.viewfinder") {
                if integration.prefersStandalone {
                    Button(tr("打开独立版")) { Task { await integration.openStandalone() } }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .fixedSize()
                        .disabled(integration.standaloneApplicationURL == nil)
                } else {
                    HStack(spacing: DS.Space.s3) {
                        if workspace.enabled {
                            Menu(tr("打开 XStats Capture")) {
                                Button(tr("截图")) { workspace.open(.screenshot) }
                                Button(tr("录屏")) { workspace.open(.record) }
                                Button(tr("打开 XStats Capture")) { workspace.open() }
                            }
                        }
                        DSToggle(isOn: Binding(get: { workspace.enabled }, set: { workspace.setEnabled($0) }), label: "XStats Capture")
                    }
                }
            }

            DisclosureGroup(isExpanded: Binding(get: { detailsExpanded }, set: { expanded in
                DS.Motion.select { detailsExpanded = expanded }
            })) {
                // 折叠时卸载详情，取消缓存统计，也让快捷键录入结束并恢复全局快捷键。
                if detailsExpanded {
                    VStack(alignment: .leading, spacing: DS.Space.s2) {
                        if integration.prefersStandalone {
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
                                Spacer(minLength: 0)
                                Button(tr("改用内置版"), action: integration.useEmbedded)
                                    .buttonStyle(.link).fixedSize()
                            }
                            .dsFont(.xs)
                        } else {
                            if workspace.enabled {
                                CaptureShortcutSettingsView(shortcuts: workspace.shortcuts)
                                Text(tr("快捷键在 XStats 运行时生效。"))
                                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                            }
                            if integration.standaloneApplicationURL != nil {
                                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
                                    Text(tr("已安装独立版，可单独运行。切换后将停用内置功能。"))
                                        .foregroundStyle(DS.Palette.textSecondary)
                                    Spacer(minLength: 0)
                                    Button(tr("改用独立版")) { Task { await integration.openStandalone() } }
                                        .buttonStyle(.link).fixedSize()
                                }
                                .dsFont(.xs)
                            }
                        }
                        if !isSnapshot {
                            Divider()
                            CaptureCacheSettingsView()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, DS.Space.s2)
                }
            } label: {
                Text(tr("快捷键、缓存与独立版"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .dsSelectionAnimation(DS.Motion.usageSelection, value: detailsExpanded)
            if integration.isOpening {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(tr("打开 XStats Capture"))
            }
            if let issue = integration.issue {
                Text(issue.message).dsFont(.xs)
                    .foregroundStyle(issue == .launchFailed ? DS.Palette.error : DS.Palette.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .disabled(integration.isOpening)
        .onAppear { if !isSnapshot { integration.refreshInstallation() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !isSnapshot { integration.refreshInstallation() }
        }
    }
}
