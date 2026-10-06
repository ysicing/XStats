// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AIUsage
import Foundation
import Localization
import Metrics
import Observation

public enum MenuBarItem: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory, network, gpu, disk, temperature, fan, battery, aiUsage, display, audio

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: tr("内存")
        case .network: tr("网络")
        case .gpu: "GPU"
        case .disk: tr("磁盘")
        case .temperature: tr("CPU 温度")
        case .fan: tr("风扇转速")
        case .battery: tr("电池")
        case .aiUsage: tr("AI 用量")
        case .display: tr("显示器")
        case .audio: tr("音频")
        }
    }

    var subtitle: String {
        switch self {
        case .cpu: tr("总占用")
        case .memory: tr("已用内存占比")
        case .network: tr("上传与下载速度、IP 地址、DNS")
        case .gpu: tr("GPU 占用")
        case .disk: tr("启动磁盘已用占比")
        case .temperature: tr("CPU 核心最高温度")
        case .fan: tr("转速最高的风扇")
        case .battery: tr("电量与充电状态；没有电池的 Mac 显示蓝牙设备电量")
        case .aiUsage: tr("Codex / Claude Code 本机 Token 用量与订阅额度")
        case .display: tr("显示器信息与支持的亮度、音量、对比度控制")
        case .audio: tr("系统音量、音频设备与应用音量")
        }
    }

    /// 菜单栏上方的小标签
    var menuBarLabel: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .network: "NET"
        case .gpu: "GPU"
        case .disk: "DISK"
        case .temperature: "TEMP"
        case .fan: "FAN"
        case .battery: "BAT"
        case .aiUsage: "AI"
        case .display: "DSP"
        case .audio: "SND"
        }
    }

    /// 详情弹窗标题
    var popoverTitle: String {
        switch self {
        case .cpu: "CPU"
        case .memory: tr("内存")
        case .network: tr("网络")
        case .gpu: "GPU"
        case .disk: tr("磁盘")
        case .temperature: tr("温度")
        case .fan: tr("风扇")
        case .battery: tr("电池")
        case .aiUsage: tr("AI 用量")
        case .display: tr("显示器")
        case .audio: tr("音频")
        }
    }

    /// 点击该项弹出的详情里可以显示的内容，按显示顺序排列
    var popoverSections: [PopoverSection] {
        switch self {
        case .cpu: [.cpuCores, .cpuHeatmap, .cpuClusters, .cpuLoadAverage, .cpuApps]
        case .memory: [.memoryWaterline, .memoryCompression, .memoryApps]
        case .network: [.networkHistory, .networkProbe, .networkInterface, .networkAddresses, .networkPurity, .networkDNS, .networkProcesses]
        case .gpu: [.gpuHistory, .gpuDetails]
        case .disk: [.diskActivity, .diskHealth, .diskProcesses]
        case .temperature: [.thermalSensors, .thermalFans, .thermalPower]
        case .fan: [.thermalFans, .thermalSensors, .thermalPower]
        case .battery: [.batteryHistory, .batteryPower, .batteryHealth, .batteryBluetooth]
        case .aiUsage, .display, .audio: []
        }
    }

    /// 可以单独指定风格的指标（网速有自己的样式）
    var supportsStyleOverride: Bool { self != .network }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .network: "arrow.up.arrow.down"
        case .gpu: "square.3.layers.3d"
        case .disk: "internaldrive"
        case .temperature: "thermometer.medium"
        case .fan: "fan"
        case .battery: "battery.75"
        case .aiUsage: "sparkles"
        case .display: "display"
        case .audio: "speaker.wave.2"
        }
    }
}

/// 详情弹窗里可以单独隐藏的区块
public enum PopoverSection: String, CaseIterable, Identifiable, Sendable {
    case cpuHeatmap, cpuCores, cpuClusters, cpuLoadAverage, cpuApps
    case memoryWaterline, memoryCompression, memoryApps
    case networkHistory, networkProbe, networkInterface, networkAddresses, networkPurity, networkDNS, networkProcesses
    case gpuHistory, gpuDetails
    case diskActivity, diskHealth, diskProcesses
    case thermalSensors, thermalFans, thermalPower
    case batteryHistory, batteryPower, batteryHealth, batteryBluetooth

    public var id: String { rawValue }

    /// 弹窗默认不显示的区块（主窗口详情页始终显示）：热力图已经能看出各核心此刻的占用，
    /// 每核柱状图给想要一眼看清单个核心的人在设置里打开，避免弹窗默认太长
    static let hiddenByDefault: Set<PopoverSection> = [.cpuCores]

    var title: String {
        switch self {
        case .cpuHeatmap: tr("核心热力图")
        case .cpuCores: tr("各核心占用")
        case .cpuClusters: tr("核心分工")
        case .cpuLoadAverage: tr("排队程度")
        case .cpuApps, .memoryApps: tr("按应用汇总")
        case .networkProcesses: tr("高占用进程")
        case .memoryWaterline: tr("内存水位")
        case .memoryCompression: tr("压缩与交换")
        case .networkHistory: tr("流量历史")
        case .networkProbe: tr("连接探测")
        case .networkInterface: tr("接口")
        case .networkAddresses: tr("IP 地址")
        case .networkPurity: tr("IP 纯净度")
        case .networkDNS: "DNS"
        case .gpuHistory: tr("使用历史")
        case .gpuDetails: tr("显卡信息")
        case .diskActivity: tr("读写速度")
        case .diskHealth: tr("SSD 健康")
        case .diskProcesses: tr("读写最多的应用")
        case .thermalSensors: tr("温度")
        case .thermalFans: tr("风扇")
        case .thermalPower, .batteryPower: tr("功耗")
        case .batteryHistory: tr("电量历史")
        case .batteryHealth: tr("电池健康")
        case .batteryBluetooth: tr("蓝牙设备")
        }
    }
}

/// 网络速度旁的可选出口地区显示。
public enum NetworkLocationStyle: String, CaseIterable, Identifiable, Sendable {
    case off, flag, text
    public var id: String { rawValue }

    var title: String {
        switch self {
        case .off: tr("不显示")
        case .flag: tr("国旗")
        case .text: tr("地区文字")
        }
    }
}

/// 菜单栏布局
public enum MenuBarLayout: String, CaseIterable, Identifiable, Sendable {
    /// 每个指标一个图标，点击弹出该项详情
    case separate
    /// 所有指标合成一个图标，点击弹出状态总览，可切到各项详情
    case combined
    /// 只显示应用标志；保存的项目选择用于弹出面板，不持续绘制读数。
    case iconOnly

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .separate: tr("每项独立")
        case .combined: tr("合并显示")
        case .iconOnly: tr("仅图标")
        }
    }

    var subtitle: String {
        switch self {
        case .separate: tr("每个指标一个图标，点击弹出该项详情")
        case .combined: tr("所有指标合成一个图标，点击弹出状态总览，可切到各项详情")
        case .iconOnly: tr("只显示 XStats 图标，点击查看已选项目的状态总览")
        }
    }
}

/// 连接探测的目标
public enum ProbeTarget: String, CaseIterable, Identifiable, Sendable {
    case cloudflare, google, aliyun, tencent, gateway

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .cloudflare: tr("Cloudflare（1.1.1.1）")
        case .google: tr("Google（8.8.8.8）")
        case .aliyun: tr("阿里云（223.5.5.5）")
        case .tencent: tr("腾讯（119.29.29.29）")
        case .gateway: tr("路由器（网关）")
        }
    }

    /// 网关地址随网络变化，由调用方传入
    func address(router: String?) -> String? {
        switch self {
        case .cloudflare: "1.1.1.1"
        case .google: "8.8.8.8"
        case .aliyun: "223.5.5.5"
        case .tencent: "119.29.29.29"
        case .gateway: router
        }
    }
}

/// 菜单栏风格：整体选一种套用到所有指标，个别指标可以单独指定（AppSettings.styleOverrides）；风格内部的排版保持一致
public enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case stacked, stackedCenter, inline, icon, ring, pie, history, line, meter, dot

    public var id: String { rawValue }

    /// 温度、风扇没有百分比；AI 额度没有历史采样，只提供当前剩余量的图形。
    /// 整体选择历史图时，AI 额度尚无历史序列，用圆环表达当前剩余量。
    func resolved(for item: MenuBarItem) -> MenuBarStyle {
        item == .aiUsage && (self == .history || self == .line) ? .ring : self
    }

    static func options(for item: MenuBarItem) -> [MenuBarStyle] {
        switch item {
        case .temperature, .fan, .display, .audio: [.stacked, .stackedCenter, .inline, .icon]
        case .aiUsage: [.stacked, .stackedCenter, .inline, .icon, .ring, .pie, .meter, .dot]
        default: allCases
        }
    }

    var title: String {
        switch self {
        case .stacked: tr("双行文字")
        case .stackedCenter: tr("双行居中")
        case .inline: tr("单行文字")
        case .icon: tr("图标")
        case .ring: tr("圆环")
        case .pie: tr("饼图")
        case .history: tr("柱状历史")
        case .line: tr("折线历史")
        case .meter: tr("电量条")
        case .dot: tr("状态圆点")
        }
    }

    var detail: String {
        switch self {
        case .stacked: tr("小标签在上、数值在下，两行靠右对齐，数值的右边不会跳")
        case .stackedCenter: tr("同双行文字，但两行各自居中；标签比数值宽时（风扇、温度）不会偏到一边")
        case .inline: tr("标签与数值同一行，最易读")
        case .icon: tr("用系统图标代替文字标签")
        case .ring: tr("圆环表示当前占用比例")
        case .pie: tr("饼图表示当前占用比例")
        case .history: tr("10 根柱子是最近 10 次采样（约 20 秒）的变化")
        case .line: tr("折线是最近 30 次采样（约 1 分钟）的走势")
        case .meter: tr("竖向电量条表示当前占用比例")
        case .dot: tr("绿色正常、橙色偏高（60% 以上）、红色很高（85% 以上）")
        }
    }
}

public enum NetworkMenuStyle: String, CaseIterable, Identifiable, Sendable {
    case dots, arrows, inline

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .dots: tr("双行圆点")
        case .arrows: tr("双行箭头")
        case .inline: tr("单行")
        }
    }
}

extension AppLanguage: Identifiable {
    public var id: String { rawValue }

    /// 语言名称用各自的文字写，不随界面语言翻译
    var title: String {
        self == .system ? tr("自动检测") : nativeName
    }
}

public enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .system: tr("跟随系统")
        case .light: tr("浅色")
        case .dark: tr("深色")
        }
    }
}

/// 主窗口侧边栏的页面
public enum PanelTab: String, CaseIterable, Identifiable, Sendable {
    case overview, system, history, aiUsage, cpu, gpu, memory, disk, network, thermal, battery, processes, keepAwake, rest, cleaner, uninstaller, startupItems, audio, connections
    case settingsGeneral, settingsFeatures, settingsMenuBar, settingsNotifications, settingsAccount, settingsHelper, settingsAbout

    public var id: String { rawValue }

    static let monitors: [PanelTab] = [.overview, .system, .history, .aiUsage, .cpu, .gpu, .memory, .disk, .network, .thermal, .battery]
    static let tools: [PanelTab] = [.connections, .audio, .processes, .startupItems, .keepAwake, .rest, .cleaner, .uninstaller]
    // 暂时隐藏设置同步；保留枚举值和页面实现，避免影响已有配置并方便恢复。
    static let settings: [PanelTab] = [.settingsGeneral, .settingsFeatures, .settingsMenuBar, .settingsNotifications,
                                     /* .settingsAccount, */ .settingsHelper, .settingsAbout]

    var isSettings: Bool { Self.settings.contains(self) }

    /// 页面顶栏的标题：设置页带上分组名
    var headerTitle: String { isSettings ? tr("设置 · \(title)") : title }

    var title: String {
        switch self {
        case .overview: tr("仪表盘")
        case .system: tr("本机信息")
        case .history: tr("历史")
        case .aiUsage: tr("AI 用量")
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: tr("内存")
        case .disk: tr("磁盘")
        case .network: tr("网络")
        case .thermal: tr("温度与风扇")
        case .battery: tr("电池")
        case .processes: tr("进程")
        case .keepAwake: tr("防休眠")
        case .rest: tr("番茄钟")
        case .cleaner: tr("清理")
        case .uninstaller: tr("卸载应用")
        case .startupItems: tr("启动项")
        case .audio: tr("音频")
        case .connections: tr("网络监视器")
        case .settingsGeneral: tr("通用")
        case .settingsFeatures: tr("功能")
        case .settingsMenuBar: tr("菜单栏")
        case .settingsNotifications: tr("通知")
        case .settingsAccount: tr("设置同步")
        case .settingsHelper: tr("辅助工具")
        case .settingsAbout: tr("关于")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .system: "laptopcomputer"
        case .history: "clock.arrow.circlepath"
        case .aiUsage: "sparkles"
        case .cpu: "cpu"
        case .gpu: "square.3.layers.3d"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .thermal: "fan"
        case .battery: "battery.75"
        case .processes: "list.bullet.rectangle"
        case .keepAwake: "cup.and.saucer"
        case .rest: "timer"
        case .cleaner: "eraser"
        case .uninstaller: "trash"
        case .startupItems: "power"
        case .audio: "speaker.wave.2"
        case .connections: "network.badge.shield.half.filled"
        case .settingsGeneral: "gearshape"
        case .settingsFeatures: "switch.2"
        case .settingsMenuBar: "menubar.rectangle"
        case .settingsNotifications: "bell.badge"
        case .settingsAccount: "arrow.triangle.2.circlepath"
        case .settingsHelper: "lock.shield"
        case .settingsAbout: "info.circle"
        }
    }

    /// 页面对应的菜单栏项目，页面右上角可直接开关
    var menuBarItem: MenuBarItem? {
        switch self {
        case .system: .display
        case .audio: .audio
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .network: .network
        case .disk: .disk
        case .thermal: .temperature
        case .battery: .battery
        case .aiUsage: .aiUsage
        default: nil
        }
    }

    /// 页面右上角可以直接开关的菜单栏项目：温度与风扇页有温度、风扇两项
    var menuBarItems: [MenuBarItem] {
        switch self {
        case .thermal: [.temperature, .fan]
        default: menuBarItem.map { [$0] } ?? []
        }
    }

    init(item: MenuBarItem) {
        switch item {
        case .cpu: self = .cpu
        case .gpu: self = .gpu
        case .memory: self = .memory
        case .network: self = .network
        case .disk: self = .disk
        case .temperature, .fan: self = .thermal
        case .battery: self = .battery
        case .aiUsage: self = .aiUsage
        case .display: self = .system
        case .audio: self = .audio
        }
    }
}

/// 自动更新检查策略；手动检查始终可用。
public enum UpdateCheckSchedule: String, CaseIterable, Identifiable, Sendable {
    case quietRuntime, atLaunch, daily, weekly, monthly, never

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .quietRuntime: tr("运行时静默")
        case .atLaunch: tr("启动时")
        case .daily: tr("每日一次")
        case .weekly: tr("每周一次")
        case .monthly: tr("每月一次")
        case .never: tr("从不")
        }
    }

    var promptsForUpdates: Bool { self != .quietRuntime && self != .never }

    /// 返回交给 Sparkle 的下次检查间隔；从不和本次启动已检查过时不注册计时器。
    func sparkleInterval(lastChecked: Date?, now: Date, launchedAt: Date, retry: Bool = false) -> TimeInterval? {
        guard let next = nextCheckDate(lastChecked: lastChecked, launchedAt: launchedAt) else { return nil }
        return retry ? 60 * 60 : max(60 * 60, next.timeIntervalSince(now))
    }

    /// 开机网络未就绪时，启动检查在本次成功之前始终待办，由 Sparkle 每小时重试。
    func shouldCheck(lastChecked: Date?, now: Date, launchedAt: Date) -> Bool {
        guard let next = nextCheckDate(lastChecked: lastChecked, launchedAt: launchedAt) else { return false }
        return now >= next
    }

    /// 到期判断和 Sparkle 调度共用同一日期规则，避免自然月与启动策略产生两套语义。
    private func nextCheckDate(lastChecked: Date?, launchedAt: Date) -> Date? {
        switch self {
        case .never: return nil
        case .atLaunch: return lastChecked.map { $0 >= launchedAt } == true ? nil : .distantPast
        case .quietRuntime, .daily, .weekly, .monthly:
            guard let lastChecked else { return .distantPast }
            switch self {
            case .quietRuntime, .daily: return lastChecked.addingTimeInterval(24 * 60 * 60)
            case .weekly: return lastChecked.addingTimeInterval(7 * 24 * 60 * 60)
            case .monthly: return Calendar.current.date(byAdding: .month, value: 1, to: lastChecked) ?? lastChecked
            case .atLaunch, .never: return nil
            }
        }
    }
}

/// UserDefaults 持久化的偏好设置
@MainActor
@Observable
public final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults
    var audioDefaults: UserDefaults { defaults }
    var networkObservationDefaults: UserDefaults { defaults }

    /// 日历独立于性能指标，即使指标合并也保留单独入口；旧用户默认关闭。
    public var calendarEnabled: Bool {
        didSet { defaults.set(calendarEnabled, forKey: Keys.calendarEnabled) }
    }
    public var calendarPreferences: CalendarPreferences {
        didSet { defaults.set(try? JSONEncoder().encode(calendarPreferences), forKey: Keys.calendarPreferences) }
    }
    /// nil 表示全部列表，空集合表示明确不显示任何列表；列表 ID 仅在本机有意义。
    var calendarEventSourceIDs: Set<String>? {
        didSet { defaults.set(calendarEventSourceIDs.map { Array($0).sorted() }, forKey: "calendarEventSourceIDs") }
    }
    var calendarReminderSourceIDs: Set<String>? {
        didSet { defaults.set(calendarReminderSourceIDs.map { Array($0).sorted() }, forKey: "calendarReminderSourceIDs") }
    }
    /// 休息提醒完全由本机计时；旧用户默认关闭。
    public var restEnabled: Bool {
        didSet {
            defaults.set(restEnabled, forKey: Keys.restEnabled)
            if !restEnabled && panelTab == .rest { panelTab = .settingsFeatures }
        }
    }
    public var restWorkMinutes: Int {
        didSet { defaults.set(restWorkMinutes, forKey: Keys.restWorkMinutes) }
    }
    public var restBreakMinutes: Int {
        didSet { defaults.set(restBreakMinutes, forKey: Keys.restBreakMinutes) }
    }
    public var restLongBreakMinutes: Int {
        didSet { defaults.set(restLongBreakMinutes, forKey: Keys.restLongBreakMinutes) }
    }
    public var restDailyGoal: Int {
        didSet { defaults.set(restDailyGoal, forKey: Keys.restDailyGoal) }
    }
    /// 兼容旧版布尔偏好与备份；新界面以 restMode 为准。
    public var restCycleEnabled: Bool {
        get { restMode == .cycle }
        set { restMode = newValue ? .cycle : .single }
    }
    public var restMode: RestRunMode {
        didSet {
            defaults.set(restMode.rawValue, forKey: Keys.restMode)
            defaults.set(restCycleEnabled, forKey: Keys.restCycleEnabled)
        }
    }
    public var restSound: RestSound {
        didSet { defaults.set(restSound.rawValue, forKey: Keys.restSound) }
    }
    public var restHUDStyle: RestHUDStyle {
        didSet { defaults.set(restHUDStyle.rawValue, forKey: Keys.restHUDStyle) }
    }
    public var calendarFeatures: Set<CalendarFeature> {
        didSet { defaults.set(calendarFeatures.map(\.rawValue).sorted(), forKey: Keys.calendarFeatures) }
    }
    public var calendarFirstWeekday: Int {
        didSet { defaults.set(calendarFirstWeekday, forKey: Keys.calendarFirstWeekday) }
    }

    public var menuBarItems: Set<MenuBarItem> {
        didSet { defaults.set(menuBarItems.map(\.rawValue).sorted(), forKey: Keys.menuBarItems) }
    }
    public var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Keys.menuBarStyle) }
    }
    public var networkStyle: NetworkMenuStyle {
        didSet { defaults.set(networkStyle.rawValue, forKey: Keys.networkStyle) }
    }
    public var networkLocationStyle: NetworkLocationStyle {
        didSet { defaults.set(networkLocationStyle.rawValue, forKey: Keys.networkLocationStyle) }
    }
    /// 个别指标单独指定的风格；未指定的跟随 menuBarStyle
    public var styleOverrides: [MenuBarItem: MenuBarStyle] {
        didSet {
            defaults.set(Dictionary(uniqueKeysWithValues: styleOverrides.map { ($0.key.rawValue, $0.value.rawValue) }),
                         forKey: Keys.styleOverrides)
        }
    }
    public var refreshSeconds: Int {
        didSet { defaults.set(refreshSeconds, forKey: Keys.refreshSeconds) }
    }
    /// AI 用量模块默认不启用，独立于系统指标的秒级采样。
    public var aiUsageEnabled: Bool {
        didSet {
            defaults.set(aiUsageEnabled, forKey: Keys.aiUsageEnabled)
            if !aiUsageEnabled && panelTab == .aiUsage { panelTab = .settingsFeatures }
        }
    }
    /// 网络连接仅在 macOS 15+ 开放；低版本保留偏好，但不展示或启动此模块。
    public var networkConnectionsEnabled: Bool {
        didSet {
            defaults.set(networkConnectionsEnabled, forKey: "networkConnectionsEnabled")
            if !canViewNetworkConnections && panelTab == .connections { panelTab = .settingsFeatures }
        }
    }
    var canViewNetworkConnections: Bool { NetworkMonitorSupport.isAvailable && networkConnectionsEnabled }

    /// 音频功能默认关闭；只有明确开启应用音量后才请求捕获权限。
    public var audioEnabled: Bool {
        didSet {
            defaults.set(audioEnabled, forKey: "audioEnabled")
            if !audioEnabled && panelTab == .audio { panelTab = .settingsFeatures }
        }
    }
    /// 独立进程管理器默认关闭；其他监控页仍可按需读取应用用量。
    public var processesEnabled: Bool {
        didSet {
            defaults.set(processesEnabled, forKey: Keys.processesEnabled)
            if !processesEnabled && panelTab == .processes { panelTab = .settingsFeatures }
        }
    }
    /// 清理工具默认关闭；扫描只在打开页面后按需执行。
    public var cleanerEnabled: Bool {
        didSet {
            defaults.set(cleanerEnabled, forKey: Keys.cleanerEnabled)
            if !cleanerEnabled && panelTab == .cleaner { panelTab = .settingsFeatures }
        }
    }
    /// 来源开关只保存在本机；关闭后不扫描，也不显示其历史缓存。
    public var aiUsageSources: Set<AIProviderID> {
        didSet { defaults.set(aiUsageSources.map(\.rawValue).sorted(), forKey: Keys.aiUsageSources) }
    }
    /// 订阅额度继续自动查询；关闭本地用量后停止扫描本机会话日志。
    public var aiUsageShowsLocalUsage: Bool {
        didSet { defaults.set(aiUsageShowsLocalUsage, forKey: Keys.aiUsageShowsLocalUsage) }
    }
    public var aiQuotaShowsRemaining: Bool {
        didSet { defaults.set(aiQuotaShowsRemaining, forKey: Keys.aiQuotaShowsRemaining) }
    }
    public var aiUsageWesternUnits: Bool {
        didSet { defaults.set(aiUsageWesternUnits, forKey: Keys.aiUsageWesternUnits) }
    }
    public var aiUsageCurrency: AIUsageCurrency {
        didSet { defaults.set(aiUsageCurrency.rawValue, forKey: Keys.aiUsageCurrency) }
    }
    public var aiUsageRefreshMinutes: Int {
        didSet { defaults.set(aiUsageRefreshMinutes, forKey: Keys.aiUsageRefreshMinutes) }
    }
    public var colorizeHighLoad: Bool {
        didSet { defaults.set(colorizeHighLoad, forKey: Keys.colorizeHighLoad) }
    }
    /// 键盘、鼠标、耳机等蓝牙设备电量低时，在菜单栏电池项旁提示
    public var bluetoothLowBatteryInMenuBar: Bool {
        didSet { defaults.set(bluetoothLowBatteryInMenuBar, forKey: Keys.bluetoothLowBatteryInMenuBar) }
    }
    public var useFahrenheit: Bool {
        didSet { defaults.set(useFahrenheit, forKey: Keys.useFahrenheit) }
    }
    /// 电量低于该值时自动关闭“合盖运行”
    public var lidModeBatteryFloor: Int {
        didSet { defaults.set(lidModeBatteryFloor, forKey: Keys.lidModeBatteryFloor) }
    }
    /// 自定义风扇模式下 CPU 达到该温度时恢复系统控制
    public var fanSafetyTemperature: Int {
        didSet { defaults.set(fanSafetyTemperature, forKey: Keys.fanSafetyTemperature) }
    }
    public var panelTab: PanelTab {
        didSet {
            // 统一拦截旧路由与外部打开请求，关闭的音频与进程模块回到功能开关入口。
            if panelTab == .audio && !audioEnabled { panelTab = .settingsFeatures }
            if panelTab == .connections && !canViewNetworkConnections { panelTab = .settingsFeatures }
            if panelTab == .processes && !processesEnabled { panelTab = .settingsFeatures }
            defaults.set(panelTab.rawValue, forKey: Keys.panelTab)
        }
    }
    public var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }
    /// 网络测速里单个节点的时间与流量上限
    public var speedTestBudget: SpeedTestBudget {
        didSet { defaults.set(speedTestBudget.rawValue, forKey: Keys.speedTestBudget) }
    }
    /// VPN / 代理开启时测速走直连还是代理；默认直连以测本机宽带。
    public var speedTestRoute: SpeedRoute {
        didSet { defaults.set(speedTestRoute.rawValue, forKey: Keys.speedTestRoute) }
    }
    /// 主窗口开着时在程序坞与 ⌘Tab 中显示图标；默认关闭，和其他菜单栏工具一样只在菜单栏运行
    public var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: Keys.showDockIcon) }
    }
    public var menuBarLayout: MenuBarLayout {
        didSet { defaults.set(menuBarLayout.rawValue, forKey: Keys.menuBarLayout) }
    }
    /// 用户在详情弹窗里隐藏的区块
    public var hiddenPopoverSections: Set<PopoverSection> {
        didSet { defaults.set(hiddenPopoverSections.map(\.rawValue).sorted(), forKey: Keys.hiddenPopoverSections) }
    }
    /// 弹窗里默认收起、被用户展开的区块（IP 纯净度、DNS）；只影响菜单栏弹窗，主窗口始终完整显示
    public var expandedPopoverSections: Set<PopoverSection> {
        didSet { defaults.set(expandedPopoverSections.map(\.rawValue).sorted(), forKey: Keys.expandedPopoverSections) }
    }
    public var probeEnabled: Bool {
        didSet { defaults.set(probeEnabled, forKey: Keys.probeEnabled) }
    }
    /// 网络详情关闭时，菜单栏显示网络项期间继续低频探测
    public var probeInBackground: Bool {
        didSet { defaults.set(probeInBackground, forKey: Keys.probeInBackground) }
    }
    public var probeTarget: ProbeTarget {
        didSet { defaults.set(probeTarget.rawValue, forKey: Keys.probeTarget) }
    }
    /// 打开网络详情时查询公网 IP（会访问 Cloudflare / ipify），归属地与纯净度由 cleanip.io 提供
    public var publicIPLookup: Bool {
        didSet { defaults.set(publicIPLookup, forKey: Keys.publicIPLookup) }
    }
    /// 自动检查发现新版本时发送系统通知，默认开启。
    public var notifyUpdates: Bool {
        didSet { defaults.set(notifyUpdates, forKey: Keys.notifyUpdates) }
    }
    /// 打开了系统通知的状况
    public var enabledAlerts: Set<AlertKind> {
        didSet { defaults.set(enabledAlerts.map(\.rawValue).sorted(), forKey: Keys.enabledAlerts) }
    }
    /// CPU 过热提醒的温度（摄氏度）
    public var alertCPUTemperature: Int {
        didSet { defaults.set(alertCPUTemperature, forKey: Keys.alertCPUTemperature) }
    }
    /// CPU 持续高负载提醒的总占用阈值（百分比）
    public var alertCPULoad: Int {
        didSet { defaults.set(alertCPULoad, forKey: Keys.alertCPULoad) }
    }
    /// CPU 详情顶部走势图显示最近多少秒
    public var cpuChartSeconds: Int {
        didSet { defaults.set(cpuChartSeconds, forKey: Keys.cpuChartSeconds) }
    }
    /// 界面语言：界面文字立即切换；系统提供的名称（显示器、应用名）在下次启动时跟着切换
    public var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Keys.language)
            language.applyToProcessLocale(defaults: defaults)
            L10n.configure(language)
        }
    }
    nonisolated public static let languageKey = "language"
    /// 全局快捷键
    public var hotKeys: [HotKeyAction: HotKey] {
        didSet {
            let stored = Dictionary(uniqueKeysWithValues: hotKeys.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(stored), forKey: Keys.hotKeys)
        }
    }
    /// 每分钟把主要指标写入本机历史库
    public var historyEnabled: Bool {
        didSet {
            if historyEnabled != oldValue { historyRecordingGeneration += 1 }
            defaults.set(historyEnabled, forKey: Keys.historyEnabled)
        }
    }
    /// 开关快速关闭再开启时，之前启动的异步补录仍须失效。
    @ObservationIgnored private(set) var historyRecordingGeneration = 0
    /// 旧版布尔设置只用于兼容旧备份；新界面以检查策略为准。
    public var autoCheckUpdates: Bool {
        get { updateCheckSchedule != .never }
        set { updateCheckSchedule = newValue ? .daily : .never }
    }
    public var updateCheckSchedule: UpdateCheckSchedule {
        didSet {
            defaults.set(updateCheckSchedule.rawValue, forKey: Keys.updateCheckSchedule)
            defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates)
        }
    }
    /// 可再生的缓存也先移到废纸篓（可恢复，但不会立即释放空间）
    public var cleanPrefersTrash: Bool {
        didSet { defaults.set(cleanPrefersTrash, forKey: Keys.cleanPrefersTrash) }
    }
    /// 清理页的规则选择；nil 表示用户从未调整过，使用规则默认值。空集合表示用户明确全部取消。
    public var cleanSelectedRuleIDs: Set<String>? {
        didSet {
            if let cleanSelectedRuleIDs {
                defaults.set(cleanSelectedRuleIDs.sorted(), forKey: Keys.cleanSelectedRuleIDs)
            } else {
                defaults.removeObject(forKey: Keys.cleanSelectedRuleIDs)
            }
        }
    }
    /// nil 使用动态默认目录；空数组表示用户明确移除了所有目录。仅在本机保存。
    public var projectPurgeConfiguredPaths: [String]? {
        didSet {
            if let projectPurgeConfiguredPaths {
                defaults.set(projectPurgeConfiguredPaths, forKey: Keys.projectPurgeConfiguredPaths)
            } else {
                defaults.removeObject(forKey: Keys.projectPurgeConfiguredPaths)
            }
        }
    }

    public static let refreshOptions = [1, 2, 3, 5]
    public static let restWorkOptions = [20, 25, 30, 45, 60]
    public static let restBreakOptions = [3, 5, 10]
    public static let restLongBreakOptions = [10, 15, 20, 30]
    public static let restDailyGoalOptions = [4, 6, 8, 12]
    public static let aiUsageRefreshOptions = [1, 3, 5, 10, 15, 30, 60]
    public static let batteryFloorOptions = [10, 20, 30, 40]
    public static let fanSafetyOptions = [85, 90, 95, 100]
    public static let alertTemperatureOptions = [85, 90, 95, 100]
    public static let alertLoadOptions = [70, 80, 90]
    public static let cpuChartOptions = [60, 180, 300]

    public init(defaults: UserDefaults = .standard, calendarLocale: Locale = .current, calendar: Calendar = .current) {
        self.defaults = defaults
        let isRestEnabled = defaults.bool(forKey: Keys.restEnabled)
        restEnabled = isRestEnabled
        restWorkMinutes = Self.restWorkOptions.contains(defaults.integer(forKey: Keys.restWorkMinutes))
            ? defaults.integer(forKey: Keys.restWorkMinutes) : 25
        restBreakMinutes = Self.restBreakOptions.contains(defaults.integer(forKey: Keys.restBreakMinutes))
            ? defaults.integer(forKey: Keys.restBreakMinutes) : 5
        restLongBreakMinutes = Self.restLongBreakOptions.contains(defaults.integer(forKey: Keys.restLongBreakMinutes))
            ? defaults.integer(forKey: Keys.restLongBreakMinutes) : 15
        restDailyGoal = Self.restDailyGoalOptions.contains(defaults.integer(forKey: Keys.restDailyGoal))
            ? defaults.integer(forKey: Keys.restDailyGoal) : 8
        restMode = defaults.string(forKey: Keys.restMode).flatMap(RestRunMode.init(rawValue:))
            ?? (defaults.bool(forKey: Keys.restCycleEnabled) ? .cycle : .single)
        restSound = defaults.string(forKey: Keys.restSound).flatMap(RestSound.init(rawValue:)) ?? .off
        restHUDStyle = defaults.string(forKey: Keys.restHUDStyle).flatMap(RestHUDStyle.init(rawValue:)) ?? .countdown
        // 旧版只在用户开关日历后写入该键；已有安装缺少保存值时沿用旧版默认，不按地区重新初始化。
        let isExistingCalendarInstall = defaults.object(forKey: Keys.calendarEnabled) != nil
        calendarEnabled = defaults.bool(forKey: Keys.calendarEnabled)
        let savedCalendarPreferences = defaults.data(forKey: Keys.calendarPreferences)
        calendarPreferences = savedCalendarPreferences
            .flatMap { try? JSONDecoder().decode(CalendarPreferences.self, from: $0) }
            ?? CalendarPreferences(locale: isExistingCalendarInstall ? Locale(identifier: "zh_CN") : calendarLocale)
        calendarEventSourceIDs = defaults.stringArray(forKey: "calendarEventSourceIDs").map { Set($0) }
        calendarReminderSourceIDs = defaults.stringArray(forKey: "calendarReminderSourceIDs").map { Set($0) }
        let savedCalendarFeatures = defaults.stringArray(forKey: Keys.calendarFeatures)
        calendarFeatures = savedCalendarFeatures
            .map(CalendarFeature.restored(from:))
            ?? (isExistingCalendarInstall ? CalendarFeature.mainlandChinaDefaults : CalendarFeature.defaults(for: calendarLocale))
        let savedCalendarFirstWeekday = (defaults.object(forKey: Keys.calendarFirstWeekday) as? Int)
            .flatMap { (1...7).contains($0) ? $0 : nil }
        calendarFirstWeekday = savedCalendarFirstWeekday ?? (isExistingCalendarInstall ? 2 : calendar.firstWeekday)
        let items = defaults.stringArray(forKey: Keys.menuBarItems)?.compactMap(MenuBarItem.init(rawValue:))
        menuBarItems = Set(items ?? [.cpu, .memory, .network])
        menuBarStyle = defaults.string(forKey: Keys.menuBarStyle).flatMap(MenuBarStyle.init(rawValue:)) ?? .stacked
        networkStyle = defaults.string(forKey: Keys.networkStyle).flatMap(NetworkMenuStyle.init(rawValue:)) ?? .dots
        networkLocationStyle = defaults.string(forKey: Keys.networkLocationStyle).flatMap(NetworkLocationStyle.init(rawValue:)) ?? .off
        let storedOverrides = defaults.dictionary(forKey: Keys.styleOverrides) as? [String: String] ?? [:]
        styleOverrides = Dictionary(uniqueKeysWithValues: storedOverrides.compactMap { key, value in
            guard let item = MenuBarItem(rawValue: key), let style = MenuBarStyle(rawValue: value) else { return nil }
            return (item, style)
        })
        refreshSeconds = Self.refreshOptions.contains(defaults.integer(forKey: Keys.refreshSeconds))
            ? defaults.integer(forKey: Keys.refreshSeconds) : 2
        let isAIUsageEnabled = defaults.bool(forKey: Keys.aiUsageEnabled)
        aiUsageEnabled = isAIUsageEnabled
        let isAudioEnabled = defaults.bool(forKey: "audioEnabled")
        audioEnabled = isAudioEnabled
        let isNetworkConnectionsEnabled = defaults.bool(forKey: "networkConnectionsEnabled")
        networkConnectionsEnabled = isNetworkConnectionsEnabled
        let isCleanerEnabled = defaults.bool(forKey: Keys.cleanerEnabled)
        cleanerEnabled = isCleanerEnabled
        let isProcessesEnabled = defaults.bool(forKey: Keys.processesEnabled)
        processesEnabled = isProcessesEnabled
        aiUsageSources = defaults.stringArray(forKey: Keys.aiUsageSources)
            .map { Set($0.compactMap(AIProviderID.init(rawValue:))) } ?? Set(AIProviderID.allCases)
        aiUsageShowsLocalUsage = defaults.object(forKey: Keys.aiUsageShowsLocalUsage) as? Bool ?? true
        aiQuotaShowsRemaining = defaults.object(forKey: Keys.aiQuotaShowsRemaining) as? Bool ?? true
        aiUsageWesternUnits = defaults.bool(forKey: Keys.aiUsageWesternUnits)
        aiUsageCurrency = defaults.string(forKey: Keys.aiUsageCurrency).flatMap(AIUsageCurrency.init(rawValue:)) ?? .usd
        aiUsageRefreshMinutes = Self.aiUsageRefreshOptions.contains(defaults.integer(forKey: Keys.aiUsageRefreshMinutes))
            ? defaults.integer(forKey: Keys.aiUsageRefreshMinutes) : 30
        colorizeHighLoad = defaults.bool(forKey: Keys.colorizeHighLoad)
        bluetoothLowBatteryInMenuBar = defaults.object(forKey: Keys.bluetoothLowBatteryInMenuBar) as? Bool ?? true
        useFahrenheit = defaults.bool(forKey: Keys.useFahrenheit)
        lidModeBatteryFloor = Self.batteryFloorOptions.contains(defaults.integer(forKey: Keys.lidModeBatteryFloor))
            ? defaults.integer(forKey: Keys.lidModeBatteryFloor) : 20
        fanSafetyTemperature = Self.fanSafetyOptions.contains(defaults.integer(forKey: Keys.fanSafetyTemperature))
            ? defaults.integer(forKey: Keys.fanSafetyTemperature) : 95
        let savedPanelTabValue = defaults.string(forKey: Keys.panelTab)
        let savedPanelTab = savedPanelTabValue.flatMap(PanelTab.init(rawValue:)) ?? .overview
        // 旧版 AI 助手设置页已移除，升级后仍留在设置分组。
        if savedPanelTabValue == "settingsAI" || savedPanelTab == .settingsAccount {
            panelTab = .settingsGeneral
        } else {
            panelTab = (savedPanelTab == .audio && !isAudioEnabled)
                || (savedPanelTab == .connections && (!isNetworkConnectionsEnabled || !NetworkMonitorSupport.isAvailable))
                || (savedPanelTab == .aiUsage && !isAIUsageEnabled)
                || (savedPanelTab == .rest && !isRestEnabled)
                || (savedPanelTab == .cleaner && !isCleanerEnabled)
                || (savedPanelTab == .processes && !isProcessesEnabled)
                ? .settingsFeatures : savedPanelTab
        }
        appearance = defaults.string(forKey: Keys.appearance).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        showDockIcon = defaults.bool(forKey: Keys.showDockIcon)
        speedTestBudget = defaults.string(forKey: Keys.speedTestBudget).flatMap(SpeedTestBudget.init(rawValue:)) ?? .full
        speedTestRoute = defaults.string(forKey: Keys.speedTestRoute).flatMap(SpeedRoute.init(rawValue:)) ?? .direct
        cleanPrefersTrash = defaults.bool(forKey: Keys.cleanPrefersTrash)
        cleanSelectedRuleIDs = defaults.stringArray(forKey: Keys.cleanSelectedRuleIDs).map(Set.init)
        projectPurgeConfiguredPaths = defaults.stringArray(forKey: Keys.projectPurgeConfiguredPaths)
        menuBarLayout = defaults.string(forKey: Keys.menuBarLayout).flatMap(MenuBarLayout.init(rawValue:)) ?? .separate
        expandedPopoverSections = Set((defaults.stringArray(forKey: Keys.expandedPopoverSections) ?? []).compactMap(PopoverSection.init(rawValue:)))
        hiddenPopoverSections = defaults.stringArray(forKey: Keys.hiddenPopoverSections)
            .map { Set($0.compactMap(PopoverSection.init(rawValue:))) } ?? PopoverSection.hiddenByDefault
        probeEnabled = defaults.object(forKey: Keys.probeEnabled) as? Bool ?? true
        probeInBackground = defaults.object(forKey: Keys.probeInBackground) as? Bool ?? true
        probeTarget = defaults.string(forKey: Keys.probeTarget).flatMap(ProbeTarget.init(rawValue:)) ?? .cloudflare
        publicIPLookup = defaults.object(forKey: Keys.publicIPLookup) as? Bool ?? true
        updateCheckSchedule = defaults.string(forKey: Keys.updateCheckSchedule)
            .flatMap(UpdateCheckSchedule.init(rawValue:))
            ?? ((defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true) ? .daily : .never)
        historyEnabled = defaults.object(forKey: Keys.historyEnabled) as? Bool ?? true
        language = defaults.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        let storedHotKeys = defaults.data(forKey: Keys.hotKeys).flatMap { try? JSONDecoder().decode([String: HotKey].self, from: $0) } ?? [:]
        hotKeys = Dictionary(uniqueKeysWithValues: storedHotKeys.compactMap { key, value in
            HotKeyAction(rawValue: key).map { ($0, value) }
        })
        notifyUpdates = defaults.object(forKey: Keys.notifyUpdates) as? Bool ?? true
        enabledAlerts = Set(defaults.stringArray(forKey: Keys.enabledAlerts)?.compactMap(AlertKind.init(rawValue:)) ?? [])
        alertCPUTemperature = Self.alertTemperatureOptions.contains(defaults.integer(forKey: Keys.alertCPUTemperature))
            ? defaults.integer(forKey: Keys.alertCPUTemperature) : 95
        alertCPULoad = Self.alertLoadOptions.contains(defaults.integer(forKey: Keys.alertCPULoad))
            ? defaults.integer(forKey: Keys.alertCPULoad) : 80
        cpuChartSeconds = Self.cpuChartOptions.contains(defaults.integer(forKey: Keys.cpuChartSeconds))
            ? defaults.integer(forKey: Keys.cpuChartSeconds) : 60
        // 仅在没有偏好时确定默认值；后续语言、地区变化及备份恢复不重置用户选择。
        if savedCalendarPreferences == nil {
            defaults.set(try? JSONEncoder().encode(calendarPreferences), forKey: Keys.calendarPreferences)
        }
        if savedCalendarFeatures == nil {
            defaults.set(calendarFeatures.map(\.rawValue).sorted(), forKey: Keys.calendarFeatures)
        }
        // 首次采用系统的周起始日并保存，之后系统设置变化不覆盖用户选择。
        if savedCalendarFirstWeekday == nil {
            defaults.set(calendarFirstWeekday, forKey: Keys.calendarFirstWeekday)
        }
    }

    /// 按固定顺序返回当前实际显示的菜单栏项目；可选模块关闭时保留展示偏好但不渲染。
    var orderedMenuBarItems: [MenuBarItem] {
        MenuBarItem.allCases.filter { item in
            menuBarItems.contains(item) && (item != .aiUsage || aiUsageEnabled) && (item != .audio || audioEnabled)
        }
    }

    func isEnabled(_ item: MenuBarItem) -> Bool { menuBarItems.contains(item) }

    func style(for item: MenuBarItem) -> MenuBarStyle {
        (styleOverrides[item] ?? menuBarStyle).resolved(for: item)
    }

    /// nil 表示跟随整体风格
    func setStyleOverride(_ style: MenuBarStyle?, for item: MenuBarItem) {
        styleOverrides[item] = style
    }

    func isVisible(_ section: PopoverSection) -> Bool { !hiddenPopoverSections.contains(section) }

    func isExpanded(_ section: PopoverSection) -> Bool { expandedPopoverSections.contains(section) }

    func setExpanded(_ section: PopoverSection, _ expanded: Bool) {
        if expanded { expandedPopoverSections.insert(section) } else { expandedPopoverSections.remove(section) }
    }

    func setVisible(_ section: PopoverSection, _ visible: Bool) {
        if visible { hiddenPopoverSections.remove(section) } else { hiddenPopoverSections.insert(section) }
    }

    func setEnabled(_ item: MenuBarItem, _ enabled: Bool) {
        if enabled {
            menuBarItems.insert(item)
        } else {
            menuBarItems.remove(item)
        }
    }

    private enum Keys {
        static let restEnabled = "restEnabled"
        static let restWorkMinutes = "restWorkMinutes"
        static let restBreakMinutes = "restBreakMinutes"
        static let restLongBreakMinutes = "restLongBreakMinutes"
        static let restDailyGoal = "restDailyGoal"
        static let restCycleEnabled = "restCycleEnabled"
        static let restMode = "restMode"
        static let restSound = "restSound"
        static let restHUDStyle = "restHUDStyle"
        static let calendarEnabled = "calendarEnabled"
        static let calendarPreferences = "calendarPreferences"
        static let calendarFeatures = "calendarFeatures"
        static let calendarFirstWeekday = "calendarFirstWeekday"
        static let menuBarItems = "menuBarItems"
        static let menuBarStyle = "menuBarStyle"
        static let networkStyle = "networkStyle"
        static let networkLocationStyle = "networkLocationStyle"
        static let styleOverrides = "styleOverrides"
        static let refreshSeconds = "refreshSeconds"
        static let aiUsageEnabled = "aiUsageEnabled"
        static let cleanerEnabled = "cleanerEnabled"
        static let processesEnabled = "processesEnabled"
        static let aiUsageSources = "aiUsageSources"
        static let aiUsageShowsLocalUsage = "aiUsageShowsLocalUsage"
        static let aiQuotaShowsRemaining = "aiQuotaShowsRemaining"
        static let aiUsageWesternUnits = "aiUsageWesternUnits"
        static let aiUsageCurrency = "aiUsageCurrency"
        static let aiUsageRefreshMinutes = "aiUsageRefreshMinutes"
        static let colorizeHighLoad = "colorizeHighLoad"
        static let bluetoothLowBatteryInMenuBar = "bluetoothLowBatteryInMenuBar"
        static let useFahrenheit = "useFahrenheit"
        static let lidModeBatteryFloor = "lidModeBatteryFloor"
        static let fanSafetyTemperature = "fanSafetyTemperature"
        static let panelTab = "panelTab"
        static let appearance = "appearance"
        static let showDockIcon = "showDockIcon"
        static let speedTestBudget = "speedTestBudget"
        static let speedTestRoute = "speedTestRoute"
        static let cleanPrefersTrash = "cleanPrefersTrash"
        static let cleanSelectedRuleIDs = "cleanSelectedRuleIDs"
        static let projectPurgeConfiguredPaths = "projectPurgeConfiguredPaths"
        static let menuBarLayout = "menuBarLayout"
        static let hiddenPopoverSections = "hiddenPopoverSections"
        static let expandedPopoverSections = "expandedPopoverSections"
        static let probeEnabled = "probeEnabled"
        static let probeInBackground = "probeInBackground"
        static let probeTarget = "probeTarget"
        static let publicIPLookup = "publicIPLookup"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let updateCheckSchedule = "updateCheckSchedule"
        static let historyEnabled = "historyEnabled"
        static let hotKeys = "hotKeys"
        static let language = "language"
        static let enabledAlerts = "enabledAlerts"
        static let notifyUpdates = "notifyUpdates"
        static let alertCPUTemperature = "alertCPUTemperature"
        static let alertCPULoad = "alertCPULoad"
        static let cpuChartSeconds = "cpuChartSeconds"
    }
}
