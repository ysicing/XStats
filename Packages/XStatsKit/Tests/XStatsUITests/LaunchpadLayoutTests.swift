// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

struct LaunchpadLayoutTests {
  @Test func groupingMovingAndDissolvingPreservesEveryApplication() {
    var layout = LaunchpadLayout(pages: [[.app("a"), .app("b")], [.app("c")]])
    layout.group("a", into: "b", name: "Tools")
    let folder = layout.pages[0][0]
    #expect(folder.apps == ["b", "a"])
    layout.move("a", toPage: 1, before: "c", capacity: 4)
    #expect(layout.pages == [[.app("b")], [.app("a"), .app("c")]])
    layout.move("b", toPage: 1, before: "c", capacity: 4)
    #expect(layout.pages == [[.app("a"), .app("b"), .app("c")]])
  }

  @Test func reconcileKeepsImportedPageBreaksAndAddsNewApps() {
    var layout = LaunchpadLayout(pages: [[.app("b")], [.app("a"), .app("missing"), .app("b")]])
    layout.reconcile(appIDs: ["a", "b", "c"], capacity: 4)
    #expect(layout.pages == [[.app("b")], [.app("a"), .app("c")]])
    layout.reconcile(appIDs: ["a", "b", "c"], capacity: 1)
    #expect(layout.pages == [[.app("b")], [.app("a")], [.app("c")]])
  }

  @Test func malformedAndDuplicateFoldersDoNotLoseApplications() {
    var layout = LaunchpadLayout(pages: [
      [
        .init(id: "folder.same", name: "First", apps: ["a", "b"]),
        .init(id: "folder.same", name: "Second", apps: ["c", "d"]),
        .init(id: "invalid", apps: ["e", "f"]),
      ]
    ])
    layout.reconcile(appIDs: ["a", "b", "c", "d", "e", "f", "g"], capacity: 4)
    let items = Array(layout.pages.joined())
    #expect(items.flatMap(\.apps) == ["a", "b", "c", "d", "e", "f", "g"])
    #expect(Set(items.map(\.id)).count == items.count)
    #expect(items.filter(\.isFolder).count == 2)
  }

  @Test func draggingWholeFoldersAcrossPagesAndRenamingKeepsContents() {
    var layout = LaunchpadLayout(pages: [[.app("a"), .app("b")], [.app("c")]])
    layout.group("a", into: "b", name: "Tools")
    let folder = layout.pages[0][0].id
    layout.rename(folder, to: "  Utilities  ")
    layout.move(folder, toPage: 1, before: "c", capacity: 4)
    #expect(layout.pages.count == 1)
    #expect(layout.pages[0].map(\.id) == [folder, "c"])
    #expect(layout.item(folder)?.name == "Utilities")
    #expect(layout.item(folder)?.apps == ["b", "a"])
  }

  @MainActor @Test func storeRoundTripsAndOldSystemsKeepNativeLaunchpad() throws {
    let suite = "LaunchpadLayoutTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = LaunchpadLayoutStore(defaults: defaults)
    #expect(store.load() == nil)
    let layout = LaunchpadLayout(pages: [[.app("a")], [.app("b")]])
    store.save(layout)
    #expect(store.load() == layout)
    #expect(!LaunchpadAvailability.supports(majorVersion: 14))
    #expect(!LaunchpadAvailability.supports(majorVersion: 15))
    #expect(!LaunchpadAvailability.supports(majorVersion: 25))
    #expect(LaunchpadAvailability.supports(majorVersion: 26))
    #expect(LaunchpadAvailability.supports(majorVersion: 27))
  }
}
