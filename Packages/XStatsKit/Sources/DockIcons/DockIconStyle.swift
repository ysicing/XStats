// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Localization

public enum DockIconStyle: String, CaseIterable, Sendable {
  case automatic, standard, mascot

  public static let preferenceKey = "dockIconStyle"

  public var title: String {
    switch self {
    case .automatic: tr("自动（跟随菜单栏）")
    case .standard: tr("标准")
    case .mascot: tr("手绘")
    }
  }

  public static func load(
    from defaults: UserDefaults, fallback: DockIconStyle = .standard
  ) -> DockIconStyle {
    defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? fallback
  }
}
