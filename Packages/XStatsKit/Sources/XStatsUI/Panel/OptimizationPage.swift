// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import HelperShared
import Localization
import SwiftUI

struct OptimizationPage: View {
  @Environment(AppModel.self) private var model
  @State private var resetRequested = false
  @State private var showsSpotlightRepair = false

  var body: some View {
    VStack(spacing: DS.Space.s3) {
      OptimizationActionCard(
        command: .flushDNS, icon: "network", title: tr("刷新 DNS 缓存"),
        detail: tr("遇到域名解析异常时手动刷新，不修改 DNS 服务器或代理设置。")
      )
      thumbnailReset
      Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
        HStack {
          Label(tr("修复 Spotlight 搜索"), systemImage: "magnifyingglass")
            .dsFont(.sm, weight: .medium)
          Spacer()
          Button(tr("查看修复步骤")) { showsSpotlightRepair = true }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(!model.settings.cleanerEnabled)
        }
        Text(tr("搜索找不到文件时，在系统设置中重建指定位置的索引。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
      OptimizationActionCard(
        command: .purgeMemory, icon: "memorychip", title: tr("释放内存"),
        detail: tr("手动释放可回收缓存；再次打开应用时可能需要重新加载，不建议频繁执行。")
      )
      HomebrewDependencyPreview()
    }
    .fixedSize(horizontal: false, vertical: true)
    .task(id: resetRequested && model.settings.cleanerEnabled) {
      guard resetRequested else { return }
      defer { resetRequested = false }
      guard model.settings.cleanerEnabled else { return }
      await model.maintenance.resetThumbnails()
    }
    // 隐藏或最小化窗口不会移除视图；明确撤销请求，让 .task 取消并结束子进程。
    .onChange(of: model.isMainWindowVisible) { _, visible in
      if !visible { resetRequested = false }
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
    ) { _ in resetRequested = false }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.sessionDidResignActiveNotification)
    ) { _ in resetRequested = false }
    .onReceive(
      DistributedNotificationCenter.default().publisher(
        for: Notification.Name("com.apple.screenIsLocked"))
    ) { _ in resetRequested = false }
    .sheet(isPresented: $showsSpotlightRepair) { SpotlightRepairSheet() }
  }

  private var thumbnailReset: some View {
    let maintenance = model.maintenance
    return Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
      HStack {
        Label(tr("重置缩略图"), systemImage: "photo")
          .dsFont(.sm, weight: .medium)
        Spacer()
        if maintenance.isResettingThumbnails {
          ProgressView().controlSize(.small)
          Button(tr("取消")) { resetRequested = false }
            .buttonStyle(DSButtonStyle(kind: .secondary))
        } else {
          Button(tr("重置缩略图")) { resetRequested = true }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(
              maintenance.running != nil || maintenance.isBlockedByMole
                || !model.settings.cleanerEnabled)
        }
      }
      Text(tr("预览缩略图空白或未更新时重置，文件内容不受影响。"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      if let outcome = maintenance.thumbnailOutcome {
        Text(outcome.text).dsFont(.xs)
          .foregroundStyle(outcome.isError ? DS.Palette.error : DS.Palette.success)
          .textSelection(.enabled)
      }
    }
  }
}

struct SpotlightRepairSheet: View {
  @Environment(\.dismiss) private var dismiss
  @State private var openFailed = false

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      Text(tr("修复 Spotlight 搜索")).dsFont(.lg, weight: .semibold)
      Text(tr("在系统设置中打开 Spotlight 的“搜索隐私”或“Spotlight 隐私”。"))
      Text(tr("将需要重建索引的文件夹或磁盘加入列表，等待几秒，再从列表中移除。"))
      Text(tr("macOS 随后会重新建立索引，完成前搜索结果可能不完整。"))
        .foregroundStyle(DS.Palette.textSecondary)
      if openFailed {
        Text(tr("无法打开系统设置，请手动前往 Spotlight 设置。"))
          .foregroundStyle(DS.Palette.error)
      }
      HStack {
        Link(
          tr("查看 Apple 修复步骤"),
          destination: URL(string: "https://support.apple.com/102321")!)
        Spacer()
        Button(tr("关闭")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(tr("打开 Spotlight 设置")) {
          // 新版系统将 Spotlight 与 Siri 分开；旧标识仍可能路由到 Siri。
          let pane: String
          if #available(macOS 15, *) {
            pane = "com.apple.Spotlight-Settings.extension"
          } else {
            pane = "com.apple.preference.spotlight"
          }
          let url = URL(string: "x-apple.systempreferences:\(pane)")!
          openFailed = !NSWorkspace.shared.open(url)
        }
        .buttonStyle(DSButtonStyle(kind: .primary))
      }
    }
    .dsFont(.sm)
    .padding(DS.Space.s4)
    .frame(idealWidth: 520)
  }
}

private struct OptimizationActionCard: View {
  @Environment(AppModel.self) private var model
  let command: MaintenanceCommand
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    let maintenance = model.maintenance
    Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
      HStack {
        Label(title, systemImage: icon).dsFont(.sm, weight: .medium)
        Spacer()
        Button(maintenance.running == command ? tr("执行中") : title) {
          Task { await maintenance.run(command) }
        }
        .buttonStyle(DSButtonStyle(kind: .secondary))
        .disabled(
          maintenance.running != nil || maintenance.isResettingThumbnails
            || maintenance.isBlockedByMole || !model.settings.cleanerEnabled)
      }
      Text(detail).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      Text(model.helper.isReady ? tr("由辅助工具执行") : tr("需要管理员授权"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
      if let outcome = maintenance.outcomes[command] {
        Text(outcome.text)
          .dsFont(.xs)
          .foregroundStyle(outcome.isError ? DS.Palette.error : DS.Palette.success)
          .textSelection(.enabled)
      }
    }
  }
}

private struct HomebrewDependencyPreview: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let check = model.systemCheck
    Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
      HStack {
        Label(tr("Homebrew 依赖预览"), systemImage: "shippingbox")
          .dsFont(.sm, weight: .medium)
        Spacer()
        if let date = check.checkedAt {
          Text(verbatim: date.formatted(.dateTime.hour().minute().locale(L10n.locale)))
            .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
        if check.isChecking {
          ProgressView().controlSize(.small)
          Button(tr("取消")) { check.cancel() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
        } else {
          Button(tr("预览")) { check.start() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(!model.settings.cleanerEnabled || model.cleaner.isBusy)
        }
      }
      Text(tr("由 Homebrew 列出不再需要的依赖，仅供审阅。"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      ForEach(check.findings) { finding in
        HairlineDivider()
        VStack(alignment: .leading, spacing: DS.Space.s1) {
          if !finding.isComplete || finding.status == .unchecked
            || finding.status == .notApplicable
          {
            Text(finding.detail)
          } else if finding.evidence.isEmpty {
            Text(tr("没有可移除的依赖"))
          }
          ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, evidence in
            Text(verbatim: evidence).textSelection(.enabled)
          }
        }
        .dsFont(.xs)
        .foregroundStyle(
          finding.isComplete ? DS.Palette.textSecondary : DS.Palette.warning
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}
