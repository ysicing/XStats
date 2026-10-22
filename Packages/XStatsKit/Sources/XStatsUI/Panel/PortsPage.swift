// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Metrics
import SwiftUI

/// 网络页入口采用原生 sheet，复用完整端口页和主窗口的可见性需求。
struct PortsButton: View {
  @Environment(AppModel.self) private var model
  @State private var presented = false

  var body: some View {
    MiniIconButton(systemName: "point.3.connected.trianglepath.dotted", help: tr("端口")) {
      presented = true
    }
    .sheet(isPresented: $presented) {
      PortsSheet()
        .environment(\.isPopover, false)
    }
    .onChange(of: model.settings.showsPortsInNetwork) { _, visible in
      if !visible { presented = false }
    }
  }
}

struct PortsSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: DS.Space.s3) {
      HStack {
        Text(tr("端口")).font(.title2.bold())
        Spacer()
        Button(tr("完成")) { dismiss() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.cancelAction)
      }
      .padding([.horizontal, .top], DS.Space.s3)
      PortsPage()
    }
    .frame(minWidth: 760, idealWidth: 960, minHeight: 480, idealHeight: 640)
    .onAppear { model.isPortsSheetPresented = true }
    .onDisappear { model.isPortsSheetPresented = false }
  }
}

/// 端口查看：本机监听端口与已建立连接、所属进程、按进程速率，可结束当前用户的占用进程
struct PortsPage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
  @State private var search = ""
  @State private var filter: PortFilter = .all
  @State private var sortColumn: PortColumn = .port
  @State private var ascending = true
  @State private var selection: String?
  @State private var pendingQuit: PortSocket?
  @State private var actionError: String?

  var body: some View {
    let controller = model.ports
    let rows = PortListing.rows(
      controller.sockets, filter: filter, query: search, column: sortColumn, ascending: ascending,
      rates: controller.rates)
    let selected = rows.first { $0.id == selection }

    VStack(alignment: .leading, spacing: DS.Space.s3) {
      toolbar

      Card(padding: 0, spacing: 0) {
        PortHeader(sortColumn: sortColumn, ascending: ascending) { column in
          if column == sortColumn {
            ascending.toggle()
          } else {
            sortColumn = column
            ascending = column.ascendingByDefault
          }
        }
        HairlineDivider()
        if rows.isEmpty {
          Text(emptyText)
            .dsFont(.sm)
            .foregroundStyle(DS.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(DS.Space.s6)
        } else if isSnapshot {
          ForEach(rows.prefix(16)) { socket in
            PortTableRow(
              socket: socket, rate: controller.rates[socket.pid],
              isConflict: isConflict(socket, controller.conflicts), isSelected: false,
              sortColumn: sortColumn)
          }
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(rows) { socket in
                PortTableRow(
                  socket: socket, rate: controller.rates[socket.pid],
                  isConflict: isConflict(socket, controller.conflicts),
                  isSelected: socket.id == selection, sortColumn: sortColumn
                )
                .onTapGesture {
                  selection = socket.id
                  actionError = nil
                }
                .contextMenu { menu(for: socket) }
              }
            }
            .overlayScrollers()
          }
          .frame(maxHeight: .infinity)
        }
      }
      .frame(maxHeight: isSnapshot ? nil : .infinity)

      if let selected {
        PortInspector(
          socket: selected, rate: controller.rates[selected.pid],
          isConflict: isConflict(selected, controller.conflicts), error: actionError,
          onQuit: { pendingQuit = selected })
      }
      summary(count: rows.count)
    }
    // 顶部不留边距：主窗口顶栏已经在按钮上下留了对称的空
    .padding([.horizontal, .bottom], DS.Space.s3)
    .frame(maxHeight: isSnapshot ? nil : .infinity, alignment: .top)
    .confirmationDialog(
      // 辅助进程的 displayName 是主应用名，而这里只会结束这一个进程，标题必须写出真实进程名与 PID
      pendingQuit.map { tr("结束“\($0.name)”（PID \($0.pid)）？") } ?? "",
      isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
      titleVisibility: .visible, presenting: pendingQuit
    ) { socket in
      Button(tr("退出")) { quit(socket, force: false) }
      Button(tr("强制退出"), role: .destructive) { quit(socket, force: true) }
      Button(tr("取消"), role: .cancel) {}
    } message: { _ in
      Text(tr("会断开它占用的端口与连接，未保存的内容可能会丢失。强制退出会立即结束，不给应用保存的机会。"))
    }
  }

  private var emptyText: String {
    let controller = model.ports
    if !controller.hasLoaded { return tr("正在读取端口…") }
    if controller.failed { return tr("暂时无法读取端口") }
    return tr("没有匹配的端口")
  }

  /// 冲突只针对 TCP 监听；同端口的已建立连接或 UDP 不标记
  private func isConflict(_ socket: PortSocket, _ conflicts: Set<Int>) -> Bool {
    socket.transport == .tcp && socket.state == .listening && conflicts.contains(socket.localPort)
  }

  // MARK: 工具栏与汇总

  private var toolbar: some View {
    HStack(spacing: DS.Space.s3) {
      HStack(spacing: DS.Space.s2) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
          .foregroundStyle(DS.Palette.textTertiary)
        TextField(tr("搜索端口、进程、服务或地址"), text: $search)
          .textFieldStyle(.plain)
          .dsFont(.sm)
        if !search.isEmpty {
          MiniIconButton(systemName: "xmark.circle.fill", help: tr("清除搜索")) { search = "" }
        }
      }
      .padding(.horizontal, DS.Space.s2)
      .frame(height: DS.Size.controlHeight)
      .frame(maxWidth: DS.Size.sidebarWidth + DS.Space.s16)
      .background(DS.Palette.elevated, in: RoundedRectangle(cornerRadius: DS.Radius.md))
      .overlay(
        RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(
          DS.Palette.neutral300, lineWidth: DS.Size.stroke))

      SegmentedControl(selection: $filter, options: PortFilter.allCases.map { ($0, $0.title) })
        .frame(width: DS.Size.sidebarWidth + DS.Space.s8)
      Spacer(minLength: 0)
      MiniIconButton(systemName: "arrow.clockwise", help: tr("立即刷新")) { model.ports.refresh() }
    }
  }

  private func summary(count: Int) -> some View {
    let sockets = model.ports.sockets
    let listening = sockets.filter { $0.state == .listening }.count
    return HStack(spacing: DS.Space.s4) {
      Text(verbatim: tr("监听 \(listening) · 连接 \(sockets.count - listening)"))
        .dsFont(.xs)
        .monospacedDigit()
        .foregroundStyle(DS.Palette.textSecondary)
      Text(
        sockets.count >= PortSampler.maximumSockets
          ? tr("连接过多，只显示前 \(PortSampler.maximumSockets) 项")
          : tr("仅列出当前用户的进程，系统服务占用的端口不会显示")
      )
      .dsFont(.xs)
      .foregroundStyle(DS.Palette.textTertiary)
      .lineLimit(1)
      Spacer(minLength: DS.Space.s2)
      Text(verbatim: tr("显示 \(count) 项")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
    }
    .padding(.horizontal, DS.Space.s1)
  }

  @ViewBuilder
  private func menu(for socket: PortSocket) -> some View {
    Button(tr("拷贝本地地址")) { copy(socket.localEndpoint) }
    if let remote = socket.remoteEndpoint {
      Button(tr("拷贝对端地址")) { copy(remote) }
    }
    Button(tr("拷贝 PID")) { copy(String(socket.pid)) }
    if let bundle = socket.appBundlePath {
      Button(tr("在访达中显示")) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundle)])
      }
    }
    Divider()
    Button(tr("结束进程…")) {
      selection = socket.id
      actionError = nil
      pendingQuit = socket
    }
    .disabled(PortActions.quitBlockedReason(socket) != nil)
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func quit(_ socket: PortSocket, force: Bool) {
    actionError = PortActions.terminate(socket, force: force)
    guard actionError == nil else { return }
    selection = nil
    model.ports.refresh()
  }
}

// MARK: - 筛选与排序

enum PortFilter: String, CaseIterable {
  case all, listening, established

  var title: String {
    switch self {
    case .all: tr("全部")
    case .listening: tr("监听")
    case .established: tr("已建立")
    }
  }
}

enum PortListing {
  /// 按状态筛选、按关键字搜索后排序。主键相同时依次按端口、PID、标识排序，刷新时行序保持稳定。
  static func rows(
    _ sockets: [PortSocket], filter: PortFilter, query: String, column: PortColumn,
    ascending: Bool, rates: [Int32: NetworkProcessRate]
  ) -> [PortSocket] {
    let query = query.trimmingCharacters(in: .whitespaces)
    // 按进程排序时每次比较都要取本地化名称，先算一遍
    let names =
      column == .process
      ? Dictionary(sockets.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
      : [:]
    let filtered = sockets.filter { socket in
      switch filter {
      case .all: break
      case .listening: guard socket.state == .listening else { return false }
      case .established: guard socket.state == .established else { return false }
      }
      return query.isEmpty || socket.matches(query)
    }
    return filtered.sorted { lhs, rhs in
      let primary = column.compare(lhs, rhs, rates: rates, names: names)
      if primary != .orderedSame { return ascending == (primary == .orderedAscending) }
      return (lhs.localPort, lhs.pid, lhs.id) < (rhs.localPort, rhs.pid, rhs.id)
    }
  }
}

enum PortColumn: CaseIterable {
  case port, process, peer, download, upload

  var title: String {
    switch self {
    case .port: tr("端口号")
    case .process: tr("进程")
    case .peer: tr("对端")
    case .download: tr("下载")
    case .upload: tr("上传")
    }
  }

  var width: CGFloat? {
    switch self {
    case .port: DS.Size.valueColumn + DS.Space.s8
    case .process: nil
    case .peer: DS.Size.sidebarWidth + DS.Space.s4
    case .download, .upload: DS.Size.valueColumn + DS.Space.s2
    }
  }

  var help: String {
    switch self {
    case .download, .upload: tr("按进程统计，同一进程的各行速率相同")
    default: ""
    }
  }

  var ascendingByDefault: Bool { ![.download, .upload].contains(self) }

  func compare(
    _ lhs: PortSocket, _ rhs: PortSocket, rates: [Int32: NetworkProcessRate],
    names: [String: String] = [:]
  ) -> ComparisonResult {
    switch self {
    case .port: Self.order(lhs.localPort, rhs.localPort)
    case .process:
      (names[lhs.id] ?? lhs.displayName).localizedStandardCompare(names[rhs.id] ?? rhs.displayName)
    // 监听端口没有对端，排在已建立连接之前
    case .peer: (lhs.remoteEndpoint ?? "").localizedStandardCompare(rhs.remoteEndpoint ?? "")
    case .download: Self.order(rates[lhs.pid]?.download ?? 0, rates[rhs.pid]?.download ?? 0)
    case .upload: Self.order(rates[lhs.pid]?.upload ?? 0, rates[rhs.pid]?.upload ?? 0)
    }
  }

  private static func order<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
  }
}

extension PortSocket {
  /// 应用及其辅助进程显示应用的本地化名称，与进程页一致
  var displayName: String {
    guard let appBundlePath else { return name }
    let appName = URL(fileURLWithPath: appBundlePath).deletingPathExtension().lastPathComponent
    return name.hasPrefix(appName) ? AppNameCache.shared.name(forBundle: appBundlePath) : name
  }

  /// 端口号按前缀匹配，PID 精确匹配；名称、服务名与地址按包含匹配
  func matches(_ query: String) -> Bool {
    String(localPort).hasPrefix(query) || remotePort.map { String($0).hasPrefix(query) } == true
      || String(pid) == query
      || displayName.localizedCaseInsensitiveContains(query)
      || name.localizedCaseInsensitiveContains(query)
      || PortServices.name(for: localPort)?.localizedCaseInsensitiveContains(query) == true
      || localAddress?.localizedCaseInsensitiveContains(query) == true
      || remoteAddress?.localizedCaseInsensitiveContains(query) == true
  }
}

// MARK: - 表格

private struct PortHeader: View {
  let sortColumn: PortColumn
  let ascending: Bool
  let onSort: (PortColumn) -> Void

  var body: some View {
    HStack(spacing: DS.Space.s2) {
      ForEach(PortColumn.allCases, id: \.self) { column in
        let trailing = column == .download || column == .upload
        Button {
          onSort(column)
        } label: {
          HStack(spacing: DS.Space.s1 / 2) {
            if trailing { Spacer(minLength: 0) }
            Text(column.title).lineLimit(1)
            if column == sortColumn {
              Image(systemName: ascending ? "chevron.up" : "chevron.down")
                .font(.system(size: DS.TextSize.xs.rawValue - DS.Space.s1, weight: .bold))
            }
            if !trailing { Spacer(minLength: 0) }
          }
          .foregroundStyle(column == sortColumn ? DS.Palette.primary : DS.Palette.textTertiary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(column.help)
        .frame(width: column.width)
        .frame(maxWidth: column.width == nil ? .infinity : nil)
        .padding(.leading, column == .process ? DS.Size.iconStandalone + DS.Space.s3 : 0)
      }
    }
    .dsFont(.xs, weight: .medium)
    .padding(.horizontal, DS.Space.s4)
    .frame(height: DS.Size.controlHeight)
  }
}

private struct PortTableRow: View {
  let socket: PortSocket
  let rate: NetworkProcessRate?
  let isConflict: Bool
  let isSelected: Bool
  let sortColumn: PortColumn
  @State private var hovering = false

  var body: some View {
    HStack(spacing: DS.Space.s2) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
          Text(verbatim: String(socket.localPort))
            .dsFont(.sm, weight: .semibold)
            .foregroundStyle(DS.Palette.textPrimary)
          Text(verbatim: socket.transport.rawValue)
            .dsFont(.xs)
            .foregroundStyle(DS.Palette.textTertiary)
        }
        if let service = PortServices.name(for: socket.localPort) {
          Text(verbatim: service).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
      }
      .lineLimit(1)
      .frame(width: PortColumn.port.width, alignment: .leading)

      HStack(spacing: DS.Space.s3) {
        AppIconCache.shared.image(bundlePath: socket.appBundlePath)
          .resizable()
          .frame(width: DS.Size.iconStandalone, height: DS.Size.iconStandalone)
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: DS.Space.s1) {
            Text(verbatim: socket.displayName).dsFont(.sm).foregroundStyle(DS.Palette.textPrimary)
            if isConflict { TagBadge(text: tr("冲突"), tone: .warning, compact: true) }
          }
          Text(verbatim: "PID \(socket.pid)").dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
        .lineLimit(1)
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity)

      VStack(alignment: .leading, spacing: 0) {
        if let remote = socket.remoteEndpoint {
          Text(verbatim: remote).dsFont(.xs).foregroundStyle(DS.Palette.textPrimary)
        } else {
          TagBadge(text: tr("监听"), tone: .success, compact: true)
        }
        Text(verbatim: socket.localEndpoint).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
      }
      .lineLimit(1)
      .truncationMode(.middle)
      .frame(width: PortColumn.peer.width, alignment: .leading)

      rateCell(.download, rate?.download)
      rateCell(.upload, rate?.upload)
    }
    .monospacedDigit()
    .padding(.horizontal, DS.Space.s4)
    .padding(.vertical, DS.Space.s1 + DS.Space.s1 / 2)
    .background(
      isSelected ? DS.Palette.primary.opacity(0.14) : hovering ? DS.Palette.surfaceHover : .clear
    )
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
  }

  private func rateCell(_ column: PortColumn, _ value: Double?) -> some View {
    // 不足 1 B/s 视为空闲，与菜单栏读数保持一致
    let text = value.flatMap { $0 >= 1 ? Format.menuBarRate($0) : nil } ?? "—"
    return Text(verbatim: text)
      .dsFont(.xs, weight: column == sortColumn ? .semibold : .regular)
      .foregroundStyle(column == sortColumn ? DS.Palette.textPrimary : DS.Palette.textSecondary)
      .lineLimit(1)
      .frame(width: column.width, alignment: .trailing)
  }
}

/// 选中端口后的详情条：应用路径、协议与地址、冲突提示，以及结束进程
private struct PortInspector: View {
  let socket: PortSocket
  let rate: NetworkProcessRate?
  let isConflict: Bool
  let error: String?
  let onQuit: () -> Void

  var body: some View {
    let blocked = PortActions.quitBlockedReason(socket)
    Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
      HStack(spacing: DS.Space.s3) {
        AppIconCache.shared.image(bundlePath: socket.appBundlePath)
          .resizable()
          .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
        VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
          Text(verbatim: socket.displayName).dsFont(.sm, weight: .semibold)
            .foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
          Text(verbatim: details)
            .dsFont(.xs)
            .monospacedDigit()
            .foregroundStyle(DS.Palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
        Spacer(minLength: DS.Space.s3)
        if let bundle = socket.appBundlePath {
          IconButton(systemName: "folder", help: tr("在访达中显示")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bundle)])
          }
        }
        Button(tr("结束进程…")) { onQuit() }
          .buttonStyle(DSButtonStyle(kind: .secondary))
          .disabled(blocked != nil)
          .help(blocked ?? "")
      }
      if let error {
        Text(error).dsFont(.xs).foregroundStyle(DS.Palette.error)
      } else if let blocked {
        Text(blocked).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
      } else if isConflict {
        Text(tr("端口 \(socket.localPort) 同时被多个进程监听"))
          .dsFont(.xs).foregroundStyle(DS.Palette.warning)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private var details: String {
    var parts = [
      "PID \(socket.pid)", socket.transport.rawValue.uppercased(), socket.localEndpoint,
    ]
    if let remote = socket.remoteEndpoint { parts.append("→ \(remote)") }
    if let service = PortServices.name(for: socket.localPort) { parts.append(service) }
    if let rate, rate.download + rate.upload >= 1 {
      parts.append("↓ \(Format.menuBarRate(rate.download)) ↑ \(Format.menuBarRate(rate.upload))")
    }
    return parts.joined(separator: " · ")
  }
}
