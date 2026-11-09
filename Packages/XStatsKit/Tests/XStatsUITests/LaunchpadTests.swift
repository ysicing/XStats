// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import ImageIO
import Localization
import Testing
@testable import XStatsUI

// 用例共享 AppKit 的 key window；异步等待时也不能互相抢焦点触发 dismiss。
@MainActor
@Suite(.serialized)
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

  @Test(arguments: [AppLanguage.chinese, .arabic])
  func wheelPagingKeepsPhysicalDirectionAcrossLanguages(language: AppLanguage) async throws {
    _ = NSApplication.shared
    let controller = LaunchpadWindowController()
    defer { controller.dismiss() }
    let applications = (0..<120).map { application("App \($0)") }
    controller.show(language: language, frame: frame, applicationLoader: { applications })
    try await waitForCatalog(controller, count: applications.count)
    let panel = try #require(controller.panel)
    for horizontal in [true, false] {
      controller.changePage(by: -10_000)
      let scroll = try #require(
        CGEvent(
          scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
          wheel1: horizontal ? 0 : -3, wheel2: horizontal ? -3 : 0, wheel3: 0))
      // 合成事件默认时间戳为零；间隔超过翻页防抖时间，避免被当作重复事件丢弃。
      scroll.timestamp = horizontal ? 1_000_000_000 : 2_000_000_000
      let event = try #require(NSEvent(cgEvent: scroll))
      panel.sendEvent(event)
      #expect(controller.page == 1)
    }
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

  @Test func pageSwipeProjectsVelocityResistsEdgesAndAllowsReversal() {
    var swipe = LaunchpadPageSwipe()
    swipe.update(delta: -30, timestamp: 1)
    swipe.update(delta: -30, timestamp: 1.01)
    #expect(swipe.destination(width: 800, page: 1, count: 3, timestamp: 1.01) == 2)
    #expect(swipe.destination(width: 800, page: 1, count: 3, timestamp: 1.5) == 1)
    swipe.update(delta: 40, timestamp: 1.02)
    #expect(swipe.destination(width: 800, page: 1, count: 3, timestamp: 1.02) == 0)
    #expect(swipe.translation(width: 800, page: 1, count: 3) == -20)
    let edge = LaunchpadPageSwipe(offset: 200)
    #expect(edge.translation(width: 800, page: 0, count: 3) > 0)
    #expect(edge.translation(width: 800, page: 0, count: 3) < 200)
    #expect(edge.destination(width: 800, page: 0, count: 3, timestamp: 1) == 0)
    #expect(
      LaunchpadPageSwipe(offset: -500)
        .destination(width: 800, page: 2, count: 3, timestamp: 1) == 2)
  }

  @Test(arguments: ["Saved", ""])
  func folderOverlayRenamesInlineAndReturnsToOriginalPage(name: String) async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadTests.overlay.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LaunchpadLayoutStore(defaults: defaults)
    let apps =
      [
        "Calendar", "Mail", "Music", "Photos", "Reminders", "System Settings", "Notes", "Maps",
      ].map { application($0) } + (0..<18).map { application("Extra \($0)") }
    let folder = LaunchpadLayout.Item(
      id: "folder.saved", name: name, apps: [apps[6].id, apps[7].id])
    let saved = LaunchpadLayout(pages: [
      apps.prefix(3).map { .app($0.id) },
      apps[3..<6].map { .app($0.id) } + apps.dropFirst(8).map { .app($0.id) } + [folder],
    ])
    store.save(saved)
    let controller = LaunchpadWindowController(layoutStore: store, defaults: defaults)
    defer { controller.dismiss() }
    controller.show(language: .chinese, frame: frame, applicationLoader: { apps })
    try await waitForCatalog(controller, count: 25)
    controller.changePage(by: 1)
    let content = try #require(controller.panel?.contentView)
    let tile = try #require(
      descendants(LaunchpadTileButton.self, in: content).first { $0.itemID == folder.id })
    #expect(NSApp.sendAction(try #require(tile.action), to: tile.target, from: tile))
    #expect(controller.folderID == folder.id)
    let backdrop = try #require(descendant(LaunchpadFolderBackdrop.self, in: content))
    let title = try #require(
      descendants(NSTextField.self, in: content).first {
        $0.identifier?.rawValue == "launchpad.folderTitle"
      })
    let pager = try #require(
      descendants(NSButton.self, in: content).first {
        $0.identifier?.rawValue == "launchpad.dot.0"
      }?.superview?.superview)
    #expect(pager.isHidden)
    let displayedName = name.isEmpty ? L10n.translate("文件夹", language: .chinese) : name
    #expect(title.isEditable && title.stringValue == displayedName)
    let panel = try #require(controller.panel)
    #expect(panel.makeFirstResponder(title))
    let initialEditor = try #require(title.currentEditor() as? NSTextView)
    initialEditor.insertText(
      "Discarded", replacementRange: NSRange(location: 0, length: initialEditor.string.utf16.count))
    #expect(
      controller.control(
        title, textView: initialEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(store.load()?.item(folder.id)?.name == name)
    #expect(title.stringValue == displayedName)
    #expect(panel.makeFirstResponder(title))
    let editor = try #require(title.currentEditor() as? NSTextView)
    editor.insertText(
      "Updated", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    controller.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: title))
    #expect(title.stringValue == "Updated")
    #expect(
      !controller.control(
        title, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveLeft(_:))))
    #expect(
      controller.control(
        title, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(controller.panel?.attachedSheet == nil)
    #expect(store.load()?.item(folder.id)?.name == "Updated")
    #expect(panel.makeFirstResponder(title))
    let cancelledEditor = try #require(title.currentEditor() as? NSTextView)
    cancelledEditor.insertText(
      "Discarded",
      replacementRange: NSRange(location: 0, length: cancelledEditor.string.utf16.count))
    #expect(
      controller.control(
        title, textView: cancelledEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(store.load()?.item(folder.id)?.name == "Updated")
    if let directory = ProcessInfo.processInfo.environment["XSTATS_LAUNCHPAD_PREVIEW_DIR"] {
      content.layoutSubtreeIfNeeded()
      let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let data = try #require(bitmap.representation(using: .png, properties: [:]))
      try data.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("folder-overlay.png"))
    }
    backdrop.onClose()
    #expect(controller.folderID == nil && controller.page == 1)
    #expect(controller.results[controller.selectedIndex].id == folder.id)
    #expect(descendant(LaunchpadFolderBackdrop.self, in: content) == nil)
    #expect(controller.layout.pages.map { $0.map(\.id) } == saved.pages.map { $0.map(\.id) })
  }

  @Test func preciseSwipeIsBoundedInterruptibleAndReleasedOnClose() async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadTests.swipe.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let apps = (0..<120).map { application("App \($0)") }
    let controller = LaunchpadWindowController(defaults: defaults)
    controller.show(frame: frame, applicationLoader: { apps })
    defer { controller.dismiss() }
    try await waitForCatalog(controller, count: apps.count)
    let panel = try #require(controller.panel)
    let content = try #require(panel.contentView)
    for (phase, delta, time) in [
      (NSEvent.Phase.began, -20, 1.0), (.changed, -260, 1.01), (.ended, 0, 1.02),
    ] {
      panel.sendEvent(try swipeEvent(phase: phase, delta: Int32(delta), timestamp: time))
    }
    let preview = try #require(descendant(LaunchpadPagePreview.self, in: content))
    #expect(appButtons(in: panel).count <= controller.pageSize)
    #expect(preview.strip.sublayers?.count == 2)
    panel.sendEvent(try swipeEvent(phase: .began, delta: 0, timestamp: 1.03))
    panel.sendEvent(try swipeEvent(phase: .changed, delta: 20, timestamp: 1.035))
    let resumed = try #require(descendant(LaunchpadPagePreview.self, in: content))
    #expect(resumed !== preview)
    #expect(abs(resumed.translation) <= resumed.bounds.width)
    let interruptedPage = controller.page
    panel.sendEvent(try swipeEvent(phase: .cancelled, delta: 0, timestamp: 1.04))
    try await Task.sleep(for: .milliseconds(700))
    #expect(controller.page == interruptedPage)
    #expect(descendant(LaunchpadPagePreview.self, in: content) == nil)
    panel.sendEvent(try swipeEvent(phase: .began, delta: -20, timestamp: 2))
    panel.sendEvent(try swipeEvent(phase: .changed, delta: -300, timestamp: 2.01))
    panel.sendEvent(try swipeEvent(phase: .ended, delta: 0, timestamp: 2.02))
    try await Task.sleep(for: .milliseconds(700))
    #expect(controller.page == interruptedPage + 1)
    panel.sendEvent(try swipeEvent(phase: .began, delta: -20, timestamp: 3))
    weak var releasedPreview = descendant(LaunchpadPagePreview.self, in: content)
    #expect(releasedPreview?.strip.sublayers?.count == 3)
    controller.dismiss()
    try await Task.sleep(for: .milliseconds(20))
    #expect(releasedPreview == nil)
    #expect(panel.contentView == nil)
  }

  @Test(arguments: [0, 1])
  func listSwipeKeepsShortPagePreviewAtItsOriginalSize(startingPage: Int) async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadTests.listSwipe.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let apps = (0..<14).map { application("App \($0)") }
    let controller = LaunchpadWindowController(defaults: defaults)
    defer { controller.dismiss() }
    controller.setBrowsingMode(.list)
    controller.show(
      frame: NSRect(x: -10_000, y: -10_000, width: 1920, height: 1080),
      applicationLoader: { apps })
    try await waitForCatalog(controller, count: apps.count)
    controller.changePage(by: startingPage)
    let panel = try #require(controller.panel)
    let content = try #require(panel.contentView)
    let grid = try #require(
      descendants(LaunchpadDropView.self, in: content).first {
        $0.identifier?.rawValue == "launchpad.grid"
      })
    content.layoutSubtreeIfNeeded()
    let top = content.convert(grid.bounds, from: grid).maxY
    let direction: Int32 = startingPage == 0 ? -1 : 1
    panel.sendEvent(try swipeEvent(phase: .began, delta: direction * 20, timestamp: 1))
    let preview = try #require(descendant(LaunchpadPagePreview.self, in: content))
    #expect(preview.frame.maxY == top)
    #expect(preview.bounds.height == CGFloat(controller.pageSize) * DS.Space.s12)
    let snapshots = try #require(preview.strip.sublayers)
    #expect(snapshots.count == 2)
    for (index, snapshot) in snapshots.enumerated() {
      let expectedHeight = CGFloat(index == 0 ? 12 : 2) * DS.Space.s12
      #expect(snapshot.frame.height == expectedHeight)
      #expect(snapshot.frame.maxY == preview.bounds.maxY)
      #expect(snapshot.frame.minX == CGFloat(index - startingPage) * preview.bounds.width)
    }
    panel.sendEvent(try swipeEvent(phase: .changed, delta: direction * 300, timestamp: 1.01))
    panel.sendEvent(try swipeEvent(phase: .ended, delta: 0, timestamp: 1.02))
    try await Task.sleep(for: .milliseconds(700))
    #expect(controller.page == 1 - startingPage)
    #expect(descendant(LaunchpadPagePreview.self, in: content) == nil)
    #expect(content.convert(grid.bounds, from: grid).maxY == top)
  }

  @Test(arguments: [AppLanguage.chinese, .german, .arabic])
  func adaptiveGridAndFolderKeepControlsSeparateAndViewportStable(language: AppLanguage)
    async throws
  {
    _ = NSApplication.shared
    for size in [
      NSSize(width: 640, height: 480), NSSize(width: 900, height: 650),
      NSSize(width: 1920, height: 1080),
    ] {
      let suite = "LaunchpadTests.geometry.\(UUID())"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let store = LaunchpadLayoutStore(defaults: defaults)
      let apps = (0..<70).map { application("Application \($0)") }
      let folder = LaunchpadLayout.Item(
        id: "folder.geometry", name: "Folder", apps: apps.prefix(50).map(\.id))
      let saved = LaunchpadLayout(pages: [[folder] + apps.dropFirst(50).map { .app($0.id) }])
      store.save(saved)
      let controller = LaunchpadWindowController(layoutStore: store, defaults: defaults)
      defer { controller.dismiss() }
      controller.show(
        language: language, frame: NSRect(origin: frame.origin, size: size),
        applicationLoader: { apps })
      try await waitForCatalog(controller, count: 21)
      let baseline = controller.layout
      let content = try #require(controller.panel?.contentView)
      let field = try #require(descendant(NSSearchField.self, in: content))
      let grid = try #require(
        descendants(LaunchpadDropView.self, in: content).first {
          $0.identifier?.rawValue == "launchpad.grid"
        })
      let smallTile = try #require(
        descendants(LaunchpadTileButton.self, in: content).first { $0.itemID == folder.id })
      #expect(try #require(smallTile.image).size.width == 64)
      controller.setIconSize(.large)
      let tile = try #require(
        descendants(LaunchpadTileButton.self, in: content).first { $0.itemID == folder.id })
      if size.width == 1920 {
        #expect(try #require(tile.image).size.width > 64)
      }
      #expect(NSApp.sendAction(try #require(tile.action), to: tile.target, from: tile))
      content.layoutSubtreeIfNeeded()
      let initialFrame = grid.frame
      #expect(controller.pageCount > 1)
      let surface = try #require(
        content.subviews.first { $0.identifier?.rawValue == "launchpad.folderSurface" })
      #expect(surface.frame.maxY < content.convert(field.bounds, from: field).minY)
      let controls = descendants(NSControl.self, in: content).filter {
        !$0.isHiddenOrHasHiddenAncestor
      }
      for (index, control) in controls.enumerated() {
        let rect = content.convert(control.bounds, from: control)
        #expect(content.bounds.contains(rect))
        for other in controls.dropFirst(index + 1) {
          #expect(!rect.intersects(content.convert(other.bounds, from: other)))
        }
      }
      let nextDot = try #require(
        descendants(NSButton.self, in: content).first {
          $0.identifier?.rawValue == "launchpad.dot.1"
        })
      #expect(NSApp.sendAction(try #require(nextDot.action), to: nextDot.target, from: nextDot))
      #expect(controller.page == 1)
      controller.changePage(by: 10_000)
      #expect(grid.frame == initialFrame)
      #expect(controller.layout == baseline && store.load() == baseline)
      if let directory = ProcessInfo.processInfo.environment["XSTATS_LAUNCHPAD_PREVIEW_DIR"] {
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent(
            "folder-\(Int(size.width))-\(language.rawValue).png"))
      }
      controller.panel?.makeFirstResponder(field)
      #expect(
        controller.control(
          field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
      content.layoutSubtreeIfNeeded()
      #expect(controller.folderID == nil)
      let restoredTile = try #require(
        descendants(LaunchpadTileButton.self, in: content).first { $0.itemID == folder.id })
      let restoredImage = try #require(restoredTile.cell).imageRect(forBounds: restoredTile.bounds)
      let searchGap =
        content.convert(field.bounds, from: field).minY
        - content.convert(restoredImage, from: restoredTile).maxY
      #expect(searchGap >= 32 && searchGap <= 64)
      controller.dismiss()
    }
  }

  private func swipeEvent(phase: NSEvent.Phase, delta: Int32, timestamp: Double) throws -> NSEvent {
    let event = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: 0, wheel2: delta, wheel3: 0))
    event.timestamp = UInt64(timestamp * 1_000_000_000)
    let rawPhase: Int64
    switch phase {
    case .began: rawPhase = 1
    case .changed: rawPhase = 2
    case .ended: rawPhase = 4
    case .cancelled: rawPhase = 8
    default: rawPhase = 0
    }
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: rawPhase)
    let result = try #require(NSEvent(cgEvent: event))
    try #require(result.phase == phase && result.hasPreciseScrollingDeltas)
    return result
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
