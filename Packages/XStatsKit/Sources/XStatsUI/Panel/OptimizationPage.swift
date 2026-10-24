// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import HelperShared
import Localization
import SwiftUI

struct OptimizationPage: View {
  var body: some View {
    OptimizationActionCard(
      command: .flushDNS, icon: "network", title: tr("刷新 DNS 缓存"),
      detail: tr("遇到域名解析异常时手动刷新，不修改 DNS 服务器或代理设置。")
    )
    .fixedSize(horizontal: false, vertical: true)
    OptimizationActionCard(
      command: .purgeMemory, icon: "memorychip", title: tr("释放内存"),
      detail: tr("手动释放可回收缓存；再次打开应用时可能需要重新加载，不建议频繁执行。")
    )
    .fixedSize(horizontal: false, vertical: true)
    HomebrewDependencyPreview()
      .fixedSize(horizontal: false, vertical: true)
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
        .disabled(maintenance.running != nil || !model.settings.cleanerEnabled)
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
