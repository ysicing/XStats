// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import CoreGraphics
import Localization
import ScreenCaptureKit
import AVFoundation

public enum CaptureError: Error, LocalizedError, Equatable {
  case invalidRequest, invalidRegion, invalidTransition, invalidTrim, invalidExportDestination
  case screenPermission, microphonePermission, microphoneFailed, unavailableTarget, captureFailed,
    writerFailed, exportFailed
  /// 设备断开和会话中断属于采集故障；仅权限错误提示用户恢复麦克风权限。
  static func microphoneFailure(_ error: NSError?) -> CaptureError {
    if error?.domain == AVFoundationErrorDomain,
      error?.code == AVError.Code.applicationIsNotAuthorizedToUseDevice.rawValue
    {
      return .microphonePermission
    }
    return .microphoneFailed
  }
  /// 保留业务错误，并区分系统捕获错误和媒体写入错误，避免给出错误的恢复建议。
  public static func recordingFailure(_ error: any Error) -> CaptureError {
    if let failure = error as? CaptureError { return failure }
    let failure = error as NSError
    guard failure.domain == SCStreamErrorDomain else { return .writerFailed }
    switch failure.code {
    case SCStreamError.Code.userDeclined.rawValue: return .screenPermission
    case SCStreamError.Code.noCaptureSource.rawValue,
      SCStreamError.Code.noWindowList.rawValue,
      SCStreamError.Code.noDisplayList.rawValue:
      return .unavailableTarget
    default: return .captureFailed
    }
  }
  private static var applicationName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "XStats Capture"
  }
  public var errorDescription: String? {
    switch self {
    case .invalidRequest: tr("无法识别此截图请求，请更新 XStats Capture。")
    case .invalidRegion: tr("请选择有效的屏幕区域。")
    case .invalidTransition: tr("当前操作尚未结束。")
    case .invalidTrim: tr("请选择有效的裁剪时间范围。")
    case .invalidExportDestination: tr("请选择录制临时目录之外的保存位置。")
    case .screenPermission: tr("请在系统设置中允许 \(Self.applicationName) 录制屏幕，然后重试。")
    case .microphonePermission: tr("请在系统设置中允许 \(Self.applicationName) 使用麦克风，然后重试。")
    case .microphoneFailed: tr("麦克风录制中断，请检查设备连接后重试。")
    case .unavailableTarget: tr("捕获目标已不可用，录制已结束。")
    case .captureFailed: tr("屏幕捕获未完成，请重试。")
    case .writerFailed: tr("录制写入失败，请检查可用磁盘空间。")
    case .exportFailed: tr("导出未完成，原始录制仍保留，可重试。")
    }
  }
}

public struct CaptureRequest: Sendable, Equatable {
  public enum Action: String, Sendable, CaseIterable { case open, screenshot, record }
  public static let bundleIdentifier = "work.12306.xstats.capture"
  public let action: Action
  public init(action: Action) { self.action = action }
  public init(url: URL) throws {
    guard url.absoluteString.utf8.count <= 2048, url.scheme == "xstats-capture", url.host == "v1",
      url.user == nil, url.password == nil,
      url.port == nil, url.query == nil, url.fragment == nil,
      let action = Action(rawValue: String(url.path.dropFirst())),
      URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/"
        + action.rawValue
    else { throw CaptureError.invalidRequest }
    self.action = action
  }
  public var url: URL { URL(string: "xstats-capture://v1/\(action.rawValue)")! }
}

public enum CaptureMode: String, Sendable, CaseIterable, Identifiable {
  case region, window, display
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .region: tr("区域")
    case .window: tr("窗口")
    case .display: tr("整个屏幕")
    }
  }
}

public struct RecordingOptions: Sendable {
  public var systemAudio = true
  public var microphone = false
  public init() {}
}

public struct CaptureSessionState: Sendable {
  public enum Phase: Sendable {
    case idle, selecting, countdown, starting, recording, pausing, paused, resuming, finishing,
      preview, exporting
  }
  public private(set) var phase: Phase = .idle
  public init() {}
  public mutating func transition(to next: Phase) throws {
    let allowed: Bool =
      switch (phase, next) {
      case (.idle, .selecting), (.idle, .finishing), (.selecting, .countdown),
        (.selecting, .preview),
        (.countdown, .starting), (.countdown, .recording), (.starting, .recording),
        (.recording, .pausing), (.recording, .paused), (.pausing, .paused),
        (.paused, .resuming), (.resuming, .recording), (.paused, .recording),
        (.recording, .finishing), (.paused, .finishing), (.starting, .finishing),
        (.pausing, .finishing), (.resuming, .finishing),
        (.finishing, .preview), (.preview, .exporting), (.exporting, .preview):
        true
      case (_, .idle): phase != .idle
      default: false
      }
    guard allowed else { throw CaptureError.invalidTransition }
    phase = next
  }
  public var isBusy: Bool { phase != .idle && phase != .preview }
  public var shouldInterruptCapture: Bool {
    switch phase {
    case .selecting, .countdown, .starting, .recording, .pausing, .paused, .resuming: true
    case .idle, .finishing, .preview, .exporting: false
    }
  }
}

public enum CaptureLifetime {
  public static func shouldExit(resident: Bool, windows: Int, busy: Bool) -> Bool {
    !resident && windows == 0 && !busy
  }
}

public struct RecordingTrim: Sendable {
  public let start: Double
  public let end: Double
  public var duration: Double { end - start }
  public init(start: Double, end: Double, duration: Double) throws {
    guard start.isFinite, end.isFinite, duration.isFinite, start >= 0, end > start, end <= duration
    else { throw CaptureError.invalidTrim }
    self.start = start
    self.end = end
  }
}
