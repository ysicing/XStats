// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import CaptureCore
import Localization

struct CaptureSettingsView: View {
    @ObservedObject var controller: CaptureController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(tr("设置")).font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(tr("关闭设置")).accessibilityLabel(tr("关闭设置"))
            }
            VStack(alignment: .leading, spacing: 10) {
                Toggle(tr("常驻菜单栏"), isOn: $controller.resident)
                    .onChange(of: controller.resident) { controller.applyResidentMode() }
                Text(tr("关闭后按需退出；常驻时可使用全局快捷键。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CaptureShortcutSettingsView(shortcuts: controller.shortcuts)
            if !controller.resident {
                Text(tr("快捷键在常驻菜单栏时生效。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Picker(tr("语言"), selection: Binding(get: { controller.language }, set: {
                controller.language = $0
                controller.applyLanguage()
            })) {
                ForEach(AppLanguage.allCases, id: \.rawValue) {
                    Text($0 == .system ? tr("自动检测") : $0.nativeName).tag($0)
                }
            }
            // AppKit caches the selected item's label; rebuild the picker when its language changes.
            .id(controller.language)
            Divider()
            CaptureCacheSettingsView()
        }
        .padding(20).frame(width: 340)
        .environment(\.layoutDirection, L10n.language.isRightToLeft ? .rightToLeft : .leftToRight)
        .environment(\.locale, L10n.locale)
    }
}
