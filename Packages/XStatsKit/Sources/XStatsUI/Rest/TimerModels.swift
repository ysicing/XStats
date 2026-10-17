// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

public enum TimerMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case countdown, pomodoro, stopwatch
  public var id: String { rawValue }
  var title: String {
    switch self {
    case .countdown: tr("倒计时")
    case .pomodoro: tr("番茄钟")
    case .stopwatch: tr("秒表")
    }
  }
}

/// 新计时选项单独保存，旧版 rest/wellness 偏好及已完成轮数保持原标识。
public struct TimerPreferences: Codable, Equatable, Sendable {
  public var mode: TimerMode = .pomodoro
  public var countdownSeconds: Int = 15 * 60
  public var longBreakInterval: Int = 4
  /// 0 延续旧版不限制轮数的行为。
  public var targetRounds: Int = 0

  public var sleepDisplayDuringBreak: Bool = false

  public init() {}
  private enum CodingKeys: String, CodingKey {
    case mode, countdownSeconds, longBreakInterval, targetRounds, sleepDisplayDuringBreak
  }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    mode = try values.decodeIfPresent(TimerMode.self, forKey: .mode) ?? .pomodoro
    countdownSeconds = try values.decodeIfPresent(Int.self, forKey: .countdownSeconds) ?? 900
    longBreakInterval = try values.decodeIfPresent(Int.self, forKey: .longBreakInterval) ?? 4
    targetRounds = try values.decodeIfPresent(Int.self, forKey: .targetRounds) ?? 0
    sleepDisplayDuringBreak =
      try values.decodeIfPresent(Bool.self, forKey: .sleepDisplayDuringBreak) ?? false
  }

  var normalized: Self {
    var value = self
    value.countdownSeconds = min(86_399, max(1, countdownSeconds))
    value.longBreakInterval = min(12, max(1, longBreakInterval))
    value.targetRounds = min(24, max(0, targetRounds))
    return value
  }
}

/// 单调时钟截止点包含休眠；暂停后只保留剩余值，不逐帧累减。
struct CountdownSession {
  private(set) var duration: TimeInterval
  private(set) var deadline: TimeInterval?
  private(set) var isFinished = false
  private var pausedRemaining: TimeInterval
  var isRunning: Bool { deadline != nil }
  var canContinue: Bool { !isRunning && !isFinished && pausedRemaining < duration }

  init(duration: TimeInterval) {
    let bounded = duration.isFinite ? min(86_399, max(1, duration)) : 900
    self.duration = bounded
    pausedRemaining = bounded
  }

  func remaining(at now: TimeInterval) -> TimeInterval {
    deadline.map { max(0, $0 - now) } ?? pausedRemaining
  }

  mutating func start(at now: TimeInterval) {
    guard !isRunning else { return }
    if isFinished { pausedRemaining = duration }
    isFinished = false
    deadline = now + pausedRemaining
  }

  mutating func pause(at now: TimeInterval) {
    guard isRunning else { return }
    pausedRemaining = remaining(at: now)
    deadline = nil
  }

  @discardableResult mutating func advance(to now: TimeInterval) -> Bool {
    guard let deadline, now >= deadline else { return false }
    self.deadline = nil
    pausedRemaining = 0
    isFinished = true
    return true
  }
}

struct StopwatchLap: Identifiable {
  let id: Int
  let duration: TimeInterval
  let total: TimeInterval
}

struct StopwatchSession {
  static let maximumLaps = 200
  private(set) var laps: [StopwatchLap] = []
  private var startedAt: TimeInterval?
  private var accumulated: TimeInterval = 0
  var isRunning: Bool { startedAt != nil }

  func elapsed(at now: TimeInterval) -> TimeInterval {
    accumulated + (startedAt.map { max(0, now - $0) } ?? 0)
  }

  mutating func start(at now: TimeInterval) {
    guard !isRunning else { return }
    startedAt = now
  }

  mutating func pause(at now: TimeInterval) {
    accumulated = elapsed(at: now)
    startedAt = nil
  }

  mutating func lap(at now: TimeInterval) {
    guard isRunning, laps.count < Self.maximumLaps else { return }
    let total = elapsed(at: now)
    laps.append(.init(id: laps.count + 1, duration: total - (laps.last?.total ?? 0), total: total))
  }

  mutating func reset() { self = Self() }
}

/// 倒计时向上取整、秒表向下取整，超过一小时始终保留小时位。
enum TimerFormat {
  static func clock(
    _ seconds: TimeInterval, countingDown: Bool = true, locale: Locale = L10n.locale
  ) -> String {
    let safe = seconds.isFinite ? max(0, seconds) : 0
    let value = countingDown ? ceil(safe) : floor(safe)
    let pattern: Duration.TimeFormatStyle.Pattern =
      value >= 3600
      ? .hourMinuteSecond(padHourToLength: 1)
      : .minuteSecond(padMinuteToLength: 2)
    return Duration.seconds(value).formatted(.time(pattern: pattern).locale(locale))
  }

  static func lap(_ seconds: TimeInterval, locale: Locale = L10n.locale) -> String {
    let value = seconds.isFinite ? max(0, seconds) : 0
    let pattern: Duration.TimeFormatStyle.Pattern =
      value >= 3600
      ? .hourMinuteSecond(
        padHourToLength: 1, fractionalSecondsLength: 2, roundFractionalSeconds: .down)
      : .minuteSecond(
        padMinuteToLength: 2, fractionalSecondsLength: 2, roundFractionalSeconds: .down)
    return Duration.seconds(value).formatted(.time(pattern: pattern).locale(locale))
  }
}
