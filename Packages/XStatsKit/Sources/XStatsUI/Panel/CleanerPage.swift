import Cleaner
import Localization
import Metrics
import SwiftUI

struct CleanerPage: View {
  enum Section {
    case applicationCaches
    case category(CleanCategory)

    var title: String {
      switch self {
      case .applicationCaches: tr("应用缓存")
      case .category(let category): category.title
      }
    }

    func contains(_ rule: CleanRule) -> Bool {
      // 展示分组独立于扫描分类，保留原规则、选择及清理权限。
      // 当前系统清单除日志规则外均为缓存，应用专属路径仍由 Cleaner 内部管理。
      let isApplicationCache = rule.category == .system && rule.id != "system.logs"
      switch self {
      case .applicationCaches: return isApplicationCache
      case .category(let category): return rule.category == category && !isApplicationCache
      }
    }
  }

  enum Tab: String, CaseIterable, Identifiable {
    case clean, optimize

    var id: String { rawValue }
    var title: String { self == .clean ? tr("清理") : tr("优化") }
  }

  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
  @State private var showsMoleInstallation = false
  @Binding var tab: Tab

  init(tab: Binding<Tab> = .constant(.clean)) {
    _tab = tab
  }

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      if model.cleaner.engine == .mole {
        MoleCommandView(controller: model.cleaner.mole, nativeBusy: nativeBusy)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else if tab == .clean {
        nativeCleanup
      } else {
        PageScroll {
          if model.cleaner.mole.executable == nil { moleGuide }
          OptimizationPage()
        }
      }
    }
    .task {
      guard !isSnapshot else { return }
      await model.cleaner.mole.refreshAvailability()
      guard !Task.isCancelled else { return }
      updateTab()
    }
    .onChange(of: tab) { _, _ in updateTab() }
    .onChange(of: model.cleaner.engine) { _, _ in updateTab() }
    .onChange(of: model.cleaner.mole.executable) { _, executable in
      if executable == nil { model.cleaner.selectEngine(.native) }
    }
    .onDisappear {
      model.systemCheck.cancel()
      if model.cleaner.phase == .scanning { model.cleaner.cancelOperation() }
      model.cleaner.mole.cancelPreview()
    }
    .onChange(of: model.settings.cleanerEnabled) { _, enabled in
      if !enabled {
        model.systemCheck.cancel()
        model.cleaner.mole.cancel()
      }
    }
    .sheet(isPresented: $showsMoleInstallation) {
      VStack(alignment: .leading, spacing: DS.Space.s3) {
        HStack {
          Text(tr("安装 Mole")).dsFont(.lg, weight: .semibold)
          Spacer()
          Button(tr("关闭")) { showsMoleInstallation = false }
            .disabled(model.cleaner.mole.isRunning)
        }
        .padding([.top, .horizontal], DS.Space.s3)
        MoleCommandView(
          controller: model.cleaner.mole, nativeBusy: nativeBusy, installation: true)
      }
      .frame(width: 760, height: 520)
      .interactiveDismissDisabled(model.cleaner.mole.isRunning)
    }
  }

  private func updateTab() {
    guard !isSnapshot else { return }
    // 真实执行可在离开页面后继续；外部入口改写或窗口重建后的 Tab 以运行中的工作流为准，
    // 不能借 selectWorkflow 取消任务。
    if model.cleaner.mole.isRunning {
      let running: Tab = model.cleaner.mole.workflow == .clean ? .clean : .optimize
      if tab != running { tab = running }
    }
    model.cleaner.mole.selectWorkflow(tab == .clean ? .clean : .optimize)
    if tab == .clean {
      model.systemCheck.cancel()
      model.cleaner.scan(ifNeeded: true)
    } else {
      if model.cleaner.phase == .scanning { model.cleaner.cancelOperation() }
    }
    if model.cleaner.engine == .mole { model.systemCheck.cancel() }
  }

  private var nativeBusy: Bool {
    model.cleaner.isBusy || model.maintenance.isBusy
  }

  private var toolbar: some View {
    HStack(spacing: DS.Space.s3) {
      SegmentedControl(
        selection: $tab,
        options: Tab.allCases.map { ($0, $0.title) }
      )
      .fixedSize(horizontal: true, vertical: false)
      // 切换 Tab 会取消 Mole 任务，运行中的清理或优化不能被一次点击打断。
      .disabled(model.cleaner.mole.isRunning)
      Spacer(minLength: 0)
      if model.cleaner.mole.executable != nil {
        Picker(
          tr("引擎"),
          selection: Binding(
            get: { model.cleaner.engine }, set: { model.cleaner.selectEngine($0) })
        ) {
          Text(verbatim: "XStats").tag(CleanerController.Engine.native)
          Text(verbatim: "Mole").tag(CleanerController.Engine.mole)
        }
        .fixedSize()
        .disabled(
          model.cleaner.phase == .cleaning || model.cleaner.mole.isRunning
            || model.maintenance.isBusy)
      }
    }
    .padding(.horizontal, DS.Space.s3)
    .padding(.top, DS.Space.s2)
    .padding(.bottom, DS.Space.s3)
  }

  private var moleGuide: some View {
    Group {
      MolePreviewGuide(
        command: tab == .clean ? "mo clean --dry-run" : "mo optimize --dry-run",
        detail: tab == .clean
          ? tr("安装 Mole 后，可在终端预览更多清理项目，不会删除文件。")
          : tr("安装 Mole 后，可在终端预览更多优化项目，不会执行优化。"))
      HStack(spacing: DS.Space.s2) {
        Button(tr("安装 Mole")) {
          showsMoleInstallation = true
          model.cleaner.mole.install()
        }
        .buttonStyle(DSButtonStyle(kind: .secondary))
        .disabled(!model.cleaner.mole.canInstall)
        Button(tr("重新检测 Mole")) {
          Task { await model.cleaner.mole.refreshAvailability() }
        }
        .buttonStyle(DSButtonStyle(kind: .secondary))
        .disabled(model.cleaner.mole.isRunning)
        if !model.cleaner.mole.brewAvailable {
          Text(tr("尚未安装 Homebrew"))
            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        }
      }
    }
  }

  private var nativeCleanup: some View {
    VStack(spacing: 0) {
      PageScroll {
        SummaryCard()
        if model.cleaner.mole.executable == nil {
          moleGuide
        }
        if model.cleaner.needsFullDiskAccess {
          InfoBanner(
            icon: "lock.shield", text: tr("部分项目需要“完全磁盘访问权限”才能扫描（Safari 缓存、废纸篓）。"), tone: .warning
          ) {
            Button(tr("去授权")) { model.cleaner.openFullDiskAccessSettings() }
              .buttonStyle(DSButtonStyle(kind: .secondary))
          }
        }
        // 固定分类所属列；展开只推开同列卡片，不按高度重新分配位置。
        HStack(alignment: .top, spacing: DS.Space.s3) {
          VStack(spacing: DS.Space.s3) {
            CategoryCard(section: .applicationCaches).fixedSize(horizontal: false, vertical: true)
            CategoryCard(section: .category(.browser)).fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity)
          VStack(spacing: DS.Space.s3) {
            CategoryCard(section: .category(.developer)).fixedSize(
              horizontal: false, vertical: true)
            CategoryCard(section: .category(.system)).fixedSize(horizontal: false, vertical: true)
            CategoryCard(section: .category(.downloads)).fixedSize(
              horizontal: false, vertical: true)
            CategoryCard(section: .category(.trash)).fixedSize(horizontal: false, vertical: true)
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
      if cleaner.scans.contains(where: { $0.isCleanable && $0.rule.usesToolCleaner }) {
        Text(tr("工具缓存容量单独列出，不计入文件合计。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
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
        .disabled(cleaner.isBusy || model.systemCheck.isChecking)

        Button {
          cleaner.requestClean()
        } label: {
          Label(
            cleaner.phase == .cleaning
              ? tr("清理中…")
              : cleaner.selectedScans.contains(where: { $0.rule.usesToolCleaner })
                ? tr("确认清理") : tr("清理所选 \(Format.bytes(cleaner.selectedBytes, base: .decimal))"),
            systemImage: "trash")
        }
        .buttonStyle(DSButtonStyle(kind: .primary))
        .disabled(cleaner.isBusy || cleaner.selectedScans.isEmpty)
        .confirmationDialog(
          confirmation.title, isPresented: $cleaner.isConfirming, titleVisibility: .visible
        ) {
          Button(confirmation.buttonTitle, role: .destructive) {
            // 系统弹层可能先清除展示绑定；执行的是弹出时冻结的同一份选择。
            cleaner.confirmClean()
          }
          Button(tr("取消"), role: .cancel) { cleaner.cancelClean() }
        } message: {
          Text(confirmation.message)
        }
        if cleaner.phase == .scanning {
          Button(cleaner.isCancelling ? tr("正在停止…") : tr("取消")) { cleaner.cancelOperation() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(cleaner.isCancelling)
        }
        Spacer()
      }
    }
  }

  private var confirmation: CleanerConfirmation {
    CleanerConfirmation(
      scans: model.cleaner.confirmationScans, preferTrash: model.settings.cleanPrefersTrash)
  }

}

// MARK: - 分类

private struct CategoryCard: View {
  @Environment(AppModel.self) private var model
  let section: CleanerPage.Section
  @State private var showsEmpty = false

  var body: some View {
    let registeredScans = model.cleaner.scans.filter {
      section.contains($0.rule) && model.cleaner.shouldDisplay($0)
    }
    let scans: [RuleScan] =
      if case .category(.developer) = section {
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
    let total = CleanItem.totalSize(
      of: scans.filter { $0.isCleanable && !$0.rule.usesToolCleaner }.flatMap(\.items))
    // 只折叠确定无需清理的项目；运行中、权限不足及扫描失败等状态仍需直接展示。
    let visibleScans = scans.filter {
      showsEmpty || model.cleaner.keepsEmptyVisible($0)
        || !$0.items.isEmpty || $0.blocked != nil || $0.unreadableCount > 0
        || $0.skippedCount > 0 || $0.interruption != nil
    }
    let emptyCount = scans.filter {
      $0.items.isEmpty && $0.isComplete && $0.skippedCount == 0
        && !model.cleaner.keepsEmptyVisible($0)
    }.count
    let isCollapsedEmpty = visibleScans.isEmpty && emptyCount > 0

    Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
      HStack {
        Text(section.title).dsFont(.xs, weight: .semibold).foregroundStyle(
          DS.Palette.textSecondary)
        Spacer()
        if isCollapsedEmpty {
          emptyDisclosure(count: emptyCount)
        } else if scans.isEmpty, model.cleaner.lastScan != nil {
          Text(tr("未发现缓存")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        } else if total > 0 {
          Text(verbatim: Format.bytes(total, base: .decimal))
            .dsFont(.xs, weight: .medium)
            .monospacedDigit()
            .foregroundStyle(DS.Palette.textSecondary)
        }
      }
      if scans.isEmpty, model.cleaner.lastScan == nil {
        ForEach(0..<placeholderRows, id: \.self) { _ in
          PlaceholderLine().frame(height: DS.Size.controlHeight)
        }
      }
      if !visibleScans.isEmpty {
        VStack(spacing: DS.Space.s1) {
          ForEach(Array(visibleScans.enumerated()), id: \.element.id) { index, scan in
            if index > 0 { HairlineDivider() }
            RuleRow(scan: scan)
          }
        }
      }
      if emptyCount > 0, !isCollapsedEmpty {
        emptyDisclosure(count: emptyCount)
      }
    }
  }

  private func emptyDisclosure(count: Int) -> some View {
    Button {
      showsEmpty.toggle()
    } label: {
      Label(
        tr("未发现内容（\(count.formatted(.number.locale(L10n.locale)))）"),
        systemImage: showsEmpty ? "chevron.up" : "chevron.down")
    }
    .buttonStyle(.plain).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
  }

  /// 扫描完成前占位，保持面板高度稳定
  private var placeholderRows: Int {
    RuleCatalog.rules().filter { !$0.previewOnly && section.contains($0) }.count
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
        ZStack {
          if !scan.rule.previewOnly {
            CleanupCheckbox(
              title: scan.rule.title, selected: selectedIDs.count, total: scan.items.count
            ) { cleaner.toggle(scan) }
            .disabled(!scan.isCleanable || cleaner.isBusy)
          }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(scan.rule.previewOnly)
        RuleIcon(name: scan.rule.symbol)
        VStack(alignment: .leading, spacing: 0) {
          Text(scan.rule.title)
            .dsFont(.sm, weight: .medium)
            .foregroundStyle(scan.blocked == nil ? DS.Palette.textPrimary : DS.Palette.textTertiary)
            .lineLimit(1)
          Text(status)
            .dsFont(.xs)
            .foregroundStyle(scan.isComplete ? DS.Palette.textTertiary : DS.Palette.warning)
            .lineLimit(scan.isComplete ? 1 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .help(statusText(selectedCount: selectedIDs.count, detailed: true))
        }
        Spacer(minLength: DS.Space.s1)
        if !scan.items.isEmpty {
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

      if expanded && !scan.items.isEmpty {
        if scan.rule.usesToolCleaner {
          Text(tr("由对应工具整体清理，不支持逐项勾选；保留其中任一项目会跳过整条规则。"))
            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        }
        VStack(alignment: .leading, spacing: DS.Space.s1) {
          ForEach(scan.items.prefix(Self.previewLimit)) { item in
            HStack {
              ZStack {
                if !scan.rule.previewOnly {
                  CleanupCheckbox(
                    title: item.url.path, selected: selectedIDs.contains(item.id) ? 1 : 0
                  ) { cleaner.toggle(item, in: scan) }
                  .disabled(cleaner.isBusy || !scan.isCleanable || scan.rule.usesToolCleaner)
                }
              }
              .frame(width: 24, height: 24)
              .accessibilityHidden(scan.rule.previewOnly)
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
        .padding(.leading, DS.Size.iconStandalone + DS.Space.s2)
      }
    }
    .sheet(isPresented: $showsReview) { CleanerReviewSheet(scan: scan, cleaner: cleaner) }
  }

  private static let previewLimit = 6

  private func statusText(selectedCount: Int, detailed: Bool = false) -> String {
    let usage = scan.cleanupStatusText(selectedCount: selectedCount, detailed: detailed)
    switch model.cleaner.applicationState(for: scan) {
    case .previouslyInstalled: return tr("曾安装") + " · " + usage
    case .cacheRemains: return tr("缓存残留") + " · " + usage
    default: return usage
    }
  }

}

extension RuleScan {
  /// 失败原因优先展示；清理能力只标在已有内容的结果上，避免与空结果或运行状态混写。
  func cleanupStatusText(selectedCount: Int, detailed: Bool = false) -> String {
    if let blocked { return blocked.title }
    if let interruption {
      return interruption == .timeLimit ? tr("工具预览超时，暂不可清理") : interruption.title
    }
    if items.isEmpty && unreadableCount > 0 {
      return tr("\(unreadableCount) 个文件或目录无法读取")
    }
    if items.isEmpty && skippedCount > 0 { return tr("已跳过 \(skippedCount) 项") }
    if items.isEmpty {
      return rule.previewOnly ? tr("未发现缓存") : tr("无需清理")
    }
    var text =
      selectedCount > 0 && selectedCount < items.count
      ? tr("已选 \(selectedCount)/\(items.count) 项") : tr("\(items.count) 项")
    if unreadableCount > 0 {
      text += " · " + tr("\(unreadableCount) 个文件或目录无法读取")
    }
    // 卡片只显示计数；完整原因可悬停查看，避免一串 Bundle ID 抢占摘要。
    if detailed, !skippedReasons.isEmpty {
      text += "\n" + skippedReasons.keys.map(\.title).sorted().joined(separator: "\n")
    } else if skippedCount > 0 {
      text += tr(" · 已跳过 \(skippedCount) 项")
    }
    if rule.policy == .trash { text += tr(" · 移到废纸篓") }
    return rule.previewOnly ? tr("不支持清理 · \(text)") : text
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
