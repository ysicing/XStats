// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureUI
import Combine
import Localization
import os

/// 发现独立版不会改变用户选择；只有明确切换且启动成功才停用内置入口。
@MainActor final class XStatsCapture: ObservableObject {
  static let shared = XStatsCapture()
  static var workspace: CaptureWorkspace { shared.embedded }
  static let standaloneBundleID = "work.12306.xstats.capture"
  private static let logger = Logger(
    subsystem: "work.12306.xstats.app", category: "CaptureIntegration")

  enum Issue: Equatable {
    case workspaceOpen, missingApplication, launchFailed

    var message: String {
      switch self {
      case .workspaceOpen: tr("请先完成并关闭内置截图或录屏窗口，再切换。")
      case .missingApplication: tr("未找到独立版，可改用内置版。")
      case .launchFailed: tr("无法打开 XStats Capture，请检查所选应用。")
      }
    }
  }

  let embedded: CaptureWorkspace
  @Published private(set) var prefersStandalone: Bool
  @Published private(set) var standaloneApplicationURL: URL?
  @Published private(set) var isOpening = false
  @Published private(set) var issue: Issue?
  private let defaults: UserDefaults
  private let findApplications: () -> [URL]
  private let openApplication: (URL) async throws -> Void

  init(
    defaults: UserDefaults = .standard,
    findApplications: @escaping () -> [URL] = {
      NSWorkspace.shared.urlsForApplications(withBundleIdentifier: standaloneBundleID)
    },
    openApplication: @escaping (URL) async throws -> Void = { url in
      _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
  ) {
    self.defaults = defaults
    self.findApplications = findApplications
    self.openApplication = openApplication
    embedded = CaptureWorkspace(host: .embedded, defaults: defaults)
    prefersStandalone = defaults.bool(forKey: "capture.prefersStandalone")
    if prefersStandalone { embedded.setEnabled(false) }
  }

  /// 仅在设置页出现、应用重新激活及显式操作时查询，不扫描磁盘或轮询。
  func refreshInstallation() {
    let url = findApplications().first { Self.validatedStandaloneApplication(at: $0) != nil }
    if standaloneApplicationURL != url { standaloneApplicationURL = url }
  }

  static func validatedStandaloneApplication(at url: URL) -> URL? {
    guard url.isFileURL,
      let bundle = Bundle(url: url), bundle.bundleIdentifier == standaloneBundleID,
      bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
      let executable = bundle.executableURL,
      FileManager.default.isExecutableFile(atPath: executable.path)
    else { return nil }
    return url
  }

  func useEmbedded() {
    guard !isOpening else { return }
    prefersStandalone = false
    defaults.set(false, forKey: "capture.prefersStandalone")
    issue = nil
    embedded.setEnabled(true)
  }

  func openStandalone() async {
    guard !isOpening else { return }
    issue = nil
    refreshInstallation()
    guard let url = standaloneApplicationURL else {
      issue = .missingApplication
      return
    }
    // 不替用户关闭窗口或丢弃内容，也避免两个宿主同时承接新的捕获任务。
    guard !embedded.hasActiveWorkspace else {
      issue = .workspaceOpen
      return
    }
    isOpening = true
    let wasEnabled = embedded.enabled
    embedded.setEnabled(false)
    defer { isOpening = false }
    do {
      try await openApplication(url)
      prefersStandalone = true
      defaults.set(true, forKey: "capture.prefersStandalone")
      Self.logger.info("Switched to standalone Capture")
    } catch {
      embedded.setEnabled(wasEnabled)
      issue = .launchFailed
      let message = String(error.localizedDescription.prefix(240))
      Self.logger.error("Standalone Capture launch failed: \(message, privacy: .private)")
    }
  }
}
