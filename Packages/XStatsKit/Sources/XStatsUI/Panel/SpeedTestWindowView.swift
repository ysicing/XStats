// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Localization
import Metrics
import SwiftUI

/// 网络测速窗口：本机宽带、国内分省三网延迟、全球节点、全球探针看目标
struct SpeedTestWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            // 滚动内容会延伸到标题栏下面：顶栏垫底色压在上面，红绿灯按钮才不会被盖住
            SpeedTestHeader()
                .background(DS.Palette.background)
                .zIndex(1)
            PageScroll {
                RouteBanner()
                BroadbandCard()
                ChinaLatencyCard()
                GlobalNodeCard()
                GlobalpingCard()
            }
        }
        .background(DS.Palette.background)
        .ignoresSafeArea()
        .appLanguageEnvironment()
    }
}

// MARK: - 顶栏

private struct SpeedTestHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let speedTest = model.speedTest
        HStack(spacing: DS.Space.s3) {
            HStack(spacing: 0) {
                Text(tr("网络测速"))
                    .dsFont(.base, weight: .semibold)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .fixedSize()
                Spacer(minLength: DS.Space.s3)
            }
            .frame(maxHeight: .infinity)
            .background(WindowDragArea())

            if speedTest.bytesUsed > 0 {
                // 窗口窄时让它截断，不去挤标题
                Text(tr("本次用掉 \(Format.bytes(Double(speedTest.bytesUsed)))"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            SegmentedControl(selection: $settings.speedTestBudget,
                             options: SpeedTestBudget.allCases.map { ($0, SpeedText.budget($0)) })
                .frame(width: DS.Size.sidebarWidth + DS.Space.s16 * 2 + DS.Space.s4)
                .help(tr("单个节点一次测速最多花的时间与流量，先到哪个停哪个"))
        }
        // 让出红绿灯按钮，再隔开一段，标题不贴着最右边的按钮
        .padding(.leading, Self.titleLeading)
        .padding(.trailing, DS.Space.s3 + DS.Space.s1)
        .frame(height: DS.Size.windowHeader)
    }

    /// 三颗红绿灯按钮加间距约 80pt，标题从它们右边再隔一段开始（与出口与分流窗口一致）
    static let titleLeading = DS.Size.trafficLightsWidth + DS.Space.s4
}

/// 测速窗口里的一张卡片：图标标题行 + 一行说明 + 内容
private struct SpeedSection<Trailing: View, Content: View>: View {
    let icon: String
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        Card {
            CardHeader(icon: icon, title: title) { trailing }
            if let subtitle {
                Text(subtitle).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
            content
        }
    }
}

/// 开始 / 停止：跑起来之后同一个按钮变成停止
private struct RunButton: View {
    let isRunning: Bool
    var title: String = tr("开始")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.s1) {
                if isRunning {
                    ProgressView().controlSize(.mini)
                    Text(tr("停止"))
                } else {
                    Image(systemName: "play.fill")
                    Text(title)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(DSButtonStyle(kind: isRunning ? .secondary : .primary))
    }
}

// MARK: - 线路

/// 开着 VPN / 代理时才出现：选直连（绕开它测本机宽带）还是经它测代理线路
private struct RouteBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let speedTest = model.speedTest
        if speedTest.hasProxy {
            let name = speedTest.proxyName
            InfoBanner(icon: "arrow.triangle.branch",
                       text: tr("检测到 \(name)。直连会绕开它，测的是本机宽带；经 \(name) 测的是代理线路")) {
                SegmentedControl(selection: $settings.speedTestRoute,
                                 options: [(.direct, tr("直连")), (.proxy, tr("经 \(name)"))])
                    .fixedSize()
                    .onChange(of: settings.speedTestRoute) { speedTest.routeDidChange() }
            }
        }
    }
}

// MARK: - 本机宽带

private struct BroadbandCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let speedTest = model.speedTest
        let result = speedTest.broadband
        SpeedSection(icon: "gauge.with.dots.needle.67percent", title: tr("本机宽带"),
                     subtitle: SpeedText.broadbandStatus(speedTest)) {
            RunButton(isRunning: speedTest.isTestingBroadband, title: tr("测速")) { speedTest.runBroadband() }
        } content: {
            if speedTest.isTestingBroadband {
                LiveSpeed(bitsPerSecond: speedTest.liveBitsPerSecond, stage: speedTest.broadbandStage)
            }
            HStack(alignment: .top, spacing: DS.Space.s3) {
                SpeedStatTile(title: tr("下行"), value: SpeedText.rate(result?.download?.bitsPerSecond), tone: .primary)
                SpeedStatTile(title: tr("上行"), value: SpeedText.rate(result?.upload?.bitsPerSecond), tone: .primary)
                SpeedStatTile(title: tr("延迟"), value: SpeedText.milliseconds(result?.latencyMilliseconds), tone: .plain)
                SpeedStatTile(title: tr("抖动"), value: SpeedText.milliseconds(result?.jitterMilliseconds), tone: .plain)
            }
        }
    }
}

/// 测试进行中的实时速率
private struct LiveSpeed: View {
    let bitsPerSecond: Double
    let stage: BroadbandTest.Stage?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
            Text(verbatim: SpeedText.rate(bitsPerSecond > 0 ? bitsPerSecond : nil))
                .dsFont(.xl, weight: .semibold)
                .foregroundStyle(DS.Palette.primary)
                .monospacedDigit()
            Text(SpeedText.stage(stage)).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            Spacer(minLength: 0)
        }
    }
}

/// 指标块：上面小标题，下面大数字
private struct SpeedStatTile: View {
    enum Tone { case primary, plain }
    let title: String
    let value: String
    var tone: Tone = .plain
    /// 带运营商时，标题前面多一个运营商标志
    var carrier: ChinaCarrier?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(spacing: DS.Space.s1) {
                if let carrier { CarrierLogo(carrier: carrier) }
                Text(title).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
            Text(verbatim: value)
                .dsFont(.lg, weight: .semibold)
                .foregroundStyle(tone == .primary ? DS.Palette.primary : DS.Palette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 运营商标志，鼠标停留显示运营商名
private struct CarrierLogo: View {
    let carrier: ChinaCarrier

    var body: some View {
        Group {
            if let image = LogoCache.shared.image(named: "carrier-" + String(describing: carrier), template: false) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Text(verbatim: SpeedText.carrier(carrier)).dsFont(.xs, weight: .semibold)
            }
        }
        .frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
        .accessibilityElement()
        .accessibilityLabel(SpeedText.carrier(carrier))
        .help(SpeedText.carrier(carrier))
    }
}

// MARK: - 国内分省三网

private struct ChinaLatencyCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let speedTest = model.speedTest
        SpeedSection(icon: "map", title: tr("国内分省三网延迟"),
                     subtitle: speedTest.isTestingChina
                         ? tr("正在测 \(speedTest.chinaProgress)/\(ChinaNode.all.count)")
                         : SpeedText.status(route: speedTest.chinaRoute, date: speedTest.chinaDate, speedTest)) {
            RunButton(isRunning: speedTest.isTestingChina, title: tr("测延迟")) { speedTest.runChina() }
        } content: {
            if let notice = speedTest.chinaNotice {
                Text(notice).dsFont(.xs).foregroundStyle(DS.Palette.error)
            } else if speedTest.hasProxy && speedTest.chinaLatency.isEmpty {
                Text(tr("国内节点只能测 TCP 建连，经代理测不准，所以始终直连测"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
            if !speedTest.chinaLatency.isEmpty {
                HStack(spacing: DS.Space.s3) {
                    ForEach(ChinaCarrier.allCases, id: \.self) { carrier in
                        let counts = speedTest.chinaReachable(carrier)
                        SpeedStatTile(title: tr("中位延迟"),
                                      value: SpeedText.milliseconds(speedTest.chinaMedian(carrier)),
                                      carrier: carrier)
                            .help(tr("\(SpeedText.carrier(carrier))：\(counts.reachable)/\(counts.total) 个节点连得上"))
                    }
                }
                HairlineDivider()
                VStack(spacing: 0) {
                    HStack(spacing: DS.Space.s2) {
                        Text(tr("省份")).frame(width: DS.Space.s16 * 2, alignment: .leading)
                        ForEach(ChinaCarrier.allCases, id: \.self) { carrier in
                            CarrierLogo(carrier: carrier)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .padding(.vertical, DS.Space.s1)
                    ForEach(ChinaNode.provinces, id: \.code) { province in
                        HStack(spacing: DS.Space.s2) {
                            Text(L10n.usesEnglishNames ? province.english : province.name)
                                .dsFont(.xs)
                                .foregroundStyle(DS.Palette.textSecondary)
                                .lineLimit(1)
                                .frame(width: DS.Space.s16 * 2, alignment: .leading)
                            ForEach(ChinaCarrier.allCases, id: \.self) { carrier in
                                LatencyValue(speedTest.chinaLatency["\(province.code)-\(carrier.rawValue)"])
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .padding(.vertical, DS.Space.s1 / 2)
                    }
                }
            }
        }
    }
}

/// 延迟数值：按快慢着色，连不上显示横杠
private struct LatencyValue: View {
    let result: LatencyResult?

    init(_ result: LatencyResult?) {
        self.result = result
    }

    var body: some View {
        Text(verbatim: SpeedText.milliseconds(result?.best))
            .dsFont(.xs, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(color)
    }

    private var color: Color {
        guard let best = result?.best else { return DS.Palette.textTertiary }
        if best < 80 { return DS.Palette.success }
        if best < 200 { return DS.Palette.warning }
        return DS.Palette.error
    }
}

// MARK: - 全球节点

private struct GlobalNodeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let speedTest = model.speedTest
        SpeedSection(icon: "globe", title: tr("全球节点"),
                     subtitle: speedTest.isTestingGlobal
                         ? tr("正在测 \(speedTest.globalProgress)/\(GlobalNode.all.count)")
                         : SpeedText.status(route: speedTest.globalRoute, date: speedTest.globalDate, speedTest)) {
            RunButton(isRunning: speedTest.isTestingGlobal, title: tr("测延迟")) { speedTest.runGlobal() }
        } content: {
            ForEach(GlobalRegion.allCases, id: \.self) { region in
                let nodes = GlobalNode.all.filter { $0.region == region }
                if !nodes.isEmpty {
                    Text(L10n.usesEnglishNames ? region.nameEnglish : region.name)
                        .dsFont(.xs, weight: .medium)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .padding(.top, DS.Space.s1)
                    VStack(spacing: 0) {
                        ForEach(nodes) { node in
                            GlobalNodeRow(node: node)
                            if node.id != nodes.last?.id { HairlineDivider() }
                        }
                    }
                }
            }
        }
    }
}

private struct GlobalNodeRow: View {
    @Environment(AppModel.self) private var model
    let node: GlobalNode

    var body: some View {
        let speedTest = model.speedTest
        let isDownloading = speedTest.downloadingNode == node.id
        HStack(spacing: DS.Space.s2) {
            FlagImage(countryCode: node.countryCode, height: DS.Space.s4)
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.usesEnglishNames ? node.cityEnglish : node.city)
                    .dsFont(.sm, weight: .medium)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(verbatim: node.provider).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
            Spacer(minLength: DS.Space.s2)
            if isDownloading {
                Text(verbatim: SpeedText.rate(speedTest.liveBitsPerSecond > 0 ? speedTest.liveBitsPerSecond : nil))
                    .dsFont(.sm, weight: .semibold)
                    .foregroundStyle(DS.Palette.primary)
                    .monospacedDigit()
            } else if let speed = speedTest.globalSpeed[node.id] {
                Text(verbatim: SpeedText.rate(speed.bitsPerSecond))
                    .dsFont(.sm, weight: .semibold)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .monospacedDigit()
            }
            LatencyValue(speedTest.globalLatency[node.id])
                .frame(width: DS.Space.s16, alignment: .trailing)
            Button { speedTest.download(node) } label: {
                Image(systemName: isDownloading ? "stop.fill" : "arrow.down.circle")
            }
            .buttonStyle(DSButtonStyle(kind: .ghost))
            .help(isDownloading ? tr("停止") : tr("从这个节点下载测速，上限 \(SpeedText.budget(model.settings.speedTestBudget))"))
        }
        .padding(.vertical, DS.Space.s1)
    }
}

// MARK: - 全球探针

private struct GlobalpingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var speedTest = model.speedTest
        SpeedSection(icon: "dot.radiowaves.left.and.right", title: tr("全球探针看目标"),
                     subtitle: SpeedText.quota(speedTest.globalpingRun)) {
            RunButton(isRunning: speedTest.isProbing, title: tr("开始探测")) { speedTest.runGlobalping() }
        } content: {
            HStack(spacing: DS.Space.s2) {
                TextField(tr("域名，例如 example.com"), text: $speedTest.globalpingTarget)
                    .textFieldStyle(.roundedBorder)
                    .dsFont(.sm)
                    .onSubmit { speedTest.runGlobalping() }
                SegmentedControl(selection: $speedTest.globalpingProbes, options: [(10, "10"), (20, "20"), (30, "30")])
                    .frame(width: DS.Space.s16 * 3)
                    .help(tr("探针数量，一个探针占一次额度"))
            }
            if let error = speedTest.globalpingError {
                Text(error).dsFont(.xs).foregroundStyle(DS.Palette.error)
            }
            if let run = speedTest.globalpingRun {
                HairlineDivider()
                VStack(spacing: 0) {
                    ForEach(run.probes) { probe in
                        HStack(spacing: DS.Space.s2) {
                            FlagImage(countryCode: probe.countryCode, height: DS.Space.s4)
                            Text(verbatim: probe.city).dsFont(.sm).foregroundStyle(DS.Palette.textPrimary)
                            Text(verbatim: probe.network)
                                .dsFont(.xs)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .lineLimit(1)
                            Spacer(minLength: DS.Space.s2)
                            if let loss = probe.loss, loss > 0 {
                                Text(tr("丢包 \(Int(loss))%")).dsFont(.xs).foregroundStyle(DS.Palette.error)
                            }
                            Text(verbatim: SpeedText.milliseconds(probe.milliseconds))
                                .dsFont(.sm, weight: .medium)
                                .foregroundStyle(DS.Palette.textPrimary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, DS.Space.s1)
                        if probe.id != run.probes.last?.id { HairlineDivider() }
                    }
                }
            }
        }
    }
}

// MARK: - 文案

@MainActor
private enum SpeedText {
    static func rate(_ bitsPerSecond: Double?) -> String {
        guard let bitsPerSecond, bitsPerSecond > 0 else { return "—" }
        return Format.bandwidth(bitsPerSecond)
    }

    static func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value < 10 ? String(format: "%.1f ms", value) : "\(Int(value.rounded())) ms"
    }

    static func carrier(_ carrier: ChinaCarrier) -> String {
        L10n.usesEnglishNames ? carrier.nameEnglish : carrier.name
    }

    static func budget(_ budget: SpeedTestBudget) -> String {
        let limit = budget.limit
        return tr("\(Int(limit.seconds)) 秒·\(limit.bytes / 1_048_576) MB")
    }

    static func stage(_ stage: BroadbandTest.Stage?) -> String {
        switch stage {
        case .latency: tr("正在测延迟")
        case .download: tr("正在测下行")
        case .upload: tr("正在测上行")
        case nil: ""
        }
    }

    /// 测过之后显示走的线路、哪个边缘节点、什么时候测的
    static func broadbandStatus(_ speedTest: SpeedTestController) -> String? {
        let colo = speedTest.broadband?.colo.map { tr("经 Cloudflare \($0) 边缘节点") }
        let parts = [route(speedTest.broadbandRoute, speedTest), colo, checkedAt(speedTest.broadbandDate)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 线路与测量时间，例如“直连 · 17:34 测”；没有代理时只有时间
    static func status(route value: SpeedRoute?, date: Date?, _ speedTest: SpeedTestController) -> String? {
        guard let checked = checkedAt(date) else { return nil }
        return route(value, speedTest).map { $0 + " · " + checked } ?? checked
    }

    static func route(_ route: SpeedRoute?, _ speedTest: SpeedTestController) -> String? {
        switch route {
        case .direct: tr("直连")
        case .proxy: tr("经 \(speedTest.proxyName)")
        case nil: nil
        }
    }

    static func checkedAt(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateFormat = "HH:mm"
        return tr("\(formatter.string(from: date)) 测")
    }

    /// 额度按调用方 IP 计算，跑过一次才知道还剩多少
    static func quota(_ run: GlobalpingRun?) -> String? {
        guard let run, let remaining = run.remaining, let limit = run.limit else { return nil }
        return tr("本机 IP 这一小时还剩 \(remaining)/\(limit) 次探针额度")
    }
}
