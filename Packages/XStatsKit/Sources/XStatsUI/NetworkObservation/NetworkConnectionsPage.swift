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
  var processID: Int32? = nil
  var historyCount: Int? = nil
  var hasChildren = false
  var count: Int { historyCount ?? records.count }

  func filteringActiveConnections(_ activeIDs: Set<UUID>, onlyActive: Bool) -> Self {
    Self(
      id: id, name: name, applicationPath: applicationPath,
      records: records.filter { !onlyActive || activeIDs.contains($0.id) }, processID: processID,
      hasChildren: hasChildren)
  }

  static let allIdentifier = "\u{0}all"

  static func selected(in groups: [Self], id: String?) -> Self? {
    if let id, let group = groups.first(where: { $0.id == id }) { return group }
    return Self(
      id: allIdentifier, name: tr("全部连接"), applicationPath: nil,
      records: groups.flatMap(\.records).sorted(by: newestFirst))
  }

  /// 跨应用分组沿用 Dictionary(grouping:) 的元素顺序；整体按时间排序，避免同一域名或地域按应用名分段。
  static func matching(records: [ObservedConnection], query: String) -> [ObservedConnection] {
    make(records: records, query: query).flatMap(\.records).sorted(by: newestFirst)
  }

  private static func newestFirst(_ lhs: ObservedConnection, _ rhs: ObservedConnection) -> Bool {
    lhs.timestamp == rhs.timestamp
      ? lhs.id.uuidString < rhs.id.uuidString : lhs.timestamp > rhs.timestamp
  }

  static func make(records: [ObservedConnection], query: String) -> [Self] {
    let filtered = records.filter { matches($0, query: query) }
    return Dictionary(grouping: filtered) { record in
      record.applicationGroupKey
    }.map { key, events in
      Self(
        id: key, name: events[0].applicationName,
        applicationPath: events.compactMap(\.applicationPath).min(),
        records: events.sorted(by: newestFirst))
    }.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }

  static func matches(_ record: ObservedConnection, query: String) -> Bool {
    query.isEmpty
      || [
        record.applicationName, record.executablePath, record.address ?? "",
        record.hostname ?? "", String(record.processID), record.port.map(String.init) ?? "",
      ].contains { $0.localizedCaseInsensitiveContains(query) }
  }
}

private struct GeographyLookupRequest: Hashable {
  let addresses: Set<String>
  let revision: Int
  let historyRevision: Int
  let visible: Bool
}

struct NetworkHistoryQueryKey: Hashable {
  let filter: NetworkHistoryFilter
  let activeOnly: Bool
  let offset: Int
  let historyRevision: Int
  let visibility: Bool
  let enabled: Bool
  let refresh: Int

  func hasSamePage(as other: Self) -> Bool {
    filter == other.filter && activeOnly == other.activeOnly && offset == other.offset
      && enabled == other.enabled
  }

  func shouldQuery(after previous: Self?, isReading: Bool) -> Bool {
    guard visibility, enabled else { return false }
    guard let previous else { return true }
    return isReading || !hasSamePage(as: previous) || refresh != previous.refresh
  }
}

struct NetworkHistoryPagination {
  static let pageSize = 200
  let offset: Int
  let count: Int
  let total: Int
  var previousOffset: Int { max(0, offset - Self.pageSize) }
  var nextOffset: Int { offset + Self.pageSize }
  var hasPrevious: Bool { offset > 0 }
  var hasNext: Bool { offset + count < total }
  var first: Int { count == 0 ? 0 : offset + 1 }
  var last: Int { min(total, offset + count) }

  static func validOffset(_ offset: Int, total: Int) -> Int {
    min(max(0, offset), max(0, (total - 1) / pageSize) * pageSize)
  }
}

enum ConnectionGrouping: String, CaseIterable, Identifiable {
  case apps, process, domain, country
  var id: Self { self }
  var title: String {
    switch self {
    case .apps: tr("应用")
    case .process: tr("进程")
    case .domain: tr("域名")
    case .country: tr("地区")
    }
  }

  func identifier(for record: ObservedConnection, countries: [String: String]) -> String {
    switch self {
    case .apps:
      record.applicationGroupKey
    case .process: "\(record.executablePath)#\(record.processID)"
    case .domain: record.hostname ?? record.address ?? "??"
    case .country:
      OfflineGeography.regionKey(
        address: record.address, country: record.address.flatMap { countries[$0] })
    }
  }
}

/// 历史查询按保存的流元数据匹配，不依赖当前活动 ID 或有界连接列表是否仍保留该流。
struct NetworkConnectionFilter {
  let grouping: ConnectionGrouping
  let selection: String?
  let query: String
  let countries: [String: String]

  func matches(_ record: ObservedConnection) -> Bool {
    guard NetworkConnectionGroup.matches(record, query: query) else { return false }
    guard let selection else { return true }
    let key = grouping.identifier(for: record, countries: countries)
    return grouping == .country
      ? NetworkRegionHierarchy.matches(key, selection: selection) : key == selection
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
  @State private var selectedTitle = ""
  @State private var pageVisible = false
  @FocusState private var focusedGroup: String?
  @State private var mode = NetworkConnectionMode.live
  @State private var historyInterval: TimeInterval = 900
  @State private var historyEnd = NetworkConnectionMode.historyEnd()
  @State private var expandedRegions: Set<String> = []
  private var activeOnly: Bool { mode == .live }
  @State private var resolvedCountries: [String: String] = [:]
  @State private var resolvedLocations: [String: NetworkIPLocation] = [:]
  @State private var world: [NetworkCountry] = []
  @State private var historyView: NetworkHistoryView?
  @State private var historyOffset = 0
  @State private var historyRefresh = 0
  @State private var historyGeneration = 0
  @State private var loadedHistoryQuery: NetworkHistoryQueryKey?
  @State private var historyError: String?
  @State private var isQueryingHistory = false
  @State private var clearingHistoryRevision: Int?

  init(
    mode: NetworkConnectionMode = .live, grouping: ConnectionGrouping = .apps,
    expandedRegions: Set<String> = []
  ) {
    _mode = State(initialValue: mode)
    _grouping = State(initialValue: grouping)
    _expandedRegions = State(initialValue: expandedRegions)
  }

  private var countries: [String: String] {
    if isSnapshot || monitor.status == .preview { return monitor.previewCountries }
    return (displayedHistory?.countries ?? [:]).merging(resolvedCountries) { _, new in new }
  }
  private var mapWorld: [NetworkCountry] { isSnapshot ? monitor.previewWorld : world }
  private var locations: [String: NetworkIPLocation] {
    if isSnapshot || monitor.status == .preview { return monitor.previewLocations }
    return (displayedHistory?.locations ?? [:]).merging(resolvedLocations) { _, new in new }
  }
  private var places: [String: String] {
    countries.merging(locations.compactMapValues(\.mapKey)) { _, new in new }
  }
  private var monitor: NetworkMonitorController { model.connectionMonitor }
  private var usesHistory: Bool {
    monitor.status != .preview && !isSnapshot
  }
  private var refreshesHistory: Bool {
    mode == .live
      && (monitor.isReading
        || (!monitor.isManuallyPaused && (monitor.status == .idle || monitor.status == .failed)))
  }
  private var showsConnectionDetail: Bool {
    monitor.status == .running || monitor.status == .preview || !monitor.records.isEmpty
      || (usesHistory && (historyView != nil || isQueryingHistory || historyError != nil))
  }
  private var historyQuery: NetworkHistoryQueryKey {
    NetworkHistoryQueryKey(
      filter: NetworkHistoryFilter(
        grouping: grouping.rawValue, selection: selection, search: search,
        interval: mode == .live ? 60 : historyInterval,
        end: mode == .history ? historyEnd : nil, expandedRegions: expandedRegions),
      activeOnly: activeOnly, offset: historyOffset,
      historyRevision: refreshesHistory || clearingHistoryRevision != nil
        ? monitor.historyRevision : 0,
      visibility: pageVisible && model.isMainWindowVisible,
      enabled: usesHistory && monitor.historyEnabled,
      refresh: historyRefresh)
  }
  private var displayedHistory: NetworkHistoryView? {
    guard usesHistory, loadedHistoryQuery?.hasSamePage(as: historyQuery) == true else { return nil }
    return historyView
  }
  private var currentGroups: [NetworkConnectionGroup] {
    if usesHistory {
      // 分组来自完整15分钟的聚合，不能用当前200条页记录重新分组或求总数。
      var requested = historyQuery.filter
      var loaded = loadedHistoryQuery?.filter
      requested.selection = nil
      loaded?.selection = nil
      let groups =
        loaded == requested && loadedHistoryQuery?.activeOnly == activeOnly
        ? historyView?.groups ?? [] : []
      let presented = groups.map { group in
        NetworkConnectionGroup(
          id: group.id,
          name: grouping == .country
            ? networkRegionName(group.id)
            : (grouping == .domain && group.id == "??" ? tr("目标未知") : group.name),
          applicationPath: group.applicationPath, records: [], processID: group.processID,
          historyCount: group.count, hasChildren: group.hasChildren)
      }
      return grouping == .country ? presented.sorted { $0.id < $1.id } : presented
    }
    if grouping == .apps {
      return NetworkConnectionGroup.make(records: monitor.records, query: search)
    }
    let matching = NetworkConnectionGroup.matching(records: monitor.records, query: search)
    if grouping == .country {
      var groups: [NetworkConnectionGroup] = []
      for depth in 0...2 {
        let visible = matching.filter { record in
          let key = grouping.identifier(for: record, countries: places)
          return NetworkRegionHierarchy.key(key, at: depth) != nil
            && (depth == 0
              || NetworkRegionHierarchy.key(key, at: depth - 1).map { expandedRegions.contains($0) }
                == true)
        }
        let grouped = Dictionary(grouping: visible) {
          NetworkRegionHierarchy.key(grouping.identifier(for: $0, countries: places), at: depth)!
        }
        groups += grouped.map { key, records in
          NetworkConnectionGroup(
            id: key, name: networkRegionName(key), applicationPath: nil,
            records: records,
            hasChildren: records.contains {
              NetworkRegionHierarchy.key(
                grouping.identifier(for: $0, countries: places), at: depth + 1) != nil
            })
        }
      }
      return groups.sorted { $0.id < $1.id }
    }
    if grouping == .process {
      return Dictionary(grouping: matching) { grouping.identifier(for: $0, countries: places) }
        .map {
          key, records in
          NetworkConnectionGroup(
            id: key, name: records[0].applicationName,
            applicationPath: records[0].applicationPath, records: records,
            processID: records[0].processID)
        }.sorted {
          $0.name == $1.name
            ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    return Dictionary(grouping: matching) { grouping.identifier(for: $0, countries: places) }
      .map { key, records in
        NetworkConnectionGroup(
          id: key,
          name: grouping == .country
            ? networkRegionName(key) : (key == "??" ? tr("目标未知") : key),
          applicationPath: nil, records: records)
      }.sorted {
        let order = $0.name.localizedStandardCompare($1.name)
        return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
      }
  }
  var body: some View {
    // 分组需过滤、分组和本地化排序；每次渲染只计算一次，再传给子视图。
    // 活动筛选只改变列表计数与详情，不能使所选历史分组消失或把走势切回全部。
    let groups = currentGroups.map { group in
      usesHistory
        ? group
        : group.filteringActiveConnections(monitor.activeConnectionIDs, onlyActive: activeOnly)
    }.filter { !activeOnly || $0.count > 0 || $0.id == selection }
    let selected =
      selection.map { identifier in
        groups.first { $0.id == identifier }
          ?? NetworkConnectionGroup(
            id: identifier, name: selectedTitle, applicationPath: nil, records: [])
      } ?? NetworkConnectionGroup.selected(in: groups, id: nil)
    VStack(spacing: 0) {
      toolbar
      if mode == .history { historyControls }
      if mode == .live
        && (monitor.installationProgress != nil || monitor.status == .needsApproval
          || monitor.status == .restartRequired || monitor.status == .failed)
      {
        setup
      }
      if mode == .live && !monitor.isReading && monitor.status != .preview {
        VStack(spacing: DS.Space.s3) {
          ContentUnavailableView(tr("采集已停止"), systemImage: "pause.circle")
          Button(tr("查看历史")) { mode = .history }
            .buttonStyle(DSButtonStyle(kind: .ghost))
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if showsConnectionDetail {
        HSplitView {
          groupList(groups).frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
          connectionDetail(
            selected,
            records: usesHistory ? displayedHistory?.records ?? [] : previewRecords,
            total: usesHistory ? displayedHistory?.total ?? 0 : previewRecords.count
          ).frame(
            minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        Spacer(minLength: 0)
      }
    }
    .sheet(
      isPresented: $managesNetworkComponent, onDismiss: { enablesAfterComponentInstall = false }
    ) {
      NetworkComponentManagementView(
        onInstalled: {
          guard enablesAfterComponentInstall else { return }
          enablesAfterComponentInstall = false
          managesNetworkComponent = false
          model.enableNetworkObservation()
        }, onClose: { enablesAfterComponentInstall = false }
      ).environment(model)
    }
    .onAppear {
      // 重启尚未启用采集时，旧会话没有活动连接；默认展示仍在15分钟内的历史。
      if monitor.status == .idle { mode = .history }
      pageVisible = true
    }
    .onDisappear {
      pageVisible = false
      enablesAfterComponentInstall = false
      historyGeneration &+= 1
      isQueryingHistory = false
    }
    .frame(height: isSnapshot ? 580 : nil)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      world = await OfflineGeography.shared.world()
    }
    .task(id: historyQuery) {
      await queryHistory(historyQuery)
    }
    .onChange(of: search) { _, _ in historyOffset = 0 }
    .onChange(of: grouping) { _, _ in historyOffset = 0 }
    .onChange(of: selection) { _, _ in historyOffset = 0 }
    .onChange(of: mode) { _, value in
      historyOffset = 0
      if value == .history { historyEnd = NetworkConnectionMode.historyEnd() }
    }
    .onChange(of: historyInterval) { _, _ in
      historyOffset = 0
      historyEnd = NetworkConnectionMode.historyEnd()
    }
    .onChange(of: monitor.error) { _, error in
      if clearingHistoryRevision != nil, let error {
        isQueryingHistory = false
        historyError = error
      }
    }
    .task(
      id: GeographyLookupRequest(
        addresses: Set(
          monitor.records.compactMap(\.address)
            + (displayedHistory?.records.compactMap(\.address) ?? [])),
        revision: model.networkGeography.revision,
        historyRevision: refreshesHistory ? monitor.historyRevision : 0,
        visible: pageVisible && model.isMainWindowVisible)
    ) {
      await resolveCountries()
    }
  }

  private func queryHistory(_ query: NetworkHistoryQueryKey) async {
    guard !Task.isCancelled, query == historyQuery else { return }
    historyGeneration &+= 1
    let generation = historyGeneration
    guard query.shouldQuery(after: loadedHistoryQuery, isReading: refreshesHistory) else {
      isQueryingHistory = false
      return
    }
    if clearingHistoryRevision == query.historyRevision {
      // 清空由控制器串行落库；等持久化版本推进后查询，避免暂停状态下读回清空前的数据。
      isQueryingHistory = historyError == nil
      return
    }
    clearingHistoryRevision = nil
    isQueryingHistory = true
    historyError = nil
    defer {
      if generation == historyGeneration { isQueryingHistory = false }
    }
    do {
      let result = try await monitor.historyStore.view(
        filter: query.filter, activeOnly: query.activeOnly, offset: query.offset)
      guard !Task.isCancelled, generation == historyGeneration, query == historyQuery else {
        return
      }
      let validOffset = NetworkHistoryPagination.validOffset(query.offset, total: result.total)
      if validOffset != query.offset {
        // 历史过期或清空后，收敛到仍存在的最后一页，不把空页误报为没有连接。
        historyOffset = validOffset
        return
      }
      historyView = result
      loadedHistoryQuery = query
    } catch {
      guard !Task.isCancelled, generation == historyGeneration, query == historyQuery else {
        return
      }
      historyError = error.localizedDescription
    }
  }

  private func resolveCountries() async {
    guard !Task.isCancelled, !isSnapshot, monitor.status != .preview, pageVisible,
      model.isMainWindowVisible
    else {
      return
    }
    let pageAddresses = displayedHistory?.records.compactMap(\.address) ?? []
    let visibleAddresses = Set(monitor.records.compactMap(\.address) + pageAddresses)
    do {
      // 每次只补一批历史未知地址，后续持久化版本再补下一批，禁止循环读完整库。
      let version = await OfflineGeography.shared.locationVersion()
      let pending: [String]
      if usesHistory && monitor.historyEnabled && refreshesHistory {
        pending =
          version.isEmpty
          ? try await monitor.historyStore.pendingAddresses(limit: 256)
          : try await monitor.historyStore.pendingLocationAddresses(version: version)
      } else {
        pending = []
      }
      guard !Task.isCancelled else { return }
      let addresses = visibleAddresses.union(pending)
      var result = await OfflineGeography.shared.resolve(Array(addresses))
      var details = try await OfflineGeography.shared.resolveLocations(Array(addresses))
      guard !Task.isCancelled else { return }
      if !version.isEmpty {
        for address in addresses {
          if details[address] == nil { details[address] = NetworkIPLocation() }
          if details[address]?.province.isEmpty == false { result[address] = "CN" }
        }
      }
      if model.networkGeography.hasData {
        // 已有地图库时，明确的未知/内网也落库，避免同一批地址永远占满待解析窗口。
        for address in addresses where result[address] == nil { result[address] = "??" }
      }
      let changed = result.filter { resolvedCountries[$0.key] != $0.value }
      let changedLocations = details.filter { resolvedLocations[$0.key] != $0.value }
      // 长期归属保存在数据库，UI只保留实时窗口和当前页所需的映射。
      resolvedCountries = result.filter { visibleAddresses.contains($0.key) }
      resolvedLocations = details.filter { visibleAddresses.contains($0.key) }
      if usesHistory, monitor.historyEnabled, !changed.isEmpty || !changedLocations.isEmpty {
        if !changed.isEmpty { try await monitor.historyStore.updateCountries(changed) }
        if !version.isEmpty, !changedLocations.isEmpty {
          try await monitor.historyStore.updateLocations(changedLocations, version: version)
        }
        guard !Task.isCancelled else { return }
        if refreshesHistory { historyRefresh &+= 1 }
      }
    } catch {
      guard !Task.isCancelled else { return }
      historyError = error.localizedDescription
    }
  }

  private var previewRecords: [ObservedConnection] {
    let filter = NetworkConnectionFilter(
      grouping: grouping, selection: selection, query: search, countries: places)
    return monitor.records.filter {
      filter.matches($0) && (!activeOnly || monitor.activeConnectionIDs.contains($0.id))
    }
  }

  private var historyControls: some View {
    HStack(spacing: DS.Space.s3) {
      Picker(tr("时间范围"), selection: $historyInterval) {
        Text(tr("5 分钟")).tag(TimeInterval(300))
        Text(tr("15 分钟")).tag(TimeInterval(900))
      }.pickerStyle(.segmented).labelsHidden().fixedSize()
      Text(
        verbatim: historyEnd.addingTimeInterval(-historyInterval).formatted(
          .dateTime.hour().minute().second().locale(L10n.locale))
          + " – " + historyEnd.formatted(.dateTime.hour().minute().second().locale(L10n.locale))
      )
      .dsFont(.xs).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
      Spacer(minLength: 0)
      Button(tr("更新")) {
        historyEnd = NetworkConnectionMode.historyEnd()
        historyOffset = 0
        historyRefresh &+= 1
      }.buttonStyle(DSButtonStyle(kind: .ghost)).disabled(isQueryingHistory)
    }.padding(.horizontal, DS.Space.s4).padding(.bottom, DS.Space.s2)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var toolbar: some View {
    HStack(spacing: DS.Space.s2) {
      Picker(tr("查看方式"), selection: $mode) {
        Text(tr("实时")).tag(NetworkConnectionMode.live)
        Text(tr("历史")).tag(NetworkConnectionMode.history)
      }.pickerStyle(.segmented).labelsHidden().frame(width: 148)
      Spacer(minLength: DS.Space.s2)
      Circle().fill(
        monitor.isManuallyPaused
          ? DS.Palette.warning
          : (monitor.isReading || monitor.status == .preview
            ? DS.Palette.success : DS.Palette.textTertiary)
      )
      .frame(width: 6, height: 6).accessibilityHidden(true)
      Text(statusText).dsFont(.sm, weight: .medium)
      Spacer(minLength: DS.Space.s2)
      Button {
        if monitor.status == .preview {
          monitor.setObservationPaused(!monitor.isManuallyPaused)
        } else if monitor.isReading {
          monitor.stop()
        } else if monitor.status == .running {
          monitor.setObservationPaused(false)
        } else if model.networkComponent.requiresInstallation {
          enablesAfterComponentInstall = true
          managesNetworkComponent = true
        } else {
          monitor.start()
        }
      } label: {
        Label(
          monitor.isReading ? tr("停止采集") : tr("开始采集"),
          systemImage: monitor.isReading ? "stop.fill" : "play.fill")
      }.buttonStyle(DSButtonStyle(kind: .ghost)).disabled(monitor.isBusy)
      Menu {
        Button(tr("管理组件")) { managesNetworkComponent = true }
        Divider()
        Button(tr("更新地图数据库")) { model.networkGeography.retry() }
          .disabled(!monitor.isReading || model.networkGeography.state.isDownloading)
        Button(tr("清空记录")) {
          if usesHistory {
            clearingHistoryRevision = monitor.historyRevision
            historyView = nil
            loadedHistoryQuery = nil
          }
          monitor.clearRecords()
          historyOffset = 0
          historyRefresh &+= 1
        }
        .disabled(!usesHistory && monitor.records.isEmpty)
        Divider()
        Button(tr("移除网络扩展")) { monitor.uninstall() }.disabled(
          monitor.isBusy || monitor.status == .preview)
      } label: {
        Image(systemName: "ellipsis")
      }
      .menuStyle(.borderlessButton).fixedSize().help(tr("更多"))
    }.padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s2)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func groupList(_ groups: [NetworkConnectionGroup]) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack {
        Picker(
          tr("汇总方式"),
          selection: Binding(
            get: { grouping },
            set: {
              grouping = $0
              selection = nil
            })
        ) {
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
          Button {
            search = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).accessibilityLabel(tr("清除搜索"))
        }
      }.dsFont(.sm).padding(DS.Space.s2)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: DS.Space.s1) {
            Button {
              selection = nil
              focusedGroup = NetworkConnectionGroup.allIdentifier
            } label: {
              HStack(spacing: DS.Space.s2) {
                Image(systemName: "square.grid.2x2").frame(width: 26)
                  .foregroundStyle(DS.Palette.primary).accessibilityHidden(true)
                Text(tr("全部")).dsFont(.sm, weight: selection == nil ? .semibold : .medium)
                  .foregroundStyle(DS.Palette.textPrimary)
                Spacer(minLength: DS.Space.s1)
                if !usesHistory || selection == nil {
                  Text(
                    verbatim: (usesHistory
                      ? displayedHistory?.total ?? 0
                      : monitor.records.filter {
                        NetworkConnectionGroup.matches($0, query: search)
                          && (!activeOnly || monitor.activeConnectionIDs.contains($0.id))
                      }.count)
                      .formatted(
                        .number.locale(L10n.locale))
                  )
                  .dsFont(.xs, weight: .medium).monospacedDigit().foregroundStyle(
                    DS.Palette.textSecondary)
                }
              }.padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                .background(
                  selection == nil ? DS.Palette.sidebarSelected : .clear,
                  in: RoundedRectangle(cornerRadius: DS.Radius.md))
            }.buttonStyle(.plain).id(NetworkConnectionGroup.allIdentifier).focusable()
              .focused($focusedGroup, equals: NetworkConnectionGroup.allIdentifier)
              .accessibilityAddTraits(selection == nil ? .isSelected : [])
            ForEach(groups) { group in
              HStack(spacing: 0) {
                if grouping == .country {
                  if group.hasChildren {
                    Button {
                      if expandedRegions.contains(group.id) {
                        expandedRegions = expandedRegions.filter {
                          !NetworkRegionHierarchy.matches($0, selection: group.id)
                        }
                        if let selection, selection != group.id,
                          NetworkRegionHierarchy.matches(selection, selection: group.id)
                        {
                          self.selection = group.id
                          selectedTitle = group.name
                        }
                      } else {
                        expandedRegions.insert(group.id)
                      }
                    } label: {
                      Image(
                        systemName: expandedRegions.contains(group.id)
                          ? "chevron.down" : "chevron.right"
                      )
                      .font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 30)
                    }.buttonStyle(.plain)
                      .accessibilityLabel(expandedRegions.contains(group.id) ? tr("收起") : tr("展开"))
                      .accessibilityValue(group.name)
                  } else {
                    Color.clear.frame(width: 18, height: 1)
                  }
                }
                Button {
                  selection = group.id
                  selectedTitle = group.name
                  focusedGroup = group.id
                } label: {
                  HStack(spacing: DS.Space.s2) {
                    if grouping == .apps || grouping == .process {
                      AppIconCache.shared.image(bundlePath: group.applicationPath)
                        .resizable().frame(width: 26, height: 26).accessibilityHidden(true)
                    } else {
                      Image(systemName: grouping == .domain ? "globe" : "mappin.and.ellipse")
                        .frame(width: 26).foregroundStyle(DS.Palette.textSecondary)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                      Text(
                        verbatim: grouping == .country && group.id.contains("|")
                          ? String(group.id.split(separator: "|").last ?? "") : group.name
                      ).dsFont(
                        .sm, weight: selection == group.id ? .semibold : .medium
                      )
                      .foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                      if grouping == .process, let processID = group.processID {
                        Text(verbatim: "PID \(processID)")
                          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                      }
                    }
                    Spacer(minLength: DS.Space.s1)
                    Text(verbatim: group.count.formatted(.number.locale(L10n.locale)))
                      .dsFont(.xs, weight: .medium).monospacedDigit()
                      .foregroundStyle(
                        selection == group.id ? DS.Palette.primary : DS.Palette.textSecondary
                      )
                      .padding(.horizontal, 6).padding(.vertical, 3)
                      .background(DS.Palette.elevated.opacity(0.7), in: Capsule())
                  }.padding(.horizontal, DS.Space.s2).padding(.vertical, DS.Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md))
                    .background(
                      selection == group.id ? DS.Palette.sidebarSelected : .clear,
                      in: RoundedRectangle(cornerRadius: DS.Radius.md))
                }.buttonStyle(.plain).id(group.id)
                  .focusable()
                  .focused($focusedGroup, equals: group.id)
                  .accessibilityAddTraits(selection == group.id ? .isSelected : [])
              }.padding(
                .leading,
                grouping == .country
                  ? CGFloat(max(0, NetworkRegionHierarchy.depth(group.id))) * 12 : 0)
            }
          }
        }.onMoveCommand { direction in
          let identifiers = [NetworkConnectionGroup.allIdentifier] + groups.map(\.id)
          guard direction == .up || direction == .down else { return }
          let current =
            identifiers.firstIndex(of: selection ?? NetworkConnectionGroup.allIdentifier) ?? 0
          let next = min(identifiers.count - 1, max(0, current + (direction == .down ? 1 : -1)))
          let identifier = identifiers[next]
          selection = identifier == NetworkConnectionGroup.allIdentifier ? nil : identifier
          selectedTitle = groups.first { $0.id == identifier }?.name ?? ""
          focusedGroup = identifier
          proxy.scrollTo(identifier)
        }
      }
      Label(tr("只读观察 · 全部放行"), systemImage: "eye")
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).fixedSize(
          horizontal: false, vertical: true)
    }.padding(.horizontal, DS.Space.s3).padding(.top, DS.Space.s2).padding(.bottom, DS.Space.s3)
  }

  private func connectionDetail(
    _ selected: NetworkConnectionGroup?, records: [ObservedConnection], total: Int
  ) -> some View {
    let rowLocations = locations
    let rowCountries = countries
    let filter = NetworkConnectionFilter(
      grouping: grouping, selection: selection, query: search, countries: places)
    let providedPoints = usesHistory ? displayedHistory?.points ?? [] : nil
    let hasStoredTraffic =
      providedPoints?.contains {
        $0.receivedBytesPerSecond != nil || $0.sentBytesPerSecond != nil
      } ?? false
    // 节点数量来自完整 SQL 聚合；实时窗口只提供新到达反馈，历史不重播光环。
    let mapRecords =
      usesHistory
      ? monitor.records.filter {
        filter.matches($0) && (!activeOnly || monitor.activeConnectionIDs.contains($0.id))
      } : records
    return VStack(alignment: .leading, spacing: DS.Space.s2) {
      ScrollView {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
          HStack(spacing: DS.Space.s3) {
            if selected?.id == NetworkConnectionGroup.allIdentifier {
              Image(systemName: "network").font(.system(size: 24)).foregroundStyle(
                DS.Palette.primary
              )
              .frame(width: 32, height: 32).accessibilityHidden(true)
            } else if let selected, grouping == .apps || grouping == .process {
              AppIconCache.shared.image(bundlePath: selected.applicationPath)
                .resizable().frame(width: 32, height: 32).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
              Text(verbatim: selected?.name ?? tr("暂无连接记录")).dsFont(.lg, weight: .semibold)
                .lineLimit(1)
              Text(activeOnly ? tr("活动连接") : tr("最近连接记录"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer(minLength: DS.Space.s1)
            Text(verbatim: total.formatted(.number.locale(L10n.locale)))
              .dsFont(.lg, weight: .medium).monospacedDigit().foregroundStyle(
                DS.Palette.textSecondary)
          }
          if let error = monitor.error {
            Text(verbatim: error).dsFont(.xs).foregroundStyle(DS.Palette.error)
              .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          }
          if usesHistory {
            if let historyError {
              VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(displayedHistory == nil ? tr("无法读取") : tr("读取失败，显示上次统计结果"))
                HStack(alignment: .top, spacing: DS.Space.s2) {
                  DisclosureGroup(tr("错误详情")) {
                    Text(verbatim: historyError).textSelection(.enabled)
                  }
                  Button(tr("重试")) {
                    clearingHistoryRevision = nil
                    historyRefresh &+= 1
                  }
                  .buttonStyle(DSButtonStyle(kind: .ghost))
                }
              }.dsFont(.xs).foregroundStyle(DS.Palette.error)
            } else if isQueryingHistory && displayedHistory == nil {
              ProgressView(tr("正在读取…")).controlSize(.small).dsFont(.xs)
            }
          }
          if !isSnapshot { geographyStatus }
          if selection != "LAN" && selection != "??" {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
              ConnectionWorldMap(
                world: mapWorld, records: mapRecords, observedRecords: monitor.records,
                countries: places, locations: locations,
                providedDestinations: usesHistory
                  ? NetworkMapDestination.make(
                    world: mapWorld, regions: displayedHistory?.regions ?? []) : nil,
                isReading: mode == .live && pageVisible && model.isMainWindowVisible
                  && monitor.isReading
                  && monitor.status != .preview && !isSnapshot
              ) { code in
                let parts = code.split(separator: "|").map(String.init)
                let key =
                  parts.count == 3 && parts[1] == parts[2]
                  ? parts.prefix(2).joined(separator: "|") : parts.joined(separator: "|")
                grouping = .country
                selection = key
                selectedTitle = networkRegionName(key)
                for depth in 0..<NetworkRegionHierarchy.depth(key) {
                  if let parent = NetworkRegionHierarchy.key(key, at: depth) {
                    expandedRegions.insert(parent)
                  }
                }
              }.frame(minHeight: 150, idealHeight: 170, maxHeight: 190)
              HStack {
                Text(mode == .history ? tr("近期连接地区分布") : tr("连接地区分布"))
                  .dsFont(.xs, weight: .medium)
                Image(systemName: "info.circle").foregroundStyle(DS.Palette.textTertiary)
                  .help(tr("按城市、省份或国家聚合，非设备精确位置"))
                  .accessibilityLabel(tr("按城市、省份或国家聚合，非设备精确位置"))
                Spacer(minLength: DS.Space.s1)
                Link("DB-IP", destination: URL(string: "https://db-ip.com/")!)
                Link(
                  "ip2region",
                  destination: URL(string: "https://github.com/lionsoul2014/ip2region")!)
              }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
          }
          NetworkTrafficChart(
            history: usesHistory ? NetworkTrafficHistory() : monitor.trafficHistory,
            available: mode == .history || monitor.trafficAvailable || hasStoredTraffic,
            matching: filter.matches,
            providedPoints: providedPoints, interval: mode == .live ? 60 : historyInterval,
            summarizesHistory: mode == .history)
          Text(tr("连接详情")).dsFont(.sm, weight: .semibold)
          if records.isEmpty && !isQueryingHistory && historyError == nil {
            ContentUnavailableView(
              search.isEmpty ? tr("暂无连接记录") : tr("没有匹配的连接"), systemImage: "network")
          } else {
            LazyVStack(spacing: 0) {
              ForEach(records) { record in
                let location = record.address.flatMap { rowLocations[$0]?.displayName } ?? ""
                let name =
                  location.isEmpty
                  ? networkRegionName(
                    record.address.flatMap { rowCountries[$0] } ?? "??", address: record.address)
                  : location
                connectionRow(record, locationName: name)
                if record.id != records.last?.id { Divider().opacity(0.5) }
              }
            }
          }
        }
      }.id([mode.rawValue, grouping.rawValue, selection ?? "", search, String(historyOffset)])
      if usesHistory, let result = displayedHistory {
        historyPagination(records: result.records.count, total: result.total)
      }
      HStack(alignment: .top, spacing: DS.Space.s2) {
        Image(systemName: "info.circle").accessibilityHidden(true)
        Text(
          mode == .history
            ? tr("仅保留最近 15 分钟的观察记录；过期数据会自动清理。")
            : tr("显示观察期间的新连接；重新开始前已建立的连接不在此列。")
        )
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

  private func historyPagination(records: Int, total: Int) -> some View {
    let page = NetworkHistoryPagination(offset: historyOffset, count: records, total: total)
    let range = Text(
      tr(
        "第 \(page.first.formatted(.number.locale(L10n.locale)))–\(page.last.formatted(.number.locale(L10n.locale))) 条，共 \(total.formatted(.number.locale(L10n.locale))) 条"
      )
    ).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    let controls = HStack(spacing: DS.Space.s2) {
      Button(tr("上一页")) { historyOffset = page.previousOffset }
        .disabled(!page.hasPrevious || isQueryingHistory)
      Button(tr("下一页")) { historyOffset = page.nextOffset }
        .disabled(!page.hasNext || isQueryingHistory)
    }.buttonStyle(DSButtonStyle(kind: .ghost))
    return ViewThatFits(in: .horizontal) {
      HStack {
        range
        Spacer(minLength: DS.Space.s1)
        controls
      }
      VStack(alignment: .leading, spacing: DS.Space.s1) {
        range
        HStack {
          Spacer(minLength: 0)
          controls
        }
      }
    }
  }

  private func connectionRow(_ record: ObservedConnection, locationName: String) -> some View {
    HStack(alignment: .top, spacing: DS.Space.s3) {
      Image(systemName: record.direction == .outbound ? "arrow.up.right" : "arrow.down.left")
        .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Palette.textSecondary)
        .frame(width: 26, height: 26).background(
          DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.sm)
        )
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
        if mode == .history {
          HStack(spacing: DS.Space.s2) {
            Text(record.timestamp, format: .dateTime.hour().minute().second().locale(L10n.locale))
            if let closed = record.closedAt {
              Image(systemName: "arrow.right").accessibilityHidden(true)
              Text(closed, format: .dateTime.hour().minute().second().locale(L10n.locale))
              Text(tr("已结束"))
            } else {
              Text(tr("未记录结束"))
            }
          }.dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
      }
      Spacer(minLength: DS.Space.s1)
      VStack(alignment: .trailing, spacing: DS.Space.s1) {
        Text(verbatim: locationName)
          .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
          .help(locationName)
        Text(
          verbatim: selection == nil || grouping == .country || grouping == .domain
            ? "\(record.applicationName) · PID \(record.processID)" : "PID \(record.processID)"
        )
        .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary).lineLimit(1).help(
          record.applicationName)
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
          Text(
            verbatim: progress.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
          )
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
      if !showsConnectionDetail {
        Label(tr("网络监视器"), systemImage: "network").dsFont(.lg, weight: .semibold)
        Text(tr("查看应用连接、域名和国家或地域分布，不读取通信内容。"))
          .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
      }
      if let progress = monitor.installationProgress {
        Text(tr("正在下载")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
        ProgressView(value: progress)
      }
      if monitor.status == .needsApproval {
        Text(tr("请在系统设置中允许 XStats 网络扩展，然后返回此处。"))
          .dsFont(.sm).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: DS.Space.s2) {
          Button(tr("打开系统设置")) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
              NSWorkspace.shared.open(url)
            }
          }.buttonStyle(DSButtonStyle(kind: .primary))
          Button(tr("启用连接查看")) { monitor.start() }
            .buttonStyle(DSButtonStyle(kind: .ghost)).disabled(monitor.isBusy)
        }
      } else if monitor.status == .restartRequired {
        Text(tr("需要重启系统")).foregroundStyle(DS.Palette.warning)
      } else {
        Button(tr("启用连接查看")) {
          if model.networkComponent.requiresInstallation {
            enablesAfterComponentInstall = true
            managesNetworkComponent = true
          } else {
            monitor.start()
          }
        }
        .buttonStyle(DSButtonStyle(kind: .primary)).disabled(monitor.isBusy)
      }
      if let error = monitor.error, !showsConnectionDetail {
        DisclosureGroup(tr("错误详情")) { Text(verbatim: error).dsFont(.xs).textSelection(.enabled) }
          .dsFont(.sm).foregroundStyle(DS.Palette.error)
      }
    }.padding(showsConnectionDetail ? DS.Space.s2 : DS.Space.s6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg)).padding(
        DS.Space.s3)
  }

  private var statusText: String {
    switch monitor.status {
    case .idle: tr("采集已停止")
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
func networkRegionName(_ code: String, address: String? = nil) -> String {
  if code.hasPrefix("CN|") {
    let names = code.split(separator: "|").dropFirst().map(String.init)
    return (names.count == 2 && names[0] == names[1] ? [names[0]] : names)
      .joined(separator: " · ")
  }
  return switch code {
  case "CN": tr("中国大陆")
  case "HK": tr("中国香港")
  case "MO": tr("中国澳门")
  case "TW": tr("中国台湾")
  case "LAN": tr("内网地址")
  case "??":
    address.map(OfflineGeography.isLocalAddress) == true ? tr("内网地址") : tr("位置未知")
  default: L10n.locale.localizedString(forRegionCode: code) ?? code
  }
}
