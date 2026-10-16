// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

public struct RecordingClock: Sendable {
  private var origin: Double?
  private var pausedAt: Double?
  private var removedTime = 0.0
  private var segmentStart: Double?
  public var isRunning: Bool { origin != nil && pausedAt == nil }
  public init() {}
  public mutating func start(at time: Double) throws {
    guard origin == nil, time.isFinite else { throw CaptureError.invalidTransition }
    origin = time
    segmentStart = time
  }
  public mutating func pause(at time: Double) throws {
    guard origin != nil, pausedAt == nil, time.isFinite else {
      throw CaptureError.invalidTransition
    }
    pausedAt = time
  }
  public mutating func resume(at time: Double) throws {
    guard let pausedAt, time.isFinite, time >= pausedAt else {
      throw CaptureError.invalidTransition
    }
    removedTime += time - pausedAt
    self.pausedAt = nil
    segmentStart = time
  }
  public func presentationTime(at time: Double) -> Double? {
    guard let origin, let segmentStart, pausedAt == nil, time.isFinite, time >= segmentStart else {
      return nil
    }
    return max(0, time - origin - removedTime)
  }
  /// 用于控制窗口的累计时长；暂停时保持最后值，不包含暂停间隔。
  public func elapsedTime(at time: Double) -> Double {
    guard let origin, time.isFinite else { return 0 }
    return max(0, (pausedAt ?? time) - origin - removedTime)
  }
}
