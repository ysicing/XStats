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

    init(integration: XStatsCapture = .shared) {
        self.integration = integration
        workspace = integration.embedded
    }

    private var subtitle: String {
        guard integration.prefersStandalone else { return tr("内置截图与录屏工具，按需使用。") }
        return tr(integration.standaloneApplicationURL == nil
                  ? "未找到独立版，可改用内置版。" : "正在使用独立版，内置功能已停用。")
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
                        DSToggle(isOn: Binding(get: { workspace.enabled }, set: workspace.setEnabled), label: "XStats Capture")
                    }
                }
            }

            if integration.prefersStandalone {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
                    Spacer(minLength: 0)
                    Button(tr("改用内置版"), action: integration.useEmbedded)
                        .buttonStyle(.link).fixedSize()
                }
                .dsFont(.xs)
            } else {
                if workspace.enabled {
                    Divider()
                    CaptureShortcutSettingsView(shortcuts: workspace.shortcuts)
                    Text(tr("快捷键在 XStats 运行时生效。"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                }
                if integration.standaloneApplicationURL != nil {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
                        Text(tr("已找到独立版，可脱离 XStats 使用。"))
                            .foregroundStyle(DS.Palette.textSecondary)
                        Spacer(minLength: 0)
                        Button(tr("使用独立版")) { Task { await integration.openStandalone() } }
                            .buttonStyle(.link).fixedSize()
                    }
                    .dsFont(.xs)
                }
            }
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
