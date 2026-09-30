// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Observation
import Testing
@testable import XStatsUI

@MainActor
struct UninstallerRunningApplicationTests {
    @Test(.serialized, arguments: [true, false])
    func quittingTargetRefreshesRunningStateAndKeepsWindow(accessory: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UninstallerQuit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let identifier = "test.xstats.uninstaller.\(UUID().uuidString)"
        let url = try await Task.detached {
            try Self.makeTestApplication(in: root, identifier: identifier, accessory: accessory)
        }.value
        let controller = UninstallerController()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        let running = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        defer { if !running.isTerminated { running.forceTerminate() } }
        let target = InstalledApp(url: url, name: "UninstallerQuitTest", bundleIdentifier: identifier,
                                  version: nil, teamIdentifier: nil)
        controller.select(target)
        // openApplication 返回与运行列表更新不是同一个时刻。
        // 全套 UI 测试可长时间占用主线程，不能把调度等待误判成启动失败。
        let launchDeadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < launchDeadline, !running.isFinishedLaunching || !controller.isRunning(target) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(controller.isRunning(target))

        // 保留一个测试窗口，确保退出的只是临时目标应用；不触碰用户的应用或文件。
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 100, height: 100),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        // 等启动时排队的状态刷新完成，再模拟 SwiftUI 对运行状态的依赖。
        try await Task.sleep(for: .milliseconds(100))
        let change = RunningStateChange()
        withObservationTracking {
            _ = controller.isRunning(target)
        } onChange: {
            Task { @MainActor in change.received = true }
        }

        controller.quit(target)
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, !running.isTerminated || !change.received {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(running.isTerminated)
        #expect(change.received, "目标退出后必须通知卸载页刷新，而不只是下次读取时返回新值")
        #expect(!controller.isRunning(target))
        #expect(controller.selected == target)
        #expect(window.isVisible)
    }

    /// 使用真正的 AppKit 应用覆盖 LSUIElement 的通知差异；编译在后台执行，不使用输出管道。
    nonisolated private static func makeTestApplication(in root: URL, identifier: String, accessory: Bool) throws -> URL {
        let app = root.appendingPathComponent("Target.app")
        let contents = app.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Target")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Target",
                                   "CFBundlePackageType": "APPL", "LSUIElement": accessory]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let source = root.appendingPathComponent("main.m")
        try """
        #import <AppKit/AppKit.h>
        int main(void) {
            @autoreleasepool { [[NSApplication sharedApplication] run]; }
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [source.path, "-framework", "AppKit", "-o", executable.path]
        compiler.standardInput = FileHandle.nullDevice
        compiler.standardOutput = FileHandle.nullDevice
        compiler.standardError = FileHandle.standardError
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        // 绑定完整 App 的 Bundle ID，避免仅签名 Mach-O 时 LaunchServices 使用临时可执行文件身份。
        let signer = Process()
        signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signer.arguments = ["--force", "--sign", "-", app.path]
        signer.standardInput = FileHandle.nullDevice
        signer.standardOutput = FileHandle.nullDevice
        signer.standardError = FileHandle.standardError
        try signer.run()
        signer.waitUntilExit()
        try #require(signer.terminationStatus == 0)
        return app
    }
}

@MainActor
private final class RunningStateChange {
    var received = false
}
