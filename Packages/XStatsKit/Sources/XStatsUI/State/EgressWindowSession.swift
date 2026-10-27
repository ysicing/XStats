// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Metrics
import Observation

/// 窗口统一启动三项检测；分类只筛选结果，关闭取消进行中的检测但保留已完成结果。
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
  private var attempt: (date: Date, signature: String)?

  var isChecking: Bool {
    egress.isChecking || webRTC.phase == .running || dns.phase == .running
  }

  /// 时间属于当前分类的有效结果；失败或取消不能沿用旧的成功时间。
  var lastCheckedAt: Date? {
    switch tab {
    case .webRTC: webRTC.completedAt
    case .dns: dns.completedAt
    default: egress.isChecking ? nil : egress.report?.date
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

  func cancelChecks() {
    egress.cancelCheck()
    cancelLeakTests()
  }

  func select(_ tab: Tab) {
    self.tab = tab
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
    // 保留已完成的结果和批次时间；重开时由 checkIfNeeded 按时效与网络环境统一判断是否重测。
    tab = .overview
  }

  func check() {
    guard visible, !suspended, !hidden, !isChecking else { return }
    startChecks(signature: egress.environment?.signature ?? "")
  }

  private func startChecks(signature: String) {
    // 网络变更时取消上一轮的全部任务，避免混用不同网络环境的结果。
    cancelChecks()
    attempt = (now(), signature)
    egress.check()
    webRTC.start(.webRTC)
    dns.start(.dns)
  }

  private func observeEnvironment() {
    // 三项共用唯一的环境观察任务，不因分类切换重复注册或重测。
    egress.windowDidOpen(automaticallyChecks: false) { [weak self] environment, first in
      self?.checkIfNeeded(environment: environment, first: first)
    }
  }

  private func checkIfNeeded(environment: ProxyEnvironment, first: Bool) {
    guard visible, !suspended, !hidden else { return }
    let changed = attempt.map { $0.signature != environment.signature } ?? false
    let stale =
      attempt.map { now().timeIntervalSince($0.date) > EgressController.staleAfter } ?? true
    // 出口报告跨批次保存，被取消的批次仍可能留着上一次的报告；必须属于本批次才算完成。
    let reportIsCurrent =
      attempt.flatMap { started in egress.report.map { $0.date >= started.date } } ?? false
    let unfinished = !reportIsCurrent || webRTC.phase != .complete || dns.phase != .complete
    // 失败或手动取消只在再次打开／恢复时重试，不在每次环境轮询时重试。
    if changed || (first && !isChecking && (stale || unfinished)) {
      startChecks(signature: environment.signature)
    }
  }
}
