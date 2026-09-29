// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Combine
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct StatusPanelLayoutTests {
    @Test func liveLocalStateControlsHeightWithoutRecreatingTheMeasuringView() async throws {
        let screen = try #require(NSScreen.main)
        let defaultsName = "StatusPanelLayoutTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(settings: AppSettings(defaults: defaults), historyURL: nil,
                             aiUsageProviders: [], aiQuotaProviders: [])
        let changes = PassthroughSubject<CGFloat, Never>()
        var measurements = 0
        let panel = StatusPanel(width: DS.Size.popoverWidth, minHeight: 100, maxHeight: 500) {
            StatefulContent(changes: changes).environment(model)
        } measuring: {
            measurements += 1
            return StatefulContent(changes: nil).environment(model).environment(\.isSnapshot, true)
        }
        panel.isPinned = true
        defer { panel.close() }
        panel.present(below: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 10, height: 10), on: screen)
        try await Task.sleep(for: .milliseconds(200))
        let original = panel.frame
        let initialMeasurements = measurements
        // 局部 @State 相当于 DNS 编辑框或模型筛选状态；测量副本始终保留默认值。
        for height in [220.0, 700.0, 60.0, 120.0] {
            changes.send(height)
            let expected = min(500, original.height + height - 120)
            // 等待 SwiftUI 布局与下一轮主队列更新均完成；其他主线程测试可能同时计算日历。
            for _ in 0..<40 {
                panel.contentView?.layoutSubtreeIfNeeded()
                if abs(panel.frame.height - expected) < 1 { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(abs(panel.frame.height - expected) < 1)
            #expect(abs(panel.frame.maxY - original.maxY) < 1)
            panel.refreshHeight()
            #expect(abs(panel.frame.height - min(500, original.height + height - 120)) < 1)
        }
        #expect(measurements == initialMeasurements)
    }

    private struct StatefulContent: View {
        let changes: PassthroughSubject<CGFloat, Never>?
        @State private var height: CGFloat = 120

        var body: some View {
            PopoverFrame {
                Color.clear.frame(height: 40)
            } content: {
                Color.clear.frame(height: height)
            }
            .onReceive(changes?.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { height = $0 }
        }
    }

    @Test func absoluteHeightUpdatesAreCoalescedAndBounded() async throws {
        let screen = try #require(NSScreen.main)
        var measurements = 0
        let panel = StatusPanel(width: 320, minHeight: 100, maxHeight: 400) {
            Color.clear.frame(width: 320, height: 240)
        } measuring: {
            measurements += 1
            return Color.clear.frame(width: 320, height: 240)
        }
        panel.isPinned = true
        defer { panel.close() }
        panel.present(below: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 10, height: 10), on: screen)
        let original = panel.frame
        let before = measurements
        for height in 200..<300 { panel.updateContentHeight(CGFloat(height)) }
        #expect(panel.frame == original)
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(panel.frame.height - 299) < 1)
        for height in [600.0, 150.0, 240.0] {
            panel.updateContentHeight(height)
            try await Task.sleep(for: .milliseconds(100))
            #expect(abs(panel.frame.height - min(height, 400)) < 1)
            #expect(abs(panel.frame.maxY - original.maxY) < 1)
        }
        #expect(measurements == before)
    }
}
