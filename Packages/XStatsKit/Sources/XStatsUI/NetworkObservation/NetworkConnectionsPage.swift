// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import NetworkObservation
import SwiftUI

struct NetworkConnectionGroup: Identifiable {
    let id: String
    let name: String
    let applicationPath: String?
    let records: [ObservedConnection]

    static func make(records: [ObservedConnection], query: String) -> [Self] {
        let filtered = records.filter { record in
            query.isEmpty || [record.applicationName, record.executablePath, record.address ?? "",
                              record.hostname ?? "", String(record.processID), record.port.map(String.init) ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return Dictionary(grouping: filtered) { record in
            record.applicationPath ?? (record.executablePath.isEmpty ? "pid:\(record.processID)" : record.executablePath)
        }.map { key, events in
            Self(id: key, name: events[0].applicationName, applicationPath: events[0].applicationPath,
                 records: events.sorted { $0.timestamp > $1.timestamp })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct GeographyLookupRequest: Hashable {
    let addresses: Set<String>
    let revision: Int
}

private enum ConnectionGrouping: String, CaseIterable, Identifiable {
    case apps, process, domain, country
    var id: Self { self }
    var title: String {
        switch self { case .apps: tr("应用"); case .process: tr("进程"); case .domain: tr("域名"); case .country: tr("国家") }
    }
}

struct NetworkConnectionsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var search = ""
    @State private var grouping = ConnectionGrouping.apps
    @State private var selection: String?
    @State private var activeOnly = true
    @State private var resolvedCountries: [String: String] = [:]
    @State private var world: [NetworkCountry] = []

    private var countries: [String: String] { isSnapshot ? monitor.previewCountries : resolvedCountries }
    private var mapWorld: [NetworkCountry] { isSnapshot ? monitor.previewWorld : world }
    private var monitor: NetworkMonitorController { model.connectionMonitor }
    private var visibleRecords: [ObservedConnection] {
        monitor.records.filter { !activeOnly || monitor.activeConnectionIDs.contains($0.id) }
    }
    private var groups: [NetworkConnectionGroup] {
        if grouping == .apps { return NetworkConnectionGroup.make(records: visibleRecords, query: search) }
        let matching = NetworkConnectionGroup.make(records: visibleRecords, query: search).flatMap(\.records)
        if grouping == .process {
            return Dictionary(grouping: matching) { "\($0.executablePath)#\($0.processID)" }.map { key, records in
                NetworkConnectionGroup(id: key, name: records[0].applicationName,
                                       applicationPath: records[0].applicationPath, records: records)
            }.sorted { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return Dictionary(grouping: matching) { record in
            grouping == .domain ? (record.hostname ?? record.address ?? tr("目标未知"))
                : (record.address.flatMap { countries[$0] } ?? "??")
        }.map { key, records in
            NetworkConnectionGroup(id: key, name: grouping == .country ? countryName(key) : key,
                                   applicationPath: nil, records: records)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var selectedGroup: NetworkConnectionGroup? {
        groups.first { $0.id == selection } ?? groups.first
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if monitor.status != .running && monitor.status != .preview { setup }
            if monitor.status == .running || monitor.status == .preview || !monitor.records.isEmpty {
                HSplitView {
                    groupList.frame(minWidth: 180, idealWidth: 200, maxWidth: 280)
                    connectionDetail.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { Spacer(minLength: 0) }
        }
        .frame(height: isSnapshot ? 580 : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            world = await OfflineGeography.shared.world()
        }
        .task(id: GeographyLookupRequest(addresses: Set(monitor.records.compactMap(\.address)), revision: model.networkGeography.revision)) {
            guard !isSnapshot else { return }
            let result = await OfflineGeography.shared.resolve(monitor.records.compactMap(\.address))
            guard !Task.isCancelled else { return }
            resolvedCountries = result
        }
        .onChange(of: groups.map(\.id), initial: true) { _, identifiers in
            // 刷新保留当前选择；只有所选组消失时才转到下一项，并让列表高亮与详情一致。
            if selection == nil || !identifiers.contains(selection ?? "") { selection = identifiers.first }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Circle().fill(monitor.isManuallyPaused ? DS.Palette.warning : (monitor.isReading || monitor.status == .preview ? DS.Palette.success : DS.Palette.textTertiary)).frame(width: 6, height: 6)
                Text(statusText).dsFont(.sm)
                Spacer(minLength: DS.Space.s1)
                if monitor.status == .running || monitor.status == .preview {
                    Button {
                        monitor.setObservationPaused(!monitor.isManuallyPaused)
                    } label: {
                        Label(monitor.isManuallyPaused ? tr("继续监视") : tr("暂停监视"),
                              systemImage: monitor.isManuallyPaused ? "play.fill" : "pause.fill")
                    }.buttonStyle(DSButtonStyle(kind: .secondary))
                }
                Menu {
                    Toggle(tr("仅显示活动连接"), isOn: $activeOnly)
                    Button(tr("更新地图数据库")) { model.networkGeography.retry() }
                        .disabled(!monitor.isReading || model.networkGeography.state.isDownloading)
                    Button(tr("清空记录")) { monitor.clearRecords() }.disabled(monitor.records.isEmpty)
                    Divider()
                    Button(tr("停止查看")) { monitor.stop() }.disabled(monitor.status == .preview)
                    Button(tr("移除网络扩展")) { monitor.uninstall() }.disabled(monitor.isBusy || monitor.status == .preview)
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help(tr("更多"))
            }
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Palette.textTertiary)
                TextField(tr("搜索应用、地址或端口"), text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel(tr("清除搜索"))
                }
            }.dsFont(.sm).padding(DS.Space.s2)
                .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        }.padding(DS.Space.s3)
    }

    private var groupList: some View {
        VStack(spacing: DS.Space.s2) {
            Picker(tr("汇总方式"), selection: Binding(get: { grouping }, set: { grouping = $0; selection = nil })) {
                ForEach(ConnectionGrouping.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).labelsHidden().padding(.horizontal, DS.Space.s2)
            List(selection: $selection) {
                ForEach(groups) { group in
                    HStack(spacing: DS.Space.s2) {
                        if grouping == .process || grouping == .apps {
                            AppIconCache.shared.image(bundlePath: group.applicationPath)
                                .resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                        } else { Image(systemName: grouping == .domain ? "globe" : "mappin.and.ellipse").foregroundStyle(DS.Palette.textSecondary) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: group.name).foregroundStyle(selection == group.id ? Color.white : DS.Palette.textPrimary).lineLimit(1)
                            if grouping == .process {
                                Text(verbatim: "PID \(Set(group.records.map(\.processID)).sorted().map(String.init).joined(separator: ", "))").dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(verbatim: group.records.count.formatted(.number.locale(L10n.locale))).monospacedDigit()
                            .foregroundStyle(DS.Palette.textSecondary)
                    }.dsFont(.sm).padding(.vertical, DS.Space.s1).tag(group.id)
                }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            Text(tr("只读观察 · 全部放行")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .padding(.bottom, DS.Space.s3)
        }
    }

    private var connectionDetail: some View {
        let selected = selectedGroup
        let records = selected?.records ?? []
        return VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: selected?.name ?? tr("暂无连接记录")).dsFont(.base, weight: .semibold).lineLimit(1)
                Spacer(minLength: DS.Space.s1)
                Text(activeOnly ? tr("活动连接") : tr("最近连接记录")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                Text(verbatim: records.count.formatted(.number.locale(L10n.locale))).dsFont(.sm).monospacedDigit()
            }.padding(.horizontal, DS.Space.s3)
            if !isSnapshot { geographyStatus.padding(.horizontal, DS.Space.s3) }
            ConnectionWorldMap(world: mapWorld, records: records, countries: countries) { code in
                grouping = .country
                selection = code
            }.frame(height: 200).padding(.horizontal, DS.Space.s3)
            HStack {
                Text(tr("国家级位置，非设备精确位置")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                Spacer(minLength: 0)
                Link("DB-IP", destination: URL(string: "https://db-ip.com/")!).dsFont(.xs)
            }.padding(.horizontal, DS.Space.s3)
            if records.isEmpty {
                ContentUnavailableView(search.isEmpty ? tr("暂无连接记录") : tr("没有匹配的连接"),
                                       systemImage: "network", description: Text(tr("启用查看后，打开网页或使用联网应用，新的连接会显示在这里。")))
            } else {
                Table(records) {
                    TableColumn(tr("目标")) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: record.hostname ?? record.address ?? tr("目标未知")).lineLimit(1).textSelection(.enabled)
                            if let address = record.address, record.hostname != nil {
                                Text(verbatim: address).font(.caption).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled)
                            }
                            Text(verbatim: "\(record.transport.rawValue.uppercased())  \(record.port.map(String.init) ?? "—")  ·  \(countryName(record.address.flatMap { countries[$0] } ?? "??"))")
                                .font(.caption).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                        }.padding(.vertical, 4)
                    }
                    TableColumn(tr("进程")) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: record.applicationName).lineLimit(1)
                            Text(verbatim: "PID \(record.processID)").font(.caption).foregroundStyle(DS.Palette.textSecondary)
                        }
                    }.width(min: 80, ideal: 100)
                }.tableStyle(.inset(alternatesRowBackgrounds: true))
            }
            Text(monitor.isManuallyPaused ? tr("暂停时保留当前画面；继续后更新观察到的连接。")
                 : tr("显示观察期间的新连接；重新开始前已建立的连接不在此列。"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.s3).padding(.bottom, DS.Space.s3)
        }
    }

    @ViewBuilder private var geographyStatus: some View {
        let geography = model.networkGeography
        switch geography.state {
        case .ready: EmptyView()
        case .downloading(let progress):
            ProgressView(value: progress) {
                HStack {
                    Text(geography.hasData ? tr("正在更新地图数据库…") : tr("正在下载地图数据库…"))
                    Spacer(minLength: DS.Space.s1)
                    Text(verbatim: progress.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale)))
                }.dsFont(.xs)
            }.controlSize(.small)
        case .idle, .failed:
            HStack {
                Text(geography.hasData ? tr("更新失败，继续使用已缓存的数据。") : tr("地图数据库未就绪，连接列表仍可使用。"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s1)
                Button(geography.state == .failed ? tr("重试") : tr("下载地图数据库")) { geography.retry() }
                    .buttonStyle(DSButtonStyle(kind: .ghost)).disabled(!monitor.isReading)
            }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Label(tr("网络监视器"), systemImage: "network").dsFont(.lg, weight: .semibold)
            Text(tr("查看应用连接、域名和国家分布，不读取通信内容。"))
                .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
            if monitor.status == .needsApproval {
                Text(tr("请在系统设置中允许 XStats 网络扩展，然后返回此处。"))
                    .dsFont(.sm).fixedSize(horizontal: false, vertical: true)
                Button(tr("打开系统设置")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { NSWorkspace.shared.open(url) }
                }.buttonStyle(DSButtonStyle(kind: .primary))
            } else if monitor.status == .restartRequired {
                Text(tr("需要重启系统")).foregroundStyle(DS.Palette.warning)
            } else {
                Button(tr("启用连接查看")) { monitor.start() }
                    .buttonStyle(DSButtonStyle(kind: .primary)).disabled(monitor.isBusy)
            }
            if let error = monitor.error {
                DisclosureGroup(tr("错误详情")) { Text(verbatim: error).dsFont(.xs).textSelection(.enabled) }
                    .dsFont(.sm).foregroundStyle(DS.Palette.error)
            }
        }.padding(DS.Space.s6).frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg)).padding(DS.Space.s3)
    }

    private var statusText: String {
        switch monitor.status {
        case .idle: tr("未启用")
        case .starting: tr("正在启用…")
        case .needsApproval: tr("等待系统授权")
        case .running: monitor.isReading ? tr("正在监视") : tr("采集已暂停")
        case .failed: tr("未能启用")
        case .restartRequired: tr("需要重启系统")
        case .preview: monitor.isManuallyPaused ? tr("采集已暂停") : tr("示例数据")
        }
    }

    private func countryName(_ code: String) -> String {
        code == "??" ? tr("内网或位置未知") : (L10n.locale.localizedString(forRegionCode: code) ?? code)
    }
}

private struct ConnectionWorldMap: View {
    let world: [NetworkCountry]
    let records: [ObservedConnection]
    let countries: [String: String]
    let selectCountry: (String) -> Void

    private var counts: [String: Int] {
        Dictionary(grouping: records.compactMap { $0.address.flatMap { countries[$0] } }, by: { $0 }).mapValues(\.count)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let counts = counts
            ZStack {
                Canvas { context, canvasSize in
                    for country in world {
                        var path = Path()
                        for ring in country.rings {
                            guard let first = ring.first, first.count == 2 else { continue }
                            path.move(to: point(first, size: canvasSize))
                            for coordinate in ring.dropFirst() where coordinate.count == 2 { path.addLine(to: point(coordinate, size: canvasSize)) }
                            path.closeSubpath()
                        }
                        context.fill(path, with: .color(DS.Palette.textTertiary.opacity(0.2)))
                    }
                }.accessibilityHidden(true)
                ForEach(world.filter { counts[$0.code] != nil }, id: \.code) { country in
                    Button { selectCountry(country.code) } label: {
                        Text(verbatim: String(counts[country.code] ?? 0)).font(.system(size: 10, weight: .semibold))
                            .padding(5).background(DS.Palette.primary, in: Circle()).foregroundStyle(.white)
                    }.buttonStyle(.plain)
                        .position(point([country.longitude, country.latitude], size: size))
                        .help(L10n.locale.localizedString(forRegionCode: country.code) ?? country.code)
                        .accessibilityLabel(L10n.locale.localizedString(forRegionCode: country.code) ?? country.code)
                        .accessibilityValue(String(counts[country.code] ?? 0))
                }
            }
        }.background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
            // 经纬度是物理坐标；不能随阿拉伯语布局翻转标记，而保留画布的地理轮廓。
            .environment(\.layoutDirection, .leftToRight)
    }

    private func point(_ coordinate: [Double], size: CGSize) -> CGPoint {
        CGPoint(x: (coordinate[0] + 180) / 360 * size.width, y: (90 - coordinate[1]) / 180 * size.height)
    }
}
