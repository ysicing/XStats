// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SwiftUI

/// 清理审阅使用原生三态复选框；部分选择不冒充全选，VoiceOver 可读出名称与混合状态。
struct CleanupCheckbox: NSViewRepresentable {
    let title: String
    let selected: Int
    var total: Int = 1
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(checkboxWithTitle: "", target: context.coordinator, action: #selector(Coordinator.toggle))
        button.allowsMixedState = true
        button.imagePosition = .imageOnly
        button.setAccessibilityRole(.checkBox)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action
        button.state = selected == 0 ? .off : (selected == total ? .on : .mixed)
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(title)
        button.toolTip = title
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func toggle() { action() }
    }
}
