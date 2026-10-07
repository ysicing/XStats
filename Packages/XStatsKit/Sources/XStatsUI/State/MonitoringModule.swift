// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization

/// 基础监控的功能开关。温度与风扇共享传感器和控制生命周期，使用同一个开关。
public enum MonitoringModule: String, CaseIterable, Identifiable, Sendable {
    case cpu, gpu, memory, disk, network, thermal, battery, display

    public var id: String { rawValue }

    var menuBarItems: [MenuBarItem] {
        switch self {
        case .thermal: [.temperature, .fan]
        case .cpu: [.cpu]
        case .gpu: [.gpu]
        case .memory: [.memory]
        case .disk: [.disk]
        case .network: [.network]
        case .battery: [.battery]
        case .display: [.display]
        }
    }

    var title: String {
        if self == .display { return tr("显示器参数控制") }
        return self == .thermal ? tr("温度与风扇") : menuBarItems[0].title
    }
    var symbol: String { menuBarItems[0].symbol }
}

extension MenuBarItem {
    var monitoringModule: MonitoringModule? {
        switch self {
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .disk: .disk
        case .network: .network
        case .temperature, .fan: .thermal
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
        case .cpuTemperature: .thermal
        case .memoryPressure: .memory
        case .diskSpace: .disk
        case .networkDown: .network
        case .batteryHealth, .bluetoothBattery: .battery
        }
    }
}
