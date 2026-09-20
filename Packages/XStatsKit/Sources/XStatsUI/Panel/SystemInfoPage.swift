import AppKit
import Localization
import Metrics
import SwiftUI

/// 本机信息：机型、芯片、内存、图形、存储、显示器、电池与标识
struct SystemInfoPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var revealSerial = false

    var body: some View {
        let store = model.store
        let system = store.system
        let topology = store.topology

        PageScroll {
            Card(padding: DS.Space.s4, spacing: DS.Space.s3) {
                HStack(spacing: DS.Space.s4) {
                    Image(nsImage: NSImage(named: NSImage.computerName) ?? NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: DS.Space.s16 + DS.Space.s8, height: DS.Space.s16 + DS.Space.s8)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.s2) {
                        Text(verbatim: localizedModel(system.modelName))
                            .dsFont(.xl, weight: .semibold)
                            .foregroundStyle(DS.Palette.textPrimary)
                        Text(verbatim: tr("\(system.osVersion)（\(system.osBuild)）"))
                            .dsFont(.sm)
                            .foregroundStyle(DS.Palette.textSecondary)
                        FlowLayout(spacing: DS.Space.s2) {
                            Chip(text: chipName(topology.brand), icon: "apple.logo")
                            Chip(text: Format.bytes(ProcessInfo.processInfo.physicalMemory).replacingOccurrences(of: ".0 ", with: " "))
                            if let disk = store.disk {
                                Chip(text: Format.bytes(disk.total, base: .decimal).replacingOccurrences(of: ".0 ", with: " "))
                            }
                            if let boot = system.bootDate {
                                Chip(text: tr("已运行 ") + Format.uptime(since: boot))
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            WeightedRow(weights: [1, 1]) {
                InfoCard(icon: "cpu", title: tr("处理器")) {
                    InfoRow(label: tr("芯片"), text: topology.brand)
                    InfoRow(label: tr("核心"), text: tr("\(topology.logicalCores) 核"))
                    ForEach(topology.clusters) { cluster in
                        InfoRow(label: cluster.name, text: tr("\(cluster.coreIndices.count) 核"))
                    }
                }
                InfoCard(icon: "memorychip", title: tr("内存与图形")) {
                    InfoRow(label: tr("内存"), text: Format.bytes(ProcessInfo.processInfo.physicalMemory))
                    InfoRow(label: tr("图形"), text: store.gpu?.name ?? topology.brand)
                    InfoRow(label: tr("图形核心"), text: store.gpu?.coreCount.map { tr("\($0) 核") } ?? "—")
                    InfoRow(label: tr("内存类型"), text: tr("统一内存（CPU 与 GPU 共享）"))
                }
            }

            WeightedRow(weights: [1, 1]) {
                InfoCard(icon: "internaldrive", title: tr("存储")) {
                    if let disk = store.disk {
                        InfoRow(label: tr("卷"), text: disk.volumeName)
                        InfoRow(label: tr("容量"), text: Format.bytes(disk.total, base: .decimal))
                        InfoRow(label: tr("可用"), text: Format.bytes(disk.available, base: .decimal))
                        ProgressTrack(fraction: disk.usedFraction,
                                      color: disk.usedFraction > 0.9 ? DS.Palette.warning : DS.Palette.primary)
                    } else {
                        Text(tr("正在读取…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                InfoCard(icon: "battery.75", title: tr("电池")) {
                    if let battery = store.battery {
                        InfoRow(label: tr("电量"), text: Format.percent(battery.level))
                        InfoRow(label: tr("健康度"), text: battery.health.map { Format.percent($0) } ?? "—")
                        InfoRow(label: tr("循环次数"), text: battery.cycleCount.map(String.init) ?? "—")
                        InfoRow(label: tr("电源"), text: battery.isPluggedIn ? tr("电源适配器\(battery.adapterWatts.map { " · \($0)W" } ?? "")") : tr("电池供电"))
                        // macOS 26 起系统自带充电上限；新款机型已不开放第三方写入 SMC 充电控制键，不另做一套
                        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) {
                            HStack(spacing: DS.Space.s2) {
                                Text(tr("充电上限可在系统设置中设为 80%–100%，长期接电源时有助于延缓电池老化"))
                                    .dsFont(.xs)
                                    .foregroundStyle(DS.Palette.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button(tr("电池设置")) {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .buttonStyle(DSButtonStyle(kind: .secondary))
                                .fixedSize()
                            }
                        }
                    } else {
                        Text(tr("这台 Mac 没有电池")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
            }

            BluetoothCard()

            InfoCard(icon: "display.2", title: tr("显示器")) {
                let displays = DisplayInfo.all()
                if displays.isEmpty {
                    Text(tr("没有检测到显示器")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                }
                ForEach(Array(displays.enumerated()), id: \.offset) { index, display in
                    if index > 0 { HairlineDivider() }
                    HStack(spacing: DS.Space.s3) {
                        Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                            .font(.system(size: DS.TextSize.base.rawValue))
                            .foregroundStyle(DS.Palette.textSecondary)
                            .frame(width: DS.Size.iconStandalone)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: display.name).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.textPrimary)
                            Text(verbatim: display.summary).dsFont(.xs).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                        }
                        Spacer(minLength: 0)
                        if display.isMain { Chip(text: tr("主显示器"), tone: .primary) }
                    }
                }
            }

            InfoCard(icon: "number", title: tr("标识")) {
                InfoRow(label: tr("机型标识符")) { CopyableText(text: system.modelIdentifier.isEmpty ? "—" : system.modelIdentifier) }
                InfoRow(label: tr("系统版号")) { CopyableText(text: system.osBuild.isEmpty ? "—" : system.osBuild) }
                InfoRow(label: tr("序列号")) {
                    HStack(spacing: DS.Space.s1) {
                        if revealSerial, !isSnapshot, let serial = system.serialNumber {
                            CopyableText(text: serial)
                        } else {
                            Text(verbatim: system.serialNumber.map { String(repeating: "•", count: min(12, $0.count)) } ?? "—")
                        }
                        if system.serialNumber != nil, !isSnapshot {
                            MiniIconButton(systemName: revealSerial ? "eye.slash" : "eye", help: revealSerial ? tr("隐藏序列号") : tr("显示序列号")) {
                                revealSerial.toggle()
                            }
                        }
                    }
                }
                if let boot = system.bootDate {
                    InfoRow(label: tr("启动于"), text: boot.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: L10n.locale)))
                }
            }
        }
    }

    /// “MacBook Pro (16-inch, M5 Max)” → “MacBook Pro 16 英寸（M5 Max）”
    private func localizedModel(_ name: String) -> String {
        guard let open = name.firstIndex(of: "("), name.hasSuffix(")") else { return name }
        let base = name[..<open].trimmingCharacters(in: .whitespaces)
        var details = name[name.index(after: open)..<name.index(before: name.endIndex)]
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var size = ""
        if let index = details.firstIndex(where: { $0.hasSuffix("-inch") }) {
            size = tr(" \(details[index].dropLast("-inch".count)) 英寸")
            details.remove(at: index)
        }
        return details.isEmpty ? base + size : tr("\(base)\(size)（\(details.joined(separator: tr("，")))）")
    }

    private func chipName(_ brand: String) -> String {
        brand.hasPrefix("Apple ") ? String(brand.dropFirst("Apple ".count)) : brand
    }
}

private struct InfoCard<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: icon).font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                Text(title).dsFont(.xs, weight: .semibold)
            }
            .foregroundStyle(DS.Palette.textSecondary)
            content
        }
    }
}

/// 显示器信息：名称、尺寸、原生分辨率与最高刷新率
struct DisplayInfo {
    let name: String
    let isBuiltIn: Bool
    let isMain: Bool
    let summary: String

    @MainActor
    static func all() -> [DisplayInfo] {
        NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            var parts: [String] = []
            let millimeters = CGDisplayScreenSize(id)
            if millimeters.width > 0 {
                let inches = (millimeters.width * millimeters.width + millimeters.height * millimeters.height).squareRoot() / 25.4
                parts.append(tr("\(Int(inches.rounded())) 英寸"))
            }
            if let native = nativeResolution(id) { parts.append("\(native.width)×\(native.height)") }
            let points = screen.frame.size
            parts.append(tr("显示为 \(Int(points.width))×\(Int(points.height))"))
            if screen.maximumFramesPerSecond > 0 { parts.append("\(screen.maximumFramesPerSecond)Hz") }
            return DisplayInfo(name: screen.localizedName, isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                               isMain: CGDisplayIsMain(id) != 0, summary: parts.joined(separator: " · "))
        }
    }

    /// 面板的原生分辨率：优先取标记为原生的显示模式；缩放模式的像素可能比面板还多（如 6400×3600）
    private static func nativeResolution(_ id: CGDirectDisplayID) -> (width: Int, height: Int)? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode], !modes.isEmpty else { return nil }
        let nativeFlag: UInt32 = 0x0200_0000   // kDisplayModeNativeFlag
        let native = modes.filter { $0.ioFlags & nativeFlag != 0 }
        guard let best = (native.isEmpty ? modes : native)
            .max(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) else { return nil }
        return (best.pixelWidth, best.pixelHeight)
    }
}

/// 已连接蓝牙设备的电量；页面打开期间由 BluetoothController 每分钟刷新
private struct BluetoothCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        InfoCard(icon: "dot.radiowaves.left.and.right", title: tr("蓝牙设备")) {
            BluetoothDeviceList(devices: model.bluetooth.devices)
        }
    }
}
