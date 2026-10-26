// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Metrics
import Observation

/// 窗口内的临时检测状态；切页停止任务，关闭清空结果，出口报告仍由原控制器保存。
@MainActor @Observable
final class EgressWindowSession {
  enum Tab: Hashable, CaseIterable {
    case overview, ai, media, social, developer, domestic, webRTC, dns

    var isOverview: Bool { self != .webRTC && self != .dns }

    var title: String {
      switch self {
      case .overview: tr("全部")
      case .ai: "AI"
      case .media: tr("影音")
      case .social: tr("社交")
      case .developer: tr("开发")
      case .domestic: tr("国内")
      case .webRTC: "WebRTC"
      case .dns: "DNS"
      }
    }

    func includes(_ target: EgressTarget) -> Bool {
      switch self {
      case .overview: true
      case .ai: target.category == .ai
      case .media: target.category == .media
      case .social: target.category == .social
      case .developer: target.category == .developer
      case .domestic: target.category == .domestic
      case .webRTC, .dns: false
      }
    }
  }

  private(set) var tab: Tab = .overview
  private(set) var webRTC: NetworkLeakTestController
  private(set) var dns: NetworkLeakTestController
  private var visible = false
  private var suspended = false
  private var hidden = false
  private let egress: EgressController
  private let makeController: () -> NetworkLeakTestController
  private let now: () -> Date
  private var attempts: [Tab: (date: Date, signature: String)] = [:]

  var isChecking: Bool {
    switch tab {
    case .webRTC: webRTC.phase == .running
    case .dns: dns.phase == .running
    default: egress.isChecking
    }
  }

  init(
    egress: EgressController,
    makeController: @escaping () -> NetworkLeakTestController = { NetworkLeakTestController() },
    now: @escaping () -> Date = Date.init
  ) {
    self.egress = egress
    self.makeController = makeController
    self.now = now
    webRTC = makeController()
    dns = makeController()
  }

  func cancelLeakTests() {
    webRTC.cancel()
    dns.cancel()
  }

  func select(_ tab: Tab) {
    guard tab != self.tab else { return }
    if tab.isOverview && self.tab.isOverview {
      self.tab = tab
      return
    }
    cancelLeakTests()
    egress.windowDidClose()
    self.tab = tab
    if visible && !suspended && !hidden { observeEnvironment() }
  }

  func open() {
    guard !visible else { return }
    visible = true
    suspended = false
    if !hidden { observeEnvironment() }
  }

  func setSuspended(_ value: Bool) {
    guard suspended != value else { return }
    suspended = value
    if value {
      cancelLeakTests()
      egress.windowDidClose()
    } else if visible && !hidden {
      observeEnvironment()
    }
  }

  func setHidden(_ value: Bool) {
    guard hidden != value else { return }
    hidden = value
    if value {
      cancelLeakTests()
      egress.windowDidClose()
    } else if visible && !suspended {
      observeEnvironment()
    }
  }

  func close() {
    visible = false
    egress.windowDidClose()
    cancelLeakTests()
    webRTC = makeController()
    dns = makeController()
    attempts = [:]
    tab = .overview
  }

  func check() {
    guard visible, !suspended, !hidden, !isChecking else { return }
    if tab.isOverview {
      egress.check()
    } else {
      checkLeakTest()
    }
  }

  private func checkLeakTest() {
    guard visible, !suspended, !hidden, !tab.isOverview else { return }
    attempts[tab] = (now(), egress.environment?.signature ?? "")
    if tab == .webRTC { webRTC.start(.webRTC) } else { dns.start(.dns) }
  }

  private func observeEnvironment() {
    // 复用出口检测唯一的环境观察任务；仅当前页可以发起公网检测。
    egress.windowDidOpen(automaticallyChecks: tab.isOverview) { [weak self] environment, first in
      self?.checkLeakTestIfNeeded(environment: environment, first: first)
    }
  }

  private func checkLeakTestIfNeeded(environment: ProxyEnvironment, first: Bool) {
    guard visible, !suspended, !hidden, !tab.isOverview else { return }
    let controller = tab == .webRTC ? webRTC : dns
    let attempt = attempts[tab]
    let changed = attempt.map { $0.signature != environment.signature } ?? false
    let stale =
      attempt.map { now().timeIntervalSince($0.date) > EgressController.staleAfter } ?? true
    let unfinished = controller.phase != .complete && controller.phase != .running
    if changed || (first && (stale || unfinished)) { checkLeakTest() }
  }
}
