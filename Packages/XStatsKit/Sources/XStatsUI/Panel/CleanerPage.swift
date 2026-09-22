import Cleaner
import HelperShared
import Localization
import Metrics
import SwiftUI

struct CleanerPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PageScroll {
            WeightedRow(weights: [2, 1]) {
                SummaryCard()
                MaintenanceCard()
            }
            if model.cleaner.needsFullDiskAccess {
                InfoBanner(icon: "lock.shield", text: tr("部分项目需要“完全磁盘访问权限”才能扫描（Safari 缓存、废纸篓）。"), tone: .warning) {
                    Button(tr("去授权")) { model.cleaner.openFullDiskAccessSettings() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                }
            }
            HStack(alignment: .top, spacing: DS.Space.s3) {
                VStack(spacing: DS.Space.s3) {
                    CategoryCard(category: .system)
                    CategoryCard(category: .browser)
                }
                .frame(maxWidth: .infinity)
                VStack(spacing: DS.Space.s3) {
                    CategoryCard(category: .developer)
                    CategoryCard(category: .downloads)
                    CategoryCard(category: .trash)
                }
                .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            CleanerFooter()
        }
        .onAppear { model.cleaner.scan(ifNeeded: true) }
    }
}

// MARK: - 汇总

private struct SummaryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleaner = model.cleaner

        Card(padding: DS.Space.s3, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "sparkles").font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                Text(tr("磁盘清理")).dsFont(.xs, weight: .semibold)
                Spacer()
                if let last = cleaner.lastScan {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Chip(text: tr("扫描于 ") + Self.relative(last, now: context.date))
                    }
                }
            }
            .foregroundStyle(DS.Palette.textSecondary)

            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Text(verbatim: headline)
                    .dsFont(.xxl, weight: .semibold)
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(subline)
                    .dsFont(.sm)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
            }

            if let disk = model.store.disk {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    ProgressTrack(fraction: disk.usedFraction)
                    Text(verbatim: tr("\(disk.volumeName) 可用 \(Format.bytes(disk.available, base: .decimal)) · 共 \(Format.bytes(disk.total, base: .decimal))"))
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textTertiary)
                }
            }

            if cleaner.isConfirming {
                InfoBanner(icon: "exclamationmark.triangle.fill", text: confirmationText, tone: .warning) {
                    HStack(spacing: DS.Space.s2) {
                        Button(tr("取消")) { cleaner.cancelClean() }
                            .buttonStyle(DSButtonStyle(kind: .secondary))
                        Button(tr("确认清理")) { cleaner.confirmClean() }
                            .buttonStyle(DSButtonStyle(kind: .primary))
                    }
                }
            } else {
                HStack(spacing: DS.Space.s2) {
                    Button { cleaner.scan() } label: {
                        Label(cleaner.phase == .scanning ? tr("扫描中…") : tr("重新扫描"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(cleaner.isBusy)

                    Button { cleaner.requestClean() } label: {
                        Label(cleaner.phase == .cleaning ? tr("清理中…") : tr("清理所选 \(Format.bytes(cleaner.selectedBytes, base: .decimal))"),
                              systemImage: "trash")
                    }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(cleaner.isBusy || cleaner.selectedBytes == 0)
                    Spacer()
                }
            }
        }
    }

    private var headline: String {
        let cleaner = model.cleaner
        if cleaner.phase == .finished { return Format.bytes(cleaner.report?.freedBytes ?? 0, base: .decimal) }
        return cleaner.scans.isEmpty ? tr("扫描中") : Format.bytes(cleaner.totalBytes, base: .decimal)
    }

    private var subline: String {
        let cleaner = model.cleaner
        switch cleaner.phase {
        case .idle, .scanning: return tr("正在计算可清理空间")
        case .cleaning: return tr("正在清理…")
        case .ready: return tr("可清理 · 已选 \(cleaner.selectedScans.count) 项")
        case .finished:
            guard let report = cleaner.report else { return "" }
            var parts = [tr("已释放")]
            if report.trashedBytes > 0 { parts.append(tr("另有 \(Format.bytes(report.trashedBytes, base: .decimal)) 移到废纸篓")) }
            if report.skippedCount > 0 { parts.append(tr("跳过 \(report.skippedCount) 项")) }
            if !report.failures.isEmpty { parts.append(tr("\(report.failures.count) 项失败")) }
            return parts.joined(separator: " · ")
        }
    }

    private var confirmationText: String {
        let cleaner = model.cleaner
        let count = cleaner.selectedScans.reduce(0) { $0 + $1.items.count }
        let trashNote = model.settings.cleanPrefersTrash
            ? tr("支持的内容先移到废纸篓；工具缓存由对应命令直接清理。")
            : tr("缓存与日志直接删除，下载内容移到废纸篓。")
        return tr("将清理 \(count) 个项目，共 \(Format.bytes(cleaner.selectedBytes, base: .decimal))。\(trashNote)")
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? tr("刚刚") : tr("\(Format.duration(minutes: minutes))前")
    }
}

// MARK: - 系统维护

private struct MaintenanceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s1) {
                Image(systemName: "wrench.and.screwdriver").font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                Text(tr("系统维护")).dsFont(.xs, weight: .semibold)
            }
            .foregroundStyle(DS.Palette.textSecondary)

            MaintenanceButton(command: .flushDNS, icon: "network", title: tr("刷新 DNS 缓存"))
            MaintenanceButton(command: .purgeMemory, icon: "memorychip", title: tr("释放内存"))

            Text(model.helper.isReady ? tr("由辅助工具执行") : tr("需要管理员授权"))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
        }
    }
}

private struct MaintenanceButton: View {
    @Environment(AppModel.self) private var model
    let command: MaintenanceCommand
    let icon: String
    let title: String
    @State private var hovering = false

    var body: some View {
        let maintenance = model.maintenance
        let isRunning = maintenance.running == command
        let outcome = maintenance.outcomes[command]

        Button {
            Task { await maintenance.run(command) }
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: icon)
                        .font(.system(size: DS.TextSize.sm.rawValue, weight: .medium))
                        .frame(width: DS.Size.iconStandalone)
                    Text(title).dsFont(.sm, weight: .medium)
                    Spacer(minLength: 0)
                    if isRunning {
                        Text(tr("执行中")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                .foregroundStyle(DS.Palette.textPrimary)
                if let outcome {
                    Text(outcome.text)
                        .dsFont(.xs)
                        .foregroundStyle(outcome.isError ? DS.Palette.error : DS.Palette.success)
                        .lineLimit(1)
                        .padding(.leading, DS.Size.iconStandalone + DS.Space.s2)
                }
            }
            .padding(.horizontal, DS.Space.s2)
            .padding(.vertical, DS.Space.s2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? DS.Palette.surfaceHover : DS.Palette.track, in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(maintenance.running != nil)
        .onHover { hovering = $0 }
    }
}

// MARK: - 分类

private struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    let category: CleanCategory

    var body: some View {
        let scans = model.cleaner.scans(in: category)
        let total = scans.filter(\.isCleanable).reduce(0) { $0 + $1.totalSize }

        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack {
                Text(category.title).dsFont(.xs, weight: .semibold).foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                if total > 0 {
                    Text(verbatim: Format.bytes(total, base: .decimal))
                        .dsFont(.xs, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            if scans.isEmpty {
                ForEach(0..<placeholderRows, id: \.self) { _ in
                    PlaceholderLine().frame(height: DS.Size.controlHeight)
                }
            }
            ForEach(Array(scans.enumerated()), id: \.element.id) { index, scan in
                if index > 0 { HairlineDivider() }
                RuleRow(scan: scan)
            }
        }
    }

    /// 扫描完成前占位，保持面板高度稳定
    private var placeholderRows: Int {
        RuleCatalog.rules().filter { $0.category == category }.count
    }
}

private struct RuleRow: View {
    @Environment(AppModel.self) private var model
    let scan: RuleScan
    @State private var expanded = false

    var body: some View {
        let cleaner = model.cleaner
        let selected = cleaner.selection.contains(scan.id) && scan.isCleanable

        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                DSCheckbox(isOn: selected) { cleaner.toggle(scan) }
                    .disabled(!scan.isCleanable || cleaner.isBusy)
                RuleIcon(name: scan.rule.symbol)
                VStack(alignment: .leading, spacing: 0) {
                    Text(scan.rule.title)
                        .dsFont(.sm, weight: .medium)
                        .foregroundStyle(scan.blocked == nil ? DS.Palette.textPrimary : DS.Palette.textTertiary)
                    Text(statusText)
                        .dsFont(.xs)
                        .foregroundStyle(scan.blocked == nil ? DS.Palette.textTertiary : DS.Palette.warning)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.Space.s1)
                if scan.isCleanable {
                    Text(verbatim: Format.bytes(scan.totalSize, base: .decimal))
                        .dsFont(.sm, weight: .medium)
                        .monospacedDigit()
                        .foregroundStyle(DS.Palette.textPrimary)
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: DS.TextSize.xs.rawValue, weight: .semibold))
                            .foregroundStyle(DS.Palette.textTertiary)
                            .frame(width: DS.Size.iconStandalone, height: DS.Size.iconStandalone)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("查看包含的项目"))
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    ForEach(scan.items.prefix(Self.previewLimit)) { item in
                        Button { cleaner.reveal(item) } label: {
                            HStack {
                                Text(item.url.lastPathComponent).dsFont(.xs).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: DS.Space.s2)
                                Text(verbatim: Format.bytes(item.size, base: .decimal)).dsFont(.xs).monospacedDigit()
                            }
                            .foregroundStyle(DS.Palette.textSecondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tr("在访达中显示"))
                    }
                    if scan.items.count > Self.previewLimit {
                        Text(verbatim: tr("另有 \(scan.items.count - Self.previewLimit) 项"))
                            .dsFont(.xs)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                .padding(.leading, DS.Size.iconInline + DS.Size.iconStandalone + DS.Space.s2 * 2)
            }
        }
    }

    private static let previewLimit = 6

    private var statusText: String {
        if let blocked = scan.blocked { return blocked.title }
        if scan.items.isEmpty { return tr("无需清理") }
        var text = tr("\(scan.items.count) 项")
        if scan.skippedCount > 0 { text += tr(" · \(scan.skippedCount) 项使用中") }
        if scan.rule.policy == .trash { text += tr(" · 移到废纸篓") }
        return text
    }
}

private struct RuleIcon: View {
    let name: String

    var body: some View {
        Group {
            if let image = LogoCache.shared.image(named: name, template: true) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: DS.Size.iconStandalone, height: DS.TextSize.sm.rawValue)
            } else {
                Image(systemName: name)
                    .font(.system(size: DS.TextSize.sm.rawValue))
            }
        }
        .foregroundStyle(DS.Palette.textSecondary)
        .frame(width: DS.Size.iconStandalone, height: DS.Size.iconStandalone)
    }
}

// MARK: - 底部

private struct CleanerFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        HStack(spacing: DS.Space.s3) {
            DSToggle(isOn: $settings.cleanPrefersTrash, label: tr("缓存也先移到废纸篓"))
            VStack(alignment: .leading, spacing: 0) {
                Text(tr("缓存也先移到废纸篓")).dsFont(.sm, weight: .medium).foregroundStyle(DS.Palette.textPrimary)
                Text(tr("支持的缓存可以恢复；工具缓存始终由对应命令直接清理"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            }
            Spacer()
            Button(tr("查看清理日志")) { model.cleaner.revealLog() }
                .buttonStyle(DSButtonStyle(kind: .ghost))
        }
        .padding(.horizontal, DS.Space.s1)
    }
}
