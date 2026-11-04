// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Localization
import SwiftUI

enum InstallationSourceEvidence: Equatable {
  case homebrew(HomebrewPackage, URL?)
  case cachedHomebrew
  case appStore(URL)
  case unknown

  var title: String {
    title(language: L10n.language)
  }

  func title(language: AppLanguage) -> String {
    switch self {
    case .homebrew: "Homebrew"
    case .cachedHomebrew: L10n.translate("Homebrew（缓存）", language: language)
    case .appStore: "App Store"
    case .unknown: L10n.translate("未知", language: language)
    }
  }
}

struct InstallationSourceView: View {
  let evidence: InstallationSourceEvidence
  let language: AppLanguage

  init(evidence: InstallationSourceEvidence, language: AppLanguage = L10n.language) {
    self.evidence = evidence
    self.language = language
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      Text(verbatim: text("来源识别依据")).dsFont(.sm, weight: .semibold)
      Text(verbatim: evidence.title(language: language)).dsFont(.sm)
      switch evidence {
      case .homebrew(let package, let appURL):
        Text(verbatim: text("来自本次读取的 Homebrew 安装清单。"))
        Text(verbatim: "\(package.kind == .formula ? "Formula" : "Cask") · \(package.name)")
          .environment(\.layoutDirection, .leftToRight)
        if let appURL {
          Text(verbatim: text("应用路径与 Cask 的安装产物匹配。"))
          path(appURL)
        } else {
          ForEach(package.installationURLs, id: \.path) { path($0) }
        }
      case .cachedHomebrew:
        Text(verbatim: text("来自上次保存的 Homebrew 来源记录，尚未通过本次清单核实。"))
      case .appStore(let receipt):
        Text(verbatim: text("应用包中存在 App Store 收据；未验证收据签名。"))
        path(receipt)
      case .unknown:
        Text(verbatim: text("未找到可确认来源的记录，不能仅凭名称或目录判断。"))
      }
    }
    .dsFont(.xs)
    .foregroundStyle(DS.Palette.textSecondary)
    .fixedSize(horizontal: false, vertical: true)
    .textSelection(.enabled)
    .padding(DS.Space.s4)
    .frame(width: 360, alignment: .leading)
    .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
    .environment(\.locale, L10n.locale(for: language))
  }

  private func text(_ source: String) -> String { L10n.translate(source, language: language) }

  private func path(_ url: URL) -> some View {
    Text(verbatim: url.path)
      .monospaced()
      .environment(\.layoutDirection, .leftToRight)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct InstallationSourceButton: View {
  let label: String
  let evidence: InstallationSourceEvidence
  @State private var showsEvidence = false

  var body: some View {
    Button {
      showsEvidence.toggle()
    } label: {
      HStack(spacing: DS.Space.s1) {
        Text(verbatim: label).lineLimit(1)
        Image(systemName: "info.circle").foregroundStyle(.secondary)
      }
    }
    .buttonStyle(.plain)
    .help(tr("查看来源依据"))
    .accessibilityLabel(tr("查看来源依据"))
    .accessibilityValue(evidence.title)
    .popover(isPresented: $showsEvidence) { InstallationSourceView(evidence: evidence) }
  }
}
