// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import SwiftUI

/// SwiftUI 的 macOS 分段 Picker 会省略 Label 图标；仅桥接此系统控件，选择仍由 SwiftUI 管理。
struct MagpieProviderPicker: NSViewRepresentable {
    let providers: [String]
    @Binding var selection: String
    @Environment(\.layoutDirection) private var layoutDirection

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.controlSize = .small
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectProvider(_:))
        control.setAccessibilityLabel(tr("订阅额度"))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.userInterfaceLayoutDirection = layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        if context.coordinator.providers != providers {
            context.coordinator.providers = providers
            control.segmentCount = providers.count
            for (index, provider) in providers.enumerated() {
                control.setLabel(AIServiceBrand.title(provider), forSegment: index)
                let source = AIServiceBrand.logoName(provider).flatMap { LogoCache.shared.image(named: $0, template: true) }
                    ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
                // 缓存图标也供页面和菜单栏使用，不修改其共享尺寸。
                let image = source?.copy() as? NSImage
                image?.size = NSSize(width: 14, height: 14)
                control.setImage(image, forSegment: index)
                control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            }
            control.invalidateIntrinsicContentSize()
        }
        let index = providers.firstIndex(of: selection) ?? -1
        if control.selectedSegment != index { control.selectedSegment = index }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<String>
        var providers: [String] = []

        init(selection: Binding<String>) { self.selection = selection }

        @objc func selectProvider(_ sender: NSSegmentedControl) {
            guard providers.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = providers[sender.selectedSegment]
        }
    }
}
