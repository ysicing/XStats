// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Foundation
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct ProjectPurgeReviewTests {
    // 使用真实扫描临时项目覆盖筛选/选择交互，不接触用户目录或执行清理。
    @Test func filteredGroupSelectionKeepsHiddenChoicesAndCanBeCleared() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ProjectReview.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }
        for project in ["alpha", "beta"] {
            for file in ["package.json", "build/output", "node_modules/package/data"] {
                let url = root.appendingPathComponent("Projects/\(project)/\(file)")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 65, count: 4096).write(to: url)
            }
        }
        let scan = await ProjectPurge.scan(home: root.path)
        try #require(scan.items.count == 4)
        let controller = ProjectPurgeController(settings: AppSettings(defaults: defaults), home: root.path)
        controller.showPreview(scan)
        let all = ProjectPurgeGroup.filtered(scan.items, query: "", kind: "", byName: true)
        #expect(all.map(\.project.lastPathComponent) == ["alpha", "beta"])
        controller.toggle(all[0].items[0])
        controller.toggle(all[0].items)
        #expect(controller.selection.count == 2)
        let filtered = ProjectPurgeGroup.filtered(scan.items, query: "BETA", kind: "build", byName: false)
        try #require(filtered.count == 1 && filtered[0].items.count == 1)
        controller.toggle(filtered[0].items)
        #expect(controller.selection.count == 3)
        controller.requestClean()
        #expect(controller.isConfirming)
        controller.toggle(filtered[0].items)
        #expect(controller.selection.count == 2 && !controller.isConfirming)
        #expect(ProjectPurgeGroup.filtered(scan.items, query: "no-match", kind: "", byName: false).isEmpty)
        controller.clearSelection()
        #expect(controller.selectedBytes == 0 && controller.selectedItems.isEmpty)
    }

    @Test func nativeCheckboxExposesNameAndMixedState() throws {
        let host = NSHostingView(rootView: CleanupCheckbox(title: "Fixture project", selected: 1, total: 2, action: {})
            .frame(width: 24, height: 24))
        host.frame = CGRect(x: 0, y: 0, width: 24, height: 24)
        host.layoutSubtreeIfNeeded()
        var views: [NSView] = [host]
        var checkbox: NSButton?
        while let view = views.popLast() {
            if let button = view as? NSButton { checkbox = button; break }
            views.append(contentsOf: view.subviews)
        }
        let button = try #require(checkbox)
        #expect(button.state == .mixed)
        #expect(button.accessibilityLabel() == "Fixture project")
        #expect(button.accessibilityRole() == .checkBox)
    }
}
