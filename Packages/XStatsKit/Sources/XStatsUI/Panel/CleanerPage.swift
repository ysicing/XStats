import Cleaner
import HelperShared
import Localization
import Metrics
import SwiftUI

struct CleanerPage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot

  var body: some View {
    VStack(spacing: 0) {
      PageScroll {
        WeightedRow(weights: [2, 1]) {
          SummaryCard()
          MaintenanceCard()
        }
        if model.cleaner.needsFullDiskAccess {
          InfoBanner(
            icon: "lock.shield", text: tr("部分项目需要“完全磁盘访问权限”才能扫描（Safari 缓存、废纸篓）。"), tone: .warning
          ) {
            Button(tr("去授权")) { model.cleaner.openFullDiskAccessSettings() }
              .buttonStyle(DSButtonStyle(kind: .secondary))
          }
        }
        if model.cleaner.hasIncompleteScan {
          InfoBanner(
            icon: "exclamationmark.triangle", text: tr("部分项目未能读取，大小仅包含已完整扫描的项目。请检查权限后重新扫描。"),
            tone: .warning)
        }
        HStack(alignment: .top, spacing: DS.Space.s3) {
          VStack(spacing: DS.Space.s3) {
            CategoryCard(category: .system).fixedSize(horizontal: false, vertical: true)
            CategoryCard(category: .browser).fixedSize(horizontal: false, vertical: true)
            CategoryCard(category: .downloads).fixedSize(horizontal: false, vertical: true)
            CategoryCard(category: .trash).fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity)
          VStack(spacing: DS.Space.s3) {
            CategoryCard(category: .developer).fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      HairlineDivider()
      CleanerFooter()
        .padding(DS.Space.s3)
        .background(DS.Palette.background)
    }
    .onAppear { if !isSnapshot { model.cleaner.scan(ifNeeded: true) } }
  }
}

// MARK: - 汇总

private struct SummaryCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let cleaner = model.cleaner

    Card(padding: DS.Space.s3, spacing: DS.Space.s3) {
      HStack(spacing: DS.Space.s1) {
        Image(systemName: PanelTab.cleaner.symbol).font(
          .system(size: DS.TextSize.xs.rawValue, weight: .semibold))
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
          .fixedSize(horizontal: false, vertical: true)
      }

      if let disk = model.store.disk {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
          ProgressTrack(fraction: disk.usedFraction)
          Text(
            verbatim: tr(
              "\(disk.volumeName) 可用 \(Format.bytes(disk.available, base: .decimal)) · 共 \(Format.bytes(disk.total, base: .decimal))"
            )
          )
          .dsFont(.xs)
          .foregroundStyle(DS.Palette.textTertiary)
        }
      }

      CleanerActions()
    }
  }

  private var headline: String {
    let cleaner = model.cleaner
    if cleaner.phase == .idle { return tr("尚未扫描") }
    if cleaner.phase == .finished {
      guard let report = cleaner.report else { return Format.bytes(UInt64(0), base: .decimal) }
      return report.hasUncertainFreedBytes
        ? tr("释放量未确认") : Format.bytes(report.freedBytes, base: .decimal)
    }
    return cleaner.scans.isEmpty ? tr("扫描中") : Format.bytes(cleaner.totalBytes, base: .decimal)
  }

  private var subline: String {
    let cleaner = model.cleaner
    switch cleaner.phase {
    case .idle: return tr("点击重新扫描以计算可清理空间")
    case .scanning: return tr("正在计算可清理空间")
    case .cleaning: return tr("正在清理…")
    case .ready: return tr("可清理")
    case .finished:
      guard let report = cleaner.report else { return "" }
      var parts: [String]
      if report.wasCancelled {
        parts = [tr("已停止，已清理部分不会恢复")]
      } else if report.hasUncertainFreedBytes {
        parts = [tr("部分结果未确认")]
      } else {
        parts = [tr("已释放")]
      }
      if report.trashedBytes > 0 {
        parts.append(tr("另有 \(Format.bytes(report.trashedBytes, base: .decimal)) 移到废纸篓"))
      }
      if report.skippedCount > 0 { parts.append(tr("跳过 \(report.skippedCount) 项")) }
      if !report.failures.isEmpty { parts.append(tr("\(report.failures.count) 项失败")) }
      return parts.joined(separator: " · ")
    }
  }

  private static func relative(_ date: Date, now: Date) -> String {
    let minutes = Int(now.timeIntervalSince(date) / 60)
    return minutes < 1 ? tr("刚刚") : tr("\(Format.duration(minutes: minutes))前")
  }
}

private struct CleanerActions: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    @Bindable var cleaner = model.cleaner
    VStack(alignment: .leading, spacing: DS.Space.s2) {
      Text(tr("已选 \(cleaner.selectedScans.reduce(0) { $0 + $1.items.count }) 项"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      HStack(spacing: DS.Space.s2) {
        Button {
          cleaner.scan()
        } label: {
          Label(
            cleaner.phase == .scanning ? tr("扫描中…") : tr("重新扫描"), systemImage: "arrow.clockwise")
        }
        .buttonStyle(DSButtonStyle(kind: .secondary))
        .disabled(cleaner.isBusy)

        Button {
          cleaner.requestClean()
        } label: {
          Label(
            cleaner.phase == .cleaning
              ? tr("清理中…") : tr("清理所选 \(Format.bytes(cleaner.selectedBytes, base: .decimal))"),
            systemImage: "trash")
        }
        .buttonStyle(DSButtonStyle(kind: .primary))
        .disabled(cleaner.isBusy || cleaner.selectedScans.isEmpty)
        .confirmationDialog(
          tr("确认清理"), isPresented: $cleaner.isConfirming, titleVisibility: .visible
        ) {
          Button(tr("确认清理"), role: .destructive) {
            // 系统弹层可能先清除展示绑定，执行前重新验证选择并进入确认保护。
            cleaner.requestClean()
            cleaner.confirmClean()
          }
          Button(tr("取消"), role: .cancel) { cleaner.cancelClean() }
        } message: {
          Text(confirmationText)
        }
        if cleaner.phase == .scanning {
          Button(tr("取消")) { cleaner.cancelOperation() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
        }
        Spacer()
      }
    }
  }

  private var confirmationText: String {
    let cleaner = model.cleaner
    let count = cleaner.selectedScans.reduce(0) { $0 + $1.items.count }
    let trashNote =
      model.settings.cleanPrefersTrash
      ? tr("支持的内容先移到废纸篓；工具缓存由对应命令直接清理。")
      : tr("缓存与日志将直接删除且无法恢复，下载内容移到废纸篓。")
    var text = tr(
      "将清理 \(count) 个项目，共 \(Format.bytes(cleaner.selectedBytes, base: .decimal))。\(trashNote)")
    if cleaner.selectedScans.contains(where: { $0.id == "developer.homebrew" }) {
      text += " " + tr("Homebrew 将按执行时的状态清理旧版本与缓存，不自动移除依赖。")
    }
    return text
  }

}

// MARK: - 系统维护

private struct MaintenanceCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
      HStack(spacing: DS.Space.s1) {
        Image(systemName: "wrench.and.screwdriver").font(
          .system(size: DS.TextSize.xs.rawValue, weight: .semibold))
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
      .background(
        hovering ? DS.Palette.surfaceHover : DS.Palette.track,
        in: RoundedRectangle(cornerRadius: DS.Radius.md)
      )
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
  @State private var showsEmpty = false

  var body: some View {
    let registeredScans = model.cleaner.scans(in: category)
    let scans: [RuleScan] =
      if category == .developer {
        // 可清理容量降序；不可清理项及容量相同的项目保持清单顺序，避免无意义跳动。
        registeredScans.enumerated().sorted { left, right in
          if left.element.isCleanable != right.element.isCleanable {
            return left.element.isCleanable
          }
          if left.element.isCleanable, left.element.totalSize != right.element.totalSize {
            return left.element.totalSize > right.element.totalSize
          }
          return left.offset < right.offset
        }.map(\.element)
      } else {
        registeredScans
      }
    let total = scans.filter(\.isCleanable).reduce(0) { $0 + $1.totalSize }

    Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
      HStack {
        Text(category.title).dsFont(.xs, weight: .semibold).foregroundStyle(
          DS.Palette.textSecondary)
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
      // 只折叠确定无需清理的项目；运行中、权限不足及扫描失败等状态仍需直接展示。
      let visibleScans = scans.filter {
        showsEmpty || !$0.items.isEmpty || $0.blocked != nil || $0.unreadableCount > 0
          || $0.skippedCount > 0
      }
      ForEach(Array(visibleScans.enumerated()), id: \.element.id) { index, scan in
        if index > 0 { HairlineDivider() }
        RuleRow(scan: scan)
      }
      let emptyCount = scans.filter {
        $0.items.isEmpty && $0.blocked == nil && $0.unreadableCount == 0 && $0.skippedCount == 0
      }.count
      if emptyCount > 0 {
        Button {
          showsEmpty.toggle()
        } label: {
          Label(
            tr("无需清理（\(emptyCount.formatted(.number.locale(L10n.locale)))）"),
            systemImage: showsEmpty ? "chevron.up" : "chevron.down")
        }
        .buttonStyle(.plain).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
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
  @State private var showsReview = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let cleaner = model.cleaner
    let selectedIDs = Set(cleaner.selectedItems(in: scan).map(\.id))
    let status = statusText(selectedCount: selectedIDs.count)

    VStack(alignment: .leading, spacing: DS.Space.s2) {
      HStack(spacing: DS.Space.s2) {
        CleanupCheckbox(
          title: scan.rule.title, selected: selectedIDs.count, total: scan.items.count
        ) { cleaner.toggle(scan) }
        .frame(width: 24, height: 24)
        .disabled(!scan.isCleanable || cleaner.isBusy)
        RuleIcon(name: scan.rule.symbol)
        VStack(alignment: .leading, spacing: 0) {
          Text(scan.rule.title)
            .dsFont(.sm, weight: .medium)
            .foregroundStyle(scan.blocked == nil ? DS.Palette.textPrimary : DS.Palette.textTertiary)
          Text(status)
            .dsFont(.xs)
            .foregroundStyle(scan.blocked == nil ? DS.Palette.textTertiary : DS.Palette.warning)
            .lineLimit(scan.blocked == nil ? 1 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .help(statusText(selectedCount: selectedIDs.count, detailed: true))
        }
        Spacer(minLength: DS.Space.s1)
        if scan.isCleanable {
          Text(verbatim: Format.bytes(scan.totalSize, base: .decimal))
            .dsFont(.sm, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(DS.Palette.textPrimary)
          Button {
            DS.Motion.select {
              withAnimation(reduceMotion ? nil : DS.Motion.quick) { expanded.toggle() }
            }
          } label: {
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

      if expanded && scan.isCleanable {
        if scan.rule.usesToolCleaner {
          Text(tr("由对应工具整体清理，不支持逐项勾选；保留其中任一项目会跳过整条规则。"))
            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        }
        VStack(alignment: .leading, spacing: DS.Space.s1) {
          ForEach(scan.items.prefix(Self.previewLimit)) { item in
            HStack {
              CleanupCheckbox(title: item.url.path, selected: selectedIDs.contains(item.id) ? 1 : 0)
              { cleaner.toggle(item, in: scan) }
              .frame(width: 24, height: 24)
              .disabled(cleaner.isBusy || scan.rule.usesToolCleaner)
              Text(
                verbatim: scan.toolPreview == nil
                  ? item.url.lastPathComponent
                  : item.url.pathComponents.suffix(2).joined(separator: "/")
              ).dsFont(.xs).lineLimit(1).truncationMode(.middle)
              Spacer(minLength: DS.Space.s2)
              Text(
                verbatim: scan.toolPreview != nil && item.size == 0
                  ? "—" : Format.bytes(item.size, base: .decimal)
              ).dsFont(.xs).monospacedDigit()
              MiniIconButton(systemName: "magnifyingglass", help: tr("在访达中显示")) {
                cleaner.reveal(item)
              }
            }
            .foregroundStyle(DS.Palette.textSecondary)
            .contextMenu {
              Button(tr("始终保留此项目")) { cleaner.exclude(item.url) }
                .disabled(cleaner.isBusy || cleaner.exclusionLimitReached)
              if cleaner.exclusionLimitReached { Text(tr("保留项目已达 50 项上限，请先移除不再需要的保留项。")) }
            }
          }
          Button(tr("查看全部项目")) { showsReview = true }
            .buttonStyle(.plain).dsFont(.xs).foregroundStyle(DS.Palette.primary)
        }
        .padding(.leading, DS.Size.iconInline + DS.Size.iconStandalone + DS.Space.s2 * 2)
      }
    }
    .sheet(isPresented: $showsReview) { CleanerReviewSheet(scan: scan, cleaner: cleaner) }
  }

  private static let previewLimit = 6

  private func statusText(selectedCount: Int, detailed: Bool = false) -> String {
    if let blocked = scan.blocked { return blocked.title }
    if scan.items.isEmpty && scan.unreadableCount > 0 {
      return tr("扫描不完整 · \(scan.unreadableCount) 项未能读取")
    }
    if scan.items.isEmpty && scan.skippedCount > 0 { return tr("已跳过 \(scan.skippedCount) 项") }
    if scan.items.isEmpty { return tr("无需清理") }
    var text =
      selectedCount > 0 && selectedCount < scan.items.count
      ? tr("已选 \(selectedCount)/\(scan.items.count) 项") : tr("\(scan.items.count) 项")
    if scan.unreadableCount > 0 {
      text += " · " + tr("扫描不完整 · \(scan.unreadableCount) 项未能读取")
    }
    // 卡片只显示计数；完整原因可悬停查看，避免一串 Bundle ID 抢占摘要。
    if detailed, !scan.skippedReasons.isEmpty {
      text += "\n" + scan.skippedReasons.keys.map(\.title).sorted().joined(separator: "\n")
    } else if scan.skippedCount > 0 {
      text += tr(" · 已跳过 \(scan.skippedCount) 项")
    }
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
  @State private var showsExclusions = false

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
      Button(tr("保留项目")) { showsExclusions = true }
        .buttonStyle(DSButtonStyle(kind: .ghost))
      Button(tr("查看清理日志")) { model.cleaner.revealLog() }
        .buttonStyle(DSButtonStyle(kind: .ghost))
    }
    .padding(.horizontal, DS.Space.s1)
    .sheet(isPresented: $showsExclusions) { CleanerExclusionsSheet(cleaner: model.cleaner) }
  }
}
