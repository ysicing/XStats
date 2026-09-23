// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import Localization
import Metrics
import SwiftUI

/// 主窗口。左侧切换页面，右侧是仪表盘、各指标详情与工具页；窗口宽高都可调整。
/// macOS 26 起侧边栏是一块浮在窗口里的液态玻璃面板，顶栏控件是玻璃胶囊；
/// 更早的系统上侧边栏、标题栏与页面在同一张底色上，不分栏着色，也不画分隔线
public struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot

    public init() {}

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MainSidebar()
                .frame(width: DS.Size.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(alignment: .top) {
                    WindowDragArea().frame(height: DS.Size.windowHeader)
                }
                .modifier(SidebarPanel())

            content
                .frame(minWidth: DS.Size.panelWidth, maxWidth: .infinity)
                .frame(maxHeight: isSnapshot ? nil : .infinity, alignment: .top)
        }
        .frame(width: isSnapshot ? DS.Size.sidebarWidth + DS.Size.panelWidth : nil)
        .fixedSize(horizontal: false, vertical: isSnapshot)
        .background(DS.Palette.background)
        // 需要等待的任务进行中，整个窗口压暗并显示加载框
        .loadingHUD(isSnapshot ? nil : busyMessage)
        // 内容延伸到透明标题栏下方，由顶栏高度留出红绿灯按钮的位置
        .ignoresSafeArea()
        // 文案在各视图计算时翻译好，切换语言后整棵视图重建
        .appLanguageEnvironment()
    }

    /// 顶栏在上、页面在下。没有用 macOS 26 的 safeAreaBar 让页面从顶栏下面滚过：
    /// 它在 macOS 上会在交界处画一条分隔线，滚动边缘样式设成柔和或隐藏都去不掉
    private var content: some View {
        VStack(spacing: 0) {
            // 页面的滚动视图会自动向上延伸到标题栏下面，与顶栏重叠；顶栏必须在它之上，否则开关收不到点击
            PageHeader()
                .zIndex(1)
            page
        }
    }

    /// 需要等待、期间不宜继续操作的任务
    private var busyMessage: String? {
        if model.cleaner.phase == .cleaning { return tr("正在清理…") }
        if model.uninstaller.isRemoving { return tr("正在移除…") }
        if model.diagnostics.phase == .collecting { return tr("正在导出诊断信息…") }
        if model.maintenance.isApplyingDNS { return tr("正在修改 DNS…") }
        return nil
    }

    private var page: some View {
        Group {
            switch model.settings.panelTab {
            case .overview: OverviewPage()
            case .system: SystemInfoPage()
            case .history: HistoryPage()
            case .aiUsage: AIUsagePage()
            case .cpu: DetailPage { CPUPopover() }
            case .gpu: DetailPage { GPUPopover() }
            case .memory: DetailPage { MemoryPopover() }
            case .disk: DiskPage()
            case .network:
                DetailPage {
                    NetworkPopover()
                    NetworkSettings()
                }
            case .thermal: ThermalPage()
            case .battery: DetailPage { BatteryPopover() }
            case .processes: ProcessesPage()
            case .keepAwake: KeepAwakePage()
            case .cleaner: CleanerPage()
            case .uninstaller: UninstallerPage()
            case .startupItems: StartupItemsPage()
            case .settingsGeneral: SettingsTabPage { GeneralSettings() }
            case .settingsMenuBar: SettingsTabPage { MenuBarSettings() }
            case .settingsNotifications: SettingsTabPage { NotificationSettings() }
            // 设置同步暂时隐藏；旧路由进入通用设置，恢复时重新挂载 WebDAVSettings。
            case .settingsAccount: SettingsTabPage { GeneralSettings() }
            case .settingsAI: SettingsTabPage { AIAssistantSettingsView() }
            case .settingsHelper: SettingsTabPage { HelperSettings() }
            case .settingsAbout: SettingsTabPage { AboutSettings() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isSnapshot ? nil : .infinity, alignment: .top)
        // 截图时页面取自身高度：侧边栏更高时，多出的高度不能分给页面里可伸展的卡片
        .fixedSize(horizontal: false, vertical: isSnapshot)
    }
}

/// macOS 26：侧边栏浮在窗口里，四周留一圈边距，整块是液态玻璃，红绿灯按钮落在面板里
private struct SidebarPanel: ViewModifier {
    @Environment(\.isSnapshot) private var isSnapshot

    func body(content: Content) -> some View {
        if DS.Glass.isAvailable, !isSnapshot {
            // 红绿灯在面板外：面板从标题栏下方开始，标题栏那一条是窗口底色，按住可以拖动窗口
            content
                .environment(\.isInsideGlass, true)
                .dsGlass(in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
                .padding(.horizontal, DS.Space.s2)
                .padding(.bottom, DS.Space.s2)
                .padding(.top, DS.Size.windowHeader)
                .background(alignment: .top) { WindowDragArea().frame(height: DS.Size.windowHeader) }
        } else {
            content
        }
    }
}

/// 指标详情页：复用菜单栏弹窗的内容，显示全部区块
private struct DetailPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        PageScroll { content }
            .environment(\.isDetailPage, true)
    }
}

private struct MainSidebar: View {
    @Environment(AppModel.self) private var model

    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            // 三组导航加起来较高，窗口矮时侧边栏自己滚动，底部按钮始终可见
            if isSnapshot {
                navigation
            } else {
                ScrollView { navigation.overlayScrollers() }
                    .scrollBounceBehavior(.basedOnSize)
            }

            HStack(spacing: DS.Space.s1) {
                ThemeToggle()
                Spacer(minLength: 0)
                IconButton(systemName: "power", help: tr("退出 XStats")) { model.quit() }
            }
            .padding(.leading, DS.Space.s2)
        }
        .padding(.leading, DS.Space.s1)
        .padding(.trailing, DS.Space.s3)
        .padding(.top, sidebarTopPadding)
        .padding(.bottom, DS.Space.s3)
    }

    private var usesGlassPanel: Bool { DS.Glass.isAvailable && !isSnapshot }

    /// 侧边栏内容离自身顶边的距离：玻璃面板在标题栏下方，只留一点边距；没有面板时给红绿灯留出标题栏的高度
    private var sidebarTopPadding: CGFloat {
        usesGlassPanel ? DS.Space.s3 : DS.Size.windowHeader + DS.Space.s2
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            group(tr("监控"), PanelTab.monitors)
            group(tr("工具"), PanelTab.tools)
            group(tr("设置"), PanelTab.settings)
        }
        .sidebarGlider()
        // 光条的发光向左溢出几个点，留出空间避免被滚动区域裁掉
        .padding(.leading, DS.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badge(for tab: PanelTab) -> Tone? {
        switch tab {
        case .settingsAbout: model.updates.release != nil ? .primary : nil
        case .settingsHelper: model.helper.isOutdated ? .warning : nil
        case .settingsAccount:
            if model.sync.pendingDownload != nil { .primary } else if case .failed = model.sync.phase { .warning } else { nil }
        default: nil
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ tabs: [PanelTab]) -> some View {
        Text(title)
            .dsFont(.xs, weight: .medium)
            .foregroundStyle(DS.Palette.textTertiary)
            .padding(.horizontal, DS.Space.s2)
            .padding(.top, DS.Space.s2)
        ForEach(tabs) { tab in
            SidebarButton(title: tab.title, symbol: tab.symbol, isSelected: model.settings.panelTab == tab, badge: badge(for: tab)) {
                model.settings.panelTab = tab
            }
        }
    }
}

private struct PageHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let settings = model.settings
        let tab = settings.panelTab

        HStack(spacing: DS.Space.s3) {
            // 拖动窗口的区域只覆盖标题和空白，按钮与开关不在拖动层上
            HStack(spacing: 0) {
                Text(tab.headerTitle)
                    .dsFont(.base, weight: .semibold)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer(minLength: DS.Space.s3)
            }
            .frame(maxHeight: .infinity)
            .background(WindowDragArea())

            if model.keepAwake.isActive {
                // 与右边的按钮同高，顶栏里的控件高度一致
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: "cup.and.saucer.fill")
                    Text(tr("防休眠已开启")).lineLimit(1).fixedSize()
                }
                .dsFont(.xs, weight: .medium)
                .foregroundStyle(DS.Palette.primary)
                .padding(.horizontal, DS.Space.s3)
                .frame(height: DS.Size.controlHeight)
                .dsGlass(in: Capsule(), fallback: DS.Palette.primary.opacity(0.12))
            }
            if tab == .memory { PurgeMemoryButton() }
            if tab == .network {
                Button { model.openSpeedTestWindow() } label: {
                    HStack(spacing: DS.Space.s1) {
                        Image(systemName: "gauge.with.dots.needle.67percent")
                        Text(tr("网络测速")).lineLimit(1).fixedSize()
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .help(tr("测本机宽带、国内分省三网延迟与全球节点"))
            }
            if tab == .network {
                Button { model.openEgressWindow() } label: {
                    HStack(spacing: DS.Space.s1) {
                        Image(systemName: "arrow.triangle.branch")
                        Text(tr("出口与分流")).lineLimit(1).fixedSize()
                    }
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .help(tr("检查 VPN 与代理是否生效、各网站从哪个出口出去"))
            }
            // 每个监控页都能在这里开关自己的菜单栏项目；温度与风扇页有两项，各带一个小标签
            let items = tab.menuBarItems
            if !items.isEmpty {
                // macOS 26 上这一组是一颗玻璃胶囊，与访达工具栏的分组一致
                HStack(spacing: DS.Space.s3) {
                    Text(tr("在菜单栏显示")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    ForEach(items) { item in
                        if items.count > 1 {
                            Text(item.popoverTitle).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                        }
                        DSToggle(isOn: Binding(get: { settings.isEnabled(item) }, set: { settings.setEnabled(item, $0) }),
                                 label: tr("在菜单栏显示\(item.title)"))
                            .help(tr("开启后图标出现在菜单栏；按住 ⌘ 键拖动图标可以调整位置"))
                    }
                }
                .modifier(HeaderControlGroup())
            }
        }
        .padding(.horizontal, DS.Space.s3 + DS.Space.s1)
        // 52pt 高的顶栏里，32pt 的按钮与开关组上下各留 10pt
        .frame(height: DS.Size.windowHeader)
    }
}

/// 顶栏右侧的一组控件：macOS 26 上收进一颗玻璃胶囊，更早的系统直接排开
private struct HeaderControlGroup: ViewModifier {
    func body(content: Content) -> some View {
        if DS.Glass.isAvailable {
            content
                .padding(.leading, DS.Space.s4)
                .padding(.trailing, DS.Space.s2)
                .frame(height: DS.Size.controlHeight)
                .dsGlass(in: Capsule())
        } else {
            content
        }
    }
}

/// 在浅色与深色之间切换；当前跟随系统时，切到与系统相反的那一种
private struct ThemeToggle: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        IconButton(systemName: isDark ? "sun.max" : "moon", help: isDark ? tr("切换到浅色") : tr("切换到深色")) {
            model.settings.appearance = isDark ? .light : .dark
        }
    }
}

struct AppGlyph: View {
    var size: CGFloat = DS.Size.controlHeight

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
