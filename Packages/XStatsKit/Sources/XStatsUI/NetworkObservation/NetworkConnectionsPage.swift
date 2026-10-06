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

    static let allIdentifier = "\u{0}all"

    static func selected(in groups: [Self], id: String?) -> Self? {
        if let id, let group = groups.first(where: { $0.id == id }) { return group }
        return Self(id: allIdentifier, name: tr("全部连接"), applicationPath: nil,
                    records: groups.flatMap(\.records).sorted {
                        $0.timestamp == $1.timestamp ? $0.id.uuidString < $1.id.uuidString : $0.timestamp > $1.timestamp
                    })
    }

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
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
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
        switch self { case .apps: tr("应用"); case .process: tr("进程"); case .domain: tr("域名"); case .country: tr("国家或地域") }
    }
}

struct NetworkConnectionsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var managesNetworkComponent = false
    @State private var enablesAfterComponentInstall = false
    @State private var search = ""
    @State private var grouping = ConnectionGrouping.apps
    @State private var selection: String?
    @FocusState private var focusedGroup: String?
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
            NetworkConnectionGroup(id: key, name: grouping == .country ? networkRegionName(key) : key,
                                   applicationPath: nil, records: records)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
    private var selectedGroup: NetworkConnectionGroup? {
        NetworkConnectionGroup.selected(in: groups, id: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if monitor.status != .running && monitor.status != .preview { setup }
            if monitor.status == .running || monitor.status == .preview || !monitor.records.isEmpty {
                HSplitView {
                    groupList.frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
                    connectionDetail.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { Spacer(minLength: 0) }
        }
        .sheet(isPresented: $managesNetworkComponent, onDismiss: { enablesAfterComponentInstall = false }) {
            NetworkComponentManagementView(onInstalled: {
                guard enablesAfterComponentInstall else { return }
                enablesAfterComponentInstall = false
                managesNetworkComponent = false
                model.enableNetworkObservation()
            }, onClose: { enablesAfterComponentInstall = false }).environment(model)
        }
        .onDisappear { enablesAfterComponentInstall = false }
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
            // 未选择单个分组时展示全部；已选分组消失则回到全部，不自动限制为第一项。
            if let selection, !identifiers.contains(selection) { self.selection = nil }
        }
    }

    private var toolbar: some View {
        HStack(spacing: DS.Space.s2) {
            Circle().fill(monitor.isManuallyPaused ? DS.Palette.warning : (monitor.isReading || monitor.status == .preview ? DS.Palette.success : DS.Palette.textTertiary))
                .frame(width: 6, height: 6).accessibilityHidden(true)
            Text(statusText).dsFont(.sm, weight: .medium)
            Spacer(minLength: DS.Space.s2)
            if monitor.status == .running || monitor.status == .preview {
                Button { monitor.setObservationPaused(!monitor.isManuallyPaused) } label: {
                    Label(monitor.isManuallyPaused ? tr("继续监视") : tr("暂停监视"),
                          systemImage: monitor.isManuallyPaused ? "play.fill" : "pause.fill")
                }.buttonStyle(DSButtonStyle(kind: .ghost))
            }
            Menu {
                Button(tr("管理组件")) { managesNetworkComponent = true }
                Divider()
                Toggle(tr("仅显示活动连接"), isOn: $activeOnly)
                Button(tr("更新地图数据库")) { model.networkGeography.retry() }
                    .disabled(!monitor.isReading || model.networkGeography.state.isDownloading)
                Button(tr("清空记录")) { monitor.clearRecords() }.disabled(monitor.records.isEmpty)
                Divider()
                Button(tr("停止查看")) { monitor.stop() }.disabled(monitor.status == .preview)
                Button(tr("移除网络扩展")) { monitor.uninstall() }.disabled(monitor.isBusy || monitor.status == .preview)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().help(tr("更多"))
        }.padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s2)
    }

    private var groupList: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack {
                Picker(tr("汇总方式"), selection: Binding(get: { grouping }, set: { grouping = $0; selection = nil })) {
                    ForEach(ConnectionGrouping.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).labelsHidden().fixedSize()
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: groups.count.formatted(.number.locale(L10n.locale)))
                    .dsFont(.xs).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
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
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: DS.Space.s1) {
                        Button { selection = nil; focusedGroup = NetworkConnectionGroup.allIdentifier } label: {
                            HStack(spacing: DS.Space.s2) {
                                Image(systemName: "square.grid.2x2").frame(width: 26)
                                    .foregroundStyle(DS.Palette.primary).accessibilityHidden(true)
                                Text(tr("全部")).dsFont(.sm, weight: selection == nil ? .semibold : .medium)
                                    .foregroundStyle(DS.Palette.textPrimary)
                                Spacer(minLength: DS.Space.s1)
                                Text(verbatim: groups.reduce(0) { $0 + $1.records.count }.formatted(.number.locale(L10n.locale)))
                                    .dsFont(.xs, weight: .medium).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                            }.padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                                .background(selection == nil ? DS.Palette.sidebarSelected : .clear,
                                            in: RoundedRectangle(cornerRadius: DS.Radius.md))
                        }.buttonStyle(.plain).id(NetworkConnectionGroup.allIdentifier).focusable()
                            .focused($focusedGroup, equals: NetworkConnectionGroup.allIdentifier)
                            .accessibilityAddTraits(selection == nil ? .isSelected : [])
                        ForEach(groups) { group in
                            Button { selection = group.id; focusedGroup = group.id } label: {
                                HStack(spacing: DS.Space.s2) {
                                    if grouping == .apps || grouping == .process {
                                        AppIconCache.shared.image(bundlePath: group.applicationPath)
                                            .resizable().frame(width: 26, height: 26).accessibilityHidden(true)
                                    } else {
                                        Image(systemName: grouping == .domain ? "globe" : "mappin.and.ellipse")
                                            .frame(width: 26).foregroundStyle(DS.Palette.textSecondary)
                                    }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(verbatim: group.name).dsFont(.sm, weight: selection == group.id ? .semibold : .medium)
                                            .foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                                        if grouping == .process {
                                            Text(verbatim: "PID \(group.records[0].processID)")
                                                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                                        }
                                    }
                                    Spacer(minLength: DS.Space.s1)
                                    Text(verbatim: group.records.count.formatted(.number.locale(L10n.locale)))
                                        .dsFont(.xs, weight: .medium).monospacedDigit()
                                        .foregroundStyle(selection == group.id ? DS.Palette.primary : DS.Palette.textSecondary)
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .background(DS.Palette.elevated.opacity(0.7), in: Capsule())
                                }.padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                                    .background(selection == group.id ? DS.Palette.sidebarSelected : .clear,
                                                in: RoundedRectangle(cornerRadius: DS.Radius.md))
                            }.buttonStyle(.plain).id(group.id)
                                .focusable()
                                .focused($focusedGroup, equals: group.id)
                                .accessibilityAddTraits(selection == group.id ? .isSelected : [])
                        }
                    }
                }.onMoveCommand { direction in
                    let identifiers = [NetworkConnectionGroup.allIdentifier] + groups.map(\.id)
                    guard direction == .up || direction == .down else { return }
                    let current = identifiers.firstIndex(of: selection ?? NetworkConnectionGroup.allIdentifier) ?? 0
                    let next = min(identifiers.count - 1, max(0, current + (direction == .down ? 1 : -1)))
                    let identifier = identifiers[next]
                    selection = identifier == NetworkConnectionGroup.allIdentifier ? nil : identifier
                    focusedGroup = identifier
                    proxy.scrollTo(identifier)
                }
            }
            Label(tr("只读观察 · 全部放行"), systemImage: "eye")
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, DS.Space.s3).padding(.top, DS.Space.s2).padding(.bottom, DS.Space.s3)
    }

    private var connectionDetail: some View {
        let selected = selectedGroup
        let records = selected?.records ?? []
        return VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack(spacing: DS.Space.s3) {
                if selected?.id == NetworkConnectionGroup.allIdentifier {
                    Image(systemName: "network").font(.system(size: 24)).foregroundStyle(DS.Palette.primary)
                        .frame(width: 32, height: 32).accessibilityHidden(true)
                } else if let selected, grouping == .apps || grouping == .process {
                    AppIconCache.shared.image(bundlePath: selected.applicationPath)
                        .resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: selected?.name ?? tr("暂无连接记录")).dsFont(.lg, weight: .semibold).lineLimit(1)
                    Text(activeOnly ? tr("活动连接") : tr("最近连接记录"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer(minLength: DS.Space.s1)
                Text(verbatim: records.count.formatted(.number.locale(L10n.locale)))
                    .dsFont(.lg, weight: .medium).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
            }
            if !isSnapshot { geographyStatus }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                ConnectionWorldMap(world: mapWorld, records: records, countries: countries) { code in
                    grouping = .country
                    selection = code
                }.frame(height: 210)
                HStack {
                    Text(tr("国家或地域分布")).dsFont(.xs, weight: .medium)
                    Image(systemName: "info.circle").foregroundStyle(DS.Palette.textTertiary)
                        .help(tr("按国家或地域定位，非设备精确位置")).accessibilityLabel(tr("按国家或地域定位，非设备精确位置"))
                    Spacer(minLength: DS.Space.s1)
                    Link("DB-IP", destination: URL(string: "https://db-ip.com/")!)
                }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text(tr("连接详情")).dsFont(.sm, weight: .semibold)
                if records.isEmpty {
                    ContentUnavailableView(search.isEmpty ? tr("暂无连接记录") : tr("没有匹配的连接"), systemImage: "network")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(records) { record in
                                connectionRow(record)
                                if record.id != records.last?.id { Divider().opacity(0.5) }
                            }
                        }
                    }
                }
            }.frame(maxHeight: .infinity, alignment: .top)
            HStack(alignment: .top, spacing: DS.Space.s2) {
                Image(systemName: "info.circle").accessibilityHidden(true)
                Text(monitor.isManuallyPaused ? tr("暂停时保留当前画面；继续后更新观察到的连接。")
                     : tr("显示观察期间的新连接；重新开始前已建立的连接不在此列。"))
                    .fixedSize(horizontal: false, vertical: true)
            }.dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            // 突发连接超出扩展缓冲时明确提示列表不完整，不把截断的观察当作完整结果。
            if monitor.discarded > 0 {
                HStack(alignment: .top, spacing: DS.Space.s2) {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                    Text(tr("扩展缓冲区已有 \(monitor.discarded.formatted(.number.locale(L10n.locale))) 条旧记录被淘汰。"))
                        .fixedSize(horizontal: false, vertical: true)
                }.dsFont(.xs).foregroundStyle(DS.Palette.warning)
            }
        }.padding(.horizontal, DS.Space.s4).padding(.top, DS.Space.s2).padding(.bottom, DS.Space.s3)
    }

    private func connectionRow(_ record: ObservedConnection) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s3) {
            Image(systemName: record.direction == .outbound ? "arrow.up.right" : "arrow.down.left")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Palette.textSecondary)
                .frame(width: 26, height: 26).background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                .accessibilityLabel(record.direction == .outbound ? tr("出站") : tr("入站"))
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(verbatim: record.hostname ?? record.address ?? tr("目标未知"))
                    .dsFont(.sm, weight: .medium).textSelection(.enabled).lineLimit(2)
                HStack(spacing: DS.Space.s2) {
                    Text(verbatim: record.transport.rawValue.uppercased())
                    if let port = record.port { Text(verbatim: String(port)) }
                    if let address = record.address, record.hostname != nil {
                        Text(verbatim: address).textSelection(.enabled).lineLimit(1).help(address)
                    }
                }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer(minLength: DS.Space.s1)
            VStack(alignment: .trailing, spacing: DS.Space.s1) {
                Text(verbatim: networkRegionName(record.address.flatMap { countries[$0] } ?? "??"))
                    .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
                    .help(networkRegionName(record.address.flatMap { countries[$0] } ?? "??"))
                Text(verbatim: selection == nil || grouping == .country || grouping == .domain
                     ? "\(record.applicationName) · PID \(record.processID)" : "PID \(record.processID)")
                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary).lineLimit(1).help(record.applicationName)
            }.layoutPriority(-1)
        }.padding(.vertical, DS.Space.s3)
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
            Text(tr("查看应用连接、域名和国家或地域分布，不读取通信内容。"))
                .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
            if let progress = monitor.installationProgress {
                Text(tr("正在下载")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
                ProgressView(value: progress)
            }
            if monitor.status == .needsApproval {
                Text(tr("请在系统设置中允许 XStats 网络扩展，然后返回此处。"))
                    .dsFont(.sm).fixedSize(horizontal: false, vertical: true)
                Button(tr("打开系统设置")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { NSWorkspace.shared.open(url) }
                }.buttonStyle(DSButtonStyle(kind: .primary))
            } else if monitor.status == .restartRequired {
                Text(tr("需要重启系统")).foregroundStyle(DS.Palette.warning)
            } else {
                Button(tr("启用连接查看")) {
                    if model.networkComponent.requiresInstallation {
                        enablesAfterComponentInstall = true
                        managesNetworkComponent = true
                    } else { monitor.start() }
                }
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


}

/// 列表、地图提示与辅助功能统一使用同一地名规则，避免显示名称不一致。
private func networkRegionName(_ code: String) -> String {
    switch code {
    case "HK": tr("中国香港")
    case "MO": tr("中国澳门")
    case "TW": tr("中国台湾")
    case "??": tr("内网或位置未知")
    default: L10n.locale.localizedString(forRegionCode: code) ?? code
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
            // 全球经纬度投影固定2:1；窗口变宽时只增加海面留白，不能横向拉伸大陆。
            let width = min(size.width - 16, (size.height - 16) * 2)
            let mapSize = CGSize(width: width, height: width / 2)
            let origin = CGPoint(x: (size.width - mapSize.width) / 2, y: (size.height - mapSize.height) / 2)
            ZStack {
                Canvas { context, _ in
                    for country in world {
                        var path = Path()
                        for ring in country.rings {
                            guard let first = ring.first, first.count == 2 else { continue }
                            path.move(to: point(first, size: mapSize, origin: origin))
                            for coordinate in ring.dropFirst() where coordinate.count == 2 {
                                path.addLine(to: point(coordinate, size: mapSize, origin: origin))
                            }
                            path.closeSubpath()
                        }
                        context.fill(path, with: .color(counts[country.code] == nil ? DS.Palette.neutral300.opacity(0.65) : DS.Palette.primary.opacity(0.22)))
                        context.stroke(path, with: .color(DS.Palette.elevated.opacity(0.65)), lineWidth: 0.5)
                    }
                }.accessibilityHidden(true)
                ForEach(world.filter { counts[$0.code] != nil }, id: \.code) { country in
                    Button { selectCountry(country.code) } label: {
                        Text(verbatim: (counts[country.code] ?? 0).formatted(.number.locale(L10n.locale)))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Palette.onPrimary)
                            .padding(6).background(DS.Palette.primary, in: Circle())
                            .overlay(Circle().stroke(DS.Palette.elevated, lineWidth: 2))
                    }.buttonStyle(.plain)
                        .position(point([country.longitude, country.latitude], size: mapSize, origin: origin))
                        .help(networkRegionName(country.code))
                        .accessibilityLabel(networkRegionName(country.code))
                        .accessibilityValue((counts[country.code] ?? 0).formatted(.number.locale(L10n.locale)))
                }
            }
        }.background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
            .environment(\.layoutDirection, .leftToRight)
    }

    private func point(_ coordinate: [Double], size: CGSize, origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + (coordinate[0] + 180) / 360 * size.width,
                y: origin.y + (90 - coordinate[1]) / 180 * size.height)
    }
}
