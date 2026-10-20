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

  init(controller: AICleanupController, initialSection: Int = 0) {
    _controller = State(initialValue: controller)
    _section = State(initialValue: initialSection)
  }

  @State private var section = 0
  @State private var scanLocationsExpanded = true
  @State private var pauseReasons: Set<String> = []
  private var paused: Bool { !pauseReasons.isEmpty }
  private var enabled: Bool { model.settings.cleanerEnabled && model.settings.agentDataEnabled }
  @State private var isVisible = false

  var body: some View {
    VStack(spacing: 0) {
      header
      VStack(alignment: .leading, spacing: DS.Space.s4) {
        HStack(spacing: DS.Space.s4) {
          Picker(tr("类型"), selection: $section) {
            Text(tr("AI 工具")).tag(0)
            Text("Worktree").tag(1)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 320, alignment: .leading)
          Spacer(minLength: 0)
          if controller.isBusy, controller.scan != nil { ProgressView().controlSize(.small) }
          Button {
            guard enabled else { return }
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
    }
    .frame(
      minWidth: 560, idealWidth: 760, maxWidth: .infinity,
      minHeight: 400, idealHeight: 620, maxHeight: .infinity
    )
    .background(DS.Palette.background).appLanguageEnvironment()
    // Alert 自动关闭可能早于按钮回调；冻结目标由明确的按钮动作或页面取消来清除。
    .alert(
      tr("移除这个 worktree？"),
      isPresented: Binding(get: { controller.confirmation != nil }, set: { _ in })
    ) {
      Button(tr("取消"), role: .cancel) { controller.confirmation = nil }
      Button(tr("移除 worktree"), role: .destructive) {
        guard enabled else { return }
        controller.confirm()
      }
    } message: {
      Text(confirmationMessage)
    }
    .onAppear {
      isVisible = true
      if !isSnapshot {
        if enabled {
          controller.loadIfNeeded(excludedPaths: model.cleaner.excludedPaths)
        } else {
          dismiss()
        }
      }
    }
    .onDisappear {
      isVisible = false
      controller.cancel()
    }
    .onChange(of: enabled) { _, enabled in
      if !enabled {
        controller.invalidate()
        dismiss()
      }
    }
    .onChange(of: model.cleaner.excludedPaths) { _, paths in
      if enabled, isVisible, !paused, model.isMainWindowVisible {
        controller.loadIfNeeded(excludedPaths: paths)
      }
    }
    .onChange(of: model.isMainWindowVisible) { _, visible in
      if !visible {
        controller.cancel()
      } else if enabled && isVisible && !paused {
        controller.loadIfNeeded(excludedPaths: model.cleaner.excludedPaths)
      }
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
      Text(tr("Agent 数据")).dsFont(.lg, weight: .semibold)
      Spacer(minLength: DS.Space.s3)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(DS.Palette.textSecondary)
          .frame(width: 28, height: 28)
          .background(DS.Palette.surface, in: Circle())
      }
      .buttonStyle(.plain)
      .help(tr("关闭面板"))
      .accessibilityLabel(tr("关闭面板"))
      .keyboardShortcut(.cancelAction)
    }
    .padding(DS.Space.s6)
  }

  @ViewBuilder private func tools(_ scan: AICleanupScan) -> some View {
    HStack(spacing: DS.Space.s2) {
      Text(tr("已安装工具"))
      Text(verbatim: number(scan.installedCount)).monospacedDigit()
    }
    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    .padding(.horizontal, DS.Space.s3)
    if scan.tools.isEmpty {
      VStack(spacing: DS.Space.s3) {
        Image(systemName: "terminal")
          .font(.system(size: 32, weight: .light)).foregroundStyle(DS.Palette.textTertiary)
          .accessibilityHidden(true)
        Text(tr("未发现已安装的 AI 工具"))
          .dsFont(.sm, weight: .medium).multilineTextAlignment(.center)
      }
      .padding(DS.Space.s6)
      .frame(maxWidth: .infinity, minHeight: 156)
      .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    } else {
      VStack(spacing: 0) {
        MainActorForEach(Array(scan.tools.enumerated()), id: \.element.id) { index, tool in
          if index > 0 { HairlineDivider().padding(.leading, DS.Space.s4) }
          toolRow(tool)
        }
      }
      .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
  }

  private func toolRow(_ tool: AIAgentTool) -> some View {
    HStack(alignment: .top, spacing: DS.Space.s3) {
      toolIcon(tool)
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DS.Space.s2) {
        HStack(spacing: DS.Space.s3) {
          Text(verbatim: tool.name).dsFont(.sm, weight: .semibold)
          Spacer(minLength: 0)
          Text(verbatim: tool.bytes.map { Format.bytes($0, base: .decimal) } ?? tr("未完整统计"))
            .dsFont(.sm, weight: .medium).monospacedDigit()
            .foregroundStyle(tool.bytes == nil ? DS.Palette.textSecondary : DS.Palette.textPrimary)
            .fixedSize(horizontal: true, vertical: false)
        }
        if tool.dataDirectories.isEmpty {
          Text(tr("尚未发现关联数据目录"))
            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        }
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
    }
    .padding(.horizontal, DS.Space.s4)
    .padding(.vertical, DS.Space.s3)
  }

  @ViewBuilder private func toolIcon(_ tool: AIAgentTool) -> some View {
    if let applicationURL = tool.applicationURL {
      AppIconCache.shared.image(bundlePath: applicationURL.path)
        .resizable().scaledToFit().frame(width: 32, height: 32)
    } else if let name = tool.id == "codebuddy"
      ? "tool-codebuddy" : AIServiceBrand.logoName(tool.id == "vscode" ? "copilot" : tool.id),
      let logo = LogoCache.shared.image(
        named: name, template: ["codex", "grok", "vscode"].contains(tool.id))
    {
      Image(nsImage: logo).resizable().scaledToFit()
        .foregroundStyle(DS.Palette.textPrimary)
        .frame(width: 22, height: 22)
        .frame(width: 32, height: 32)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    } else {
      Image(systemName: "terminal")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(DS.Palette.textSecondary)
        .frame(width: 32, height: 32)
        .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
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
      }
      .padding(DS.Space.s6)
      .frame(maxWidth: .infinity, minHeight: 156)
      .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
    if !scan.worktrees.isEmpty {
      VStack(spacing: 0) {
        MainActorForEach(Array(scan.worktrees.enumerated()), id: \.element.id) { index, item in
          if index > 0 { HairlineDivider().padding(.leading, DS.Space.s4) }
          HStack(alignment: .top, spacing: DS.Space.s3) {
            Image(systemName: "arrow.triangle.branch")
              .font(.system(size: 16, weight: .medium)).foregroundStyle(DS.Palette.primary)
              .frame(width: 32, height: 32)
              .background(DS.Palette.surface, in: RoundedRectangle(cornerRadius: DS.Radius.md))
              .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s1) {
              HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Text(verbatim: item.repository.lastPathComponent).dsFont(.sm, weight: .semibold)
                Text(verbatim: item.branch ?? tr("分离 HEAD")).dsFont(.xs)
                  .foregroundStyle(DS.Palette.textSecondary)
              }
              .fixedSize(horizontal: false, vertical: true)
              Text(verbatim: displayPath(item.url)).dsFont(.xs).textSelection(.enabled)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.layoutDirection, .leftToRight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: DS.Space.s2) {
              Text(verbatim: item.bytes.map { Format.bytes($0, base: .decimal) } ?? "—")
                .dsFont(.sm, weight: .medium).monospacedDigit()
              HStack(spacing: DS.Space.s3) {
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
                  .help(item.protection?.title ?? tr("检查通过，移除前会再次核对"))
                  .accessibilityHint(item.protection?.title ?? tr("检查通过，移除前会再次核对"))
              }
            }
            .fixedSize(horizontal: true, vertical: false)
          }
          .padding(.horizontal, DS.Space.s4)
          .padding(.vertical, DS.Space.s3)
        }
      }
      .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
    }
    scanLocations(scan)
  }

  private func scanLocations(_ scan: AICleanupScan) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: DS.Space.s3) {
        Button {
          withAnimation(reduceMotion ? nil : DS.Motion.quick) {
            scanLocationsExpanded.toggle()
          }
        } label: {
          HStack(spacing: DS.Space.s2) {
            Image(systemName: "magnifyingglass")
              .foregroundStyle(DS.Palette.textSecondary)
              .accessibilityHidden(true)
            Text(tr("扫描位置")).dsFont(.sm, weight: .medium)
            Text(verbatim: number(scan.searchedRoots.count))
              .dsFont(.xs).monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
              .padding(.horizontal, DS.Space.s2)
              .padding(.vertical, DS.Space.s1)
              .background(DS.Palette.surface, in: Capsule())
            Image(systemName: scanLocationsExpanded ? "chevron.down" : "chevron.forward")
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(DS.Palette.textTertiary)
            Spacer(minLength: 0)
          }
          .frame(minHeight: 28)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          Text(tr("扫描位置")) + Text(" ") + Text(verbatim: number(scan.searchedRoots.count))
        )
        .accessibilityValue(scanLocationsExpanded ? tr("展开") : tr("收起"))
        .help(scanLocationsExpanded ? tr("收起") : tr("展开"))
        Button {
          addRoot()
        } label: {
          Label(tr("添加目录…"), systemImage: "plus")
        }
        .buttonStyle(.bordered)
        .disabled(controller.isBusy || paused)
      }
      .padding(.horizontal, DS.Space.s4)
      .padding(.vertical, DS.Space.s3)
      if scanLocationsExpanded {
        HairlineDivider().padding(.horizontal, DS.Space.s4)
        if scan.searchedRoots.isEmpty {
          Text(tr("没有扫描目录"))
            .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.s4)
        } else {
          VStack(spacing: 0) {
            MainActorForEach(Array(scan.searchedRoots.enumerated()), id: \.element.path) {
              index, url in
              if index > 0 { HairlineDivider().padding(.leading, DS.Space.s4) }
              HStack(alignment: .top, spacing: DS.Space.s3) {
                Image(systemName: "folder")
                  .font(.system(size: 16)).foregroundStyle(DS.Palette.textSecondary)
                  .frame(width: 24, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                  Text(verbatim: url.lastPathComponent).dsFont(.sm, weight: .medium)
                    .fixedSize(horizontal: false, vertical: true)
                  Text(verbatim: displayPath(url)).dsFont(.xs).textSelection(.enabled)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.layoutDirection, .leftToRight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                  NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                  Image(systemName: "arrow.up.forward.square")
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(tr("在访达中显示"))
                .accessibilityLabel(tr("在访达中显示"))
              }
              .padding(.horizontal, DS.Space.s4)
              .padding(.vertical, DS.Space.s3)
            }
          }
        }
      }
    }
    .background(DS.Palette.background, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
  }

  private var confirmationMessage: String {
    guard case .worktree(let item) = controller.confirmation else { return "" }
    return displayPath(item.url) + "\n\n"
      + tr("将移除该工作目录，保留 Git 分支。请先结束使用它的 Agent 会话并关闭编辑器。此操作无法撤销。")
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
        guard enabled, isVisible, model.isMainWindowVisible, !paused else { return }
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
    if enabled, isVisible, !paused, model.isMainWindowVisible {
      controller.loadIfNeeded(excludedPaths: model.cleaner.excludedPaths)
    }
  }
}
