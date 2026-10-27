// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Localization
import SwiftUI
import WidgetData

struct MagpiePreferredAccountOption: Identifiable {
  let id: String
  let provider: String
  let name: String
  let title: String
  let kind: String
  let user: String?
  let quota: MagpieQuota

  init(account: WidgetSnapshot.QuotaAccount, quota: MagpieQuota) {
    id = account.id
    provider = account.provider
    name = account.name
    let plan = quota.plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title = plan.isEmpty ? account.name : "\(account.name) · \(plan)"
    kind = quota.kind
    user = quota.user
    self.quota = quota
  }

  func menuTitle(among candidates: [Self]) -> String {
    guard candidates.filter({ $0.title == title }).count > 1 else { return title }
    // 同名同套餐仍可能属于不同类型或登录身份；不使用序号伪造可持久化身份。
    let details = [kind, user].compactMap { $0 }.filter { !$0.isEmpty && !title.contains($0) }
    return ([title] + details).joined(separator: " · ")
  }

  static func ordered(_ options: [Self], preferredID: String?) -> [Self] {
    guard let preferredID,
      let index = options.firstIndex(where: { $0.id == preferredID }),
      options.filter({ $0.id == preferredID }).count == 1
    else { return options }
    // 只前移首选账号，其余保持 Magpie 的顺序；重复身份不能被当成唯一首选。
    var ordered = options
    let preferred = ordered.remove(at: index)
    ordered.insert(preferred, at: 0)
    return ordered
  }
}

struct MagpiePreferredAccounts: View {
  let account: MagpiePreferredAccountOption
  let options: [MagpiePreferredAccountOption]
  let settings: AppSettings

  private var provider: String {
    options.first?.provider ?? ""
  }

  var selection: Binding<String> {
    Binding(
      get: { settings.aiPreferredAccounts[provider] ?? options.first?.id ?? "" },
      set: { id in settings.aiPreferredAccounts[provider] = id.isEmpty ? nil : id })
  }

  var body: some View {
    // 重复身份不能分别保存首选，不提供会同时选中多个账号的操作。
    if options.filter({ $0.id == account.id }).count == 1 {
      Group {
        if selection.wrappedValue == account.id {
          Label(tr("默认"), systemImage: "checkmark")
            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tr("默认"))
        } else {
          Button(tr("设为默认")) { selection.wrappedValue = account.id }
            .buttonStyle(.bordered).controlSize(.small)
        }
      }
      .fixedSize()
      .help(tr("用于菜单栏与小组件"))
      .accessibilityValue(account.menuTitle(among: options))
    }
  }
}
