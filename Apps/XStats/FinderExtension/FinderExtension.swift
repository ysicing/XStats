// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import FinderDocuments
import FinderSync
import Localization
import OSLog
import UniformTypeIdentifiers

final class FinderExtension: FIFinderSync {
  private let store = FinderDocumentStore.shared()
  private let logger = Logger(subsystem: "work.12306.xstats.app", category: "FinderExtension")
  private var registeredEnabled: Bool?

  override init() {
    super.init()
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(configurationChanged),
      name: NSNotification.Name(FinderDocumentStore.changedNotification), object: nil)
    for notification in [
      NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
      NSWorkspace.didRenameVolumeNotification,
    ] {
      NSWorkspace.shared.notificationCenter.addObserver(
        self, selector: #selector(mountedVolumesChanged), name: notification, object: nil)
    }
    configurationChanged()
  }

  deinit {
    DistributedNotificationCenter.default().removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }

  @objc private func configurationChanged() {
    reloadConfiguration(refreshVolumes: false)
  }

  @objc private func mountedVolumesChanged() {
    reloadConfiguration(refreshVolumes: true)
  }

  private func reloadConfiguration(refreshVolumes: Bool) {
    do {
      guard let store else { throw FinderDocumentError.unavailable }
      let configuration = try store.configuration()
      guard
        configuration.enabled != registeredEnabled
          || (refreshVolumes && configuration.enabled)
      else { return }
      // Finder Sync 的目录范围不跨挂载卷，网络共享和外置磁盘须单独登记。
      let volumes =
        configuration.enabled
        ? FileManager.default.mountedVolumeURLs(
          includingResourceValuesForKeys: nil, options: .skipHiddenVolumes) ?? []
        : []
      let directories = configuration.directoryURLs(mountedVolumes: volumes)
      let controller = FIFinderSyncController.default()
      if controller.directoryURLs != directories {
        controller.directoryURLs = directories
      }
      registeredEnabled = configuration.enabled
      logger.notice(
        "Finder configuration loaded; enabled=\(configuration.enabled, privacy: .public); roots=\(directories.count, privacy: .public)"
      )
    } catch {
      registeredEnabled = nil
      let controller = FIFinderSyncController.default()
      if !controller.directoryURLs.isEmpty {
        controller.directoryURLs = []
      }
      logger.error(
        "Finder configuration unavailable: \(String(error.localizedDescription.prefix(256)), privacy: .private)"
      )
    }
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
      guard configuration.enabledKinds.contains(kind) else { continue }
      guard
        kind.isAvailable(applicationIsInstalled: {
          NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        })
      else {
        continue
      }
      let title = L10n.translate(kind.title, language: configuration.language)
      let item = NSMenuItem(
        title: "\(title) (.\(kind.rawValue))", action: #selector(createDocument(_:)),
        keyEquivalent: "")
      let type = UTType(filenameExtension: kind.rawValue) ?? .data
      let icon = NSWorkspace.shared.icon(for: type).copy() as? NSImage
      icon?.size = NSSize(width: 16, height: 16)
      item.image = icon
      item.tag = index
      item.target = self
      documents.addItem(item)
    }
    guard !documents.items.isEmpty else { return nil }
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
