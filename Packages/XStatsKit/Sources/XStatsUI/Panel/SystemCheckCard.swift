// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Localization
import SwiftUI

struct SystemCheckCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let check = model.systemCheck
    Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
      HStack {
        Label(tr("系统检查"), systemImage: "checkmark.shield")
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
          Button(tr("开始检查")) { check.start() }
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .disabled(!model.settings.cleanerEnabled || model.cleaner.isBusy)
        }
      }
      if check.findings.isEmpty {
        Text(tr("按需检查资源、配置和维护建议，仅预览，不执行修复。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
      ForEach(check.findings) { finding in
        HairlineDivider()
        DisclosureGroup {
          VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(finding.detail)
            ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, evidence in
              Text(verbatim: evidence).textSelection(.enabled)
            }
          }
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, DS.Space.s1)
        } label: {
          HStack {
            Text(finding.title).dsFont(.sm)
            Spacer()
            Text(status(finding))
              .dsFont(.xs)
              .foregroundStyle(
                finding.status == .attention || !finding.isComplete
                  ? DS.Palette.warning : DS.Palette.textSecondary)
          }
        }
      }
    }
  }

  private func status(_ finding: SystemCheckFinding) -> String {
    let title: String
    switch finding.status {
    case .normal: title = tr("正常")
    case .attention: title = tr("需关注")
    case .optional: title = tr("可选维护")
    case .notApplicable: title = tr("不适用")
    case .unchecked: title = tr("未检查")
    }
    return !finding.isComplete && finding.status != .unchecked
      ? title + " · " + tr("部分完成") : title
  }
}
