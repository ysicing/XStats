// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing

@MainActor private final class CloseVeto: NSObject, NSWindowDelegate {
    var requests = 0
    var closes = 0
    func windowShouldClose(_ sender: NSWindow) -> Bool { requests += 1; return false }
    func windowWillClose(_ notification: Notification) { closes += 1 }
}

@Suite @MainActor struct WindowCloseTests {
    @Test func internalCloseBypassesUserCloseVetoAndPostsNotification() {
        _ = NSApplication.shared
        let delegate = CloseVeto()
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 180, height: 90),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.performClose(nil)
        #expect(delegate.requests == 1)
        #expect(delegate.closes == 0)
        // 导出完成使用 close，既绕过用户关闭保护，也同步通知控制器释放预览状态。
        window.close()
        #expect(delegate.requests == 1)
        #expect(delegate.closes == 1)
    }
}
