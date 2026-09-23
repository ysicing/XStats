import AppKit
import Localization
import Metrics
import SwiftUI

/// 进程管理器：包括系统进程，可搜索、筛选、按列排序、按应用合并，选中后查看详情或结束进程
struct ProcessesPage: View {
    enum Scope: String, CaseIterable {
        case all, mine, system

        var title: String {
            switch self {
            case .all: tr("全部")
            case .mine: tr("我的")
            case .system: tr("系统")
            }
        }
    }

    enum Grouping: String, CaseIterable {
        case processes, apps

        var title: String { self == .processes ? tr("按进程") : tr("按应用") }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var search = ""
    @State private var scope: Scope = .all
    @State private var grouping: Grouping = .processes
    @State private var sortColumn: ProcessColumn = .cpu
    @State private var ascending = false
    @State private var selection: String?
    @State private var pendingQuit: ProcessRowModel?
    @State private var actionError: String?
    @State private var tableWidth: CGFloat = DS.Size.panelWidth

    var body: some View {
        let rows = visibleRows()
        let selected = rows.first { $0.id == selection }

        VStack(alignment: .leading, spacing: DS.Space.s3) {
            if model.explainer.subject != nil {
                ProcessExplanationCard()
            }
            toolbar

            let columns = ProcessColumn.visible(forWidth: tableWidth)
            Card(padding: 0, spacing: 0) {
                ProcessHeader(columns: columns, sortColumn: sortColumn, ascending: ascending) { column in
                    if column == sortColumn { ascending.toggle() } else { sortColumn = column; ascending = column.ascendingByDefault }
                }
                HairlineDivider()
                if rows.isEmpty {
                    Text(model.store.processes.isEmpty ? tr("正在读取进程…") : tr("没有匹配的进程"))
                        .dsFont(.sm)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(DS.Space.s6)
                } else if isSnapshot {
                    ForEach(rows.prefix(16)) { row in
                        ProcessTableRow(row: row, columns: columns, isSelected: false, sortColumn: sortColumn)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                ProcessTableRow(row: row, columns: columns, isSelected: row.id == selection, sortColumn: sortColumn)
                                    .onTapGesture { selection = row.id }
                                    .contextMenu { menu(for: row) }
                            }
                        }
                        .overlayScrollers()
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: isSnapshot ? nil : .infinity)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TableWidthKey.self, value: proxy.size.width)
            })
            .onPreferenceChange(TableWidthKey.self) { tableWidth = $0 }

            if let selected {
                ProcessInspector(row: selected, error: actionError,
                                 onQuit: { pendingQuit = selected },
                                 onExplain: { model.explainProcess(.init(selected.representative)) })
            }
            summary(count: rows.count)
        }
        // 顶部不留边距：主窗口顶栏已经在按钮上下留了对称的空
        .padding([.horizontal, .bottom], DS.Space.s3)
        .frame(maxHeight: isSnapshot ? nil : .infinity, alignment: .top)
        .confirmationDialog(pendingQuit.map { tr("结束“\($0.title)”？") } ?? "", isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
                            titleVisibility: .visible, presenting: pendingQuit) { row in
            Button(tr("退出")) { quit(row, force: false) }
            Button(tr("强制退出"), role: .destructive) { quit(row, force: true) }
            Button(tr("取消"), role: .cancel) {}
        } message: { row in
            Text(row.count > 1
                 ? tr("会结束这个应用的 \(row.count) 个进程，未保存的内容可能会丢失。强制退出会立即结束，不给应用保存的机会。")
                 : tr("未保存的内容可能会丢失。强制退出会立即结束，不给应用保存的机会。"))
        }
    }

    // MARK: 工具栏与汇总

    private var toolbar: some View {
        HStack(spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                    .foregroundStyle(DS.Palette.textTertiary)
                TextField(tr("搜索名称、PID 或用户"), text: $search)
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
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(DS.Palette.neutral300, lineWidth: DS.Size.stroke))

            SegmentedControl(selection: $scope, options: Scope.allCases.map { ($0, $0.title) })
                .frame(width: DS.Size.sidebarWidth)
            SegmentedControl(selection: $grouping, options: Grouping.allCases.map { ($0, $0.title) })
                .frame(width: DS.Size.sidebarWidth - DS.Space.s8)
            Spacer(minLength: 0)
        }
    }

    private func summary(count: Int) -> some View {
        let cpu = model.store.cpu
        let counts = model.store.systemCounts
        return HStack(spacing: DS.Space.s4) {
            if let cpu {
                LegendItem(color: DS.Palette.primary, label: tr("用户"), value: Format.percent(cpu.user))
                LegendItem(color: DS.Palette.secondary, label: tr("系统"), value: Format.percent(cpu.system))
                LegendItem(color: DS.Palette.track, label: tr("空闲"), value: Format.percent(max(0, 1 - cpu.total)))
            }
            Spacer(minLength: DS.Space.s2)
            if let counts {
                Text(verbatim: tr("进程 \(counts.processes.formatted()) · 线程 \(counts.threads.formatted())"))
                    .dsFont(.xs)
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Text(verbatim: tr("显示 \(count) 项")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
        .padding(.horizontal, DS.Space.s1)
    }

    @ViewBuilder
    private func menu(for row: ProcessRowModel) -> some View {
        if ProcessExplainer.isSupported {
            Button(tr("用 AI 解释")) { model.explainProcess(.init(row.representative)) }
            Divider()
        }
        if let path = row.bundlePath ?? row.representative.executablePath {
            Button(tr("在访达中显示")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
        if let pid = row.pid {
            Button(tr("拷贝 PID")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(pid), forType: .string)
            }
        }
        Divider()
        Button(row.count > 1 ? tr("退出应用…") : tr("结束进程…")) { selection = row.id; pendingQuit = row }
            .disabled(row.quitBlockedReason != nil)
    }

    // MARK: 数据

    private func visibleRows() -> [ProcessRowModel] {
        let me = getuid()
        let filtered = model.store.processes.filter { process in
            switch scope {
            case .all: true
            case .mine: process.uid == me
            case .system: process.uid != me
            }
        }
        var rows = grouping == .processes
            ? filtered.map(ProcessRowModel.init(process:))
            : ProcessRowModel.grouped(filtered)
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            rows = rows.filter { $0.matches(query) }
        }
        return rows.sorted { lhs, rhs in
            let ordered = sortColumn.isOrdered(lhs, rhs)
            return ascending ? ordered : sortColumn.isOrdered(rhs, lhs)
        }
    }

    private func quit(_ row: ProcessRowModel, force: Bool) {
        actionError = ProcessActions.terminate(row, force: force)
        if actionError == nil { selection = nil }
    }
}

// MARK: - 行模型

struct ProcessRowModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let bundlePath: String?
    let cpu: Double
    let cpuTime: Double
    let memory: UInt64
    let threads: Int?
    let wakeups: Double?
    let disk: (read: Double, write: Double)?
    let user: String
    let pid: Int32?
    let count: Int
    let isOwned: Bool
    let representative: ProcessUsage
    let processes: [ProcessUsage]

    @MainActor
    init(process: ProcessUsage) {
        id = "pid-\(process.pid)"
        title = process.displayName
        subtitle = [process.helperRole, "PID \(process.pid)"].compactMap { $0 }.joined(separator: " · ")
        bundlePath = process.appBundlePath
        cpu = process.cpu
        cpuTime = process.cpuTime
        memory = process.memory
        threads = process.threads
        wakeups = process.idleWakeups
        disk = process.diskRead.map { ($0, process.diskWrite ?? 0) }
        user = process.userName
        pid = process.pid
        count = 1
        isOwned = process.isOwned
        representative = process
        processes = [process]
    }

    private init(group: [ProcessUsage], key: String, title: String) {
        let representative = group.max { $0.memory < $1.memory } ?? group[0]
        id = "app-\(key)"
        self.title = title
        subtitle = group.count > 1 ? tr("\(group.count) 个进程") : "PID \(representative.pid)"
        bundlePath = representative.appBundlePath
        cpu = group.reduce(0) { $0 + $1.cpu }
        cpuTime = group.reduce(0) { $0 + $1.cpuTime }
        memory = group.reduce(0) { $0 + $1.memory }
        let threadCounts = group.compactMap(\.threads)
        threads = threadCounts.isEmpty ? nil : threadCounts.reduce(0, +)
        let wakeupCounts = group.compactMap(\.idleWakeups)
        wakeups = wakeupCounts.isEmpty ? nil : wakeupCounts.reduce(0, +)
        let reads = group.compactMap(\.diskRead)
        disk = reads.isEmpty ? nil : (reads.reduce(0, +), group.compactMap(\.diskWrite).reduce(0, +))
        user = representative.userName
        pid = group.count == 1 ? representative.pid : nil
        count = group.count
        isOwned = group.allSatisfy(\.isOwned)
        self.representative = representative
        processes = group
    }

    /// 同一应用的主进程与辅助进程合并；不属于应用的进程各自一行
    @MainActor
    static func grouped(_ processes: [ProcessUsage]) -> [ProcessRowModel] {
        var buckets: [String: [ProcessUsage]] = [:]
        for process in processes {
            buckets[process.appBundlePath ?? "pid-\(process.pid)", default: []].append(process)
        }
        return buckets.map { key, group in
            if let bundle = group[0].appBundlePath {
                return ProcessRowModel(group: group, key: key, title: AppNameCache.shared.name(forBundle: bundle))
            }
            return ProcessRowModel(process: group[0])
        }
    }

    func matches(_ query: String) -> Bool {
        title.localizedCaseInsensitiveContains(query) || user.localizedCaseInsensitiveContains(query)
            || processes.contains { $0.name.localizedCaseInsensitiveContains(query) || String($0.pid) == query }
    }

    /// 不能从这里结束的原因；nil 表示可以结束
    var quitBlockedReason: String? {
        if !isOwned { return tr("系统或其他用户的进程，XStats 不提供结束") }
        if processes.contains(where: { $0.pid == getpid() }) { return tr("请从菜单退出 XStats") }
        if processes.contains(where: { ProcessActions.protectedNames.contains($0.name) }) { return tr("结束它会注销当前用户，已禁止") }
        return nil
    }
}

private struct TableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = DS.Size.panelWidth
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

enum ProcessColumn: CaseIterable {
    case name, cpu, cpuTime, memory, threads, wakeups, disk, user

    /// 窗口变窄时先隐藏 CPU 时间与唤醒，再窄只保留 CPU、内存与用户，保证名称列至少有 200pt
    static func visible(forWidth width: CGFloat) -> [ProcessColumn] {
        let tiers: [[ProcessColumn]] = [allCases, [.name, .cpu, .memory, .threads, .disk, .user], [.name, .cpu, .memory, .user]]
        return tiers.first { tier in
            let fixed = tier.compactMap(\.width).reduce(0, +) + DS.Space.s2 * CGFloat(tier.count - 1) + DS.Space.s4 * 2
            return width - fixed >= DS.Space.s16 * 3 + DS.Space.s1 * 2
        } ?? tiers[2]
    }

    var title: String {
        switch self {
        case .name: tr("进程")
        case .cpu: "CPU"
        case .cpuTime: tr("CPU 时间")
        case .memory: tr("内存")
        case .threads: tr("线程")
        case .wakeups: tr("唤醒")
        case .disk: tr("磁盘")
        case .user: tr("用户")
        }
    }

    var width: CGFloat? {
        switch self {
        case .name: nil
        case .cpu, .memory, .user: DS.Size.valueColumn
        case .cpuTime, .disk: DS.Size.valueColumn + DS.Space.s4
        case .threads, .wakeups: DS.Size.valueColumn
        }
    }

    var help: String {
        switch self {
        case .cpu: tr("以单核满载为 100%")
        case .cpuTime: tr("进程启动以来累计占用的 CPU 时间")
        case .memory: tr("自己的进程为实际占用内存，系统进程为常驻内存")
        case .threads: tr("线程数（只能读取自己的进程）")
        case .wakeups: tr("每秒让 CPU 从空闲中唤醒的次数，越高越耗电")
        case .disk: tr("每秒读写磁盘的字节数")
        default: ""
        }
    }

    var ascendingByDefault: Bool { self == .name || self == .user }

    func isOrdered(_ lhs: ProcessRowModel, _ rhs: ProcessRowModel) -> Bool {
        switch self {
        case .name: lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case .cpu: lhs.cpu < rhs.cpu
        case .cpuTime: lhs.cpuTime < rhs.cpuTime
        case .memory: lhs.memory < rhs.memory
        case .threads: (lhs.threads ?? -1) < (rhs.threads ?? -1)
        case .wakeups: (lhs.wakeups ?? -1) < (rhs.wakeups ?? -1)
        case .disk: (lhs.disk.map { $0.read + $0.write } ?? -1) < (rhs.disk.map { $0.read + $0.write } ?? -1)
        case .user: lhs.user.localizedStandardCompare(rhs.user) == .orderedAscending
        }
    }
}

// MARK: - 表格

private struct ProcessHeader: View {
    let columns: [ProcessColumn]
    let sortColumn: ProcessColumn
    let ascending: Bool
    let onSort: (ProcessColumn) -> Void

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            ForEach(columns, id: \.self) { column in
                Button { onSort(column) } label: {
                    HStack(spacing: DS.Space.s1 / 2) {
                        if column != .name { Spacer(minLength: 0) }
                        Text(column.title).lineLimit(1)
                        if column == sortColumn {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: DS.TextSize.xs.rawValue - DS.Space.s1, weight: .bold))
                        }
                        if column == .name { Spacer(minLength: 0) }
                    }
                    .foregroundStyle(column == sortColumn ? DS.Palette.primary : DS.Palette.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(column.help)
                .frame(width: column.width)
                .frame(maxWidth: column.width == nil ? .infinity : nil)
                .padding(.leading, column == .name ? DS.Size.iconStandalone + DS.Space.s3 : 0)
            }
        }
        .dsFont(.xs, weight: .medium)
        .padding(.horizontal, DS.Space.s4)
        .frame(height: DS.Size.controlHeight)
    }
}

private struct ProcessTableRow: View {
    let row: ProcessRowModel
    let columns: [ProcessColumn]
    let isSelected: Bool
    let sortColumn: ProcessColumn
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s3) {
                AppIconCache.shared.image(bundlePath: row.bundlePath)
                    .resizable()
                    .frame(width: DS.Size.iconStandalone, height: DS.Size.iconStandalone)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: row.title).dsFont(.sm).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                    Text(verbatim: row.subtitle).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            ForEach(columns.filter { $0 != .name }, id: \.self) { column in
                cell(column, text(for: column))
            }
        }
        .monospacedDigit()
        .padding(.horizontal, DS.Space.s4)
        .padding(.vertical, DS.Space.s1 + DS.Space.s1 / 2)
        .background(isSelected ? DS.Palette.primary.opacity(0.14) : hovering ? DS.Palette.surfaceHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func text(for column: ProcessColumn) -> String {
        switch column {
        case .name: row.title
        case .cpu: row.cpu < 0.0005 ? "0%" : "\((row.cpu * 100).formatted(.number.precision(.fractionLength(1))))%"
        case .cpuTime: Format.cpuTime(row.cpuTime)
        case .memory: Format.bytes(row.memory)
        case .threads: row.threads.map(String.init) ?? "—"
        case .wakeups: row.wakeups.map { String(Int($0.rounded())) } ?? "—"
        case .disk: row.disk.map { Format.menuBarRate($0.read + $0.write) } ?? "—"
        case .user: row.user
        }
    }

    private func cell(_ column: ProcessColumn, _ text: String) -> some View {
        Text(verbatim: text)
            .dsFont(.xs, weight: column == sortColumn ? .semibold : .regular)
            .foregroundStyle(column == sortColumn ? DS.Palette.textPrimary : DS.Palette.textSecondary)
            .lineLimit(1)
            .frame(width: column.width, alignment: .trailing)
    }
}

/// 选中进程后的详情条：路径、PID、用户、线程、磁盘读写，以及解释与结束
private struct ProcessInspector: View {
    let row: ProcessRowModel
    let error: String?
    let onQuit: () -> Void
    let onExplain: () -> Void

    var body: some View {
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s3) {
                AppIconCache.shared.image(bundlePath: row.bundlePath)
                    .resizable()
                    .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
                VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                    Text(verbatim: row.title).dsFont(.sm, weight: .semibold).foregroundStyle(DS.Palette.textPrimary).lineLimit(1)
                    Text(verbatim: row.bundlePath ?? row.representative.executablePath ?? tr("路径不可读"))
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(verbatim: details)
                        .dsFont(.xs)
                        .monospacedDigit()
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.s3)
                if ProcessExplainer.isSupported {
                    Button { onExplain() } label: { Label(tr("AI 解释"), systemImage: "sparkles") }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
                if let path = row.bundlePath ?? row.representative.executablePath {
                    IconButton(systemName: "folder", help: tr("在访达中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                Button(row.count > 1 ? tr("退出应用…") : tr("结束进程…")) { onQuit() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(row.quitBlockedReason != nil)
                    .help(row.quitBlockedReason ?? "")
            }
            if let error {
                Text(error).dsFont(.xs).foregroundStyle(DS.Palette.error)
            } else if let reason = row.quitBlockedReason {
                Text(reason).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .frame(maxHeight: nil)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var details: String {
        var parts = [row.pid.map { "PID \($0)" } ?? tr("\(row.count) 个进程"), tr("用户 \(row.user)")]
        if let threads = row.threads { parts.append(tr("线程 \(threads)")) }
        parts.append(tr("CPU 时间 \(Format.cpuTime(row.cpuTime))"))
        if let disk = row.disk { parts.append(tr("读 \(Format.menuBarRate(disk.read)) · 写 \(Format.menuBarRate(disk.write))")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 结束进程

enum ProcessActions {
    /// 结束会注销当前用户或导致系统异常的进程
    static let protectedNames: Set<String> = ["loginwindow", "WindowServer", "launchd", "kernel_task"]

    /// 返回错误描述，nil 表示已发出结束请求
    @MainActor
    static func terminate(_ row: ProcessRowModel, force: Bool) -> String? {
        if let reason = row.quitBlockedReason { return reason }
        // 应用优先按应用退出：辅助进程会随主进程一起结束，也给应用保存的机会
        if let bundle = row.bundlePath,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == bundle }) {
            let sent = force ? app.forceTerminate() : app.terminate()
            return sent ? nil : tr("应用拒绝退出，可以试试强制退出")
        }
        for process in row.processes where kill(process.pid, force ? SIGKILL : SIGTERM) != 0 {
            return tr("结束 \(process.name) 失败：\(String(cString: strerror(errno)))")
        }
        return nil
    }
}

/// Apple 智能对某个进程的解释，流式显示
private struct ProcessExplanationCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let explainer = model.explainer
        if let subject = explainer.subject {
            Card(padding: DS.Space.s4, spacing: DS.Space.s3) {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: "sparkles")
                        .font(.system(size: DS.TextSize.sm.rawValue, weight: .semibold))
                        .foregroundStyle(DS.Palette.primary)
                    Text(tr("AI 解释")).dsFont(.sm, weight: .semibold).foregroundStyle(DS.Palette.textPrimary)
                    Text(tr(explainer.activeProvider.title)).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    Text(verbatim: "\(subject.displayName) · PID \(subject.pid)")
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.s2)
                    if explainer.canRetry {
                        MiniIconButton(systemName: "arrow.clockwise", help: tr("重新生成")) { explainer.explain(subject) }
                    }
                    MiniIconButton(systemName: "xmark", help: tr("关闭")) { explainer.dismiss() }
                }

                switch explainer.phase {
                case .needsFallback(let reason):
                    InfoBanner(icon: "exclamationmark.triangle.fill", text: reason, tone: .warning)
                    Text(tr("Apple 智能不可用。选择一次备用服务，后续会自动使用，也可以随时在设置中修改。"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.s2) {
                        Button("Codex CLI") {
                            model.aiAssistant.fallbackChoice = .codex
                            explainer.explain(subject, using: .codex)
                        }
                        Button("Claude Code") {
                            model.aiAssistant.fallbackChoice = .claude
                            explainer.explain(subject, using: .claude)
                        }
                        Button(tr("不使用备用")) {
                            model.aiAssistant.fallbackChoice = .none
                            explainer.explain(subject)
                        }
                        Button(tr("稍后再选")) { explainer.dismiss() }
                    }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                case .failed(let message):
                    InfoBanner(icon: "exclamationmark.triangle.fill", text: message, tone: .warning)
                    Button(tr("配置 AI 助手")) { model.settings.panelTab = .settingsAI }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                default:
                    if explainer.text.isEmpty {
                        HStack(spacing: DS.Space.s2) {
                            ProgressView().controlSize(.small)
                            Text(tr("正在生成解释…")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
                        }
                    } else {
                        Text(explainer.text)
                            .dsFont(.sm)
                            .foregroundStyle(DS.Palette.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(tr(explainer.activeProvider == .apple
                    ? "由 Apple 智能在这台 Mac 上生成，不联网；内容可能不准确，结束进程前请自行确认。"
                    : "通过本机 CLI 调用 AI 服务，可能联网并消耗额度；结束进程前请自行确认。"))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// 进程图标缓存：只保留 40px 小位图，避免每次刷新解码系统图标的全部分辨率
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private static let pixelSize: CGFloat = DS.Size.iconStandalone * 2
    private static let limit = 128
    private var cache: [String: CGImage] = [:]

    func image(for process: ProcessUsage) -> Image {
        image(bundlePath: process.appBundlePath)
    }

    func image(bundlePath: String?) -> Image {
        let key = bundlePath ?? "unix-executable"
        if let cached = cache[key] { return Image(decorative: cached, scale: 2) }

        let icon = bundlePath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        var rect = NSRect(x: 0, y: 0, width: Self.pixelSize, height: Self.pixelSize)
        guard let cgImage = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return Image(systemName: "app")
        }
        if cache.count >= Self.limit { cache.removeAll() }
        cache[key] = cgImage
        return Image(decorative: cgImage, scale: 2)
    }
}

/// 应用的本地化显示名（“WeChat.app”显示为“微信”），按包路径缓存
final class AppNameCache: @unchecked Sendable {
    static let shared = AppNameCache()
    private let lock = NSLock()
    private var names: [String: String] = [:]

    func name(forBundle path: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let cached = names[path] { return cached }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        if names.count > 256 { names.removeAll() }
        names[path] = name
        return name
    }
}

extension NetworkProcessUsage {
    var localizedName: String {
        appBundlePath.map { AppNameCache.shared.name(forBundle: $0) } ?? name
    }
}

extension ProcessUsage {
    private var appName: String? {
        appBundlePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }

    /// 应用本身及其辅助进程都显示为应用的本地化名称
    var displayName: String {
        guard let appName, let appBundlePath, name.hasPrefix(appName) else { return name }
        return AppNameCache.shared.name(forBundle: appBundlePath)
    }

    /// 辅助进程的角色，例如 “Helper (Renderer)”
    var helperRole: String? {
        guard let appName, name.hasPrefix(appName), name != appName else { return nil }
        let role = name.dropFirst(appName.count).trimmingCharacters(in: .whitespaces)
        return role.isEmpty ? nil : role
    }
}
