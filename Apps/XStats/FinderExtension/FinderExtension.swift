// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import FinderDocuments
import FinderSync
import Localization
import OSLog

final class FinderExtension: FIFinderSync {
  private let store = FinderDocumentStore.shared()
  private let logger = Logger(subsystem: "work.12306.xstats.app", category: "FinderExtension")

  override init() {
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(configurationChanged),
      name: NSNotification.Name(FinderDocumentStore.changedNotification), object: nil)
    configurationChanged()
  }

  deinit { DistributedNotificationCenter.default().removeObserver(self) }

  @objc private func configurationChanged() {
    let configuration = try? store?.configuration()
    FIFinderSyncController.default().directoryURLs = configuration?.directoryURLs ?? []
  }

  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    guard menuKind == .contextualMenuForContainer,
      let configuration = try? store?.configuration(),
      let directory = FIFinderSyncController.default().targetedURL(),
      configuration.permits(directory)
    else { return nil }
    let menu = NSMenu()
    let parent = NSMenuItem(
      title: L10n.translate("新建文档", language: configuration.language),
      action: nil, keyEquivalent: "")
    let documents = NSMenu()
    for (index, kind) in FinderDocumentKind.allCases.enumerated() {
      if let identifier = kind.applicationBundleIdentifier,
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) == nil
      {
        continue
      }
      let title = L10n.translate(kind.title, language: configuration.language)
      let item = NSMenuItem(
        title: "\(title) (.\(kind.rawValue))", action: #selector(createDocument(_:)),
        keyEquivalent: "")
      item.tag = index
      item.target = self
      documents.addItem(item)
    }
    parent.submenu = documents
    menu.addItem(parent)
    return menu
  }

  @objc private func createDocument(_ sender: NSMenuItem) {
    guard FinderDocumentKind.allCases.indices.contains(sender.tag), let store,
      let directory = FIFinderSyncController.default().targetedURL()
    else { return }
    do {
      let identifier = try store.enqueue(
        FinderDocumentRequest(kind: FinderDocumentKind.allCases[sender.tag], directory: directory))
      // 定向打开包含本扩展的主应用，避免其他构建抢占 URL scheme。
      let app = Bundle.main.bundleURL.deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      let options = NSWorkspace.OpenConfiguration()
      options.activates = false
      NSWorkspace.shared.open(
        [FinderDocumentStore.launchURL(identifier)], withApplicationAt: app, configuration: options
      ) { [logger] _, error in
        if let error {
          store.discard(identifier)
          logger.error(
            "Finder request delivery failed: \(String(error.localizedDescription.prefix(256)), privacy: .private)"
          )
        }
      }
    } catch {
      logger.error(
        "Finder request failed: \(String(error.localizedDescription.prefix(256)), privacy: .private)"
      )
    }
  }
}
