// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import ImageIO
import Localization
import Testing
@testable import XStatsUI

@MainActor
struct LaunchpadTests {
  private let frame = NSRect(x: -10_000, y: -10_000, width: 900, height: 650)

  @Test func applicationSearchDoesNotInterpretCommandParameters() {
    let commands = ["IP Scanner", "Brew Tool", "DNS Utility", "活动监视器"].map { application($0) }
    let search = CommandBarSearch(commands: commands, supportsParameterQueries: false)
    #expect(search.results(for: "ip").first?.title == "IP Scanner")
    #expect(search.results(for: "brew").first?.title == "Brew Tool")
    #expect(search.results(for: "dns").first?.title == "DNS Utility")
    #expect(search.results(for: "hdjsq").first?.title == "活动监视器")
    #expect(search.results(for: String(repeating: "x", count: 2049)).isEmpty)
  }

  @Test func pagesBoundControlsAndKeepKeyboardSelectionVisible() async throws {
    _ = NSApplication.shared
    let controller = LaunchpadWindowController()
    defer { controller.dismiss() }
    let applications = (0..<120).map { application("App \($0)") }
    controller.show(frame: frame, applicationLoader: { applications })
    try await waitForCatalog(controller, count: applications.count)
    let panel = try #require(controller.panel)
    controller.show(frame: frame, applicationLoader: { [] })
    #expect(controller.panel === panel)
    #expect(controller.pageCount > 1 && controller.pageSize <= 48)
    #expect(appButtons(in: panel).count == controller.pageSize)
    controller.changePage(by: 1)
    #expect(controller.page == 1)
    controller.moveSelection(by: -1)
    #expect(controller.page == 0 && controller.selectedIndex == controller.pageSize - 1)
    controller.changePage(by: 10_000)
    #expect(controller.page == controller.pageCount - 1)
    #expect(appButtons(in: panel).count <= controller.pageSize)
    #expect(appButtons(in: panel).contains { $0.tag == controller.selectedIndex })

    let field = try #require(descendant(NSSearchField.self, in: panel.contentView))
    field.stringValue = "App 119"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(controller.results.count == 1 && controller.selectedIndex == 0)
    var executed: AppCommand?
    controller.onSelect = {
      #expect(controller.panel == nil && controller.results.isEmpty)
      executed = $0
    }
    defer { controller.onSelect = { _ in } }
    let button = try #require(appButtons(in: panel).first)
    #expect(NSApp.sendAction(try #require(button.action), to: button.target, from: button))
    #expect(executed?.title == "App 119")
    #expect(appButtons(in: panel).isEmpty)
  }

  @Test func lateScanCannotReplaceReopenedCatalogAndCloseReleasesContent() async throws {
    _ = NSApplication.shared
    let controller = LaunchpadWindowController()
    defer { controller.dismiss() }
    let old = application("Old")
    controller.show(
      frame: frame,
      applicationLoader: {
        Thread.sleep(forTimeInterval: 0.08)
        return [old]
      })
    let oldPanel = try #require(controller.panel)
    controller.dismiss()
    let fresh = application("Fresh")
    controller.show(frame: frame, applicationLoader: { [fresh] })
    try await waitForCatalog(controller, count: 1)
    try await Task.sleep(for: .milliseconds(150))
    #expect(controller.results.first?.id == fresh.id)
    #expect(oldPanel.contentView == nil)
    controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
    #expect(controller.panel == nil && controller.results.isEmpty)
  }

  @Test func queryEnteredWhileLoadingIsPreservedAndOnlyApplicationsAreIncluded() async throws {
    _ = NSApplication.shared
    let controller = LaunchpadWindowController()
    defer { controller.dismiss() }
    let applications = [
      application("Safari"), application("Terminal"),
      AppCommand(
        id: "notAnApp", title: "Safari action", symbol: "", keywords: "",
        action: .checkForUpdates),
    ]
    controller.show(
      frame: frame,
      applicationLoader: {
        Thread.sleep(forTimeInterval: 0.03)
        return applications
      })
    let field = try #require(descendant(NSSearchField.self, in: controller.panel?.contentView))
    field.stringValue = "Safari"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    try await waitForCatalog(controller, count: 1)
    #expect(controller.results.first?.title == "Safari")
    #expect(field.stringValue == "Safari")
    field.stringValue = ""
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(controller.results.count == 2)
    let editor = NSTextView()
    editor.setMarkedText(
      "sh", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange())
    #expect(
      !controller.control(
        field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(controller.panel != nil)
    editor.unmarkText()
    #expect(
      controller.control(
        field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(controller.panel == nil)
  }

  @Test func failedScanShowsRecoveryAndDoesNotLeaveLoadingState() async throws {
    _ = NSApplication.shared
    let controller = LaunchpadWindowController()
    defer { controller.dismiss() }
    controller.show(
      language: .german, frame: frame,
      applicationLoader: { throw CocoaError(.fileReadNoPermission) })
    let message = L10n.translate("无法读取应用，请关闭后重试。", language: .german)
    for _ in 0..<100 {
      if descendants(NSTextField.self, in: controller.panel?.contentView)
        .contains(where: { $0.stringValue == message })
      {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(
      descendants(NSTextField.self, in: controller.panel?.contentView)
        .contains { $0.stringValue == message && !$0.isHidden })
    #expect(controller.results.isEmpty)
  }

  @Test func closingCancelsAnActiveScanAndReleasesVisibleControls() async throws {
    _ = NSApplication.shared
    let controller = LaunchpadWindowController()
    defer { controller.dismiss() }
    let (events, continuation) = AsyncStream<Bool>.makeStream()
    controller.show(
      frame: frame,
      applicationLoader: {
        continuation.yield(false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !Task.isCancelled && ContinuousClock.now < deadline {
          Thread.sleep(forTimeInterval: 0.002)
        }
        continuation.yield(Task.isCancelled)
        continuation.finish()
        try Task.checkCancellation()
        return []
      })
    weak var content = controller.panel?.contentView
    weak var field = descendant(NSSearchField.self, in: content)
    var cancelled = false
    for await event in events {
      if event {
        cancelled = true
      } else {
        controller.dismiss()
      }
    }
    #expect(cancelled)
    #expect(controller.panel == nil && controller.results.isEmpty)
    #expect(content == nil && field == nil)
  }

  @Test(arguments: [AppLanguage.chinese, .german, .arabic])
  func smallScreenKeepsGridAndFooterSeparate(language: AppLanguage) async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let usage = CommandBarUsage(defaults: defaults)
    let controller = LaunchpadWindowController(usage: usage)
    defer { controller.dismiss() }
    let applications = (0..<120).map { application("App \($0)") }
    usage.toggleFavorite(applications[0].id)
    controller.show(
      language: language, frame: NSRect(x: -10_000, y: -10_000, width: 640, height: 480),
      applicationLoader: { applications })
    try await waitForCatalog(controller, count: applications.count)
    let content = try #require(controller.panel?.contentView)
    content.layoutSubtreeIfNeeded()
    let buttons = descendants(NSButton.self, in: content).filter { !$0.isHiddenOrHasHiddenAncestor }
    for (index, button) in buttons.enumerated() {
      let rect = content.convert(button.bounds, from: button)
      #expect(content.bounds.contains(rect))
      for other in buttons.dropFirst(index + 1) {
        #expect(!rect.intersects(content.convert(other.bounds, from: other)))
      }
    }
  }

  @Test(arguments: [AppLanguage.chinese, .german, .arabic])
  func sharedFavoritesAndNativeLayout(language: AppLanguage) async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let usage = CommandBarUsage(defaults: defaults)
    let controller = LaunchpadWindowController(usage: usage)
    defer { controller.dismiss() }
    let titles = [
      "Safari", "Calendar", "Mail", "Notes", "Maps", "Music", "Photos", "Reminders",
      "Terminal", "Activity Monitor", "System Settings", "App Store",
    ]
    let applications = titles.map { application($0) }
    usage.toggleFavorite(applications[1].id)
    controller.show(language: language, frame: frame, applicationLoader: { applications })
    try await waitForCatalog(controller, count: applications.count)
    #expect(controller.results.first?.title == "Calendar")
    let panel = try #require(controller.panel)
    let content = try #require(panel.contentView)
    content.layoutSubtreeIfNeeded()
    let buttons = appButtons(in: panel)
    #expect(
      language.isRightToLeft
        ? buttons[0].frame.minX > buttons[1].frame.minX
        : buttons[0].frame.minX < buttons[1].frame.minX)
    let field = try #require(descendant(NSSearchField.self, in: content))
    #expect(field.maximumRecents == 0 && field.recentsAutosaveName == nil)
    #expect(
      field.userInterfaceLayoutDirection == (language.isRightToLeft ? .rightToLeft : .leftToRight))
    let favorite = try #require(
      descendants(NSButton.self, in: content).first { $0.keyEquivalent == "d" })
    #expect(NSApp.sendAction(try #require(favorite.action), to: favorite.target, from: favorite))
    #expect(usage.favorites.isEmpty)
    for button in descendants(NSButton.self, in: content) {
      #expect(content.bounds.contains(content.convert(button.bounds, from: button)))
    }
    if let directory = ProcessInfo.processInfo.environment["XSTATS_LAUNCHPAD_PREVIEW_DIR"] {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
      for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        panel.appearance = NSAppearance(named: appearance)
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent(
            "launchpad-\(language.rawValue)-\(appearance.rawValue).png"))
      }
    }
  }

  @Test(arguments: [AppLanguage.chinese, .german, .arabic])
  func foldersSupportSearchEditingExtractionAndRestore(language: AppLanguage) async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadTests.folders.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LaunchpadLayoutStore(defaults: defaults)
    let applications = ["Calendar", "Mail", "Notes", "活动监视器"].map { application($0) }
    let controller = LaunchpadWindowController(layoutStore: store)
    defer { controller.dismiss() }
    store.save(LaunchpadLayout(pages: [applications.map { .app($0.id) }]))
    controller.show(language: language, frame: frame, applicationLoader: { applications })
    try await waitForCatalog(controller, count: 4)
    let panel = try #require(controller.panel)
    let target = try #require(
      descendants(LaunchpadTileButton.self, in: panel.contentView).first {
        $0.itemID == applications[0].id
      })
    target.onDrop(applications[1].id, true)
    #expect(controller.results.count == 3)
    let folder = try #require(controller.layout.pages[0].first { $0.isFolder })
    let folderButton = try #require(
      descendants(LaunchpadTileButton.self, in: panel.contentView).first {
        $0.itemID == folder.id
      })
    #expect(
      NSApp.sendAction(
        try #require(folderButton.action), to: folderButton.target, from: folderButton))
    #expect(controller.folderID == folder.id && controller.results.count == 2)
    controller.setEditing(true)
    #expect(controller.isEditing)
    let exit = try #require(
      descendants(LaunchpadDropView.self, in: panel.contentView).first {
        $0.identifier?.rawValue == "launchpad.folderExit"
      })
    #expect(!exit.isHidden)
    exit.onDrop(applications[0].id)
    #expect(controller.folderID == nil && controller.results.count == 4)
    #expect(!controller.layout.pages.joined().contains { $0.isFolder })
    let field = try #require(descendant(NSSearchField.self, in: panel.contentView))
    field.stringValue = "hdjsq"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(controller.results.map(\.id) == [applications[3].id])
    field.stringValue = ""
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    if let directory = ProcessInfo.processInfo.environment["XSTATS_LAUNCHPAD_PREVIEW_DIR"] {
      let bitmap = try #require(
        panel.contentView?.bitmapImageRepForCachingDisplay(
          in: NSRect(origin: .zero, size: frame.size)))
      panel.contentView?.cacheDisplay(in: NSRect(origin: .zero, size: frame.size), to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent(
          "launchpad-editing-\(language.rawValue).png"))
    }
    let saved = controller.layout
    controller.dismiss()
    controller.show(language: language, frame: frame, applicationLoader: { applications })
    try await waitForCatalog(controller, count: 4)
    #expect(controller.layout == saved && !controller.isEditing)
  }

  @Test func wallpaperUsesBoundedThumbnailAndIsReleasedOnClose() async throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "LaunchpadWallpaperTests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("wallpaper.png")
    let context = try #require(
      CGContext(
        data: nil, width: 2560, height: 1440, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let colors = [
      CGColor(red: 0.13, green: 0.28, blue: 0.58, alpha: 1),
      CGColor(red: 0.55, green: 0.23, blue: 0.36, alpha: 1),
    ]
    let gradient = try #require(
      CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil))
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 2560, y: 1440), options: [])
    let original = try #require(context.makeImage())
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, original, nil)
    #expect(CGImageDestinationFinalize(destination))
    let blurred = try LaunchpadWallpaper.image(at: url)
    let image = try #require(blurred)
    #expect(max(image.width, image.height) <= 1536)
    let controller = LaunchpadWindowController()
    defer { controller.dismiss() }
    controller.show(frame: frame, wallpaperURL: url, applicationLoader: { [] })
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
      for _ in 0..<100 {
        if controller.panel?.contentView?.subviews.contains(where: {
          $0.identifier?.rawValue == "launchpad.wallpaper"
        }) == true {
          break
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      #expect(
        controller.panel?.contentView?.subviews.contains(where: {
          $0.identifier?.rawValue == "launchpad.wallpaper"
        }) == true)
    }
    weak var content = controller.panel?.contentView
    controller.dismiss()
    for _ in 0..<20 {
      if content == nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(content == nil)
  }

  @Test func revealCancellationCannotDismissAnExplicitReopenOrNewGesture() async throws {
    _ = NSApplication.shared
    let controller = LaunchpadWindowController()
    defer { controller.dismiss() }
    controller.show(frame: frame, applicationLoader: { [] })
    let panel = try #require(controller.panel)
    controller.setRevealProgress(0.4)
    #expect(controller.isRevealing)
    controller.finishReveal(commit: false)
    controller.show(frame: frame, applicationLoader: { [] })
    try await Task.sleep(for: .milliseconds(250))
    #expect(controller.panel === panel && controller.isVisible && !controller.isRevealing)
    #expect(abs(panel.alphaValue - 1) < 0.01)
    controller.setRevealProgress(0.5)
    controller.finishReveal(commit: false)
    controller.setRevealProgress(0.7)
    try await Task.sleep(for: .milliseconds(250))
    #expect(controller.panel === panel && controller.isRevealing)
    controller.finishReveal(commit: true)
    try await Task.sleep(for: .milliseconds(250))
    #expect(controller.isVisible && !controller.isRevealing)
    #expect(abs(panel.alphaValue - 1) < 0.01)
    controller.finishReveal(commit: false)
    for _ in 0..<50 {
      if controller.panel == nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.panel == nil && !controller.isRevealing)
  }

  @Test func abandonedRevealTimesOutAndAllowsAnotherOpen() async throws {
    _ = NSApplication.shared
    let controller = LaunchpadWindowController()
    defer { controller.dismiss() }
    controller.show(frame: frame, applicationLoader: { [] })
    controller.setRevealProgress(0.4)
    for _ in 0..<175 {
      if controller.panel == nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(controller.panel == nil && !controller.isRevealing)
    controller.show(frame: frame, applicationLoader: { [] })
    controller.setRevealProgress(0.8)
    #expect(controller.isVisible && controller.isRevealing)
    controller.dismiss()
    #expect(!controller.isRevealing)
  }

  private func waitForCatalog(_ controller: LaunchpadWindowController, count: Int) async throws {
    for _ in 0..<250 {
      if controller.results.count == count { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Application catalog did not finish loading")
  }

  private func application(_ title: String) -> AppCommand {
    let url = URL(fileURLWithPath: "/System/Applications/\(title).app")
    return AppCommand(
      id: "application.\(url.path)", title: title, symbol: "app", keywords: "",
      action: .openApplication(url))
  }

  private func appButtons(in panel: NSPanel) -> [NSButton] {
    descendants(NSButton.self, in: panel.contentView).filter {
      $0.identifier?.rawValue.hasPrefix("application.") == true
    }
  }

  private func descendant<View: NSView>(_ type: View.Type, in view: NSView?) -> View? {
    descendants(type, in: view).first
  }

  private func descendants<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
    guard let view else { return [] }
    return (view as? View).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
  }
}
