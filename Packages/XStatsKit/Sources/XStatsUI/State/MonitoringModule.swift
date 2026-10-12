// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization

/// 基础监控的功能开关；battery 管理能耗与温度，thermal 保留独立风扇生命周期。
/// 沿用持久化标识，避免页面调整丢失已有开关和菜单栏偏好。
public enum MonitoringModule: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, disk, network, battery, thermal, display

    public var id: String { rawValue }

    var menuBarItems: [MenuBarItem] {
        switch self {
        case .thermal: [.fan]
        case .cpu: [.cpu]
        case .gpu: [.gpu]
        case .memory: [.memory]
        case .disk: [.disk]
        case .network: [.network]
        case .battery: [.battery, .temperature]
        case .display: [.display]
        }
    }

    var title: String {
        if self == .display { return tr("显示器参数控制") }
        if self == .battery { return tr("能耗") }
        return self == .thermal ? tr("风扇") : menuBarItems[0].title
    }
    var symbol: String { self == .battery ? "bolt" : menuBarItems[0].symbol }
}

extension MenuBarItem {
    var monitoringModule: MonitoringModule? {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        case .temperature: .battery
        case .fan: .thermal
        case .battery: .battery
        // 显示器入口只展示信息，不隐式开启 DDC 参数控制。
        case .display, .aiUsage, .audio: nil
        }
    }
}

extension PanelTab {
    /// 本机信息展示静态信息；显示器控制单独服从 display 开关，不关闭整个信息页。
    var monitoringModule: MonitoringModule? {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        case .thermal: .thermal
        case .battery: .battery
        default: nil
        }
    }
}

extension AlertKind {
    var monitoringModule: MonitoringModule {
        switch self {
        case .cpuLoad: .cpu
        case .cpuTemperature: .battery
        case .memoryPressure: .memory
        case .diskSpace: .disk
        case .networkDown: .network
        case .batteryHealth, .bluetoothBattery: .battery
        }
    }
}
