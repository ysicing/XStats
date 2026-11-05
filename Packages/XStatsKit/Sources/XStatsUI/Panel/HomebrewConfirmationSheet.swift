// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Localization
import SwiftUI

struct BrewConfirmation: Identifiable {
  var id: String { action.rawValue + package.id }
  let package: HomebrewPackage
  let action: HomebrewManagement.Action
}

struct HomebrewConfirmationSheet: View {
  let controller: AppManagementController
  var isRemoving = false
  let confirmation: BrewConfirmation
  let confirm: () -> Void
  let cancel: () -> Void
  @State var showsPreview = false
  private var requiresPreview: Bool { confirmation.action == .uninstall }
  private var preview: HomebrewImpactPreview? {
    guard let preview = controller.impactPreview,
      preview.package == confirmation.package, preview.action == confirmation.action
    else { return nil }
    return preview
  }
  var canConfirm: Bool {
    (!requiresPreview || preview?.canProceed == true) && !controller.isPreparingPreview
      && !controller.homebrewOperations.isRunning && !isRemoving
      && controller.canPerform(confirmation.action, package: confirmation.package)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      Text(
        confirmation.action == .upgrade
          ? tr("更新“\(confirmation.package.displayName)”？")
          : tr("卸载“\(confirmation.package.displayName)”？")
      )
      .dsFont(.lg, weight: .semibold)
      .fixedSize(horizontal: false, vertical: true)
      if requiresPreview {
        previewContent
      } else {
        Text(verbatim: confirmation.package.name).dsFont(.sm)
          .environment(\.layoutDirection, .leftToRight)
        Text(
          verbatim:
            confirmation.package.version + " → " + (confirmation.package.latestVersion ?? "—")
        )
        .dsFont(.sm).monospacedDigit()
        .environment(\.layoutDirection, .leftToRight)
        DisclosureGroup(tr("查看影响预览"), isExpanded: $showsPreview) {
          previewContent
        }
        .dsFont(.sm)
        .accessibilityIdentifier("homebrew-impact-preview")
        if !showsPreview, let error = controller.previewError {
          Text(verbatim: error).dsFont(.sm).foregroundStyle(DS.Palette.error)
        }
      }
      InstallationSourceButton(
        label: tr("来源识别依据"), evidence: .homebrew(confirmation.package, nil)
      )
      .dsFont(.xs)
      HStack(spacing: DS.Space.s2) {
        Spacer(minLength: 0)
        Button(tr("取消"), action: cancel)
          .buttonStyle(.bordered).keyboardShortcut(.cancelAction)
        Button(
          role: confirmation.action == .uninstall ? .destructive : nil, action: confirm
        ) {
          Text(confirmation.action == .upgrade ? tr("更新软件包") : tr("卸载"))
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("homebrew-confirm-action")
        .tint(confirmation.action == .upgrade ? DS.Palette.primary : DS.Palette.error)
        .disabled(!canConfirm)
      }
      .controlSize(.large)
    }
    .padding(DS.Space.s6).frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
    .appLanguageEnvironment()
    .onAppear {
      if requiresPreview || showsPreview { prepare() }
    }
    .onDisappear { controller.cancelPreview() }
    .onChange(of: showsPreview) { _, expanded in
      if expanded { prepare() } else { controller.cancelPreview() }
    }
    .onChange(of: controller.canPreparePreview) { _, available in
      if available && (requiresPreview || showsPreview) {
        prepare()
      } else {
        controller.cancelPreview()
      }
    }
    .onChange(of: controller.homebrewOperations.isRunning) { _, running in
      if running, !controller.isPreparingPreview { controller.cancelPreview() }
    }
  }

  private var previewContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DS.Space.s4) {
        if let preview {
          HomebrewImpactView(preview: preview, showsPackageDetails: requiresPreview)
        } else if controller.isPreparingPreview {
          HStack(spacing: DS.Space.s2) {
            ProgressView().controlSize(.small)
            Text(tr("正在读取操作影响…")).dsFont(.sm)
          }
        } else {
          Text(verbatim: controller.previewError ?? tr("请重新读取操作预览"))
            .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
          Button(tr("重试")) { prepare() }.buttonStyle(.bordered)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, DS.Space.s1)
    }
    .frame(height: 280)
  }

  private func prepare() {
    controller.preparePreview(confirmation.action, package: confirmation.package)
  }
}

struct HomebrewImpactView: View {
  let preview: HomebrewImpactPreview
  let language: AppLanguage
  let showsPackageDetails: Bool

  init(
    preview: HomebrewImpactPreview, language: AppLanguage = L10n.language,
    showsPackageDetails: Bool = true
  ) {
    self.preview = preview
    self.language = language
    self.showsPackageDetails = showsPackageDetails
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      Text(verbatim: text("操作影响")).dsFont(.sm, weight: .semibold)
      if showsPackageDetails {
        Text(verbatim: preview.package.name).dsFont(.sm)
          .environment(\.layoutDirection, .leftToRight)
        if preview.action == .upgrade {
          Text(
            verbatim: preview.package.version + " → " + (preview.package.latestVersion ?? "—")
          )
          .dsFont(.sm).monospacedDigit().environment(\.layoutDirection, .leftToRight)
        }
      }
      if preview.action == .upgrade {
        Text(verbatim: Self.displayed(preview.output))
          .dsFont(.xs).monospaced()
          .environment(\.layoutDirection, .leftToRight)
      } else {
        if preview.dependents.isEmpty {
          Text(verbatim: text("未发现依赖此项目的已安装软件包。")).dsFont(.sm)
        } else {
          Text(verbatim: text("以下已安装软件包依赖此项目，暂不能卸载。"))
            .dsFont(.sm).foregroundStyle(DS.Palette.warning)
          Text(verbatim: preview.dependents.joined(separator: "\n"))
            .dsFont(.xs).monospaced()
            .environment(\.layoutDirection, .leftToRight)
        }
        Text(verbatim: text("不自动移除依赖，不执行额外的用户数据清理。")).dsFont(.xs)
      }
      Text(verbatim: text("预览基于当前清单；实际影响由执行时的 Homebrew 状态决定。"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      DisclosureGroup(text("执行命令")) {
        Text(
          verbatim:
            "brew \(preview.action.rawValue) \(preview.package.kind == .formula ? "--formula" : "--cask") \(preview.package.name)"
        )
        .dsFont(.xs).monospaced()
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.layoutDirection, .leftToRight)
      }
      .dsFont(.xs)
    }
    .textSelection(.enabled)
    .fixedSize(horizontal: false, vertical: true)
    .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
    .environment(\.locale, L10n.locale(for: language))
  }

  /// 升级计划最多 256KB；整段放进单个 Text 会拖慢布局，展示层只取前若干行与有限字符。
  static func displayed(_ output: String, maxLines: Int = 200, maxCharacters: Int = 20_000)
    -> String
  {
    let clipped = String(output.prefix(maxCharacters))
    let lines = clipped.split(
      separator: "\n", maxSplits: maxLines, omittingEmptySubsequences: false)
    guard lines.count > maxLines else { return clipped }
    return lines.prefix(maxLines).joined(separator: "\n")
  }

  private func text(_ source: String) -> String { L10n.translate(source, language: language) }
}
