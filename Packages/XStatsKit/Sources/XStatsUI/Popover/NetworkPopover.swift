// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import HelperShared
import Localization
import Metrics
import SwiftUI

struct NetworkPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        let settings = model.settings
        let store = model.store
        let rate = store.network

        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s3) {
                RateHero(title: tr("下载"), bytesPerSecond: rate?.downloadBytesPerSecond, color: DS.NetworkPalette.download)
                Rectangle().fill(DS.Palette.border).frame(width: DS.Size.stroke, height: DS.Space.s8)
                RateHero(title: tr("上传"), bytesPerSecond: rate?.uploadBytesPerSecond, color: DS.NetworkPalette.upload)
            }
        }

        ForEach(MenuBarItem.network.popoverSections.filter { isDetailPage || settings.isVisible($0) }) { section in
            switch section {
            case .networkHistory: TrafficHistorySection()
            case .networkProbe: ProbeSection()
            case .networkInterface: InterfaceSection()
            case .networkAddresses: AddressSection()
            case .networkPurity: PuritySection()
            case .networkDNS: DNSSection()
            case .networkProcesses: NetworkProcessesSection()
            default: EmptyView()
            }
        }
    }
}

private struct RateHero: View {
    let title: String
    let bytesPerSecond: Double?
    let color: NSColor

    var body: some View {
        let parts = (bytesPerSecond.map { Format.menuBarRate($0) } ?? "— KB/s").split(separator: " ", maxSplits: 1).map(String.init)
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HeroValue(value: parts.first ?? "—", unit: parts.count > 1 ? parts[1] : nil)
            HStack(spacing: DS.Space.s1) {
                Circle().fill(Color(nsColor: color)).frame(width: DS.Size.barHeight, height: DS.Size.barHeight)
                Text(title).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 流量历史

private struct TrafficHistorySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        let store = model.store
        let upload = store.uploadHistory.elements
        let download = store.downloadHistory.elements

        // 峰值放在标题行，图表上不压任何文字
        SectionCard(title: PopoverSection.networkHistory.title, trailing: {
            HStack(spacing: DS.Space.s1) {
                Text(tr("60 秒峰值"))
                peak("↑", upload, color: DS.NetworkPalette.upload)
                peak("↓", download, color: DS.NetworkPalette.download)
            }
            .monospacedDigit()
        }) {
            MirroredRateChart(upload: upload, download: download,
                              height: isDetailPage ? DS.Size.chartHeight * 3 : DS.Size.chartHeight + DS.Space.s2)
        }
    }

    private func peak(_ arrow: String, _ values: [Double], color: NSColor) -> some View {
        HStack(spacing: DS.Space.s1 / 2) {
            Text(verbatim: arrow).foregroundStyle(Color(nsColor: color)).fontWeight(.semibold)
            Text(verbatim: Format.menuBarRate(max(values.max() ?? 0, MirroredRateChart.floor)))
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

// MARK: - 连接探测

private struct ProbeSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isDetailPage) private var isDetailPage

    var body: some View {
        @Bindable var settings = model.settings
        let network = model.network

        // 只看通不通，标题右侧不再写探测地址与频率
        SectionCard(title: PopoverSection.networkProbe.title) {
            if settings.probeEnabled {
                // 只用来看网络通不通：60 格是最近 60 次探测，排成两行细格
                ProbeGrid(samples: network.probes.elements, columns: NetworkController.probeCapacity / 2, rows: 2)
            } else {
                HStack {
                    Text(tr("定时 ping 一个地址，记录网络是否通畅")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    Spacer(minLength: DS.Space.s2)
                    Button(tr("开启")) { settings.probeEnabled = true }
                        .buttonStyle(DSButtonStyle(kind: .ghost))
                }
            }
        }
    }
}

// MARK: - 接口

private struct InterfaceSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let network = model.network
        let details = network.details
        let physical = details?.physical
        let totals = model.store.network

        SectionCard(title: PopoverSection.networkInterface.title, trailing: {
            // 右上角重置：把上传 / 下载从现在起重新累计，标出起算时间
            if let totals {
                if let since = network.trafficBaseline?.date {
                    Text(verbatim: tr("自 \(since.formatted(Date.FormatStyle(locale: L10n.locale).month().day().hour().minute())) 起"))
                }
                MiniIconButton(systemName: "arrow.counterclockwise",
                               help: tr("重置上传与下载统计：从现在起重新累计。重启后自动回到开机后的累计；右键可改回")) {
                    network.resetTraffic(totals)
                }
                .contextMenu {
                    if network.trafficBaseline != nil {
                        Button(tr("改回开机后累计")) { network.clearTrafficBaseline() }
                    }
                }
            }
        }) {
            if let physical {
                InfoRow(label: tr("接口"), text: tr("\(physical.displayName)（\(physical.bsdName)）"))
                InfoRow(label: tr("状态")) {
                    StatusBadge(text: physical.isUp ? tr("已连接") : tr("未连接"), tone: physical.isUp ? .success : .error)
                }
                InfoRow(label: tr("物理地址")) { CopyableText(text: physical.hardwareAddress ?? "—") }
                if let wifi = physical.wifi {
                    if let ssid = wifi.ssid { InfoRow(label: tr("网络名称"), text: ssid) }
                    InfoRow(label: tr("信号强度"), text: "\(wifi.rssi) dBm · \(signalQuality(wifi.rssi))")
                    InfoRow(label: tr("传输速率"), text: "\(Int(wifi.transmitRate)) Mbps")
                }
            } else {
                Text(details == nil ? tr("正在读取…") : tr("未连接网络")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
            if let tunnel = details?.tunnel {
                InfoRow(label: tr("VPN / 代理"), text: tr("\(tunnel.name)（\(tunnel.bsdName)）"))
            }
            if let totals {
                let counted = network.trafficTotals(totals)
                let sinceReset = network.trafficBaseline != nil
                InfoRow(label: sinceReset ? tr("重置后下载") : tr("开机后下载"), text: Format.bytes(counted.download, base: .decimal))
                InfoRow(label: sinceReset ? tr("重置后上传") : tr("开机后上传"), text: Format.bytes(counted.upload, base: .decimal))
            }
        }
    }

    private func signalQuality(_ rssi: Int) -> String {
        rssi >= -50 ? tr("极好") : rssi >= -60 ? tr("良好") : rssi >= -70 ? tr("一般") : tr("较弱")
    }
}

// MARK: - 地址

private struct AddressSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isPopover) private var isPopover

    var body: some View {
        let network = model.network
        let physical = network.details?.physical
        let lookup = model.settings.publicIPLookup
        let publicAddresses = network.publicAddresses

        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            header
            // 本地地址与路由器只在主窗口的网络页显示，菜单栏弹窗里只看公网
            if !isPopover {
                InfoRow(label: tr("本地 IPv4")) { CopyableText(text: physical?.ipv4.first ?? "—") }
                // 没有 IPv6 就不占行：网卡没有 IPv6 地址时不显示本地 IPv6，拿不到公网 IPv6 时不显示公网 IPv6
                if let localIPv6 = physical?.ipv6.first {
                    InfoRow(label: tr("本地 IPv6")) { CopyableText(text: localIPv6) }
                }
                InfoRow(label: tr("路由器")) { CopyableText(text: physical?.router ?? "—") }
            }
            if lookup {
                InfoRow(label: tr("公网 IPv4")) { publicValue(publicAddresses?.ipv4, loading: network.isLookingUpPublic) }
                if let publicIPv6 = publicAddresses?.ipv6 {
                    InfoRow(label: tr("公网 IPv6")) { CopyableText(text: publicIPv6) }
                }
                if let publicAddresses, let code = publicAddresses.countryCode {
                    InfoRow(label: tr("归属地")) {
                        HStack(spacing: DS.Space.s2) {
                            FlagImage(countryCode: code)
                            Text(verbatim: location(publicAddresses, code: code))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                if let asn = publicAddresses?.asn {
                    InfoRow(label: "ASN") { CopyableText(text: asn) }
                }
                if let organization = publicAddresses?.organization {
                    InfoRow(label: tr("网络运营方")) { Text(verbatim: organization).lineLimit(1).truncationMode(.middle) }
                }
                // 原生 / 广播、IP 类型、网络类型做成徽章，一眼看结论；反向解析、住宅概率等细节不在弹窗里占行
                if let publicAddresses, !Self.badges(publicAddresses).isEmpty {
                    FlowLayout(spacing: DS.Space.s2) {
                        ForEach(Self.badges(publicAddresses), id: \.text) { badge in
                            TagBadge(icon: badge.icon, text: badge.text, tone: badge.tone)
                        }
                    }
                    .padding(.top, DS.Space.s1)
                }
            } else {
                InfoRow(label: tr("公网 IP"), text: tr("查询已关闭"))
            }
        }
    }

    @ViewBuilder
    private func publicValue(_ value: String?, loading: Bool) -> some View {
        if loading && value == nil {
            Text(tr("查询中…")).foregroundStyle(DS.Palette.textTertiary)
        } else {
            CopyableText(text: value ?? "—")
        }
    }

    /// 国家 · 省 / 州 · 城市；英文界面优先用英文地名，重复的相邻项只留一个
    private func location(_ addresses: PublicAddresses, code: String) -> String {
        let country = L10n.locale.localizedString(forRegionCode: code) ?? code
        let region = L10n.usesEnglishNames ? (addresses.regionEnglish ?? addresses.region) : addresses.region
        let city = L10n.usesEnglishNames ? (addresses.cityEnglish ?? addresses.city) : addresses.city
        var parts: [String] = [country]
        for part in [region, city].compactMap({ $0 }) where part != parts.last { parts.append(part) }
        return parts.joined(separator: " · ")
    }

    /// 标题行：IP 地址 ……… [IPv4 | IPv6] ⟳；数据来源的字标只放在下面的纯净度区块里
    private var header: some View {
        let network = model.network
        return HStack(spacing: DS.Space.s2) {
            Text(PopoverSection.networkAddresses.title)
                .dsFont(.xs, weight: .semibold)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            if model.settings.publicIPLookup {
                HStack(spacing: DS.Space.s1) {
                    if network.hasDualStack {
                        PillSwitch(selection: Binding(get: { network.publicFamily }, set: { network.publicFamily = $0 }),
                                   options: IPFamily.allCases.map { ($0, $0.title) })
                    }
                    RefreshButton(loading: network.isLookingUpPublic, help: tr("强制刷新：忽略缓存，立即重新查询公网 IP 与归属地")) {
                        network.lookUpPublicAddresses(force: true)
                    }
                }
            }
            MiniIconButton(systemName: "arrow.triangle.branch", help: tr("出口与分流：检查 VPN 与代理是否生效、各网站从哪个出口出去")) {
                model.openEgressWindow()
            }
        }
    }

    struct Badge: Equatable {
        let icon: String
        let text: String
        let tone: TagBadge.Tone
    }

    /// 结论性徽章：原生 / 广播、住宅 / 机房、ASN 的类型
    static func badges(_ addresses: PublicAddresses) -> [Badge] {
        var badges: [Badge] = []
        if let isNative = addresses.isNative {
            badges.append(isNative ? Badge(icon: "checkmark.shield.fill", text: tr("原生 IP"), tone: .success)
                                   : Badge(icon: "antenna.radiowaves.left.and.right", text: tr("广播 IP"), tone: .warning))
        }
        if let ipType = addresses.ipType?.lowercased() {
            switch ipType {
            case "residential ip": badges.append(Badge(icon: "house.fill", text: tr("住宅 IP"), tone: .success))
            case "datacenter ip", "hosting ip": badges.append(Badge(icon: "server.rack", text: tr("机房 IP"), tone: .warning))
            case "mobile ip": badges.append(Badge(icon: "iphone.radiowaves.left.and.right", text: tr("移动网络 IP"), tone: .success))
            case "business ip": badges.append(Badge(icon: "building.2.fill", text: tr("企业 IP"), tone: .success))
            default: badges.append(Badge(icon: "questionmark.circle", text: addresses.ipType ?? "", tone: .neutral))
            }
        }
        if let asnType = addresses.asnType {
            switch asnType {
            case "isp": badges.append(Badge(icon: "wifi.router.fill", text: "ISP", tone: .success))
            case "mobile": badges.append(Badge(icon: "antenna.radiowaves.left.and.right", text: tr("移动运营商"), tone: .success))
            case "business": badges.append(Badge(icon: "building.2.fill", text: tr("企业网络"), tone: .success))
            case "education": badges.append(Badge(icon: "graduationcap.fill", text: tr("教育网"), tone: .success))
            case "government": badges.append(Badge(icon: "building.columns.fill", text: tr("政府"), tone: .success))
            case "hosting": badges.append(Badge(icon: "server.rack", text: tr("机房"), tone: .warning))
            default: break
            }
        }
        return badges
    }

    static func networkTypeLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "residential", "isp": tr("住宅宽带")
        case "business": tr("企业")
        case "hosting", "datacenter", "data center": tr("机房")
        case "mobile", "cellular": tr("移动网络")
        case "education": tr("教育网")
        case "government": tr("政府")
        default: raw
        }
    }

    static func ipTypeLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "residential ip": tr("住宅 IP")
        case "datacenter ip", "hosting ip": tr("机房 IP")
        case "mobile ip": tr("移动网络 IP")
        case "business ip": tr("企业 IP")
        default: raw
        }
    }
}

// MARK: - IP 纯净度

/// cleanip.io 给出的纯净度评分与风险标记
private struct PuritySection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isPopover) private var isPopover

    var body: some View {
        // 菜单栏弹窗里默认收起成一行，只显示分数与等级
        if isPopover, !model.settings.isExpanded(.networkPurity) {
            let summary = collapsedSummary
            CollapsedSection(title: PopoverSection.networkPurity.title, summary: summary.text, summaryColor: summary.color) {
                withAnimation(DS.Motion.quick) { model.settings.setExpanded(.networkPurity, true) }
            }
        } else {
            card
        }
    }

    private var collapsedSummary: (text: String, color: Color) {
        let network = model.network
        if let purity = network.publicAddresses?.purity {
            return ("\(purity.score) \(purity.grade)", DS.Grade.color(for: purity.score))
        }
        if !model.settings.publicIPLookup { return (tr("查询已关闭"), DS.Palette.textTertiary) }
        if network.isLookingUpPublic { return (tr("正在查询…"), DS.Palette.textTertiary) }
        return ("—", DS.Palette.textTertiary)
    }

    @ViewBuilder
    private var card: some View {
        let settings = model.settings
        let network = model.network
        let addresses = network.publicAddresses
        let hint = tr("纯净度看信誉、来路、邻居与网络类型四项；机房 IP 常见信誉高、来路和类型偏低。数据来自 cleanip.io")

        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            header(addresses)
            if let purity = addresses?.purity {
                // 分数在左、cleanip.io 字标在右，色带在下占满整行
                HStack(spacing: DS.Space.s2) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
                        Text(verbatim: "\(purity.score)")
                            .dsFont(.xxl, weight: .semibold)
                            .foregroundStyle(DS.Grade.color(for: purity.score))
                            .monospacedDigit()
                        Text(verbatim: purity.grade)
                            .dsFont(.base, weight: .semibold)
                            .foregroundStyle(DS.Grade.color(for: purity.score))
                        Text(verbatim: "/ 100").dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    }
                    .help(hint)
                    Spacer(minLength: DS.Space.s2)
                    CleanIPLink(height: DS.Size.iconInline,
                                url: addresses?.reportURL ?? CleanIPLink.site,
                                help: tr("评分由 cleanip.io 提供，点击查看完整报告"))
                }
                ScoreBand(score: purity.score).help(hint)
                if let risk = addresses?.risk {
                    InfoRow(label: tr("风险评分")) {
                        Text(verbatim: "\(risk.score)/100" + (risk.label.map { " · \(Self.riskLabel($0))" } ?? ""))
                    }
                    InfoRow(label: tr("风险标记")) {
                        Text(verbatim: risk.flags.isEmpty ? tr("未检出") : risk.flags.map(Self.flagLabel).joined(separator: "、"))
                            .foregroundStyle(risk.flags.isEmpty ? DS.Palette.success : DS.Palette.error)
                    }
                }
                if let recommendation = purity.recommendation, !L10n.usesEnglishNames {
                    Text(verbatim: recommendation)
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !settings.publicIPLookup {
                Text(tr("查询已关闭")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            } else if network.isLookingUpPublic {
                Text(tr("正在查询…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            } else {
                Text(tr("暂时没有拿到评分，稍后会再试")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    /// 标题行：IP 纯净度 [IPv4] 置信度 92% ……… [↗ ⟳ ⌃]
    /// 置信度是标题旁的一行浅色小字，不再用带框徽章；右侧的完整报告、刷新、收起并成一组按钮
    private func header(_ addresses: PublicAddresses?) -> some View {
        let network = model.network
        return HStack(spacing: DS.Space.s2) {
            Text(PopoverSection.networkPurity.title)
                .dsFont(.xs, weight: .semibold)
                .foregroundStyle(DS.Palette.textSecondary)
                .lineLimit(1)
                .fixedSize()
            if let family = network.shownFamily {
                TagBadge(text: family.title, tone: .primary, compact: true)
            }
            if let confidence = addresses?.purity?.confidence {
                HStack(spacing: DS.Space.s1 / 2) {
                    Text(tr("置信度")).foregroundStyle(DS.Palette.textTertiary)
                    Text(verbatim: "\(confidence)%")
                        .fontWeight(.medium)
                        .foregroundStyle(Self.confidenceColor(confidence))
                        .monospacedDigit()
                }
                .dsFont(.xs)
                .lineLimit(1)
                .fixedSize()
                .help(tr("cleanip.io 对这次评分的把握：各数据源结论越一致越高"))
            }
            Spacer(minLength: 0)
            HeaderActionGroup {
                if let url = addresses?.reportURL {
                    MiniIconButton(systemName: "arrow.up.forward", help: tr("在 cleanip.io 查看这个 IP 的完整报告")) {
                        NSWorkspace.shared.open(url)
                    }
                }
                RefreshButton(loading: network.isLookingUpPublic, help: tr("强制刷新：忽略缓存，立即重新查询公网 IP 与归属地")) {
                    network.lookUpPublicAddresses(force: true)
                }
                if isPopover {
                    MiniIconButton(systemName: "chevron.up", help: tr("收起")) {
                        withAnimation(DS.Motion.quick) { model.settings.setExpanded(.networkPurity, false) }
                    }
                }
            }
        }
    }

    /// 置信度高的绿、中等的灰、低的黄
    static func confidenceColor(_ confidence: Int) -> Color {
        confidence >= 80 ? DS.Palette.success : confidence >= 50 ? DS.Palette.textSecondary : DS.Palette.warning
    }

    static func riskLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "very clean": tr("非常干净")
        case "clean": tr("干净")
        case "low risk", "low": tr("低风险")
        case "medium risk", "medium", "moderate": tr("中等风险")
        case "high risk", "high": tr("高风险")
        case "very high risk", "critical": tr("极高风险")
        default: raw
        }
    }

    static func flagLabel(_ flag: String) -> String {
        switch flag {
        case "vpn": "VPN"
        case "proxy": tr("代理")
        case "residentialProxy": tr("住宅代理")
        case "tor": "Tor"
        case "relay": tr("中继")
        case "datacenter": tr("机房")
        case "hosting": tr("托管")
        case "abuser": tr("滥用记录")
        default: flag
        }
    }
}

// MARK: - DNS

private struct DNSSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isPopover) private var isPopover
    @State private var editingManual = false
    @State private var manualText = ""

    var body: some View {
        // 菜单栏弹窗里默认收起成一行，只显示正在使用的 DNS
        if isPopover, !model.settings.isExpanded(.networkDNS) {
            let servers = model.network.details?.dnsServers ?? []
            CollapsedSection(title: PopoverSection.networkDNS.title,
                             summary: servers.first.map { servers.count > 1 ? "\($0) +\(servers.count - 1)" : $0 } ?? "—") {
                withAnimation(DS.Motion.quick) { model.settings.setExpanded(.networkDNS, true) }
            }
        } else {
            card
        }
    }

    @ViewBuilder
    private var card: some View {
        let network = model.network
        let maintenance = model.maintenance
        let physical = network.details?.physical
        let manual = physical?.manualDNS ?? []
        let matched = DNSPreset.matching(manual)

        // 走代理隧道时标题旁放一个叹号，悬停才显示说明；刷新缓存是图标按钮，放在标题行右侧
        let tunnelWarning = network.details?.tunnel.map { tunnel in
            AnyView(Image(systemName: "exclamationmark.circle")
                .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                .foregroundStyle(DS.Palette.warning)
                .help(tr("流量经过 \(tunnel.name)，系统 DNS 可能由它接管，修改后不一定生效。"))
                .accessibilityLabel(tr("流量经过 \(tunnel.name)，系统 DNS 可能由它接管，修改后不一定生效。")))
        }
        // 网络服务与线路做成两个徽章：Wi-Fi / 有线，直连或经过哪个代理
        let actions = HStack(spacing: DS.Space.s2) {
            if let physical {
                TagBadge(icon: physical.wifi != nil ? "wifi" : "cable.connector", text: physical.serviceName, tone: .neutral, compact: true)
                if let tunnel = network.details?.tunnel {
                    TagBadge(icon: "globe", text: tr("经 \(tunnel.name)"), tone: .primary, compact: true)
                } else {
                    TagBadge(icon: "arrow.right", text: tr("直连"), tone: .neutral, compact: true)
                }
            }
            RefreshButton(loading: maintenance.running == .flushDNS, help: tr("刷新 DNS 缓存")) {
                Task { await maintenance.run(.flushDNS) }
            }
            .disabled(maintenance.running != nil)
        }
        SectionCard(title: PopoverSection.networkDNS.title, titleAccessory: tunnelWarning, trailing: {
            if isPopover {
                actions.collapseButton(.networkDNS, settings: model.settings)
            } else {
                actions
            }
        }) {
            InfoRow(label: tr("正在使用")) {
                Text(verbatim: network.details.map { $0.dnsServers.isEmpty ? "—" : $0.dnsServers.joined(separator: "\n") } ?? "—")
            }
            // 配置方式直接是一个下拉菜单：选预设立即切换，选“手动”展开输入框；比六个并排的按钮省两行
            if let physical {
                let isCustom = !manual.isEmpty && matched == nil
                HStack(spacing: DS.Space.s2) {
                    Text(tr("配置方式")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    Spacer(minLength: DS.Space.s2)
                    if isCustom, !editingManual {
                        MiniIconButton(systemName: "pencil", help: tr("修改地址")) {
                            manualText = manual.joined(separator: ", ")
                            editingManual = true
                        }
                    }
                    Picker(tr("配置方式"), selection: Binding<DNSPreset?>(
                        get: { editingManual ? nil : manual.isEmpty ? .automatic : matched },
                        set: { choice in
                            if let choice {
                                editingManual = false
                                apply(choice.servers, service: physical.serviceName)
                            } else {
                                manualText = manual.joined(separator: ", ")
                                editingManual = true
                            }
                        })) {
                        ForEach(DNSPreset.allCases) { preset in
                            Text(preset.title).tag(DNSPreset?.some(preset))
                        }
                        Divider()
                        Text(tr("手动")).tag(DNSPreset?.none)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(maintenance.isApplyingDNS)
                }
            } else {
                InfoRow(label: tr("配置方式"), text: manual.isEmpty ? tr("自动（由路由器分配）") : matched?.title ?? tr("手动"))
            }

            if let physical {
                if editingManual {
                    HStack(spacing: DS.Space.s2) {
                        TextField(tr("例如 1.1.1.1, 8.8.8.8"), text: $manualText)
                            .textFieldStyle(.plain)
                            .dsFont(.xs)
                            .padding(.horizontal, DS.Space.s2)
                            .frame(height: DS.Size.controlHeight)
                            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Palette.neutral300, lineWidth: DS.Size.stroke))
                            .onSubmit { applyManual(service: physical.serviceName) }
                        Button(tr("应用")) { applyManual(service: physical.serviceName) }
                            .buttonStyle(DSButtonStyle(kind: .primary))
                            .disabled(DNSConfiguration.parse(manualText)?.isEmpty != false)
                    }
                }
            }

            if maintenance.isApplyingDNS {
                Text(tr("正在修改 DNS…")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            } else if let outcome = maintenance.dnsOutcome ?? maintenance.outcomes[.flushDNS] {
                Text(outcome.text)
                    .dsFont(.xs)
                    .foregroundStyle(outcome.isError ? DS.Palette.error : DS.Palette.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func applyManual(service: String) {
        guard let servers = DNSConfiguration.parse(manualText), !servers.isEmpty else { return }
        editingManual = false
        apply(servers, service: service)
    }

    private func apply(_ servers: [String], service: String) {
        Task {
            await model.maintenance.setDNSServers(servers, service: service)
            await model.network.refreshDetails()
        }
    }
}

// MARK: - 进程

private struct NetworkProcessesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let processes = model.network.processes

        SectionCard(title: PopoverSection.networkProcesses.title, trailing: {
            HStack(spacing: 0) {
                Text(tr("下载")).frame(width: DS.Size.valueColumn, alignment: .trailing)
                Text(tr("上传")).frame(width: DS.Size.valueColumn, alignment: .trailing)
            }
        }) {
            ProcessList(count: processes.count, rowCount: 5, emptyText: tr("正在统计各进程流量…")) { index in
                let process = processes[index]
                HStack(spacing: 0) {
                    ProcessNameLabel(icon: AppIconCache.shared.image(bundlePath: process.appBundlePath), name: process.localizedName)
                    Text(verbatim: Format.menuBarRate(process.download))
                        .frame(width: DS.Size.valueColumn, alignment: .trailing)
                    Text(verbatim: Format.menuBarRate(process.upload))
                        .frame(width: DS.Size.valueColumn, alignment: .trailing)
                }
                .dsFont(.xs)
                .monospacedDigit()
                .foregroundStyle(DS.Palette.textSecondary)
                .explainable(.init(process))
            }
        }
    }
}
