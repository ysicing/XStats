// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Localization
import Metrics
import Observation
import SMC

/// 风扇控制的两种特权操作；实现仍由已认证的 HelperClient 提供。
@MainActor
protocol FanControlClient {
  func setFanTarget(fan: Int, rpm: Double) async -> String?
  func resetAllFans() async -> String?
}

extension HelperClient: FanControlClient {}

@MainActor
@Observable
public final class FanController {
  public enum Mode: String, CaseIterable, Identifiable, Sendable {
    case automatic, cooling, maximum, custom

    public var id: String { rawValue }

    var title: String {
      switch self {
      case .automatic: tr("自动")
      case .cooling: tr("降温")
      case .maximum: tr("强冷")
      case .custom: tr("自定义")
      }
    }

    /// “降温”档位于最低与最高转速之间的 60%
    static let coolingLevel = 0.6
  }

  public private(set) var mode: Mode = .automatic
  /// 自定义档位：0 为最低转速，1 为最高转速
  public var customLevel: Double {
    get { selectedCustomLevel }
    set {
      guard !isApplying, newValue.isFinite else { return }
      selectedCustomLevel = min(1, max(0, newValue))
    }
  }
  private var selectedCustomLevel: Double = 0.5
  public private(set) var isApplying = false
  public private(set) var notice: String?
  public private(set) var noticeIsError = false

  @ObservationIgnored private let helper: any FanControlClient
  @ObservationIgnored private let store: MetricsStore
  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let readFans: (@Sendable () async -> [FanState]?)?
  @ObservationIgnored private var feedbackTask: Task<Void, Never>?
  @ObservationIgnored private var feedbackGeneration = 0
  @ObservationIgnored private var feedbackVisible = false
  @ObservationIgnored private var paused = false
  @ObservationIgnored private var pauseGeneration = 0
  @ObservationIgnored private var pauseResetSucceeded = false
  @ObservationIgnored private var pauseTask: Task<Bool, Never>?
  @ObservationIgnored private var applicationWaiters: [CheckedContinuation<Void, Never>] = []
  /// 最近一次 apply 的写入失败后，兜底复位也失败。
  @ObservationIgnored private var fallbackResetFailed = false

  init(
    helper: any FanControlClient, store: MetricsStore, settings: AppSettings,
    readFans: (@Sendable () async -> [FanState]?)? = nil
  ) {
    self.helper = helper
    self.store = store
    self.settings = settings
    self.readFans = readFans
  }

  deinit { feedbackTask?.cancel() }

  func setFeedbackVisible(_ visible: Bool) {
    feedbackVisible = visible
    if !visible { cancelFeedback() }
  }

  func setPaused(_ value: Bool) {
    if paused != value { pauseGeneration &+= 1 }
    paused = value
    guard value else {
      pauseResetSucceeded = false
      return
    }
    cancelFeedback()
    guard pauseTask == nil, !pauseResetSucceeded else { return }
    // XPC 写入不能靠取消撤销。保留独立任务，等在途写与失败收尾结束后再复位；
    // 调用者被取消或立即恢复时，也必须收取真实硬件结果。
    pauseTask = Task {
      await waitForApplication()
      defer { pauseTask = nil }
      guard mode != .automatic else {
        pauseResetSucceeded = true
        return true
      }
      isApplying = true
      defer { finishApplication() }
      if let error = await helper.resetAllFans() {
        pauseResetSucceeded = false
        show(error, isError: true)
        return false
      }
      pauseResetSucceeded = true
      clearNotice()
      return true
    }
  }

  /// 仅返回 true 时才可停止安全采样；失败仍允许过热复位，恢复使旧请求失效。
  func prepareForPause() async -> Bool {
    guard !Task.isCancelled else { return false }
    setPaused(true)
    let generation = pauseGeneration
    let succeeded: Bool
    if let pauseTask {
      succeeded = await pauseTask.value
    } else {
      succeeded = pauseResetSucceeded
    }
    return succeeded && paused && generation == pauseGeneration && !Task.isCancelled
  }

  func select(_ newMode: Mode) async {
    guard !isApplying, !paused || newMode == .automatic,
      newMode != mode || newMode == .custom
    else { return }
    let previous = mode
    mode = newMode
    if let error = await apply() {
      // 兜底复位失败时硬件可能仍被手动接管，回滚成“自动”会让界面掩盖这一点；
      // 原本已经手动控制时保留旧档位：新转速未必写入，尤其不能丢失自定义低速的过热保护。
      if !fallbackResetFailed || previous != .automatic { mode = previous }
      show(error, isError: true)
    } else {
      clearNotice()
    }
  }

  func commitCustomLevel() async {
    guard !paused, !isApplying, mode == .custom else { return }
    if let error = await apply() { show(error, isError: true) }
  }

  /// 连接恢复或唤醒后重新下发
  func reapply() async {
    if let pauseTask { _ = await pauseTask.value }
    guard !paused, !isApplying, mode != .automatic else { return }
    if let error = await apply() { show(error, isError: true) }
  }

  /// 每次收到新指标时检查温度，自定义档位过低且 CPU 过热时交还系统控制
  func evaluateSafety(temperature: Double? = nil) {
    guard settings.isModuleEnabled(.thermal), !isApplying, mode == .custom, customLevel < 1,
      let hottest = temperature ?? store.sensors?.temperature(.cpu)?.maximum,
      hottest >= Double(settings.fanSafetyTemperature)
    else { return }
    Task {
      await select(.automatic)
      // 复位失败保留手动状态和错误，关闭功能流程才能继续保护并恢复入口。
      guard mode == .automatic, !noticeIsError else { return }
      show(
        tr("CPU 温度达到 \(Format.temperature(hottest, fahrenheit: settings.useFahrenheit))，已恢复系统自动控制"),
        isError: false)
    }
  }

  func targetRPM(for fan: FanState) -> Double {
    switch mode {
    case .automatic: fan.target
    case .cooling: fan.minimum + (fan.maximum - fan.minimum) * Mode.coolingLevel
    case .maximum: fan.maximum
    case .custom: fan.minimum + (fan.maximum - fan.minimum) * customLevel
    }
  }

  private func apply() async -> String? {
    isApplying = true
    pauseResetSucceeded = false
    fallbackResetFailed = false
    cancelFeedback()
    defer { finishApplication() }

    if mode == .automatic {
      let error = await helper.resetAllFans()
      if error == nil { watchFeedback() }
      return error
    }
    let fans = store.sensors?.fans ?? []
    guard !fans.isEmpty else { return tr("未检测到可调节的风扇") }
    let targets = fans.map { (id: $0.id, rpm: targetRPM(for: $0)) }
    for target in targets {
      if let error = await helper.setFanTarget(fan: target.id, rpm: target.rpm) {
        guard let resetError = await helper.resetAllFans() else { return error }
        // 兜底复位也失败时已接管的风扇可能仍是手动，优先报告复位失败，并让 select 保留手动状态。
        Log.fans.error("Fan fallback reset failed: \(resetError, privacy: .private)")
        fallbackResetFailed = true
        return resetError
      }
    }
    watchFeedback()
    return nil
  }

  private func waitForApplication() async {
    while isApplying {
      await withCheckedContinuation { applicationWaiters.append($0) }
    }
  }

  private func finishApplication() {
    isApplying = false
    let waiters = applicationWaiters
    applicationWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  private func cancelFeedback() {
    feedbackGeneration &+= 1
    feedbackTask?.cancel()
    feedbackTask = nil
  }

  /// 实际转速在切档后才逐渐变化；仅有可见读取方时短暂加快只读反馈。
  private func watchFeedback() {
    guard feedbackAllowed, let readFans else { return }
    let generation = feedbackGeneration
    Log.fans.debug("Fan feedback started")
    feedbackTask = Task { [weak self] in
      defer {
        if self?.feedbackGeneration == generation { self?.feedbackTask = nil }
        Log.fans.debug("Fan feedback stopped")
      }
      let deadline = ContinuousClock.now + .seconds(10)
      for _ in 0..<20 {
        guard !Task.isCancelled, self?.feedbackAllowed == true, ContinuousClock.now < deadline
        else { return }
        guard let fans = await readFans(), !Task.isCancelled, ContinuousClock.now < deadline else {
          return
        }
        guard self?.acceptFeedback(fans) == false else { return }
        // 容差合并唤醒；常规采样的间隔和其他指标不受影响。
        do { try await Task.sleep(for: .milliseconds(500), tolerance: .milliseconds(100)) } catch {
          return
        }
      }
    }
  }

  /// 返回 true 表示结束跟踪；不能把指令目标写成当前转速。
  private func acceptFeedback(_ fans: [FanState]) -> Bool {
    guard feedbackAllowed else { return true }
    store.updateFans(fans)
    guard !fans.isEmpty else { return true }
    return fans.allSatisfy { fan in
      let target = targetRPM(for: fan)
      // 模式键读不到时 isManual 只是占位值，不能当作已交还系统或已接管，继续等待下一次读取。
      return fan.isModeKnown && fan.isManual == (mode != .automatic) && !fan.isStarting
        && target.isFinite && abs(fan.current - target) <= max(100, abs(target) * 0.05)
    }
  }

  private var feedbackAllowed: Bool {
    feedbackVisible && !paused && settings.isModuleEnabled(.thermal)
  }

  private func show(_ message: String, isError: Bool) {
    if isError {
      Log.fans.error("\(message, privacy: .public)")
    } else {
      Log.fans.info("\(message, privacy: .public)")
    }
    notice = message
    noticeIsError = isError
  }

  private func clearNotice() {
    notice = nil
    noticeIsError = false
  }
}
