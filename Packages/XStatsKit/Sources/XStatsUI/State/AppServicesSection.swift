// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Localization

/// 应用服务的展示分类；沿用原有功能开关与 launchd 权限边界。
public enum AppServicesSection: String, CaseIterable, Sendable {
  case apps, homebrew, startup, services

  var title: String {
    switch self {
    case .apps: tr("应用")
    case .homebrew: "Homebrew"
    case .startup: tr("启动项")
    case .services: tr("服务")
    }
  }

  var managesApplications: Bool { self == .apps || self == .homebrew }

  var launchScopes: [LaunchItem.Scope] {
    switch self {
    case .startup: [.user, .allUsers]
    case .services: [.system]
    case .apps, .homebrew: []
    }
  }

  var searchPrompt: String {
    switch self {
    case .apps: tr("搜索应用")
    case .homebrew: tr("搜索软件包")
    case .startup: tr("搜索启动项")
    case .services: tr("搜索服务")
    }
  }
}
