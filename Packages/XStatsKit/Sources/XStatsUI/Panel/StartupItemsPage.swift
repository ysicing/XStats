// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Darwin
import Localization
import SwiftUI

/// 启动项：LaunchAgents / LaunchDaemons 里的后台项目，当前用户的可以直接停用
@MainActor
@Observable
final class StartupItemsController {
  private(set) var items: [LaunchItem] = []
  private(set) var status = LaunchStatus()
  private(set) var isLoading = false
  private(set) var working: String?
  private(set) var message: (text: String, isError: Bool)?

  private var section: AppServicesSection = .startup
  private var visible = false
  private var paused = false
  private var generation = UUID()
  private var refreshTask: Task<Void, Never>?
  private let readInventory: @Sendable ([LaunchItem.Scope]) async -> ([LaunchItem], LaunchStatus)

  init(
    readInventory: @escaping @Sendable ([LaunchItem.Scope]) async -> ([LaunchItem], LaunchStatus) =
      { scopes in
        let worker = Task.detached {
          (LaunchItems.scan(scopes: scopes), LaunchItems.status(scopes: scopes))
        }
        return await withTaskCancellationHandler {
          await worker.value
        } onCancel: {
          worker.cancel()
        }
      }
  ) {
    self.readInventory = readInventory
  }

  func setVisible(_ value: Bool, section: AppServicesSection? = nil) {
    if let section, self.section != section {
      cancelReading()
      self.section = section
      items = []
      status = LaunchStatus()
      message = nil
    }
    visible = value
    if value && !paused { refresh() } else { cancelReading() }
  }

  func setPaused(_ value: Bool) {
    paused = value
    if value { cancelReading() } else if visible { refresh() }
  }

  private func cancelReading() {
    generation = UUID()
    refreshTask?.cancel()
    refreshTask = nil
    isLoading = false
  }

  func refresh() {
    guard visible, !paused, !isLoading, working == nil else { return }
    isLoading = true
    let current = UUID()
    generation = current
    let scopes = section.launchScopes
    guard !scopes.isEmpty else {
      isLoading = false
      return
    }
    refreshTask = Task {
      guard !Task.isCancelled else { return }
      let (items, status) = await readInventory(scopes)
      guard !Task.isCancelled, generation == current, visible, !paused else { return }
      self.items = items
      self.status = status
      isLoading = false
      refreshTask = nil
    }
  }

  func showPreview(items: [LaunchItem], status: LaunchStatus) {
    self.items = items
    self.status = status
  }

  func setEnabled(_ enabled: Bool, _ item: LaunchItem) {
    guard visible, !paused, working == nil, item.scope == .user, item.configurationIssue == nil
    else { return }
    cancelReading()
    working = item.id
    message = nil
    Task {
      let error = await Task.detached { LaunchItems.setEnabled(enabled, item: item) }.value
      working = nil
      if let error {
        message = (error, true)
      } else {
        Log.app.notice(
          "\(enabled ? "启用" : "停用", privacy: .public)启动项 \(item.label, privacy: .public)")
        message = (tr("已\(enabled ? tr("启用") : tr("停用"))“\(item.label)”"), false)
      }
      isLoading = false
      refresh()
    }
  }
}

struct StartupItemsPage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
  let section: AppServicesSection
  let search: String

  var body: some View {
    let controller = model.startupItems

    PageScroll {
      if let message = controller.message {
        InfoBanner(
          icon: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
          text: message.text, tone: message.isError ? .error : .success)
      }
      ForEach(section.launchScopes, id: \.self) { scope in
        let items = Self.filteredItems(
          controller.items, section: section, scope: scope, search: search)
        Card {
          CardHeader(
            icon: scope == .system ? "lock.shield" : "person.crop.circle",
            title: scope == .system ? tr("后台守护进程") : scope.title
          ) {
            HStack(spacing: DS.Space.s2) {
              Text(verbatim: scopeDetail(scope, count: items.count))
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textTertiary)
            }
          }
          if items.isEmpty {
            Text(controller.isLoading && controller.items.isEmpty ? tr("正在读取…") : tr("没有匹配的项目"))
              .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
          }
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index > 0 { HairlineDivider() }
            StartupItemRow(
              item: item, status: controller.status, isWorking: controller.working == item.id,
              operationInProgress: controller.working != nil
            ) { enabled in
              controller.setEnabled(enabled, item)
            }
          }
        }
      }
    }
    .onAppear {
      if !isSnapshot { controller.setVisible(model.isMainWindowVisible, section: section) }
    }
    .onDisappear { if !isSnapshot { controller.setVisible(false) } }
    .onChange(of: section) { _, value in
      if !isSnapshot { controller.setVisible(model.isMainWindowVisible, section: value) }
    }
    .onChange(of: model.isMainWindowVisible) { _, visible in
      if !isSnapshot { controller.setVisible(visible, section: section) }
    }
  }

  static func filteredItems(
    _ items: [LaunchItem], section: AppServicesSection, scope: LaunchItem.Scope, search: String
  ) -> [LaunchItem] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard section.launchScopes.contains(scope) else { return [] }
    return items.filter { item in
      item.scope == scope
        && (query.isEmpty
          || [item.label, item.program ?? "", item.plist.path]
            .contains { $0.localizedStandardContains(query) })
    }
  }

  private func scopeDetail(_ scope: LaunchItem.Scope, count: Int) -> String {
    switch scope {
    case .user:
      count == 1 ? tr("1 项 · 可直接停用") : tr("\(count) 项 · 可直接停用")
    case .allUsers, .system:
      count == 1 ? tr("1 项 · 需要管理员权限，只读") : tr("\(count) 项 · 需要管理员权限，只读")
    }
  }
}

private struct StartupItemRow: View {
  let item: LaunchItem
  let status: LaunchStatus
  let isWorking: Bool
  let operationInProgress: Bool
  let setEnabled: (Bool) -> Void
  @State private var detailsVisible = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let disabled = status.isDisabled(item)
    let exitStatus = status.lastExitStatus(item)
    HStack(spacing: DS.Space.s3) {
      AppIconCache.shared.image(bundlePath: item.appBundlePath)
        .resizable()
        .frame(
          width: DS.Size.iconStandalone + DS.Space.s1, height: DS.Size.iconStandalone + DS.Space.s1)
      VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
        HStack(spacing: DS.Space.s2) {
          Text(verbatim: title)
            .dsFont(.sm, weight: .medium)
            .foregroundStyle(disabled ? DS.Palette.textTertiary : DS.Palette.textPrimary)
            .lineLimit(1)
          if item.configurationIssue == nil {
            badge(disabled: disabled)
          }
        }
        if let issue = item.configurationIssue {
          Text(issueText(issue)).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        } else {
          Text(verbatim: triggerSummary ?? item.label)
            .dsFont(.xs)
            .foregroundStyle(DS.Palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .help(item.label)
      Spacer(minLength: DS.Space.s2)
      if StartupItemDetails.hasDiagnostics(item, exitStatus: exitStatus) {
        MiniIconButton(
          systemName: "info.circle", help: tr("显示详情"),
          tint: detailsVisible ? DS.Palette.primary : nil
        ) {
          if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { detailsVisible.toggle() }
          } else {
            DS.Motion.select { detailsVisible.toggle() }
          }
        }
        .popover(isPresented: $detailsVisible, arrowEdge: .top) {
          StartupItemDetails(item: item, exitStatus: exitStatus, title: title)
        }
      } else {
        MiniIconButton(systemName: "folder", help: tr("在访达中显示配置")) {
          NSWorkspace.shared.activateFileViewerSelecting([item.plist])
        }
      }
      if item.scope == .user, item.configurationIssue == nil {
        if isWorking {
          ProgressView().controlSize(.small)
        } else {
          DSToggle(
            isOn: Binding(get: { !disabled }, set: { setEnabled($0) }), label: tr("启用 \(title)")
          )
          .disabled(operationInProgress)
        }
      }
    }
  }

  private var triggerSummary: String? {
    if item.details.schedules.count == 1, let schedule = item.details.schedules.first {
      return StartupItemDetails.timing(schedule)
    }
    if !item.details.schedules.isEmpty { return tr("日历计划") }
    if let interval = item.details.interval { return StartupItemDetails.intervalText(interval) }
    if !item.details.watchedPaths.isEmpty { return tr("路径变化时运行") }
    let flags = [item.runAtLoad ? tr("登录时运行") : nil, item.keepAlive ? tr("保持运行") : nil]
      .compactMap { $0 }
    return flags.isEmpty ? nil : flags.joined(separator: " · ")
  }

  private func issueText(_ issue: LaunchItem.ConfigurationIssue) -> String {
    switch issue {
    case .unreadable: tr("无法读取配置文件")
    case .tooLarge: tr("配置文件超过 1 MiB")
    case .invalidPlist: tr("配置文件不是有效的 plist 字典")
    case .missingLabel: tr("配置缺少有效的 Label")
    }
  }

  private var title: String {
    if let bundle = item.appBundlePath {
      return AppNameCache.shared.name(forBundle: bundle)
    }
    return item.program.map { ($0 as NSString).lastPathComponent } ?? item.label
  }

  @ViewBuilder
  private func badge(disabled: Bool) -> some View {
    if disabled {
      StatusBadge(text: tr("已停用"))
    } else if let pid = status.pid(item) {
      StatusBadge(text: tr("运行中 · PID \(pid)"), tone: .success)
    } else if status.isLoaded(item) {
      StatusBadge(text: tr("已加载"), tone: .primary)
    }
  }
}

struct StartupItemDetails: View {
  let item: LaunchItem
  let exitStatus: Int?
  var title: String? = nil
  @State private var availability: [String: StartupLogFile.Availability] = [:]
  @State private var pendingReveal: String?

  static func hasDiagnostics(_ item: LaunchItem, exitStatus: Int?) -> Bool {
    let details = item.details
    return item.configurationIssue == nil
      && (details.interval != nil || !details.schedules.isEmpty || !details.watchedPaths.isEmpty
        || details.standardOutput != nil || details.standardError != nil
        || exitStatus.map { $0 != 0 } == true)
  }

  var body: some View {
    let logs = StartupLogFile.configured(in: item.details)
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      VStack(alignment: .leading, spacing: DS.Space.s1) {
        Text(verbatim: title ?? item.label).dsFont(.sm, weight: .semibold)
        if let title, title != item.label {
          Text(verbatim: item.label).foregroundStyle(DS.Palette.textSecondary)
        }
      }
      timingDetails
      if !logs.isEmpty {
        HairlineDivider()
        VStack(alignment: .leading, spacing: DS.Space.s2) {
          ForEach(logs, id: \.path) { logLocation($0) }
        }
      }
      HairlineDivider()
      Button(tr("在访达中显示配置")) {
        NSWorkspace.shared.activateFileViewerSelecting([item.plist])
      }
      .buttonStyle(.link)
    }
    .dsFont(.xs)
    .padding(DS.Space.s4)
    .frame(width: 340)
    .task(id: logs) {
      let states = await Task.detached(priority: .utility) {
        Dictionary(
          uniqueKeysWithValues: logs.map { ($0.path, StartupLogFile.availability(at: $0.path)) })
      }.value
      if !Task.isCancelled { availability = states }
    }
    .task(id: pendingReveal) {
      guard let path = pendingReveal else { return }
      let current = await Task.detached(priority: .utility) {
        StartupLogFile.availability(at: path)
      }.value
      guard !Task.isCancelled else { return }
      if current == .file {
        let revealed = NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        availability[path] = revealed ? current : .unavailable
      } else {
        availability[path] = current
      }
      pendingReveal = nil
    }
  }

  private var timingDetails: some View {
    let details = item.details
    return VStack(alignment: .leading, spacing: DS.Space.s2) {
      if item.runAtLoad || item.keepAlive {
        Text(
          verbatim: [
            item.runAtLoad ? tr("登录时运行") : nil, item.keepAlive ? tr("保持运行") : nil,
          ].compactMap { $0 }.joined(separator: " · "))
      }
      if let interval = details.interval {
        Text(verbatim: Self.intervalText(interval))
      }
      if !details.schedules.isEmpty {
        LabeledContent(tr("日历计划")) {
          VStack(alignment: .leading, spacing: DS.Space.s1) {
            ForEach(Array(details.schedules.prefix(8).enumerated()), id: \.offset) { _, schedule in
              Text(verbatim: Self.timing(schedule))
            }
            if details.schedules.count > 8 {
              Text(
                tr("另有 \((details.schedules.count - 8).formatted(.number.locale(L10n.locale))) 项"))
            }
          }
        }
      }
      if !details.watchedPaths.isEmpty {
        LabeledContent(tr("路径变化时运行")) {
          VStack(alignment: .leading, spacing: DS.Space.s1) {
            ForEach(Array(details.watchedPaths.prefix(4).enumerated()), id: \.offset) { _, path in
              Text(verbatim: path).lineLimit(1).truncationMode(.middle).help(path)
            }
            if details.watchedPaths.count > 4 {
              Text(
                tr(
                  "另有 \((details.watchedPaths.count - 4).formatted(.number.locale(L10n.locale))) 项")
              )
            }
          }
        }
      }
      if let exitStatus {
        LabeledContent(tr("上次退出状态")) {
          Text(exitStatus.formatted(.number.grouping(.never).locale(L10n.locale)))
            .monospacedDigit()
            .foregroundStyle(exitStatus == 0 ? DS.Palette.textPrimary : DS.Palette.warning)
        }
      }
    }
    .foregroundStyle(DS.Palette.textSecondary)
  }

  static func intervalText(_ interval: Int) -> String {
    let duration = Duration.seconds(interval).formatted(
      .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated).locale(L10n.locale))
    return tr("每 \(duration) 运行")
  }

  static func timing(_ schedule: LaunchItem.Schedule) -> String {
    let formatter = DateFormatter()
    formatter.locale = L10n.locale
    if let hour = schedule.hour, let minute = schedule.minute, schedule.month == nil,
      schedule.day == nil, schedule.weekday == nil
    {
      let date = Date(timeIntervalSince1970: Double(hour * 3600 + minute * 60))
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.timeStyle = .short
      return tr("每天 \(formatter.string(from: date)) 运行")
    }
    let number = IntegerFormatStyle<Int>.number.grouping(.never).locale(L10n.locale)
    let fields = [
      schedule.month.map { tr("月份 \($0.formatted(number))") },
      schedule.day.map { tr("日期 \($0.formatted(number))") },
      schedule.weekday.map { formatter.weekdaySymbols[$0 % 7] },
      schedule.hour.map { tr("小时 \($0.formatted(number))") },
      schedule.minute.map { tr("分钟 \($0.formatted(number))") },
    ].compactMap { $0 }
    return fields.isEmpty ? tr("每分钟运行") : fields.joined(separator: " · ")
  }

  private func logLocation(_ log: StartupLogFile) -> some View {
    HStack(spacing: DS.Space.s2) {
      Image(systemName: "doc.text").foregroundStyle(DS.Palette.textSecondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
        Text(verbatim: (log.path as NSString).lastPathComponent)
          .dsFont(.xs, weight: .medium)
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(log.path)
        Text(log.title).foregroundStyle(DS.Palette.textSecondary)
      }
      Spacer(minLength: DS.Space.s2)
      switch availability[log.path] {
      case .file:
        Button(tr("在访达中显示")) { pendingReveal = log.path }
          .controlSize(.small)
          .disabled(pendingReveal != nil)
      case .missing:
        Text(tr("文件尚未生成")).foregroundStyle(DS.Palette.textSecondary)
      case .unavailable:
        Text(tr("日志文件不可用")).foregroundStyle(DS.Palette.textSecondary)
      case nil:
        ProgressView().controlSize(.mini)
      }
    }
  }
}

struct StartupLogFile: Hashable, Sendable {
  enum Stream: Hashable, Sendable { case output, error, combined }
  enum Availability: Equatable, Sendable { case file, missing, unavailable }

  let path: String
  let stream: Stream

  var title: String {
    switch stream {
    case .output: tr("标准输出日志")
    case .error: tr("标准错误日志")
    case .combined: tr("标准输出与错误日志")
    }
  }

  static func configured(in details: LaunchItem.Details) -> [Self] {
    if let output = details.standardOutput, output == details.standardError {
      return [.init(path: output, stream: .combined)]
    }
    return [
      details.standardOutput.map { Self(path: $0, stream: .output) },
      details.standardError.map { Self(path: $0, stream: .error) },
    ].compactMap { $0 }
  }

  static func availability(at path: String) -> Availability {
    var file = stat()
    guard path.withCString({ stat($0, &file) }) == 0 else {
      return errno == ENOENT || errno == ENOTDIR ? .missing : .unavailable
    }
    return file.st_mode & S_IFMT == S_IFREG ? .file : .unavailable
  }
}
