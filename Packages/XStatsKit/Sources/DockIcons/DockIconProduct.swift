// SPDX-License-Identifier: AGPL-3.0-or-later
public enum DockIconProduct: String, CaseIterable, Sendable {
  case xstats, network, capture

  var bundleIdentifier: String {
    switch self {
    case .xstats: "work.12306.xstats.app"
    case .network: "work.12306.xstats.networkmonitor"
    case .capture: "work.12306.xstats.capture"
    }
  }
}
