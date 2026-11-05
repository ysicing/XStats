// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import FinderDocuments
import FinderSync
import Localization
import Observation
import OSLog

@MainActor
@Observable
final class FinderDocumentsController {
  private let settings: AppSettings
  @ObservationIgnored private var store: FinderDocumentStore?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var creation: Task<URL, Error>?
  private let logger = Logger(subsystem: "work.12306.xstats.app", category: "FinderDocuments")
  private(set) var extensionEnabled = false
  private(set) var error: String?

  init(settings: AppSettings) { self.settings = settings }

  func start() {
    guard !started else { return }
    started = true
    store = FinderDocumentStore.shared()
    reconcile()
    observeSettings()
  }

  func refreshStatus() {
    extensionEnabled = FIFinderSyncController.isExtensionEnabled
  }

  func setEnabled(_ enabled: Bool) {
    settings.finderDocumentsEnabled = enabled
    reconcile()
  }

  func openExtensionSettings() { FIFinderSyncController.showExtensionManagementInterface() }

  func create(_ identifier: UUID) async {
    guard let store, creation == nil else { return }
    do {
      let request = try store.consume(identifier)
      let configuration = FinderDocumentConfiguration(
        enabled: settings.finderDocumentsEnabled,
        language: settings.language.resolved)
      let task = Task.detached(priority: .userInitiated) {
        try FinderDocumentCreator.create(request, configuration: configuration)
      }
      creation = task
      defer { creation = nil }
      let result = try await task.value
      logger.notice("Finder document created: \(request.kind.rawValue, privacy: .public)")
      NSWorkspace.shared.activateFileViewerSelecting([result])
    } catch is CancellationError {
      logger.info("Finder document creation cancelled")
    } catch {
      report(error)
      let alert = NSAlert()
      alert.messageText = tr("无法新建文档")
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: tr("好"))
      NSApp.activate()
      alert.runModal()
    }
  }

  func waitForCreation() async { _ = await creation?.result }

  private func reconcile() {
    refreshStatus()
    if !settings.finderDocumentsEnabled { creation?.cancel() }
    guard started else { return }
    do {
      guard let store else { throw FinderDocumentError.unavailable }
      let configuration = FinderDocumentConfiguration(
        enabled: settings.finderDocumentsEnabled,
        language: settings.language.resolved)
      if (try? store.configuration()) != configuration {
        try store.save(configuration)
        DistributedNotificationCenter.default().postNotificationName(
          NSNotification.Name(FinderDocumentStore.changedNotification), object: nil,
          userInfo: nil, deliverImmediately: true)
        logger.notice(
          "Finder configuration updated; enabled=\(configuration.enabled, privacy: .public)"
        )
      }
      error = nil
    } catch {
      report(error)
    }
  }

  private func observeSettings() {
    withObservationTracking {
      _ = settings.finderDocumentsEnabled
      _ = settings.language
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.reconcile()
        self?.observeSettings()
      }
    }
  }

  private func report(_ failure: Error) {
    error = failure.localizedDescription
    logger.error(
      "Finder operation failed: \(String(failure.localizedDescription.prefix(256)), privacy: .private)"
    )
  }
}
