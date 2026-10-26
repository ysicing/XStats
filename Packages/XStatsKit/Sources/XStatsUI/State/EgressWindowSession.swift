// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import Observation

/// 窗口内的临时检测状态；切页停止任务，关闭清空结果，出口报告仍由原控制器保存。
@MainActor @Observable
final class EgressWindowSession {
  enum Tab: CaseIterable {
    case overview, webRTC, dns

    var title: String {
      switch self {
      case .overview: tr("出口概览")
      case .webRTC: "WebRTC"
      case .dns: "DNS"
      }
    }
  }

  private(set) var tab: Tab = .overview
  private(set) var webRTC = NetworkLeakTestController()
  private(set) var dns = NetworkLeakTestController()
  var hideIP = false
  private var visible = false
  private var suspended = false
  private let egress: EgressController

  init(egress: EgressController) { self.egress = egress }

  func select(_ tab: Tab) {
    guard tab != self.tab else { return }
    webRTC.cancel()
    dns.cancel()
    egress.windowDidClose()
    self.tab = tab
    if visible && !suspended && tab == .overview { egress.windowDidOpen() }
  }

  func open() {
    guard !visible else { return }
    visible = true
    suspended = false
    if tab == .overview { egress.windowDidOpen() }
  }

  func setSuspended(_ value: Bool) {
    guard suspended != value else { return }
    suspended = value
    if value {
      webRTC.cancel()
      dns.cancel()
      egress.windowDidClose()
    } else if visible && tab == .overview {
      egress.windowDidOpen()
    }
  }

  func close() {
    visible = false
    egress.windowDidClose()
    webRTC.cancel()
    dns.cancel()
    webRTC = NetworkLeakTestController()
    dns = NetworkLeakTestController()
    tab = .overview
    hideIP = false
  }
}
