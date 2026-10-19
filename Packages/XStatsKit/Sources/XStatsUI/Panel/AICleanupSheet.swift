// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Localization
import Metrics
import SwiftUI

struct AICleanupSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var controller: AICleanupController

  init(excludedPaths: [String]) {
    let clean = CleanEnvironment(runningBundleIdentifiers: { [] }, excludedPaths: excludedPaths)
    _controller = State(
      initialValue: AICleanupController(environment: AICleanupEnvironment(clean: clean)))
  }
  init(controller: AICleanupController, initialSection: Int = 0) {
    _controller = State(initialValue: controller)
    _section = State(initialValue: initialSection)
  }

  @State private var section = 0
  @State private var pauseReasons: Set<String> = []
  private var paused: Bool { !pauseReasons.isEmpty }
  @State private var isVisible = false

  var body: some View {
    VStack(spacing: 0) {
      header
      VStack(alignment: .leading, spacing: DS.Space.s4) {
        HStack(spacing: DS.Space.s4) {
          Picker(tr("类型"), selection: $section) {
            Text(tr("工具数据")).tag(0)
            Text("Worktree").tag(1)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 320, alignment: .leading)
          Spacer(minLength: 0)
          if controller.isBusy, controller.scan != nil { ProgressView().controlSize(.small) }
          Button {
            controller.refresh()
          } label: {
            Label(tr("重新扫描"), systemImage: "arrow.clockwise")
          }
          .buttonStyle(.bordered)
          .disabled(controller.isBusy || paused)
        }
        if let message = controller.message {
          InfoBanner(
            icon: controller.isError ? "exclamationmark.triangle" : "checkmark.circle",
            text: message,
            tone: controller.isError ? .warning : .success)
        }
        ScrollView {
          VStack(alignment: .leading, spacing: DS.Space.s3) {
            if let scan = controller.scan {
              if scan.incomplete {
                Label(
                  tr("部分位置未完整扫描，数量与大小仅包含已确认的项目。"),
                  systemImage: "exclamationmark.circle"
                )
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
              }
              if section == 0 { tools(scan) } else { worktrees(scan) }
            } else {
              VStack(spacing: DS.Space.s3) {
                if controller.isBusy {
                  ProgressView().controlSize(.regular)
                } else {
                  Image(systemName: "externaldrive").font(.system(size: 32))
                }
                Text(controller.isBusy ? tr("扫描中") : tr("点击重新扫描以查看工具与 worktree"))
                  .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
              }
              .frame(maxWidth: .infinity, minHeight: 200)
            }
          }
          .id(section)
          .transition(.opacity)
          .padding(.vertical, DS.Space.s1)
        }
        .animation(reduceMotion ? nil : DS.Motion.quick, value: section)
      }
      .padding(.horizontal, DS.Space.s6)
      .padding(.top, DS.Space.s4)
      .padding(.bottom, DS.Space.s3)
      .frame(maxHeight: .infinity)
      .background(DS.Palette.surface)
      HairlineDivider()
      footer.padding(DS.Space.s6)
    }
    .frame(width: 760, height: sheetHeight)
    .background(DS.Palette.background).appLanguageEnvironment()
    // Alert 自动关闭可能早于按钮回调；冻结目标由明确的按钮动作或页面取消来清除。
    .alert(
      confirmationTitle,
      isPresented: Binding(get: { controller.confirmation != nil }, set: { _ in })
    ) {
      Button(tr("取消"), role: .cancel) { controller.confirmation = nil }
      Button(confirmationAction, role: .destructive) { controller.confirm() }
    } message: {
      Text(confirmationMessage)
    }
    .onAppear {
      isVisible = true
      if !isSnapshot { controller.refresh() }
    }
    .onDisappear {
      isVisible = false
      controller.cancel()
    }
    .onChange(of: model.settings.cleanerEnabled) { _, enabled in
      if !enabled {
        controller.cancel()
        dismiss()
      }
    }
    .onChange(of: model.isMainWindowVisible) { _, visible in
      if !visible { controller.cancel() } else if isVisible && !paused { controller.refresh() }
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
    ) { _ in pause("sleep") }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
    ) { _ in resume("sleep") }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.sessionDidResignActiveNotification)
    ) { _ in pause("session") }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.sessionDidBecomeActiveNotification)
    ) { _ in resume("session") }
    .onReceive(
      DistributedNotificationCenter.default().publisher(
        for: Notification.Name("com.apple.screenIsLocked"))
    ) { _ in pause("lock") }
    .onReceive(
      DistributedNotificationCenter.default().publisher(
        for: Notification.Name("com.apple.screenIsUnlocked"))
    ) { _ in resume("lock") }
  }

  private var sheetHeight: CGFloat {
    guard section == 1, let scan = controller.scan else { return 620 }
    return scan.worktrees.isEmpty ? 460 : 640
  }

  private var header: some View {
    HStack(spacing: DS.Space.s3) {
      Image(systemName: "terminal")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(DS.Palette.primary)
        .frame(width: 44, height: 44)
        .background(
          DS.Palette.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: DS.Radius.lg)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DS.Space.s1) {
        Text(tr("Agent 数据")).dsFont(.lg, weight: .semibold)
        Text(tr("编程工具的本地数据与工作目录"))
          .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: DS.Space.s3)
      Button(tr("完成")) { dismiss() }
        .buttonStyle(.bordered).keyboardShortcut(.cancelAction)
    }
    .padding(DS.Space.s6)
  }

  private func tools(_ scan: AICleanupScan) -> some View {
    let detected = scan.tools.filter { $0.installation != .absent }
    let absent = scan.tools.filter { $0.installation == .absent }
    return VStack(alignment: .leading, spacing: DS.Space.s3) {
      HStack(spacing: DS.Space.s2) {
        Text(tr("已安装工具"))
        Text(verbatim: number(scan.installedCount)).monospacedDigit()
        Text("·").accessibilityHidden(true)
        Text("Worktree")
        Text(verbatim: number(scan.worktrees.count)).monospacedDigit()
      }
      .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      .padding(.horizontal, DS.Space.s3)
      VStack(spacing: 0) {
        MainActorForEach(Array(detected.enumerated()), id: \.element.id) { index, tool in
          if index > 0 { HairlineDivider().padding(.leading, DS.Space.s4) }
          toolRow(tool)
        }
      }
      .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
      if !absent.isEmpty {
        DisclosureGroup {
          VStack(spacing: 0) {
            MainActorForEach(absent) { tool in toolRow(tool) }
          }
        } label: {
          HStack {
            Text(tr("未检测到"))
            Spacer()
            Text(verbatim: number(absent.count)).monospacedDigit()
          }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(DS.Space.s3)
        .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
      }
    }
  }

  private func toolRow(_ tool: AIAgentTool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if tool.dataDirectories.isEmpty {
        toolLabel(tool).padding(.leading, DS.Space.s4)
      } else {
        DisclosureGroup {
          VStack(alignment: .leading, spacing: DS.Space.s2) {
            MainActorForEach(tool.dataDirectories, id: \.path) { url in
              HStack(alignment: .top, spacing: DS.Space.s3) {
                Text(verbatim: displayPath(url))
                  .dsFont(.xs).textSelection(.enabled)
                  .foregroundStyle(DS.Palette.textSecondary)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .fixedSize(horizontal: false, vertical: true)
                  .environment(\.layoutDirection, .leftToRight)
                Button {
                  NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                  Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help(tr("在访达中显示")).accessibilityLabel(tr("在访达中显示"))
              }
            }
          }
          .padding(.leading, DS.Space.s12)
          .padding(.top, DS.Space.s2)
          .padding(.bottom, DS.Space.s1)
        } label: {
          toolLabel(tool)
        }
      }
    }
    .padding(.horizontal, DS.Space.s4)
    .padding(.vertical, DS.Space.s3)
  }

  private func toolLabel(_ tool: AIAgentTool) -> some View {
    HStack(spacing: DS.Space.s3) {
      Image(systemName: toolSymbol(tool.id))
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(
          tool.installation == .installed ? DS.Palette.primary : DS.Palette.textSecondary
        )
        .frame(width: 32, height: 32)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: tool.name).dsFont(.sm, weight: .semibold)
        Text(status(tool.installation)).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
      Spacer(minLength: DS.Space.s3)
      Text(verbatim: tool.bytes.map { Format.bytes($0, base: .decimal) } ?? tr("未完整统计"))
        .dsFont(.sm, weight: .medium).monospacedDigit()
        .foregroundStyle(tool.bytes == nil ? DS.Palette.textSecondary : DS.Palette.textPrimary)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  private func toolSymbol(_ id: String) -> String {
    switch id {
    case "claude": "asterisk"
    case "gemini": "sparkle"
    case "cursor": "cursorarrow"
    case "opencode": "chevron.left.forwardslash.chevron.right"
    default: "terminal"
    }
  }

  @ViewBuilder private func worktrees(_ scan: AICleanupScan) -> some View {
    if !scan.worktrees.isEmpty {
      HStack(spacing: DS.Space.s2) {
        Text("Worktree")
        Text(verbatim: number(scan.worktrees.count)).monospacedDigit()
      }
      .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      .padding(.horizontal, DS.Space.s3)
    }
    if !scan.gitAvailable || scan.worktrees.isEmpty {
      VStack(spacing: DS.Space.s3) {
        Image(systemName: scan.gitAvailable ? "folder.badge.questionmark" : "arrow.triangle.branch")
          .font(.system(size: 32, weight: .light)).foregroundStyle(DS.Palette.textTertiary)
          .accessibilityHidden(true)
        Text(
          scan.gitAvailable
            ? tr("已扫描位置中未发现 worktree") : tr("未安装 Git 命令行工具，暂时无法检查 worktree")
        )
        .dsFont(.sm, weight: .medium).multilineTextAlignment(.center)
        if scan.gitAvailable {
          Button(tr("添加扫描目录…")) { addRoot() }
            .buttonStyle(.bordered).disabled(controller.isBusy || paused)
        }
      }
      .padding(DS.Space.s6)
      .frame(maxWidth: .infinity, minHeight: 156)
      .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
    MainActorForEach(scan.worktrees) { item in
      VStack(alignment: .leading, spacing: DS.Space.s3) {
        HStack(alignment: .top, spacing: DS.Space.s3) {
          Image(systemName: "arrow.triangle.branch")
            .font(.system(size: 18, weight: .medium)).foregroundStyle(DS.Palette.primary)
            .frame(width: 36, height: 36)
            .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(verbatim: item.repository.lastPathComponent).dsFont(.sm, weight: .semibold)
            Text(verbatim: item.branch ?? tr("分离 HEAD")).dsFont(.xs)
              .foregroundStyle(DS.Palette.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: DS.Space.s3)
          Text(verbatim: item.bytes.map { Format.bytes($0, base: .decimal) } ?? "—")
            .dsFont(.sm, weight: .medium).monospacedDigit()
        }
        Text(verbatim: displayPath(item.url)).dsFont(.xs).textSelection(.enabled)
          .foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
          .environment(\.layoutDirection, .leftToRight)
        HairlineDivider()
        HStack(alignment: .center, spacing: DS.Space.s3) {
          Label(
            item.protection?.title ?? tr("检查通过，移除前会再次核对"),
            systemImage: item.canRemove ? "checkmark.shield" : "lock.shield"
          )
          .dsFont(.xs).foregroundStyle(
            item.canRemove ? DS.Palette.success : DS.Palette.textSecondary
          )
          .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
          } label: {
            Image(systemName: "folder")
          }
          .buttonStyle(.borderless)
          .help(tr("在访达中显示")).accessibilityLabel(tr("在访达中显示"))
          Button(tr("移除…")) { controller.requestRemoval(item) }
            .buttonStyle(.bordered)
            .disabled(!item.canRemove || controller.isBusy || paused)
        }
      }
      .padding(DS.Space.s4)
      .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
    DisclosureGroup(tr("已扫描位置")) {
      VStack(alignment: .leading, spacing: DS.Space.s2) {
        MainActorForEach(scan.searchedRoots, id: \.path) { url in
          Text(verbatim: displayPath(url)).dsFont(.xs).textSelection(.enabled)
            .foregroundStyle(DS.Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, .leftToRight)
        }
      }.padding(.top, DS.Space.s2)
    }
    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    .padding(DS.Space.s3)
    .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
  }

  private var footer: some View {
    HStack(alignment: .center, spacing: DS.Space.s4) {
      VStack(alignment: .leading, spacing: DS.Space.s1) {
        if section == 0, controller.scan != nil {
          Text(tr("\(number(controller.logCount)) 个旧日志可清理"))
            .dsFont(.sm, weight: .medium)
        }
        Text(
          section == 0
            ? tr("工具数据不含托管 worktree。仅清理 7 天前的日志，保留会话、配置与凭据。")
            : tr("仅检查常见工具目录与项目位置；移除 worktree 不会删除分支，且无法从废纸篓恢复。")
        )
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if section == 0 {
        Button(tr("清理旧日志…")) { controller.requestLogCleanup() }
          .buttonStyle(.borderedProminent).controlSize(.large)
          .disabled(controller.logCount == 0 || controller.isBusy || paused)
      } else if controller.scan?.worktrees.isEmpty == false {
        Button(tr("添加扫描目录…")) { addRoot() }
          .buttonStyle(.bordered).disabled(controller.isBusy || paused)
      }
    }
  }

  private var confirmationTitle: String {
    switch controller.confirmation {
    case .worktree: tr("移除这个 worktree？")
    default: tr("将旧日志移到废纸篓？")
    }
  }
  private var confirmationAction: String {
    switch controller.confirmation {
    case .worktree: tr("移除 worktree")
    default: tr("移到废纸篓")
    }
  }
  private var confirmationMessage: String {
    switch controller.confirmation {
    case .worktree(let item):
      return displayPath(item.url) + "\n\n"
        + tr("将移除该工作目录，保留 Git 分支。请先结束使用它的 Agent 会话并关闭编辑器。此操作无法撤销。")
    case .logs(let logs):
      let count = logs.reduce(0) { $0 + $1.items.count }
      return tr("将 \(number(count)) 个旧日志移到废纸篓，需要时可从废纸篓恢复。")
    case nil: return ""
    }
  }
  private func status(_ installation: AIAgentTool.Installation) -> String {
    switch installation {
    case .installed: tr("已安装")
    case .dataOnly: tr("仅检测到数据")
    case .absent: tr("未检测到")
    }
  }
  private func displayPath(_ url: URL) -> String {
    let home = NSHomeDirectory()
    return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
  }
  private func number(_ value: Int) -> String { value.formatted(.number.locale(L10n.locale)) }
  private func addRoot() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in
        guard isVisible, model.isMainWindowVisible, !paused else { return }
        controller.refresh(additionalRoot: url)
      }
    }
  }
  private func pause(_ reason: String) {
    pauseReasons.insert(reason)
    controller.cancel()
  }
  private func resume(_ reason: String) {
    pauseReasons.remove(reason)
    if isVisible, !paused, model.isMainWindowVisible { controller.refresh() }
  }
}
