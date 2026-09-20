// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import AppKit
import Localization
import Metrics
import SwiftUI

/// 出口与分流窗口：总览（结论、统计、本机网络 → 代理出口的线路）、网站分流表、本机的代理方式
struct EgressWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let egress = model.egress
        VStack(spacing: 0) {
            // 滚动视图会自动向上延伸到标题栏下面：顶栏垫上底色、放在它之上，滚动的内容才不会盖住按钮
            EgressHeader()
                .background(DS.Palette.background)
                .zIndex(1)
            PageScroll {
                if let report = egress.report, let analysis = egress.analysis {
                    let context = EgressContext(report: report, analysis: analysis)
                    OverviewCard(context: context)
                    SitesCard(context: context)
                    EnvironmentCard(environment: egress.environment ?? report.environment)
                    EgressFootnote()
                } else {
                    FirstCheckCard()
                }
            }
        }
        .background(DS.Palette.background)
        // 内容延伸到透明标题栏下方，顶栏与红绿灯按钮在同一行
        .ignoresSafeArea()
        .appLanguageEnvironment()
    }
}

/// 视图共用的查询：某个目标的测量、某个出口的归属地
private struct EgressContext {
    let report: EgressController.Report
    let analysis: EgressAnalysis

    func hit(_ target: EgressTarget, _ route: EgressRoute) -> EgressHit? {
        EgressAnalysis.hit(report.hits, target, route)
    }

    func geo(_ ip: String?) -> EgressGeo? {
        ip.flatMap { report.geo[$0] }
    }

    /// 网站表里的条目（不含基准目标），按出口分组后的数量
    var siteCounts: (proxy: Int, direct: Int, unknown: Int, failed: Int) {
        let siteIDs = Set(EgressTarget.sites.map(\.id))
        var counts = (proxy: 0, direct: 0, unknown: 0, failed: 0)
        for exit in analysis.exits {
            let count = exit.entries.filter { siteIDs.contains($0.targetID) }.count
            switch exit.path {
            case .proxy: counts.proxy += count
            case .direct: counts.direct += count
            case .unknown: counts.unknown += count
            }
        }
        counts.unknown += analysis.unassignedTargetIDs.filter(siteIDs.contains).count
        counts.failed = analysis.failedTargetIDs.filter(siteIDs.contains).count
        return counts
    }
}

// MARK: - 顶栏

private struct EgressHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let egress = model.egress
        HStack(spacing: DS.Space.s3) {
            HStack(spacing: 0) {
                Text(tr("出口与分流"))
                    .dsFont(.base, weight: .semibold)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer(minLength: DS.Space.s3)
            }
            .frame(maxHeight: .infinity)
            .background(WindowDragArea())

            if let date = egress.report?.date, !egress.isChecking {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(verbatim: EgressText.checkedAt(date, now: context.date))
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }
            Button { egress.check() } label: {
                HStack(spacing: DS.Space.s1) {
                    if egress.isChecking {
                        ProgressView().controlSize(.mini)
                        Text(tr("检测中 \(egress.progress)/\(EgressProber.jobCount)")).monospacedDigit()
                    } else {
                        Image(systemName: "arrow.clockwise")
                        Text(tr("重新检测"))
                    }
                }
                .lineLimit(1)
                .fixedSize()
            }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(egress.isChecking)
        }
        // 让出红绿灯按钮，再隔开一段，标题不贴着最右边的按钮
        .padding(.leading, DS.Size.trafficLightsWidth + DS.Space.s4)
        .padding(.trailing, DS.Space.s3 + DS.Space.s1)
        .frame(height: DS.Size.windowHeader)
    }
}

private struct FirstCheckCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(spacing: DS.Space.s3) {
            Text(tr("正在检测出口与分流…"))
                .dsFont(.base, weight: .semibold)
                .foregroundStyle(DS.Palette.textPrimary)
            ProgressView(value: Double(model.egress.progress), total: Double(EgressProber.jobCount))
                .tint(DS.Palette.primary)
            Text(tr("分别经物理网卡、系统代理与 VPN 隧道访问检测目标，约需 10 秒。"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

// MARK: - 总览

private struct OverviewCard: View {
    @Environment(AppModel.self) private var model
    let context: EgressContext

    var body: some View {
        let analysis = context.analysis
        let summary = EgressText.verdict(analysis, report: context.report)
        Card(spacing: DS.Space.s4) {
            HStack(alignment: .top, spacing: DS.Space.s3) {
                Image(systemName: summary.icon)
                    .font(.system(size: DS.TextSize.lg.rawValue, weight: .semibold))
                    .foregroundStyle(summary.tone.color)
                    .frame(width: DS.Space.s8 + DS.Space.s2, height: DS.Space.s8 + DS.Space.s2)
                    .background(summary.tone.color.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    Text(verbatim: summary.title)
                        .dsFont(.lg, weight: .semibold)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text(verbatim: summary.detail)
                        .dsFont(.sm)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.s4)
                SiteStats(counts: context.siteCounts, verified: analysis.verdict != .unverified)
            }

            HairlineDivider()
            RouteDiagram(context: context)

            if model.egress.networkChanged || !analysis.findings.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    if model.egress.networkChanged {
                        InfoBanner(icon: "arrow.triangle.2.circlepath", text: tr("网络环境变了，下面是之前的结果，正在重新检测。"), tone: .primary)
                    }
                    ForEach(Array(analysis.findings.enumerated()), id: \.offset) { _, finding in
                        let banner = EgressText.finding(finding)
                        InfoBanner(icon: banner.icon, text: banner.text, tone: banner.tone)
                    }
                }
            }
        }
    }
}

private struct SiteStats: View {
    let counts: (proxy: Int, direct: Int, unknown: Int, failed: Int)
    let verified: Bool

    var body: some View {
        HStack(spacing: DS.Space.s4) {
            if verified {
                stat(tr("经代理"), counts.proxy, tone: .primary)
                divider
                stat(tr("直连"), counts.direct, tone: .neutral)
            } else {
                stat(tr("可访问"), counts.proxy + counts.direct + counts.unknown, tone: .neutral)
            }
            divider
            stat(tr("连不上"), counts.failed, tone: counts.failed > 0 ? .error : .neutral)
        }
        .fixedSize()
    }

    private var divider: some View {
        Rectangle().fill(DS.Palette.border).frame(width: DS.Size.stroke, height: DS.Space.s8)
    }

    private func stat(_ label: String, _ value: Int, tone: Tone) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: "\(value)")
                .dsFont(.xl, weight: .semibold)
                .foregroundStyle(tone == .neutral ? DS.Palette.textPrimary : tone.color)
                .monospacedDigit()
            Text(verbatim: label)
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

/// 本机网络 ──代理──▶ 代理出口。没有代理出口时只画本机网络
private struct RouteDiagram: View {
    let context: EgressContext

    var body: some View {
        let analysis = context.analysis
        let environment = context.report.environment
        let rawV4 = context.hit(.cloudflare, .interface)?.ip ?? context.hit(.domestic, .interface)?.ip
        let rawV6 = context.hit(.cloudflareIPv6, .interface)?.ip
        let proxyExits = analysis.exits.filter { $0.path != .direct }
        let primary = proxyExits.first

        HStack(alignment: .top, spacing: DS.Space.s4) {
            ExitNode(caption: tr("本机网络"),
                     subtitle: environment.physicalName.map { tr("经 \($0) 直接连接") } ?? tr("不经过代理"),
                     ipv4: rawV4, ipv6: rawV6, geo: context.geo(rawV4) ?? context.geo(rawV6),
                     country: context.hit(.cloudflare, .interface)?.country,
                     missing: tr("VPN 不允许绕开它连接"))
            if let primary {
                RouteConnector(name: environment.tunnelName ?? environment.apps.first ?? tr("代理"),
                               detail: environment.tunnelInterface ?? (environment.proxies.isEmpty ? nil : tr("系统代理")))
                let systemV6 = context.hit(.cloudflareIPv6, .system)?.ip
                ExitNode(caption: primary.path == .unknown ? tr("出口") : tr("代理出口"),
                         subtitle: proxyExits.count > 1 ? tr("另有 \(proxyExits.count - 1) 个出口，见网站分流") : tr("按系统代理访问国际网站"),
                         ipv4: primary.ip.contains(":") ? nil : primary.ip,
                         ipv6: primary.ip.contains(":") ? primary.ip : systemV6,
                         geo: context.geo(primary.ip), country: primary.country, missing: "—")
            }
        }
    }
}

private struct RouteConnector: View {
    let name: String
    let detail: String?

    var body: some View {
        VStack(spacing: DS.Space.s1) {
            Text(verbatim: name)
                .dsFont(.xs, weight: .semibold)
                .foregroundStyle(DS.Palette.primary)
                .lineLimit(1)
            HStack(spacing: 0) {
                Circle().fill(DS.Palette.primary).frame(width: DS.Space.s1 + DS.Space.s1 / 2, height: DS.Space.s1 + DS.Space.s1 / 2)
                Rectangle().fill(DS.Palette.primary.opacity(0.5)).frame(height: DS.Size.stroke)
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: DS.TextSize.xs.rawValue - DS.Space.s1))
                    .foregroundStyle(DS.Palette.primary)
            }
            if let detail {
                Text(verbatim: detail)
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: DS.Space.s16 + DS.Space.s12)
        .padding(.top, DS.Space.s6)
    }
}

private struct ExitNode: View {
    let caption: String
    let subtitle: String
    let ipv4: String?
    let ipv6: String?
    let geo: EgressGeo?
    let country: String?
    let missing: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s1) {
                Text(verbatim: caption).dsFont(.xs, weight: .semibold).foregroundStyle(DS.Palette.textSecondary)
                Text(verbatim: subtitle).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
            }
            if let address = ipv4 ?? ipv6 {
                HStack(spacing: DS.Space.s2) {
                    if let code = geo?.countryCode ?? country { FlagImage(countryCode: code, height: DS.Space.s4) }
                    CopyableText(text: address)
                        .dsFont(.lg, weight: .semibold)
                        .monospacedDigit()
                }
                .padding(.top, DS.Space.s1)
                let location = EgressText.location(geo, fallback: country)
                if !location.isEmpty {
                    Text(verbatim: location).dsFont(.sm).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                }
                HStack(spacing: DS.Space.s2) {
                    if let organization = geo?.organization {
                        Text(verbatim: organization)
                            .dsFont(.xs)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let type = geo?.ipType.flatMap(EgressText.ipTypeBadge) {
                        TagBadge(text: type.text, tone: type.tone, compact: true)
                    }
                }
                if ipv4 != nil {
                    if let ipv6 {
                        HStack(spacing: DS.Space.s1) {
                            Text(verbatim: "IPv6").dsFont(.xs, weight: .medium).foregroundStyle(DS.Palette.textTertiary)
                            CopyableText(text: ipv6).dsFont(.xs).monospacedDigit()
                        }
                    } else {
                        Text(tr("不支持 IPv6")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
            } else {
                Text(verbatim: missing)
                    .dsFont(.sm)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .padding(.top, DS.Space.s1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 网站分流

private enum SiteFilter: Hashable, CaseIterable {
    case all, ai, media, social, developer, domestic

    var title: String {
        switch self {
        case .all: tr("全部")
        case .ai: "AI"
        case .media: tr("影音")
        case .social: tr("社交")
        case .developer: tr("开发")
        case .domestic: tr("国内")
        }
    }

    func includes(_ target: EgressTarget) -> Bool {
        switch self {
        case .all: true
        case .ai: target.category == .ai
        case .media: target.category == .media
        case .social: target.category == .social
        case .developer: target.category == .developer
        case .domestic: target.category == .domestic
        }
    }
}

private struct SitesCard: View {
    let context: EgressContext
    @State private var filter = SiteFilter.all

    var body: some View {
        let groups = siteGroups
        Card(padding: 0, spacing: 0) {
            HStack(spacing: DS.Space.s3) {
                VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                    Text(tr("网站分流")).dsFont(.base, weight: .semibold).foregroundStyle(DS.Palette.textPrimary)
                    Text(tr("接入 Cloudflare 的网站能实测出口，其余按国内 / 国际规则推断"))
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.s3)
                SegmentedControl(selection: $filter, options: SiteFilter.allCases.map { ($0, $0.title) })
                    .frame(width: DS.Size.sidebarWidth * 2)
            }
            .padding(DS.Space.s4)

            SiteColumnsHeader()
            ForEach(groups) { group in
                SiteGroupHeader(group: group, context: context)
                ForEach(group.rows, id: \.target.id) { row in
                    SiteTableRow(target: row.target, hit: context.hit(row.target, .system), measured: row.measured, failed: group.kind == .failed)
                }
            }
            if groups.isEmpty {
                Text(tr("这一类没有检测结果"))
                    .dsFont(.sm)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .frame(maxWidth: .infinity)
                    .padding(DS.Space.s6)
            }
            // 最后一行的悬停底色不贴到卡片圆角
            Color.clear.frame(height: DS.Space.s2)
        }
    }

    struct SiteGroup: Identifiable {
        enum Kind: Equatable { case exit(EgressAnalysis.Exit), unassigned, failed }
        let kind: Kind
        let rows: [(target: EgressTarget, measured: Bool)]
        var id: String {
            switch kind {
            case .exit(let exit): exit.ip
            case .unassigned: "unassigned"
            case .failed: "failed"
            }
        }
    }

    private var siteGroups: [SiteGroup] {
        let analysis = context.analysis
        func target(_ id: String) -> EgressTarget? {
            EgressTarget.sites.first { $0.id == id && filter.includes($0) }
        }
        var groups: [SiteGroup] = []
        for exit in analysis.exits {
            let rows = exit.entries.compactMap { entry in target(entry.targetID).map { ($0, entry.measured) } }
            if !rows.isEmpty { groups.append(SiteGroup(kind: .exit(exit), rows: rows)) }
        }
        let unassigned = analysis.unassignedTargetIDs.compactMap(target).map { ($0, false) }
        if !unassigned.isEmpty { groups.append(SiteGroup(kind: .unassigned, rows: unassigned)) }
        let failed = analysis.failedTargetIDs.compactMap(target).map { ($0, false) }
        if !failed.isEmpty { groups.append(SiteGroup(kind: .failed, rows: failed)) }
        return groups
    }
}

/// 列宽：出口依据、Cloudflare 节点、延迟
private enum SiteColumn {
    static let basis = DS.Size.valueColumn
    static let colo = DS.Size.labelColumn
    static let latency = DS.Size.valueColumn + DS.Space.s12
}

private struct SiteColumnsHeader: View {
    var body: some View {
        HStack(spacing: DS.Space.s3) {
            Text(tr("网站")).frame(maxWidth: .infinity, alignment: .leading)
            Text(tr("出口依据")).frame(width: SiteColumn.basis, alignment: .leading)
            Text(tr("节点")).frame(width: SiteColumn.colo, alignment: .leading)
                .help(tr("Cloudflare 接入节点（机场代码）"))
            Text(tr("延迟")).frame(width: SiteColumn.latency, alignment: .trailing)
        }
        .dsFont(.xs, weight: .medium)
        .foregroundStyle(DS.Palette.textTertiary)
        .padding(.horizontal, DS.Space.s4)
        .padding(.bottom, DS.Space.s2)
    }
}

private struct SiteGroupHeader: View {
    let group: SitesCard.SiteGroup
    let context: EgressContext

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            switch group.kind {
            case .exit(let exit):
                let badge = EgressText.pathBadge(exit.path)
                let geo = context.geo(exit.ip)
                TagBadge(icon: badge.icon, text: badge.text, tone: badge.tone, compact: true)
                if let code = geo?.countryCode ?? exit.country { FlagImage(countryCode: code) }
                CopyableText(text: exit.ip)
                    .dsFont(.xs, weight: .semibold)
                    .monospacedDigit()
                let location = EgressText.location(geo, fallback: exit.country)
                if !location.isEmpty {
                    Text(verbatim: location)
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
            case .unassigned:
                TagBadge(icon: "questionmark.circle", text: tr("出口未知"), tone: .neutral, compact: true)
            case .failed:
                TagBadge(icon: "xmark.circle.fill", text: tr("连不上"), tone: .warning, compact: true)
            }
            Spacer(minLength: DS.Space.s2)
            Text(tr("\(group.rows.count) 个网站"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .fixedSize()
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.track)
    }
}

private struct SiteTableRow: View {
    let target: EgressTarget
    let hit: EgressHit?
    let measured: Bool
    let failed: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s3) {
                SiteLogo(name: target.logo, fallback: target.name)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: target.name).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                    Text(verbatim: target.host).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if failed {
                    Text(verbatim: "—").foregroundStyle(DS.Palette.textTertiary)
                } else if measured {
                    Label(tr("实测"), systemImage: "checkmark.circle.fill").foregroundStyle(DS.Palette.success)
                } else {
                    Label(tr("推断"), systemImage: "circle.dashed").foregroundStyle(DS.Palette.textTertiary)
                }
            }
            .labelStyle(CompactLabelStyle())
            .dsFont(.xs)
            .frame(width: SiteColumn.basis, alignment: .leading)
            .help(measured ? tr("读到了这次连接的出口") : failed ? "" : tr("网站没有接入 Cloudflare，读不到出口，按国内 / 国际规则归到对应出口"))

            Text(verbatim: hit?.colo ?? "—")
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .monospaced()
                .frame(width: SiteColumn.colo, alignment: .leading)

            LatencyCell(milliseconds: failed ? nil : hit?.milliseconds)
                .frame(width: SiteColumn.latency, alignment: .trailing)
        }
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s2)
        .background(hovering ? DS.Palette.surfaceHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: DS.Space.s1) {
            configuration.icon
            configuration.title
        }
    }
}

/// 网站图标放在浅色圆角底上，深色模式下黑色字标也看得清；没有图标时显示首字
private struct SiteLogo: View {
    let name: String?
    let fallback: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.md - DS.Space.s1 / 2, style: .continuous)
                .fill(DS.Palette.logoTile)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md - DS.Space.s1 / 2, style: .continuous)
                    .strokeBorder(DS.Palette.border, lineWidth: DS.Size.stroke))
            if let name, let image = LogoCache.shared.image(named: name, template: false) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
            } else {
                Text(verbatim: String(fallback.prefix(1)))
                    .dsFont(.xs, weight: .semibold)
                    .foregroundStyle(DS.Palette.neutral500)
            }
        }
        .frame(width: DS.Space.s6 + DS.Space.s1, height: DS.Space.s6 + DS.Space.s1)
        .accessibilityHidden(true)
    }
}

/// 5 格信号条 + 毫秒数：越快格子越多，颜色按快慢分绿、橙、红
private struct LatencyCell: View {
    let milliseconds: Int?

    var body: some View {
        let tone = milliseconds.map(Self.tone) ?? .error
        let filled = milliseconds.map(Self.bars) ?? 0
        HStack(spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1 / 2) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: DS.Size.stroke)
                        .fill(index < filled ? tone.color : DS.Palette.track)
                        .frame(width: DS.Space.s1, height: DS.Space.s3)
                }
            }
            Text(verbatim: milliseconds.map { "\($0) ms" } ?? tr("超时"))
                .dsFont(.xs, weight: .medium)
                .foregroundStyle(milliseconds == nil ? DS.Palette.error : DS.Palette.textPrimary)
                .monospacedDigit()
                .frame(width: DS.Size.valueColumn, alignment: .trailing)
        }
    }

    static func tone(_ milliseconds: Int) -> Tone {
        milliseconds < 300 ? .success : milliseconds < 1000 ? .warning : .error
    }

    static func bars(_ milliseconds: Int) -> Int {
        switch milliseconds {
        case ..<150: 5
        case ..<300: 4
        case ..<600: 3
        case ..<1000: 2
        default: 1
        }
    }
}

// MARK: - 代理方式

private struct EnvironmentCard: View {
    let environment: ProxyEnvironment

    var body: some View {
        SectionCard(title: tr("代理方式")) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s8), GridItem(.flexible())],
                      alignment: .leading, spacing: DS.Space.s2) {
                InfoRow(label: tr("VPN / 隧道"),
                        text: environment.tunnelName.map { name in
                            [name, environment.tunnelInterface].compactMap { $0 }.joined(separator: " · ")
                        } ?? tr("未使用"))
                InfoRow(label: tr("系统代理"), text: systemProxy)
                InfoRow(label: "DNS", text: dns)
                InfoRow(label: tr("代理软件"), text: environment.apps.isEmpty ? tr("未发现") : environment.apps.joined(separator: tr("、")))
            }
        }
    }

    /// 同一地址的几种代理合成一条：HTTP、HTTPS 127.0.0.1:6152
    private var systemProxy: String {
        var groups: [(address: String, kinds: [String])] = []
        for proxy in environment.proxies {
            let address = "\(proxy.host):\(proxy.port)"
            let kind = proxy.kind.rawValue.uppercased()
            if let index = groups.firstIndex(where: { $0.address == address }) {
                groups[index].kinds.append(kind)
            } else {
                groups.append((address, [kind]))
            }
        }
        var parts = groups.map { "\($0.kinds.joined(separator: "/")) \($0.address)" }
        if environment.pacURL != nil { parts.append(tr("自动代理配置")) }
        return parts.isEmpty ? tr("未设置") : parts.joined(separator: "\n")
    }

    private var dns: String {
        guard !environment.dnsServers.isEmpty else { return "—" }
        let servers = environment.dnsServers.joined(separator: ", ")
        return environment.usesFakeIPDNS ? tr("\(servers)（代理接管）") : servers
    }
}

private struct EgressFootnote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
            Text(tr("归属地数据来自")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            CleanIPLink(height: DS.Space.s3, url: URL(string: "https://cleanip.io/outbound")!, help: "cleanip.io/outbound")
            Text(tr("· 结果反映 XStats 自己发出的请求，按应用分流的规则下其他应用可能走不同出口"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, DS.Space.s1)
    }
}

// MARK: - 文案

@MainActor
private enum EgressText {
    struct Summary {
        let icon: String
        let tone: Tone
        let title: String
        let detail: String
    }

    static func verdict(_ analysis: EgressAnalysis, report: EgressController.Report) -> Summary {
        let environment = report.environment
        let proxyName = environment.tunnelName ?? environment.apps.first ?? tr("代理")
        let proxyExit = analysis.exits.first { $0.path == .proxy }
        let proxyLocation = proxyExit.map { location(report.geo[$0.ip], fallback: $0.country) } ?? ""
        let exitText = proxyLocation.isEmpty ? tr("代理出口") : tr("代理出口（\(proxyLocation)）")

        switch analysis.verdict {
        case .offline:
            return Summary(icon: "wifi.exclamationmark", tone: .error, title: tr("网络不通"),
                           detail: tr("所有检测目标都连不上。请检查网络连接，或者代理软件是否正常运行。"))
        case .noProxy:
            return Summary(icon: "checkmark", tone: .success, title: tr("未使用代理"),
                           detail: tr("没有检测到 VPN 或系统代理，所有流量都从本机网络直接出去。"))
        case .proxyInactive:
            return Summary(icon: "exclamationmark", tone: .warning, title: tr("代理没有生效"),
                           detail: tr("检测到 \(proxyName)，但测试的网站都在直连，没有经过代理出口。"))
        case .split:
            return Summary(icon: "checkmark", tone: .success, title: tr("分流正常"),
                           detail: tr("国内网站直连，国际网站经 \(proxyName) 的\(exitText)。"))
        case .mixed:
            return Summary(icon: "arrow.triangle.branch", tone: .primary, title: tr("按规则分流"),
                           detail: tr("部分网站直连、部分经代理，每个网站走哪个出口见下方。"))
        case .fullProxy where analysis.rawCountry == "CN":
            return Summary(icon: "exclamationmark", tone: .warning, title: tr("全局代理"),
                           detail: tr("国内网站也绕到了\(exitText)，访问会变慢，也可能触发风控。"))
        case .fullProxy:
            return Summary(icon: "checkmark", tone: .success, title: tr("全部经代理"),
                           detail: tr("测试的网站都经 \(proxyName) 的\(exitText)，没有暴露本机网络的地址。"))
        case .unverified:
            return Summary(icon: "questionmark", tone: .primary, title: tr("无法确认是否经过代理"),
                           detail: tr("VPN 不允许绕开它连接，读不到本机网络原本的出口。下方按出口列出各网站。"))
        }
    }

    static func finding(_ finding: EgressAnalysis.Finding) -> (icon: String, text: String, tone: Tone) {
        switch finding {
        case .ipv6Leak(let address):
            ("exclamationmark.triangle.fill", tr("IPv6 没有经过代理：只走 IPv6 的连接会直接暴露本机地址 \(address)。"), .warning)
        case .ipv6Blocked:
            ("checkmark.shield.fill", tr("代理出口不支持 IPv6，IPv6 连接也不会绕过代理泄露地址。"), .success)
        case .ipv6Proxied:
            ("checkmark.shield.fill", tr("IPv6 连接也经过代理。"), .success)
        case .socketBypass:
            ("exclamationmark.triangle.fill",
             tr("只设置了系统代理：浏览器等应用走代理，命令行工具、游戏等不读代理设置的程序仍在直连。要接管全部流量，可以开启增强模式或 TUN 模式。"), .warning)
        case .domesticProxied:
            ("exclamationmark.triangle.fill", tr("国内网站走了代理，访问会绕路变慢。"), .warning)
        }
    }

    static func pathBadge(_ path: EgressAnalysis.Path) -> (icon: String, text: String, tone: TagBadge.Tone) {
        switch path {
        case .proxy: ("globe", tr("经代理"), .primary)
        case .direct: ("house.fill", tr("直连"), .neutral)
        case .unknown: ("circle.dashed", tr("出口"), .neutral)
        }
    }

    static func ipTypeBadge(_ raw: String) -> (text: String, tone: TagBadge.Tone)? {
        let type = raw.lowercased()
        if type.contains("residential") { return (tr("住宅 IP"), .success) }
        if type.contains("mobile") { return (tr("移动网络 IP"), .success) }
        if type.contains("business") { return (tr("企业 IP"), .success) }
        if type.contains("idc") || type.contains("datacenter") || type.contains("hosting") { return (tr("机房 IP"), .warning) }
        return nil
    }

    /// 国家 · 省 / 州 · 城市；英文界面优先用英文地名，重复的相邻项只留一个
    static func location(_ geo: EgressGeo?, fallback country: String?) -> String {
        guard let code = geo?.countryCode ?? country else { return "" }
        let name = L10n.locale.localizedString(forRegionCode: code) ?? code
        let region = L10n.usesEnglishNames ? (geo?.regionEnglish ?? geo?.region) : geo?.region
        let city = L10n.usesEnglishNames ? (geo?.cityEnglish ?? geo?.city) : geo?.city
        var parts = [name]
        for part in [region, city].compactMap({ $0 }) where part != parts.last { parts.append(part) }
        return parts.joined(separator: " · ")
    }

    static func checkedAt(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? tr("刚刚检测") : tr("\(Format.duration(minutes: minutes))前检测")
    }
}
