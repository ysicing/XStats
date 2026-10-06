// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import SwiftUI
import Observation
import NetworkObservation
import Updates
import Sparkle
import Localization

/// 伴随应用是系统扩展的唯一拥有者；主应用经认证 XPC 请求生命周期操作。
@MainActor @Observable final class ComponentController: NSObject, NetworkComponentService {
    var message = tr("尚未启用")
    var enabled = false
    var busy = false
    var phase: UpdatePhase = .idle
    private let manager = NetworkComponentManager()
    private let listener = NSXPCListener.anonymous()
    private var listenerDelegate: ComponentListener?
    private var driver: SparkleInstaller?
    private var updater: SPUUpdater?
    private var resumeAfterUpdate = false
    private var updatePreparing = false
    private var suppressUpdateResume = false
    private var preparationTask: Task<Void, any Error>?
    private var updateStopTask: Task<Void, any Error>?
    private var release: UpdateRelease?

    func start() {
        guard let team = UpdateInstaller.teamIdentifier(of: Bundle.main.bundleURL) else {
            message = tr("需要包含网络扩展权限的签名构建。")
            return
        }
        listenerDelegate = ComponentListener(controller: self, requirement: "anchor apple generic and identifier \"work.12306.xstats.app\" and certificate leaf[subject.OU] = \"\(team)\"")
        listener.delegate = listenerDelegate
        listener.resume()
        manager.onApproval = { [weak self] in self?.message = tr("等待系统授权") }
        if let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, let url = URL(string: feed) {
            let driver = SparkleInstaller(endpoints: [url], onPhase: { [weak self] in self?.phase = $0 }, onRelaunch: {})
            driver.onNoUpdate = { [weak self] in self?.release = nil }
            driver.hasKnownRelease = { [weak self] in self?.release != nil }
            driver.onRelease = { [weak self] release, _ in self?.release = release }
            driver.prepareForInstallation = { [weak self, weak driver] in
                guard let self, let target = driver?.installationExtension else { throw NetworkMonitorError.missingExtension }
                guard !self.busy else { throw NetworkMonitorError.unavailable }
                self.updatePreparing = true
                self.suppressUpdateResume = false
                self.resumeAfterUpdate = false
                let task = Task {
                    self.resumeAfterUpdate = try await self.manager.filterEnabled()
                    _ = try await self.manager.prepareForUpdate(target: target)
                    try Task.checkCancellation()
                    if self.suppressUpdateResume { self.resumeAfterUpdate = false }
                    UserDefaults.standard.set(self.resumeAfterUpdate, forKey: "resumeFilterAfterComponentUpdate")
                }
                self.preparationTask = task
                defer { self.preparationTask = nil }
                try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                // 期间收到的明确停止命令与准备串行，先完成停用再让 Sparkle 接受安装。
                try await self.updateStopTask?.value

            }
            driver.cancelInstallationPreparation = { [weak self] in
                guard let self, self.updatePreparing else { return }
                self.updatePreparing = false
                UserDefaults.standard.removeObject(forKey: "resumeFilterAfterComponentUpdate")
                if self.resumeAfterUpdate && !self.suppressUpdateResume { Task { await self.run("enable") } }
            }
            self.driver = driver
            do { updater = try driver.start() } catch { message = error.localizedDescription }
        }
        Task { await bootstrap() }

    }

    func bootstrap() async {
        let response = await run("connect")
        guard response.error == nil, !response.needsRestart else { return }
        if UserDefaults.standard.bool(forKey: "resumeFilterAfterComponentUpdate") {
            UserDefaults.standard.removeObject(forKey: "resumeFilterAfterComponentUpdate")
            await run("enable")
        }
    }

    nonisolated func perform(_ command: String, reply: @escaping @Sendable (Data) -> Void) {
        Task { @MainActor in
            let response = await run(command)
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    @discardableResult func run(_ command: String) async -> NetworkComponentResponse {
        if updatePreparing, command == "disable" { return await stopDuringUpdate() }
        guard !busy, !updatePreparing, updateStopTask == nil else { return .init(error: tr("无法连接网络扩展，请重试。")) }
        busy = true
        defer { busy = false }
        do {
            var restart = false
            switch command {
            case "activate":
                restart = try await manager.activate()
            case "connect":
                let original = try await manager.filterEnabled()
                do {
                    restart = try await manager.activate()
                    if restart {
                        if original { UserDefaults.standard.set(true, forKey: "resumeFilterAfterComponentUpdate") }
                        message = tr("需要重启系统")
                        return .init(needsRestart: true)
                    }
                    // provider 启动后才能传递匿名端点；引导阶段结束必须恢复原过滤状态。
                    // 主应用只有通过签名认证的正式 enable 请求才持续开启查看。
                    try await manager.setFilterEnabled(true)
                    try await registerControl()
                    if !original { try await manager.setFilterEnabled(false) }
                    enabled = original
                } catch {
                    try? await manager.setFilterEnabled(original)
                    throw error
                }
            case "enable":
                restart = try await manager.activate()
                guard !restart else { message = tr("需要重启系统"); return .init(needsRestart: true) }
                try await manager.setFilterEnabled(true)
                enabled = true
                try await registerControl()
            case "status": break
            case "disable": try await manager.setFilterEnabled(false); enabled = false
            case "uninstall": restart = try await manager.uninstall(); enabled = false
            default: throw NetworkMonitorError.unavailable
            }
            message = restart ? tr("需要重启系统") : enabled ? tr("正在监视") : tr("尚未启用")
            return .init(needsRestart: restart)
        } catch { message = error.localizedDescription; return .init(error: message) }
    }
    private func stopDuringUpdate() async -> NetworkComponentResponse {
        suppressUpdateResume = true
        resumeAfterUpdate = false
        UserDefaults.standard.removeObject(forKey: "resumeFilterAfterComponentUpdate")
        if updateStopTask == nil {
            let preparation = preparationTask
            updateStopTask = Task {
                defer { updateStopTask = nil }
                // 准备失败也要执行用户的停用意图，不能由失败回退重新启用。
                _ = await preparation?.result
                try await manager.setFilterEnabled(false)
                enabled = false
                message = tr("尚未启用")
                UserDefaults.standard.removeObject(forKey: "resumeFilterAfterComponentUpdate")
            }
        }
        do { try await updateStopTask?.value; return .init() }
        catch { return .init(error: error.localizedDescription) }
    }
    private func registerControl() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while true {
            do { try await manager.register(endpoint: listener.endpoint); return }
            catch {
                manager.stopReading()
                guard clock.now < deadline else { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    func checkUpdates() { driver?.check(userInitiated: true) }
    func cancelUpdate() { driver?.cancel() }
    func installUpdate() { if let release { driver?.check(userInitiated: true, action: .install(release)) } }
    var updateAvailable: Bool { release != nil }
    var updateVersion: String? { release?.version }
    var installationPending: Bool { driver?.hasInstallationRequest == true }
    func prepareForTermination() async throws {
        try await driver?.waitForInstallationPreparation()
        try await updateStopTask?.value
    }
}

private final class ComponentListener: NSObject, NSXPCListenerDelegate {
    private weak var controller: ComponentController?
    private let requirement: String
    init(controller: ComponentController, requirement: String) { self.controller = controller; self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let controller else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: NetworkComponentService.self)
        connection.exportedObject = controller
        connection.resume()
        return true
    }
}

private struct ComponentView: View {
    @Bindable var controller: ComponentController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(tr("网络监视器"), systemImage: "network").font(.title2.bold())
            Text(controller.message).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button(tr("启用连接查看")) { Task { await controller.run("enable") } }
                Button(tr("停止查看")) { Task { await controller.run("disable") } }
            }.disabled(controller.busy)
            Divider()
            Button(tr("检查更新")) { controller.checkUpdates() }
            if let version = controller.updateVersion { Text(verbatim: version).font(.headline) }
            if controller.updateAvailable, controller.phase == .available { Button(tr("一键安装")) { controller.installUpdate() } }
            if controller.phase == .checking { Text(tr("正在检查更新")).foregroundStyle(.secondary) }
            if controller.phase == .upToDate { Text(tr("已是最新版本")).foregroundStyle(.secondary) }
            if case .downloading(let progress) = controller.phase {
                ProgressView(value: progress)
                Button(tr("取消")) { controller.cancelUpdate() }
            }
            if case .failed(let error) = controller.phase { Text(error).foregroundStyle(.red) }
            Button(tr("移除网络扩展")) { Task { await controller.run("uninstall") } }
        }.padding(24).frame(width: 400).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor private final class ComponentAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = ComponentController()
    private var window: NSWindow?
    private var terminationPrepared = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        if !CommandLine.arguments.contains("--activate") { showWindow() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { Task { await controller.bootstrap() }; showWindow(); return true }
    private func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 448, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = tr("网络监视器")
            window.contentView = NSHostingView(rootView: ComponentView(controller: controller))
            window.isReleasedWhenClosed = false; window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.installationPending, !terminationPrepared else { return .terminateNow }
        Task {
            do { try await controller.prepareForTermination(); terminationPrepared = true; sender.reply(toApplicationShouldTerminate: true) }
            catch { sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}

let app = NSApplication.shared
private let delegate = ComponentAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
