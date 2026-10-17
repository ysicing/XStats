// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Localization
import OSLog
import Sparkle
import Updates

/// 独立宿主使用 Sparkle 原生更新界面与调度；不增加后台定时器或自动下载。
@MainActor final class CaptureUpdater: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
  private let logger = Logger(subsystem: "work.12306.xstats.capture", category: "Updates")
  private var controller: SPUStandardUpdaterController!

  override init() {
    super.init()
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    controller.updater.automaticallyDownloadsUpdates = false
    controller.updater.sendsSystemProfile = false
    do {
      try controller.updater.start()
      logger.notice("独立 Capture 更新器已启动")
    } catch {
      logger.error("更新器启动失败：\(String(error.localizedDescription.prefix(512)), privacy: .private)")
    }
  }

  func addMenuItems(to menu: NSMenu) {
    let about = menu.addItem(withTitle: tr("关于"), action: #selector(aboutApp), keyEquivalent: "")
    about.target = self
    let check = menu.addItem(
      withTitle: tr("检查更新…"), action: #selector(checkForUpdates), keyEquivalent: "")
    check.target = self
    let automatic = menu.addItem(
      withTitle: tr("自动检查更新"), action: #selector(toggleAutomaticChecks), keyEquivalent: "")
    automatic.target = self
    automatic.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
    menu.addItem(.separator())
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    menuItem.action != #selector(checkForUpdates) || controller.updater.canCheckForUpdates
  }

  @objc private func aboutApp() { NSApp.orderFrontStandardAboutPanel(nil) }
  @objc private func checkForUpdates() { controller.checkForUpdates(nil) }
  @objc private func toggleAutomaticChecks(_ sender: NSMenuItem) {
    controller.updater.automaticallyChecksForUpdates.toggle()
    sender.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    UpdateFeed.sparkleURLs(
      prefersChina: UpdateFeed.prefersChinaEndpoint(), applicationID: "xstats-capture"
    ).first?.absoluteString
  }

  @objc(feedParametersForUpdater:sendingSystemProfile:)
  func feedParameters(for updater: SPUUpdater, sendingSystemProfile: Bool) -> [[String: String]] {
    guard let identifier = try? InstallationIdentity().hashedID() else { return [] }
    return [
      ["key": "installation_id", "value": identifier],
      [
        "key": "current_version",
        "value": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
          ?? "0",
      ],
    ]
  }

  @objc(updater:didAbortWithError:)
  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    let failure = error as NSError
    logger.info("更新检查结束 domain=\(failure.domain, privacy: .public) code=\(failure.code)")
  }
}
