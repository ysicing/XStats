// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Testing
@testable import XStatsUI

@MainActor
@Suite(.serialized)
struct LaunchpadBrowsingTests {
  private let frame = NSRect(x: -10_000, y: -10_000, width: 900, height: 650)

  @Test func categoriesUseSmallGroupsAndUnknownMetadataFallsBack() {
    #expect(LaunchpadApplicationCategory(nil) == .other)
    #expect(LaunchpadApplicationCategory("") == .other)
    #expect(LaunchpadApplicationCategory("public.app-category.future") == .other)
    #expect(LaunchpadApplicationCategory("developer-tools") == .other)
    #expect(LaunchpadApplicationCategory("public.app-category.business") == .productivity)
    #expect(LaunchpadApplicationCategory("public.app-category.developer-tools") == .development)
    #expect(LaunchpadApplicationCategory("public.app-category.photography") == .creative)
    #expect(LaunchpadApplicationCategory("public.app-category.utilities") == .utilities)
    #expect(LaunchpadApplicationCategory("public.app-category.strategy-games") == .games)
    #expect(LaunchpadApplicationCategory("public.app-category.reference") == .education)
    #expect(LaunchpadApplicationCategory("public.app-category.travel") == .lifestyle)
    let applications = [
      application("Unknown", category: "public.app-category.future"),
      application("Editor 1", category: "public.app-category.developer-tools"),
      application("Photo", category: "public.app-category.photography"),
      application("Editor 2", category: "public.app-category.developer-tools"),
      application("No Metadata"),
      application("Editor 3", category: "public.app-category.developer-tools"),
    ]
    let pages = LaunchpadBrowsing.pages(applications: applications, mode: .categories, capacity: 2)
    #expect(pages.map(\.category) == [.development, .development, .creative, .other])
    #expect(
      pages.map { $0.commands.map(\.title) } == [
        ["Editor 1", "Editor 2"], ["Editor 3"], ["Photo"], ["Unknown", "No Metadata"],
      ])
    #expect(
      pages.allSatisfy { page in
        page.commands.count <= 2
          && page.commands.allSatisfy {
            LaunchpadApplicationCategory($0.applicationCategory) == page.category
          }
      })
    #expect(LaunchpadBrowsing.pages(applications: [], mode: .categories, capacity: 0).isEmpty)
    #expect(
      LaunchpadBrowsing.pages(applications: applications, mode: .list, capacity: 0)
        .allSatisfy { $0.commands.count == 1 })
  }

  @Test func preferencesRoundTripAndStayInsideInjectedDefaults() throws {
    let firstSuite = "LaunchpadBrowsingTests.preferences.\(UUID())"
    let secondSuite = "LaunchpadBrowsingTests.preferences.\(UUID())"
    let first = try #require(UserDefaults(suiteName: firstSuite))
    let second = try #require(UserDefaults(suiteName: secondSuite))
    defer {
      first.removePersistentDomain(forName: firstSuite)
      second.removePersistentDomain(forName: secondSuite)
    }
    let standardValue = UserDefaults.standard.string(forKey: LaunchpadBrowsingMode.preferenceKey)
    let controller = LaunchpadWindowController(defaults: first)
    #expect(controller.browsingMode == .grid)
    controller.setBrowsingMode(.list)
    #expect(LaunchpadWindowController(defaults: first).browsingMode == .list)
    #expect(LaunchpadWindowController(defaults: second).browsingMode == .grid)
    controller.setBrowsingMode(.categories)
    #expect(LaunchpadWindowController(defaults: first).browsingMode == .categories)
    second.set("invalid-mode", forKey: LaunchpadBrowsingMode.preferenceKey)
    #expect(LaunchpadWindowController(defaults: second).browsingMode == .grid)
    #expect(
      UserDefaults.standard.string(forKey: LaunchpadBrowsingMode.preferenceKey) == standardValue)
  }

  @Test func derivedModesKeepFoldersOrderAndGridReconciliationCapacity() async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.layout.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LaunchpadLayoutStore(defaults: defaults)
    let applications = (0..<16).map {
      application("App \($0)", category: "public.app-category.developer-tools")
    }
    let folder = LaunchpadLayout.Item(
      id: "folder.saved", name: "Saved", apps: [applications[1].id, applications[0].id])
    let saved = LaunchpadLayout(pages: [
      [folder] + applications.dropFirst(2).reversed().map { .app($0.id) }
    ])
    store.save(saved)
    let controller = LaunchpadWindowController(layoutStore: store, defaults: defaults)
    defer { controller.dismiss() }
    controller.show(frame: frame, applicationLoader: { applications })
    try await waitForResults(controller, count: 15)
    let folderButton = try #require(tiles(in: controller).first { $0.itemID == folder.id })
    #expect(folderButton.imagePosition == .imageAbove && folderButton.title == folder.name)
    #expect(folderButton.accessibilityLabel() == folder.name)
    #expect(
      NSApp.sendAction(
        try #require(folderButton.action), to: folderButton.target, from: folderButton))
    #expect(controller.folderID == folder.id)
    controller.setEditing(true)
    let fields = descendants(NSSearchField.self, in: controller.panel?.contentView)
    let field = try #require(fields.first)
    field.stringValue = "App"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    controller.setBrowsingMode(.list)
    #expect(!controller.isEditing && controller.folderID == nil && field.stringValue == "App")
    #expect(controller.results.count == applications.count && controller.columns == 1)
    #expect(controller.pageSize < saved.pages[0].count)
    controller.setEditing(true)
    controller.moveItem(applications[0].id, before: applications[4].id)
    tiles(in: controller).first?.onDrop(applications[0].id, true)
    #expect(!controller.isEditing && controller.layout == saved && store.load() == saved)
    let firstRow = try #require(tiles(in: controller).first)
    controller.setBrowsingMode(.list)
    #expect(tiles(in: controller).first === firstRow)
    field.stringValue = ""
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(controller.results.map(\.id) == saved.pages.joined().flatMap(\.apps))
    controller.setBrowsingMode(.categories)
    #expect(controller.layout == saved && store.load() == saved)
    #expect(controller.results.map(\.id) == saved.pages.joined().flatMap(\.apps))
    controller.setBrowsingMode(.grid)
    #expect(controller.results.map(\.id) == saved.pages[0].map(\.id))
    controller.setBrowsingMode(.list)
    controller.dismiss()
    controller.show(frame: frame, applicationLoader: { applications })
    try await waitForResults(controller, count: applications.count)
    #expect(controller.browsingMode == .list && controller.layout == saved && store.load() == saved)
  }

  @Test func gridLayoutPreferenceIsLocalAndInvalidValuesFallBack() throws {
    let suite = "LaunchpadBrowsingTests.gridPreference.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let standardValue = UserDefaults.standard.string(forKey: LaunchpadGridLayout.preferenceKey)
    let standardIconSize = UserDefaults.standard.string(forKey: LaunchpadIconSize.preferenceKey)
    let controller = LaunchpadWindowController(defaults: defaults)
    #expect(controller.gridLayout == .automatic)
    #expect(controller.gridIconSize == .small)
    for value in LaunchpadGridLayout.allCases {
      controller.setGridLayout(value)
      #expect(LaunchpadWindowController(defaults: defaults).gridLayout == value)
    }
    defaults.set("future-layout", forKey: LaunchpadGridLayout.preferenceKey)
    #expect(LaunchpadWindowController(defaults: defaults).gridLayout == .automatic)
    #expect(
      UserDefaults.standard.string(forKey: LaunchpadGridLayout.preferenceKey) == standardValue)
    for value in LaunchpadIconSize.allCases {
      controller.setIconSize(value)
      #expect(LaunchpadWindowController(defaults: defaults).gridIconSize == value)
    }
    defaults.set("future-size", forKey: LaunchpadIconSize.preferenceKey)
    #expect(LaunchpadWindowController(defaults: defaults).gridIconSize == .small)
    #expect(
      UserDefaults.standard.string(forKey: LaunchpadIconSize.preferenceKey) == standardIconSize)
  }

  @Test(arguments: [AppLanguage.chinese, .german, .arabic])
  func listKeepsCenteredColumnAcrossPagesAndSearch(language: AppLanguage) async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.listColumn.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let applications =
      ["App Store", "Calendar", "Notes", "Calculator"].map { application($0) }
      + (0..<46).map { application("Application with a long name \($0)") }
    let controller = LaunchpadWindowController(defaults: defaults)
    defer { controller.dismiss() }
    controller.setBrowsingMode(.list)
    for size in [
      NSSize(width: 640, height: 480), NSSize(width: 1920, height: 1080),
      NSSize(width: 2560, height: 1440),
    ] {
      controller.show(
        language: language, frame: NSRect(origin: frame.origin, size: size),
        applicationLoader: { applications })
      try await waitForResults(controller, count: applications.count)
      let content = try #require(controller.panel?.contentView)
      let field = try #require(descendants(NSSearchField.self, in: content).first)
      content.layoutSubtreeIfNeeded()
      let first = try #require(tiles(in: controller).first)
      let rowFrame = content.convert(first.bounds, from: first)
      let searchFrame = content.convert(field.bounds, from: field)
      #expect(abs(rowFrame.midX - searchFrame.midX) < 1)
      #expect(abs(rowFrame.midX - content.bounds.midX) < 1)
      #expect(abs(field.alignmentRect(forFrame: searchFrame).width - rowFrame.width) < 1)
      #expect(searchFrame.minY - rowFrame.maxY >= DS.Space.s4)
      #expect(searchFrame.minY - rowFrame.maxY <= DS.Space.s6)
      #expect(first.alignment == (language.isRightToLeft ? .right : .left))
      #expect(first.imagePosition == .imageLeading)
      let surface = try #require(
        descendants(NSBox.self, in: content).first {
          $0.identifier?.rawValue == "launchpad.listSurface"
        })
      let surfaceFrame = content.convert(surface.bounds, from: surface)
      #expect(!surface.isHidden && content.bounds.contains(surfaceFrame))
      #expect(surfaceFrame.contains(rowFrame) && surfaceFrame.contains(searchFrame))
      let surfaceColor = try #require(surface.fillColor.usingColorSpace(.deviceRGB))
      #expect(
        max(surfaceColor.redComponent, surfaceColor.greenComponent, surfaceColor.blueComponent)
          < 0.3)
      let cell = try #require(first.cell as? LaunchpadListButtonCell)
      let imageFrame = cell.imageRect(forBounds: first.bounds)
      let titleFrame = cell.titleRect(forBounds: first.bounds)
      #expect(
        language.isRightToLeft
          ? imageFrame.minX - titleFrame.maxX == DS.Space.s3
          : titleFrame.minX - imageFrame.maxX == DS.Space.s3)
      #expect(first.layer?.borderWidth == 0)
      let gridMenu = try #require(
        descendants(NSPopUpButton.self, in: content).first {
          $0.identifier?.rawValue == "launchpad.gridLayout"
        })
      #expect(gridMenu.isHidden)
      if let directory = ProcessInfo.processInfo.environment["XSTATS_LAUNCHPAD_PREVIEW_DIR"] {
        try FileManager.default.createDirectory(
          atPath: directory, withIntermediateDirectories: true)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: URL(fileURLWithPath: directory).appendingPathComponent(
            "list-column-\(Int(size.width))-\(language.rawValue).png"))
      }
      #expect(
        controller.control(
          field, textView: NSTextView(), doCommandBy: #selector(NSResponder.pageDown(_:))))
      #expect(controller.page == 1)
      let nextPageFirst = try #require(tiles(in: controller).first)
      #expect(content.convert(nextPageFirst.bounds, from: nextPageFirst) == rowFrame)
      field.stringValue = "Calendar"
      controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
      #expect(controller.results.map(\.id) == [applications[1].id])
      let searchResult = try #require(tiles(in: controller).first)
      #expect(content.convert(searchResult.bounds, from: searchResult) == rowFrame)
      #expect(searchResult.tag == controller.selectedIndex)
      content.layoutSubtreeIfNeeded()
      #expect(content.convert(surface.bounds, from: surface).height < surfaceFrame.height)
      field.stringValue = "No application matches this query"
      controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
      content.layoutSubtreeIfNeeded()
      #expect(controller.results.isEmpty && tiles(in: controller).isEmpty)
      #expect(content.bounds.contains(content.convert(surface.bounds, from: surface)))
      #expect(content.convert(field.bounds, from: field) == searchFrame)
      controller.setBrowsingMode(.grid)
      content.layoutSubtreeIfNeeded()
      #expect(surface.isHidden && !gridMenu.isHidden)
      #expect(field.focusRingType == .default)
      controller.setBrowsingMode(.list)
      controller.dismiss()
    }
  }

  @Test(arguments: [AppLanguage.chinese, .german, .arabic])
  func gridLayoutMenuPreservesPagesSelectionAndSearch(language: AppLanguage) async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.gridMenu.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let applications = (0..<90).map { application("App \($0)") }
    let folder = LaunchpadLayout.Item(
      id: "folder.grid", name: "Tools", apps: applications.prefix(3).map(\.id))
    let saved = LaunchpadLayout(pages: [
      [folder] + applications[3..<47].map { .app($0.id) },
      applications[47...].map { .app($0.id) },
    ])
    let store = LaunchpadLayoutStore(defaults: defaults)
    store.save(saved)
    let controller = LaunchpadWindowController(layoutStore: store, defaults: defaults)
    defer { controller.dismiss() }
    controller.show(
      language: language, frame: NSRect(x: -10_000, y: -10_000, width: 1920, height: 1080),
      applicationLoader: { applications })
    try await waitForResults(controller, count: 88)
    let content = try #require(controller.panel?.contentView)
    let menu = try #require(
      descendants(NSPopUpButton.self, in: content).first {
        $0.identifier?.rawValue == "launchpad.gridLayout"
      }?.menu)
    controller.moveSelection(by: 40)
    let selectedID = controller.results[controller.selectedIndex].id
    for (index, value) in LaunchpadGridLayout.allCases.enumerated() {
      let item = try #require(menu.item(at: index + 1))
      #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
      #expect(controller.gridLayout == value && item.state == .on)
      #expect(controller.columns == value.maximumColumns)
      #expect(controller.pageSize == value.maximumColumns * value.maximumRows)
      #expect(controller.results[controller.selectedIndex].id == selectedID)
      #expect(tiles(in: controller).contains { $0.itemID == selectedID })
      #expect(controller.pageCount == (88 + controller.pageSize - 1) / controller.pageSize)
      for target in 0..<controller.pageCount {
        controller.changePage(by: target - controller.page)
        let start = target * controller.pageSize
        #expect(
          tiles(in: controller).map(\.itemID)
            == Array(saved.pages.joined().map(\.id)[start..<min(start + controller.pageSize, 88)]))
      }
      controller.moveSelection(
        by: try #require(controller.results.firstIndex { $0.id == selectedID })
          - controller.selectedIndex)
      #expect(controller.layout == saved && store.load() == saved)
      for (sizeIndex, size) in LaunchpadIconSize.allCases.enumerated() {
        let sizeItem = try #require(
          menu.item(at: LaunchpadGridLayout.allCases.count + 2 + sizeIndex))
        #expect(
          NSApp.sendAction(try #require(sizeItem.action), to: sizeItem.target, from: sizeItem))
        #expect(controller.gridIconSize == size && sizeItem.state == .on)
        #expect(controller.results[controller.selectedIndex].id == selectedID)
        let expectedPoints: CGFloat = size == .small ? 64 : value.maximumRows == 6 ? 84 : 96
        #expect(
          tiles(in: controller).allSatisfy {
            $0.image?.size == NSSize(width: expectedPoints, height: expectedPoints)
          })
        let gridTile = try #require(tiles(in: controller).first)
        let gridFrame = try #require(gridTile.superview).frame
        let imageFrame = content.convert(
          try #require(gridTile.cell).imageRect(forBounds: gridTile.bounds), from: gridTile)
        controller.setBrowsingMode(.categories)
        content.layoutSubtreeIfNeeded()
        let categoryTile = try #require(tiles(in: controller).first)
        #expect(categoryTile.superview?.frame == gridFrame)
        #expect(
          content.convert(
            try #require(categoryTile.cell).imageRect(forBounds: categoryTile.bounds),
            from: categoryTile) == imageFrame)
        #expect(
          tiles(in: controller).allSatisfy {
            $0.imagePosition == .imageOnly && !$0.canDrag
              && $0.image?.size == NSSize(width: expectedPoints, height: expectedPoints)
          })
        #expect(controller.layout == saved && store.load() == saved)
        #expect(controller.results[controller.selectedIndex].id == selectedID)
        controller.setBrowsingMode(.grid)
      }
      controller.setIconSize(.small)
      let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      if let directory = ProcessInfo.processInfo.environment["XSTATS_LAUNCHPAD_PREVIEW_DIR"] {
        try FileManager.default.createDirectory(
          atPath: directory, withIntermediateDirectories: true)
        for mode in [LaunchpadBrowsingMode.grid, .categories] {
          controller.setBrowsingMode(mode)
          content.layoutSubtreeIfNeeded()
          content.cacheDisplay(in: content.bounds, to: bitmap)
          try #require(bitmap.representation(using: .png, properties: [:])).write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(
              "\(mode.rawValue)-layout-\(value.rawValue)-\(language.rawValue).png"))
        }
      }
      controller.setBrowsingMode(.list)
      content.layoutSubtreeIfNeeded()
      let grid = try #require(
        descendants(LaunchpadDropView.self, in: content).first {
          $0.identifier?.rawValue == "launchpad.grid"
        })
      #expect(controller.pageSize == 12)
      #expect(tiles(in: controller).allSatisfy { grid.bounds.contains($0.frame) })
      controller.setBrowsingMode(.grid)
    }
    let field = try #require(descendants(NSSearchField.self, in: content).first)
    field.stringValue = "App 8"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let searchIDs = controller.results.map(\.id)
    controller.setGridLayout(.sevenByFive)
    controller.setIconSize(.large)
    #expect(field.stringValue == "App 8" && controller.results.map(\.id) == searchIDs)
    controller.dismiss()
    controller.show(
      language: language, frame: NSRect(x: -10_000, y: -10_000, width: 1920, height: 1080),
      applicationLoader: { applications })
    try await waitForResults(controller, count: 88)
    #expect(
      controller.gridLayout == .sevenByFive && controller.gridIconSize == .large
        && controller.layout == saved)
    controller.setGridLayout(.automatic)
    #expect(controller.pageCount == 2 && store.load() == saved)
  }

  @Test func draggingFromProjectedPageUsesVisiblePage() async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.gridDrag.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let applications = (0..<60).map { application("App \($0)") }
    let saved = LaunchpadLayout(pages: [
      applications.prefix(45).map { .app($0.id) },
      applications.dropFirst(45).map { .app($0.id) },
    ])
    let store = LaunchpadLayoutStore(defaults: defaults)
    store.save(saved)
    let controller = LaunchpadWindowController(layoutStore: store, defaults: defaults)
    defer { controller.dismiss() }
    controller.setGridLayout(.sevenByFive)
    controller.show(
      frame: NSRect(x: -10_000, y: -10_000, width: 1920, height: 1080),
      applicationLoader: { applications })
    try await waitForResults(controller, count: 60)
    controller.changePage(by: 1)
    controller.moveItem(applications[36].id, before: applications[35].id)
    #expect(controller.layout.pages.map(\.count) == [35, 25])
    #expect(
      controller.layout.pages[1].prefix(2).map(\.id) == [applications[36].id, applications[35].id])
    controller.changePage(by: -1)
    controller.moveItem(applications[36].id, before: applications[3].id)
    #expect(controller.results[3].id == applications[36].id)
    #expect(tiles(in: controller).count == 35)
    controller.moveItem(applications[2].id, toAdjacentPage: 1, afterHover: false)
    #expect(controller.results.last?.id == applications[2].id)
    #expect(tiles(in: controller).count == 35)
    controller.changePage(by: 1)
    #expect(tiles(in: controller).count == 25 && controller.pageCount == 2)
    #expect(Set(controller.layout.pages.joined().flatMap(\.apps)) == Set(applications.map(\.id)))
    #expect(store.load() == controller.layout)
  }

  @Test func draggingFromFolderUsesItsRootPage() async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.folderPage.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let applications = (0..<80).map { application("App \($0)") }
    let folder = LaunchpadLayout.Item(
      id: "folder.last", name: "Last", apps: applications.suffix(2).map(\.id))
    let store = LaunchpadLayoutStore(defaults: defaults)
    store.save(
      LaunchpadLayout(pages: [applications.dropLast(2).map { .app($0.id) } + [folder]]))
    let controller = LaunchpadWindowController(layoutStore: store, defaults: defaults)
    defer { controller.dismiss() }
    controller.setGridLayout(.sevenByFive)
    controller.show(
      frame: NSRect(x: -10_000, y: -10_000, width: 1920, height: 1080),
      applicationLoader: { applications })
    try await waitForResults(controller, count: 79)
    controller.changePage(by: 2)
    let tile = try #require(tiles(in: controller).first { $0.itemID == folder.id })
    #expect(NSApp.sendAction(try #require(tile.action), to: tile.target, from: tile))
    #expect(controller.folderID == folder.id && controller.pageCount == 1)
    controller.moveItem(applications[78].id, toAdjacentPage: 1, afterHover: false)
    #expect(controller.folderID == nil && controller.pageCount == 3)
    #expect(
      controller.results.suffix(2).map(\.id) == [applications[79].id, applications[78].id])
    #expect(Set(controller.results.map(\.id)) == Set(applications.map(\.id)))
    #expect(store.load() == controller.layout)
  }

  @Test(arguments: LaunchpadBrowsingMode.allCases)
  func searchFavoritesAndKeyboardRemainAvailable(mode: LaunchpadBrowsingMode) async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.search.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let usage = CommandBarUsage(defaults: defaults)
    let applications =
      [application("活动监视器"), application("Brew Tool"), application("IP Scanner")]
      + (0..<60).map { application("Tool \($0)") }
    let controller = LaunchpadWindowController(usage: usage, defaults: defaults)
    defer { controller.dismiss() }
    controller.setBrowsingMode(mode)
    controller.show(frame: frame, applicationLoader: { applications })
    try await waitForResults(controller, count: applications.count)
    let fields = descendants(NSSearchField.self, in: controller.panel?.contentView)
    let field = try #require(fields.first)
    let editor = NSTextView()
    #expect(
      controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    #expect(controller.selectedIndex == controller.columns)
    #expect(
      controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.pageDown(_:))))
    #expect(controller.page == 1)
    #expect(tiles(in: controller).count <= controller.pageSize)
    #expect(tiles(in: controller).contains { $0.tag == controller.selectedIndex })
    field.stringValue = "hdjsq"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(controller.results.map(\.id) == [applications[0].id])
    let buttons = descendants(NSButton.self, in: controller.panel?.contentView)
    let favorite = try #require(buttons.first { $0.keyEquivalent == "d" })
    #expect(NSApp.sendAction(try #require(favorite.action), to: favorite.target, from: favorite))
    #expect(usage.favorites == [applications[0].id] && field.stringValue == "hdjsq")
    controller.setBrowsingMode(mode == .list ? .categories : .list)
    #expect(controller.results.map(\.id) == [applications[0].id] && field.stringValue == "hdjsq")
    field.stringValue = "brew"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    #expect(controller.results.map(\.id) == [applications[1].id])
    var executed: String?
    controller.onSelect = { executed = $0.id }
    #expect(
      controller.control(
        field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
    #expect(executed == applications[1].id && controller.panel == nil)
  }

  @Test(arguments: [0, 1])
  func gridDropsFillPagesAndPreserveUnavailableApps(offlinePage: Int) async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.offline.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let visible = ["B", "C", "Anchor", "D", "E"].map { application($0) }
    let applications =
      visible
      + (0..<(CommandBarApplications.maxApplications - visible.count)).map {
        application("Filler \($0)")
      }
    let offlineID = application("Offline").id
    var pages: [[LaunchpadLayout.Item]] = [
      visible.prefix(3).map { .app($0.id) },
      visible.suffix(2).map { .app($0.id) },
      applications.dropFirst(visible.count).map { .app($0.id) },
    ]
    pages.insert([.app(offlineID)], at: offlinePage)
    let store = LaunchpadLayoutStore(defaults: defaults)
    store.save(LaunchpadLayout(pages: pages))
    let controller = LaunchpadWindowController(layoutStore: store, defaults: defaults)
    defer { controller.dismiss() }
    controller.show(frame: frame, applicationLoader: { applications })
    try await waitForResults(controller, count: applications.count)
    #expect(controller.layout.pages[offlinePage] == [.app(offlineID)])
    #expect(tiles(in: controller).count == controller.pageSize)
    #expect(controller.results.map(\.id) == applications.map(\.id))
    controller.moveItem(visible[1].id, before: visible[0].id)
    #expect(
      controller.results.prefix(3).map(\.id) == [
        visible[1].id, visible[0].id, visible[2].id,
      ])
    #expect(controller.layout.item(offlineID) != nil)
    let zones = descendants(LaunchpadDropView.self, in: controller.panel?.contentView)
    let background = try #require(zones.first { $0.identifier?.rawValue == "launchpad.grid" })
    background.onDrop(visible[1].id)
    #expect(controller.results[controller.pageSize - 1].id == visible[1].id)
    #expect(controller.results.prefix(2).map(\.id) == [visible[0].id, visible[2].id])
    let next = try #require(zones.first { $0.identifier?.rawValue == "launchpad.page.next" })
    next.onDrop(visible[1].id)
    #expect(controller.results[controller.pageSize * 2 - 1].id == visible[1].id)
    try #require(next.onHover())
    #expect(controller.page == 1)
    controller.moveItem(visible[0].id, toAdjacentPage: 1, afterHover: true)
    #expect(controller.results[controller.pageSize * 2 - 1].id == visible[0].id)
    controller.changePage(by: 1 - controller.page)
    let previous = try #require(
      zones.first { $0.identifier?.rawValue == "launchpad.page.previous" })
    previous.onDrop(visible[0].id)
    #expect(controller.results[controller.pageSize].id == visible[0].id)
    #expect(controller.layout.item(offlineID) != nil)
    #expect(controller.results.count == applications.count)
    #expect(Set(controller.results.map(\.id)) == Set(applications.map(\.id)))
    #expect(Set(controller.layout.pages.joined().flatMap(\.apps)).count == applications.count + 1)
    for target in 0..<controller.pageCount {
      controller.changePage(by: target - controller.page)
      #expect(
        tiles(in: controller).count
          == min(controller.pageSize, applications.count - target * controller.pageSize))
    }
    #expect(store.load() == controller.layout)
  }

  @Test(.timeLimit(.minutes(1)))
  func successfulRemovalAfterDismissalNotifiesVisibleConsumer() async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.removal.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let removed = application("Removed")
    let survivor = application("Survivor")
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let (starts, startedContinuation) = AsyncStream<Bool>.makeStream()
    defer { startedContinuation.finish() }
    let controller = LaunchpadWindowController(
      defaults: defaults,
      applicationRemover: { _ in
        startedContinuation.yield(true)
        guard gate.wait(timeout: .now() + 5) == .success else {
          throw CocoaError(.userCancelled)
        }
      })
    defer { controller.dismiss() }
    controller.show(frame: frame, applicationLoader: { [removed] })
    try await waitForResults(controller, count: 1)
    controller.removeApplication(removed)
    var startsIterator = starts.makeAsyncIterator()
    let started = await startsIterator.next()
    try #require(started == true)
    controller.dismiss()

    let consumer = LaunchpadWindowController(defaults: defaults)
    defer { consumer.dismiss() }
    consumer.show(frame: frame, applicationLoader: { [survivor] })
    try await waitForResults(consumer, count: 1)
    let previousRow = try #require(tiles(in: consumer).first)
    let (changes, changedContinuation) = AsyncStream<Bool>.makeStream()
    defer { changedContinuation.finish() }
    let observer = NotificationCenter.default.addObserver(
      forName: .launcherApplicationsChanged, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { consumer.reloadApplications() }
      changedContinuation.yield(true)
    }
    defer { NotificationCenter.default.removeObserver(observer) }
    var changesIterator = changes.makeAsyncIterator()
    gate.signal()
    let changed = await changesIterator.next()
    try #require(changed == true)
    try await waitForPageReplacement(consumer, replacing: previousRow)
    #expect(controller.panel == nil && controller.layout.pages.isEmpty)
    #expect(consumer.results.map(\.id) == [survivor.id])
  }

  @Test(.timeLimit(.minutes(1))) func visibleReloadKeepsLatestSelectionSearchAndEdits() async throws
  {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.reload.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let applications = (0..<20).map { application("App \($0)") }
    let store = LaunchpadLayoutStore(defaults: defaults)
    let controller = LaunchpadWindowController(layoutStore: store, defaults: defaults)
    defer { controller.dismiss() }
    let (loads, continuation) = AsyncStream<Bool>.makeStream()
    defer { continuation.finish() }
    var completions = loads.makeAsyncIterator()
    controller.show(
      frame: frame,
      applicationLoader: {
        defer { continuation.yield(true) }
        return applications
      })
    let initialLoadCompleted = await completions.next()
    try #require(initialLoadCompleted == true)
    try await waitForResults(controller, count: applications.count)
    controller.moveSelection(by: 3)
    let selected = controller.results[controller.selectedIndex].id
    controller.reloadApplications()
    controller.moveItem(applications[1].id, before: applications[0].id)
    let saved = controller.layout
    let previousPage = try #require(tiles(in: controller).first)
    controller.reloadApplications()
    let reloadCompleted = await completions.next()
    try #require(reloadCompleted == true)
    try await waitForPageReplacement(controller, replacing: previousPage)
    #expect(controller.layout == saved && store.load() == saved)
    #expect(controller.results[controller.selectedIndex].id == selected)
    let fields = descendants(NSSearchField.self, in: controller.panel?.contentView)
    let field = try #require(fields.first)
    field.stringValue = "App 3"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let baseline = controller.results.map(\.id)
    #expect(baseline.first == applications[3].id)
    controller.reloadApplications()
    controller.setBrowsingMode(.list)
    let previousRow = try #require(tiles(in: controller).first)
    let searchReloadCompleted = await completions.next()
    try #require(searchReloadCompleted == true)
    try await waitForPageReplacement(controller, replacing: previousRow)
    #expect(field.stringValue == "App 3" && controller.results.map(\.id) == baseline)
    #expect(controller.layout == saved && store.load() == saved)
  }

  @Test func slowerReloadCannotReplaceNewerCatalogInSameWindow() async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.stale.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let initial = [application("Initial")]
    let fresh = application("Fresh")
    let stale = application("Stale")
    let (events, continuation) = AsyncStream<Bool>.makeStream()
    defer { continuation.finish() }
    let loader = LaunchpadBrowsingReloadLoader(
      initial: initial, stale: initial + [stale], latest: initial + [fresh],
      continuation: continuation)
    let controller = LaunchpadWindowController(defaults: defaults)
    defer { controller.dismiss() }
    controller.show(frame: frame, applicationLoader: { loader.load() })
    try await waitForResults(controller, count: 1)
    let panel = controller.panel
    var iterator = events.makeAsyncIterator()
    controller.reloadApplications()
    let started = await iterator.next()
    #expect(started == false)
    controller.reloadApplications()
    try await waitForResults(controller, count: 2)
    let finished = await iterator.next()
    #expect(finished == true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(controller.panel === panel)
    #expect(controller.results.map(\.id) == [initial[0].id, fresh.id])
    #expect(!controller.layout.pages.joined().flatMap(\.apps).contains(stale.id))
  }

  @Test(arguments: [AppLanguage.chinese, .arabic])
  func gridFoldersAndAppsShareIconAlignment(language: AppLanguage) async throws {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.iconAlignment.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let applications = ["App Store", "Calendar", "Notes", "Calculator"].map { application($0) }
    let folder = LaunchpadLayout.Item(
      id: "folder.alignment", name: "Tools 工具 تطبيقات", apps: applications.suffix(2).map(\.id))
    let store = LaunchpadLayoutStore(defaults: defaults)
    store.save(
      LaunchpadLayout(pages: [[.app(applications[0].id), folder, .app(applications[1].id)]]))
    let controller = LaunchpadWindowController(layoutStore: store, defaults: defaults)
    defer { controller.dismiss() }
    for size in [
      NSSize(width: 640, height: 480), NSSize(width: 1920, height: 1080),
      NSSize(width: 2560, height: 1440),
    ] {
      controller.show(
        language: language, frame: NSRect(origin: frame.origin, size: size),
        applicationLoader: { applications })
      try await waitForResults(controller, count: 3)
      let content = try #require(controller.panel?.contentView)
      let field = try #require(descendants(NSSearchField.self, in: content).first)
      for layout in LaunchpadGridLayout.allCases {
        controller.setGridLayout(layout)
        for iconSize in LaunchpadIconSize.allCases {
          controller.setIconSize(iconSize)
          content.layoutSubtreeIfNeeded()
          let buttons = tiles(in: controller)
          let app = try #require(buttons.first { $0.itemID == applications[0].id })
          let folderButton = try #require(buttons.first { $0.itemID == folder.id })
          let appRect = try #require(app.cell).imageRect(forBounds: app.bounds)
          let folderRect = try #require(folderButton.cell).imageRect(forBounds: folderButton.bounds)
          let appPosition = content.convert(appRect, from: app)
          let folderPosition = content.convert(folderRect, from: folderButton)
          let searchGap = content.convert(field.bounds, from: field).minY - appPosition.maxY
          #expect(searchGap >= 32 && searchGap <= 64)
          #expect(abs(appPosition.midY - folderPosition.midY) < 1)
          #expect(appPosition.size == folderPosition.size)
          #expect(app.bounds.contains(appRect) && folderButton.bounds.contains(folderRect))
          let titleRect = try #require(folderButton.cell).titleRect(forBounds: folderButton.bounds)
          #expect(folderButton.bounds.contains(titleRect) && !titleRect.intersects(folderRect))
          #expect(titleRect.minY - folderRect.maxY <= DS.Space.s2)
          #expect(
            abs(appPosition.midX - folderPosition.midX)
              <= max(132, iconSize.points + DS.Space.s16))
          #expect(folderButton.accessibilityLabel() == folder.name)
          #expect(app.imagePosition == .imageOnly && folderButton.imagePosition == .imageAbove)
          if let directory = ProcessInfo.processInfo.environment["XSTATS_LAUNCHPAD_PREVIEW_DIR"] {
            try FileManager.default.createDirectory(
              atPath: directory, withIntermediateDirectories: true)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
              to: URL(fileURLWithPath: directory).appendingPathComponent(
                "icon-alignment-\(Int(size.width))-\(layout.rawValue)-\(iconSize.rawValue)-\(language.rawValue).png"
              ))
          }
        }
      }
      controller.dismiss()
    }
  }

  @Test(arguments: [AppLanguage.chinese, .german, .arabic])
  func smallWindowKeepsModesSearchAndFooterSeparateAndCapturesPNG(language: AppLanguage)
    async throws
  {
    _ = NSApplication.shared
    let suite = "LaunchpadBrowsingTests.preview.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let applications = (0..<50).map {
      application(
        "Application with a long name \($0)",
        category: $0 < 25 ? "public.app-category.developer-tools" : nil)
    }
    let controller = LaunchpadWindowController(
      usage: CommandBarUsage(defaults: defaults), defaults: defaults)
    defer { controller.dismiss() }
    controller.show(
      language: language, frame: NSRect(x: -10_000, y: -10_000, width: 640, height: 480),
      applicationLoader: { applications })
    try await waitForResults(controller, count: applications.count)
    let panel = try #require(controller.panel)
    let content = try #require(panel.contentView)
    let popups = descendants(NSPopUpButton.self, in: content)
    let popup = try #require(popups.first { $0.identifier?.rawValue == "launchpad.browsingMode" })
    for mode in LaunchpadBrowsingMode.allCases {
      popup.selectItem(at: try #require(LaunchpadBrowsingMode.allCases.firstIndex(of: mode)))
      #expect(NSApp.sendAction(try #require(popup.action), to: popup.target, from: popup))
      #expect(controller.browsingMode == mode)
      controller.setGridLayout(.eightBySix)
      #expect(controller.columns == (mode == .list ? 1 : 4))
      content.layoutSubtreeIfNeeded()
      let controls = descendants(NSControl.self, in: content)
        .filter { !$0.isHiddenOrHasHiddenAncestor }
      for (index, control) in controls.enumerated() {
        let rect = content.convert(control.bounds, from: control)
        #expect(content.bounds.contains(rect))
        for other in controls.dropFirst(index + 1) {
          #expect(!rect.intersects(content.convert(other.bounds, from: other)))
        }
      }
      let buttons = tiles(in: controller)
      #expect(buttons.count <= controller.pageSize)
      for button in buttons {
        let command = try #require(controller.results.first { $0.id == button.itemID })
        #expect(button.toolTip == command.title && button.accessibilityLabel() == command.title)
        #expect(
          button.imagePosition == (mode == .list ? .imageLeading : .imageOnly))
      }
      if mode == .list {
        #expect(buttons.allSatisfy { !$0.canDrag && $0.frame.height == 44 })
        #expect(Set(buttons.map { $0.frame.minX }).count == 1)
        #expect(buttons.first?.alignment == (language.isRightToLeft ? .right : .left))
      } else if mode == .categories {
        #expect(buttons.allSatisfy { !$0.canDrag })
        let labels = descendants(NSTextField.self, in: content)
        let title = try #require(
          labels.first {
            $0.identifier?.rawValue == "launchpad.heading"
          })
        #expect(title.stringValue == L10n.translate("开发工具", language: language))
        controller.changePage(by: 10_000)
        #expect(title.stringValue == L10n.translate("其他", language: language))
        controller.changePage(by: -10_000)
      }
      if let directory = ProcessInfo.processInfo.environment["XSTATS_LAUNCHPAD_PREVIEW_DIR"] {
        try FileManager.default.createDirectory(
          atPath: directory, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
          panel.appearance = NSAppearance(named: appearance)
          content.layoutSubtreeIfNeeded()
          let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
          content.cacheDisplay(in: content.bounds, to: bitmap)
          let data = try #require(bitmap.representation(using: .png, properties: [:]))
          try data.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(
              "launchpad-browsing-\(mode.rawValue)-\(language.rawValue)-\(appearance.rawValue).png")
          )
        }
      }
    }
  }

  private func application(_ title: String, category: String? = nil) -> AppCommand {
    let url = URL(fileURLWithPath: "/System/Applications/\(title).app")
    return AppCommand(
      id: "application.\(url.path)", title: title, symbol: "app", keywords: "",
      action: .openApplication(url), applicationCategory: category)
  }

  private func waitForResults(_ controller: LaunchpadWindowController, count: Int) async throws {
    for _ in 0..<250 {
      if controller.results.count == count { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Launchpad browsing did not finish loading")
  }

  private func waitForPageReplacement(
    _ controller: LaunchpadWindowController, replacing button: LaunchpadTileButton
  ) async throws {
    for _ in 0..<250 {
      if let current = tiles(in: controller).first, current !== button { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Launchpad did not render the reloaded catalog")
  }

  private func tiles(in controller: LaunchpadWindowController) -> [LaunchpadTileButton] {
    descendants(LaunchpadTileButton.self, in: controller.panel?.contentView)
  }

  private func descendants<View: NSView>(_ type: View.Type, in view: NSView?) -> [View] {
    guard let view else { return [] }
    return (view as? View).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
  }
}

private final class LaunchpadBrowsingReloadLoader: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  private let initial: [AppCommand]
  private let stale: [AppCommand]
  private let latest: [AppCommand]
  private let continuation: AsyncStream<Bool>.Continuation

  init(
    initial: [AppCommand], stale: [AppCommand], latest: [AppCommand],
    continuation: AsyncStream<Bool>.Continuation
  ) {
    self.initial = initial
    self.stale = stale
    self.latest = latest
    self.continuation = continuation
  }

  func load() -> [AppCommand] {
    let call = lock.withLock {
      calls += 1
      return calls
    }
    if call == 2 {
      continuation.yield(false)
      // 刻意不响应取消，验证控制器也能拒绝同一窗口的过期扫描。
      Thread.sleep(forTimeInterval: 0.12)
      continuation.yield(true)
      return stale
    }
    return call == 1 ? initial : latest
  }
}
