// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import Localization
import Metrics
import SwiftUI

/// 点击菜单栏单个指标弹出的窄详情。区块可在设置中逐个隐藏
struct PopoverRootView: View {
    let item: MenuBarItem

    var body: some View {
        PopoverFrame {
            PopoverHeader(item: item)
        } content: {
            PopoverDetail(item: item)
        }
    }
}

/// 菜单栏弹窗的外框：顶部标题栏固定，下面的内容可滚动
struct PopoverFrame<Header: View, Content: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DS.Space.s3)
                .padding(.vertical, DS.Space.s2)

            PageScroll { content }
                .frame(maxWidth: .infinity, maxHeight: isSnapshot ? nil : .infinity, alignment: .top)
                .environment(\.isPopover, true)
        }
        .frame(width: DS.Size.popoverWidth)
        .frame(maxHeight: isSnapshot ? nil : .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: isSnapshot)
        .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.xl))
        .appLanguageEnvironment()
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.xl).strokeBorder(DS.Palette.border, lineWidth: DS.Size.stroke)
        }
    }
}

/// 某一项的详情内容，每项独立时的弹窗与合并时的弹窗共用
struct PopoverDetail: View {
    let item: MenuBarItem

    var body: some View {
        switch item {
        case .cpu: CPUPopover()
        case .memory: MemoryPopover()
        case .network: NetworkPopover()
        case .gpu: GPUPopover()
        case .disk: DiskPopover()
        case .temperature, .fan: ThermalPopover(item: item)
        case .battery: BatteryPopover()
        case .aiUsage: AIUsagePopover()
        }
    }
}

struct PopoverHeader: View {
    let item: MenuBarItem
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: item.symbol)
                .font(.system(size: DS.TextSize.sm.rawValue, weight: .semibold))
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: DS.Size.iconStandalone)
            Text(item.popoverTitle)
                .dsFont(.base, weight: .semibold)
                .foregroundStyle(DS.Palette.textPrimary)
            Spacer(minLength: DS.Space.s2)
            if item == .memory { PurgeMemoryButton() }
            // 左边的按钮用该指标自己的图标，点进主窗口里它的页面；右边的齿轮进总设置
            let page = PanelTab(item: item)
            MiniIconButton(systemName: page.symbol, help: tr("在主窗口打开“\(page.title)”")) { model.openMainWindow(page) }
            MiniIconButton(systemName: "gearshape", help: tr("设置")) { model.openSettings() }
        }
    }
}

// MARK: - 共用组件

/// 弹窗里的一个区块：小标题 + 内容。
/// 解释性文字不常驻界面：给 `hint` 后标题旁出现一个很淡的 ⓘ，鼠标悬停在 ⓘ 或卡片内容上才显示说明，看一遍就够的人不用一直看着它
struct SectionCard<Trailing: View, Content: View>: View {
    let title: String
    var hint: String?
    /// 紧跟标题之后的小附件，例如数据来源的 logo
    var titleAccessory: AnyView?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Text(title)
                    .dsFont(.xs, weight: .semibold)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                if let titleAccessory {
                    titleAccessory
                }
                if let hint {
                    Image(systemName: "info.circle")
                        .font(.system(size: DS.TextSize.xs.rawValue, weight: .medium))
                        .foregroundStyle(DS.Palette.textTertiary)
                        .help(hint)
                        .accessibilityLabel(hint)
                }
                Spacer(minLength: DS.Space.s2)
                trailing
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            content
                .help(optional: hint)
        }
    }
}

extension SectionCard where Trailing == EmptyView {
    init(title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, hint: hint, trailing: { EmptyView() }, content: content)
    }
}

extension View {
    /// 有说明时才挂悬停提示
    @ViewBuilder
    func help(optional text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}

/// 弹窗里默认收起的区块：只占一行，左边标题、右边摘要，点一下展开
struct CollapsedSection: View {
    let title: String
    let summary: String
    var summaryColor: Color = DS.Palette.textPrimary
    let expand: () -> Void

    var body: some View {
        Card {
            Button(action: expand) {
                HStack(spacing: DS.Space.s2) {
                    Text(title)
                        .dsFont(.xs, weight: .semibold)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: DS.Space.s2)
                    Text(verbatim: summary)
                        .dsFont(.xs, weight: .medium)
                        .foregroundStyle(summaryColor)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                        .foregroundStyle(DS.Palette.textTertiary)
                }
                .frame(height: DS.Size.segmentHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tr("展开\(title)"))
        }
    }
}

extension View {
    /// 弹窗里可收起区块的收起按钮，放在标题栏最右边
    func collapseButton(_ section: PopoverSection, settings: AppSettings) -> some View {
        HStack(spacing: DS.Space.s1) {
            self
            MiniIconButton(systemName: "chevron.up", help: tr("收起")) {
                withAnimation(DS.Motion.quick) { settings.setExpanded(section, false) }
            }
        }
    }
}

/// 左侧标签、右侧数值的一行
struct InfoRow<Value: View>: View {
    let label: String
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s3) {
            Text(label)
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize()
            Spacer(minLength: 0)
            value
                .dsFont(.xs, weight: .medium)
                .foregroundStyle(DS.Palette.textPrimary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}

extension InfoRow where Value == Text {
    init(label: String, text: String) {
        self.label = label
        self.value = Text(verbatim: text)
    }
}

/// 点击拷贝的数值（IP、MAC 地址）
struct CopyableText: View {
    let text: String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                copied = false
            }
        } label: {
            Text(verbatim: copied ? tr("已拷贝") : text)
                .foregroundStyle(copied ? DS.Palette.success : hovering ? DS.Palette.primary : DS.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tr("点击拷贝"))
        .disabled(text == "—")
    }
}

/// 区块标题栏里的小图标按钮
struct MiniIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                .foregroundStyle(hovering ? DS.Palette.textPrimary : DS.Palette.textSecondary)
                .frame(width: DS.Size.segmentHeight, height: DS.Size.segmentHeight)
                .modifier(MiniIconSurface(hovering: hovering))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// macOS 26 上是一颗小玻璃圆钮，更早的系统、或已经在一组玻璃按钮里时只有悬停底色
private struct MiniIconSurface: ViewModifier {
    let hovering: Bool
    @Environment(\.isInsideGlass) private var isInsideGlass

    func body(content: Content) -> some View {
        if DS.Glass.isAvailable, !isInsideGlass {
            content.dsGlass(in: Circle(), interactive: true)
        } else {
            content.background(hovering ? DS.Palette.surfaceHover : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
    }
}

/// 区块标题栏右侧的一组小图标按钮：macOS 26 上合成一颗玻璃胶囊（与访达工具栏的按钮分组一致），
/// 里面的按钮不再各自带玻璃；更早的系统是一条浅灰胶囊
struct HeaderActionGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.horizontal, DS.Space.s1 / 2)
        .environment(\.isInsideGlass, true)
        .dsGlass(in: Capsule(), fallback: DS.Palette.track)
    }
}

/// 区块标题栏里的刷新按钮：查询进行中换成系统的转圈，查完自动变回图标
struct RefreshButton: View {
    var loading: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        ZStack {
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(tr("正在查询…"))
            } else {
                MiniIconButton(systemName: "arrow.clockwise", help: help, action: action)
            }
        }
        .frame(width: DS.Size.segmentHeight, height: DS.Size.segmentHeight)
        .animation(DS.Motion.quick, value: loading)
    }
}

/// 弹窗顶部的大号数值
struct HeroValue: View {
    let value: String
    var unit: String?
    var size: DS.TextSize = .xl

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1 / 2) {
            Text(verbatim: value)
                .dsFont(size, weight: .semibold)
                .monospacedDigit()
                .foregroundStyle(DS.Palette.textPrimary)
            if let unit {
                Text(verbatim: unit).dsFont(.xs, weight: .medium).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .lineLimit(1)
    }
}

/// 固定行数的进程列表，数据不足时用占位行，弹窗高度保持不变
struct ProcessList<Row: View>: View {
    let count: Int
    var rowCount = 5
    var emptyText = tr("正在统计…")
    @ViewBuilder var row: (Int) -> Row

    var body: some View {
        if count == 0 {
            Text(emptyText)
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Self.rowHeight)
            ForEach(1..<rowCount, id: \.self) { _ in
                Color.clear.frame(height: Self.rowHeight)
            }
        } else {
            ForEach(0..<min(count, rowCount), id: \.self) { index in
                row(index).frame(height: Self.rowHeight)
            }
            ForEach(0..<max(0, rowCount - count), id: \.self) { _ in
                Color.clear.frame(height: Self.rowHeight)
            }
        }
    }

    static var rowHeight: CGFloat { DS.Size.iconInline + DS.Space.s1 }
}

struct ProcessNameLabel: View {
    let icon: Image
    let name: String

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            icon.resizable().frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
            Text(verbatim: name)
                .dsFont(.xs, weight: .medium)
                .foregroundStyle(DS.Palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.s2)
        }
    }
}
