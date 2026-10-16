// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization

enum IslandPlacement: String, Codable, CaseIterable, Sendable {
    case floating, attached

    var title: String {
        switch self {
        case .floating: tr("悬浮胶囊")
        case .attached: tr("顶部贴合")
        }
    }

    var hint: String {
        switch self {
        case .floating: tr("悬浮在可用顶边下方；菜单栏隐藏时自动上移，保留设定间距。")
        case .attached: tr("贴合屏幕顶边，内容避开刘海和菜单栏；系统菜单优先显示。")
        }
    }
}

enum IslandOpening: String, Codable, CaseIterable, Sendable {
    case click, hoverPreview, hoverExpand

    var title: String {
        switch self {
        case .click: tr("点击展开")
        case .hoverPreview: tr("悬停预览")
        case .hoverExpand: tr("悬停展开")
        }
    }
}

enum IslandSize: String, Codable, CaseIterable, Sendable {
    case compact, standard, custom

    var title: String {
        switch self {
        case .compact: tr("紧凑")
        case .standard: tr("标准")
        case .custom: tr("自定义")
        }
    }
}

enum IslandSystemMetric: String, Codable, CaseIterable, Sendable {
    case cpu, memory, temperature, power

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: tr("内存")
        case .temperature: tr("温度")
        case .power: tr("功耗")
        }
    }
}

/// 只保存展示偏好，不改变系统监控、AI 用量或休息功能的启用状态。
public struct IslandPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var scene = IslandScene.system
    var scenes = IslandScene.allCases
    var automaticFocus = false
    var quotaAccountID = ""
    var systemMetrics = IslandSystemMetric.allCases
    /// 空字符串自动选择内建屏幕；UUID 跨重启保留显示器选择，断开时临时回退。
    var display = ""
    var placement = IslandPlacement.floating
    var opening = IslandOpening.hoverPreview
    var hoverDelay = 0.25
    var closeDelay = 0.2
    var hideInFullscreen = true
    var size = IslandSize.standard
    var customWidth = 420.0
    var customHeight = 320.0
    var topInset = 8.0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, scene, scenes, systemMetrics, display, placement, opening, hoverDelay, closeDelay, hideInFullscreen
        case size, customWidth, customHeight, topInset, automaticFocus, quotaAccountID
    }

    // 新增展示选项时，旧偏好和备份中缺少的字段沿用默认值，不能丢失启用状态和场景。
    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automaticFocus = try values.decodeIfPresent(Bool.self, forKey: .automaticFocus) ?? automaticFocus
        quotaAccountID = try values.decodeIfPresent(String.self, forKey: .quotaAccountID) ?? quotaAccountID
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        scene = try values.decodeIfPresent(IslandScene.self, forKey: .scene) ?? scene
        scenes = try values.decodeIfPresent([IslandScene].self, forKey: .scenes) ?? scenes
        systemMetrics = try values.decodeIfPresent([IslandSystemMetric].self, forKey: .systemMetrics) ?? systemMetrics
        display = try values.decodeIfPresent(String.self, forKey: .display) ?? display
        placement = try values.decodeIfPresent(IslandPlacement.self, forKey: .placement) ?? placement
        opening = try values.decodeIfPresent(IslandOpening.self, forKey: .opening) ?? opening
        hoverDelay = try values.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? hoverDelay
        closeDelay = try values.decodeIfPresent(Double.self, forKey: .closeDelay) ?? closeDelay
        hideInFullscreen = try values.decodeIfPresent(Bool.self, forKey: .hideInFullscreen) ?? hideInFullscreen
        size = try values.decodeIfPresent(IslandSize.self, forKey: .size) ?? size
        customWidth = try values.decodeIfPresent(Double.self, forKey: .customWidth) ?? customWidth
        customHeight = try values.decodeIfPresent(Double.self, forKey: .customHeight) ?? customHeight
        topInset = try values.decodeIfPresent(Double.self, forKey: .topInset) ?? topInset
    }

    var normalized: Self {
        var result = self
        result.scenes = IslandScene.allCases.filter { scenes.contains($0) }
        if result.scenes.isEmpty { result.scenes = [.system] }
        if !result.scenes.contains(scene) { result.scene = result.scenes[0] }
        result.systemMetrics = IslandSystemMetric.allCases.filter { systemMetrics.contains($0) }
        if result.systemMetrics.isEmpty { result.systemMetrics = [.cpu] }
        result.hoverDelay = hoverDelay.isFinite ? min(1, max(0.1, hoverDelay)) : 0.25
        result.closeDelay = closeDelay.isFinite ? min(2, max(0.1, closeDelay)) : 0.2
        result.customWidth = customWidth.isFinite ? min(600, max(360, customWidth)) : 420
        result.customHeight = customHeight.isFinite ? min(480, max(300, customHeight)) : 320
        result.topInset = topInset.isFinite ? min(32, max(8, topInset)) : 8
        return result
    }

    /// 只裁剪运行时内容；空结果表示暂时隐藏，不能再次 normalized 而恢复已关闭的 CPU。
    func available(hasInternalBattery: Bool?, enabledMetrics: [IslandSystemMetric] = IslandSystemMetric.allCases,
                   aiEnabled: Bool = true, restEnabled: Bool = true) -> Self {
        var value = normalized
        value.systemMetrics.removeAll { !enabledMetrics.contains($0) }
        let hasSystemMetrics = !value.systemMetrics.isEmpty
        value.scenes.removeAll { scene in
            switch scene {
            case .system: !hasSystemMetrics
            case .ai: !aiEnabled
            case .focus: !restEnabled
            case .battery: hasInternalBattery == false
            }
        }
        if !value.scenes.contains(value.scene), let first = value.scenes.first { value.scene = first }
        return value
    }

    @MainActor func available(settings: AppSettings, hasInternalBattery: Bool?) -> Self {
        let metrics = IslandSystemMetric.allCases.filter { metric in
            switch metric {
            case .cpu: settings.isModuleEnabled(.cpu)
            case .memory: settings.isModuleEnabled(.memory)
            case .temperature, .power: settings.isModuleEnabled(.battery)
            }
        }
        return available(hasInternalBattery: hasInternalBattery, enabledMetrics: metrics,
                         aiEnabled: settings.aiUsageEnabled, restEnabled: settings.restEnabled)
    }

    /// 收起态使用首个可用的已选指标；全部不可用时不产生系统监控需求。
    var primaryMetric: IslandSystemMetric? { systemMetrics.first }

    mutating func setScene(_ scene: IslandScene, visible: Bool) {
        var value = normalized
        if visible { value.scenes.append(scene) }
        else if value.scenes.count > 1 { value.scenes.removeAll { $0 == scene } }
        self = value.normalized
    }

    mutating func setMetric(_ metric: IslandSystemMetric, visible: Bool) {
        var value = normalized
        if visible { value.systemMetrics.append(metric) }
        else if value.systemMetrics.count > 1 { value.systemMetrics.removeAll { $0 == metric } }
        self = value.normalized
    }

    var expandedSize: CGSize {
        switch size {
        case .compact: CGSize(width: 360, height: 300)
        case .standard: CGSize(width: 420, height: 320)
        case .custom: CGSize(width: normalized.customWidth, height: normalized.customHeight)
        }
    }

    @MainActor static func displayKey(_ screen: NSScreen) -> String {
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// 同一排文字的测量与渲染使用相同字号；宽度按小步取整，避免个位读数导致细碎抖动。
enum IslandCompactLayout {
    static let horizontalPadding: CGFloat = 12
    static let spacing: CGFloat = 8
    static let iconWidth: CGFloat = 14
    static let disclosureWidth: CGFloat = 8

    static func width(for value: String) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let textWidth = (value as NSString).size(withAttributes: [.font: font]).width
        // Spacer 两侧也参与 HStack 间距，完整保留三段间距，避免挤掉百分号。
        let chromeWidth = 2 * horizontalPadding + iconWidth + disclosureWidth + 3 * spacing
        return min(260, max(120, ceil((textWidth + chromeWidth) / 8) * 8))
    }
}
