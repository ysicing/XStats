// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct StatusPanelLifecycleTests {
    @Test func reopeningImmediatelyAfterDismissalKeepsTheNewContentVisible() async throws {
        let screen = try #require(NSScreen.main)
        let anchor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 20, height: 20)
        let panel = StatusPanel(width: 200, minHeight: 100) {
            Color.clear.frame(width: 200, height: 100)
        } measuring: {
            Color.clear.frame(width: 200, height: 100)
        }
        // 固定面板只排除其他并行窗口用例引发的失焦，显式关闭仍以正常状态执行。
        panel.isPinned = true
        defer { panel.isPinned = false; panel.dismiss(); panel.close() }
        panel.present(below: anchor, on: screen)
        try await Task.sleep(for: .milliseconds(200))
        panel.isPinned = false
        panel.dismiss()
        #expect(!panel.isVisible)
        panel.isPinned = true
        panel.present(below: anchor, on: screen)
        #expect(panel.isVisible)
        let newContent = try #require(panel.contentView)
        try await Task.sleep(for: .milliseconds(250))
        #expect(panel.isVisible)
        #expect(panel.contentView === newContent)
        #expect(panel.alphaValue == 1)
    }

    @Test func anOutsideDismissalDoesNotBlockTheNextToggle() async throws {
        let screen = try #require(NSScreen.main)
        let anchor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 20, height: 20)
        let panel = StatusPanel(width: 200, minHeight: 100) {
            Color.clear.frame(width: 200, height: 100)
        } measuring: {
            Color.clear.frame(width: 200, height: 100)
        }
        panel.isPinned = true
        defer { panel.isPinned = false; panel.dismiss(); panel.close() }
        panel.present(below: anchor, on: screen)
        try await Task.sleep(for: .milliseconds(200))
        panel.isPinned = false
        panel.dismiss()
        // 已隐藏但仍处于旧的 300ms 冷却区间，正常的新打开请求必须生效。
        panel.isPinned = true
        panel.toggle(below: anchor, on: screen)
        #expect(panel.isVisible)
    }

    @Test func clickingTheSameAnchorClosesWithoutReopening() async throws {
        let screen = try #require(NSScreen.main)
        let anchor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 20, height: 20)
        let panel = StatusPanel(width: 200, minHeight: 100) {
            Color.clear.frame(width: 200, height: 100)
        } measuring: {
            Color.clear.frame(width: 200, height: 100)
        }
        panel.isPinned = true
        defer { panel.isPinned = false; panel.dismiss(); panel.close() }
        panel.present(below: anchor, on: screen)
        let mouseDown = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: anchor.midX, y: anchor.midY), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        panel.isPinned = false
        panel.dismiss(triggeredBy: mouseDown)
        panel.isPinned = true
        // mouse-down 已关闭弹窗，同一次点击的 mouse-up 不能再把它打开。
        panel.toggle(below: anchor, on: screen)
        #expect(!panel.isVisible)
        // 抑制只消费这一次 mouse-up，紧接着的新点击仍应立即打开。
        panel.toggle(below: anchor, on: screen)
        #expect(panel.isVisible)
    }

    @Test func repeatedDismissalNotifiesOnlyOnce() throws {
        let screen = try #require(NSScreen.main)
        let panel = StatusPanel(width: 200, minHeight: 100) {
            Color.clear.frame(width: 200, height: 100)
        } measuring: {
            Color.clear.frame(width: 200, height: 100)
        }
        var visibility: [Bool] = []
        panel.onVisibilityChange = { visibility.append($0) }
        panel.isPinned = true
        defer { panel.isPinned = false; panel.dismiss(); panel.close() }
        panel.present(below: NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY,
                                   width: 20, height: 20), on: screen)
        panel.isPinned = false
        panel.dismiss()
        panel.dismiss()
        #expect(visibility == [true, false])
    }

    @Test func repeatedOpenAndCloseReleasesTheContent() async throws {
        let screen = try #require(NSScreen.main)
        let anchor = NSRect(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY, width: 20, height: 20)
        let panel = StatusPanel(width: 200, minHeight: 100) {
            Color.clear.frame(width: 200, height: 100)
        } measuring: {
            Color.clear.frame(width: 200, height: 100)
        }
        var visibility: [Bool] = []
        panel.onVisibilityChange = { visibility.append($0) }
        defer { panel.isPinned = false; panel.dismiss(); panel.close() }
        for _ in 0..<20 {
            panel.isPinned = true
            panel.toggle(below: anchor, on: screen)
            #expect(panel.isVisible)
            #expect(panel.contentView != nil)
            panel.isPinned = false
            panel.dismiss()
        }
        // 关闭应当同步释放内容，不能等下一次主线程动画回调。
        #expect(!panel.isVisible)
        #expect(panel.contentView == nil)
        #expect(visibility == Array(repeating: [true, false], count: 20).flatMap { $0 })
    }
}
