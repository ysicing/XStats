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
  @ObservationIgnored private var isCreating = false
  @ObservationIgnored private var nameAlert: NSAlert?
  @ObservationIgnored private let namePrompt:
    ((FinderDocumentRequest, FinderDocumentConfiguration) -> String?)?
  private let logger = Logger(subsystem: "work.12306.xstats.app", category: "FinderDocuments")
  private(set) var extensionEnabled = false
  private(set) var error: String?

  init(
    settings: AppSettings, store: FinderDocumentStore? = nil,
    namePrompt: ((FinderDocumentRequest, FinderDocumentConfiguration) -> String?)? = nil
  ) {
    self.settings = settings
    self.store = store
    self.namePrompt = namePrompt
  }

  func start() {
    guard !started else { return }
    started = true
    store = store ?? FinderDocumentStore.shared()
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
    guard let store, !isCreating else { return }
    isCreating = true
    defer { isCreating = false }
    do {
      let request = try store.consume(identifier)
      guard configuration.enabled else { throw FinderDocumentError.disabled }
      guard configuration.enabledKinds.contains(request.kind),
        configuration.permits(request.directory)
      else { throw FinderDocumentError.invalidRequest }
      var manualName: String?
      if configuration.namingMode == .manual {
        manualName =
          if let namePrompt { namePrompt(request, configuration) } else {
            promptForName(request, configuration: configuration)
          }
        guard manualName != nil else { return }
      }
      // 输入期间设置可能改变，创建前重新读取，避免关闭功能后仍写入文件。
      let configuration = configuration
      let confirmedName = manualName
      let task = Task.detached(priority: .userInitiated) {
        try FinderDocumentCreator.create(
          request, configuration: configuration, manualName: confirmedName)
      }
      creation = task
      defer { creation = nil }
      let result = try await task.value
      error = nil
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

  private var configuration: FinderDocumentConfiguration {
    FinderDocumentConfiguration(
      enabled: settings.finderDocumentsEnabled, language: settings.language.resolved,
      namingMode: settings.finderDocumentNamingMode, fixedName: settings.finderDocumentFixedName,
      enabledKinds: settings.finderDocumentFormats)
  }

  private func promptForName(
    _ request: FinderDocumentRequest, configuration: FinderDocumentConfiguration
  ) -> String? {
    let alert = NSAlert()
    alert.messageText = tr("新建文档")
    alert.informativeText = tr("文件名（无需扩展名）")
    alert.addButton(withTitle: tr("创建"))
    alert.addButton(withTitle: tr("取消"))
    let field = NSTextField(
      frame: NSRect(x: 0, y: 0, width: 340, height: 24))
    field.stringValue = L10n.translate(request.kind.title, language: configuration.language)
    field.setAccessibilityLabel(tr("文件名（无需扩展名）"))
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    nameAlert = alert
    defer { nameAlert = nil }
    NSApp.activate()
    while alert.runModal() == .alertFirstButtonReturn {
      do {
        _ = try configuration.baseName(for: request.kind, manualName: field.stringValue)
        return field.stringValue
      } catch {
        alert.informativeText = error.localizedDescription
      }
    }
    return nil
  }

  private func reconcile() {
    refreshStatus()
    if !settings.finderDocumentsEnabled {
      creation?.cancel()
      if nameAlert?.window.isVisible == true { NSApp.abortModal() }
    }
    guard started else { return }
    do {
      guard let store else { throw FinderDocumentError.unavailable }
      let configuration = configuration
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
      _ = settings.finderDocumentNamingMode
      _ = settings.finderDocumentFixedName
      _ = settings.finderDocumentFormats
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
