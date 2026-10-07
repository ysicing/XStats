// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Foundation
import Localization
import NetworkObservation
import Observation
import SwiftUI

/// 手动 GUI 仅是控制客户端；过滤与 Sparkle 的唯一拥有者始终是按需 agent。
@MainActor @Observable private final class ComponentGUIModel: NSObject, NetworkComponentClientService {
    var message = tr("尚未启用")
    var status: NetworkComponentStatus?
    private var calls = 0
    var busy: Bool { calls > 0 }
    private var connection: NSXPCConnection?

    func initialize() async {
        do {
            try await ComponentRegistration.ensureRegistered()
            guard ComponentRegistration.status != .requiresApproval else { throw NetworkMonitorError.backgroundApproval }
            await run("status")
        }
        catch { message = error.localizedDescription }
    }
    func run(_ command: String) async {
        calls += 1
        defer { calls -= 1 }
        do {
            let peer = try ensureConnection()
            let reply = NetworkMonitorReply()
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                reply.finish(.failure(NetworkMonitorError.timeout))
            }
            defer { timeout.cancel() }
            let data = try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                guard let proxy = peer.remoteObjectProxyWithErrorHandler({ @Sendable error in reply.finish(.failure(error)) }) as? NetworkComponentService else {
                    reply.finish(.failure(NetworkMonitorError.unavailable)); return
                }
                proxy.perform(command) { @Sendable data in reply.finish(.success(data)) }
            }
            guard data.count <= 256 * 1024 else { throw NetworkMonitorError.protocolMismatch }
            let response = try JSONDecoder().decode(NetworkComponentResponse.self, from: data)
            guard response.protocolVersion == NetworkObservationProtocol.version else { throw NetworkMonitorError.protocolMismatch }
            status = response.status
            if let error = response.error { message = tr(error) }
            else if response.needsRestart { message = tr("需要重启系统") }
            else { message = statusMessage }
        } catch { message = error.localizedDescription }
    }
    private var statusMessage: String {
        if status?.needsSystemApproval == true, status?.filterEnabled != true { return tr("等待系统授权") }
        return status?.filterEnabled == true ? tr("正在监视") : tr("尚未启用")
    }
    private func ensureConnection() throws -> NSXPCConnection {
        if let connection { return connection }
        let team = try NetworkCodeIdentity.currentTeam()
        let candidate = NSXPCConnection(machServiceName: NetworkObservationProtocol.controlServiceName(team: team), options: [])
        candidate.setCodeSigningRequirement("anchor apple generic and identifier \"work.12306.xstats.networkmonitor\" and certificate leaf[subject.OU] = \"\(team)\"")
        candidate.remoteObjectInterface = NSXPCInterface(with: NetworkComponentService.self)
        candidate.exportedInterface = NSXPCInterface(with: NetworkComponentClientService.self)
        candidate.exportedObject = self
        let identity = ObjectIdentifier(candidate)
        let clear: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, let current = self.connection, ObjectIdentifier(current) == identity else { return }
                current.invalidate(); self.connection = nil
            }
        }
        candidate.invalidationHandler = clear; candidate.interruptionHandler = clear
        candidate.resume(); connection = candidate
        return candidate
    }
    nonisolated func needsSystemApproval() { Task { @MainActor in message = tr("等待系统授权") } }
    nonisolated func componentStatusChanged(_ data: Data) {
        guard data.count <= 256 * 1024, let value = try? JSONDecoder().decode(NetworkComponentStatus.self, from: data) else { return }
        Task { @MainActor in
            status = value
            // 请求超时后服务仍可能完成授权与启用；空闲时按推送状态刷新文字，进行中的请求由其回复决定提示。
            if calls == 0 { message = statusMessage }
        }
    }
}

private struct ComponentView: View {
    @Bindable var model: ComponentGUIModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(tr("网络监视器"), systemImage: "network").font(.title2.bold())
            Text(model.message).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button(tr("启用连接查看")) { Task { await model.run("enable") } }.disabled(model.busy)
                Button(tr("停止查看")) { Task { await model.run("disable") } }
            }
            Divider()
            Button(tr("检查更新")) { Task { await model.run("checkUpdates") } }.disabled(model.busy)
            if let update = model.status?.update {
                if let version = update.version { Text(verbatim: version).font(.headline) }
                if update.phase == .available { Button(tr("一键安装")) { Task { await model.run("installUpdate") } } }
                if update.phase == .checking { Text(tr("正在检查更新")).foregroundStyle(.secondary) }
                if update.phase == .upToDate { Text(tr("已是最新版本")).foregroundStyle(.secondary) }
                if update.phase == .downloading {
                    ProgressView(value: update.progress ?? 0)
                    Button(tr("取消")) { Task { await model.run("cancelUpdate") } }
                }
                if let error = update.error { Text(tr(error)).foregroundStyle(.red) }
            }
            Button(tr("移除网络扩展")) { Task { await model.run("uninstall") } }
        }.padding(24).frame(width: 400).fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor private final class ComponentAppDelegate: NSObject, NSApplicationDelegate {
    private let serviceMode = CommandLine.arguments.contains("--service")
    private var host: NetworkComponentServiceHost?
    private var model: ComponentGUIModel?
    private var window: NSWindow?
    private var terminationPrepared = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if serviceMode {
            let host = NetworkComponentServiceHost()
            do { try host.start(); self.host = host }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); NSApp.terminate(nil) }
        } else {
            UserDefaults.standard.synchronize()
            if let previous = UserDefaults.standard.string(forKey: NetworkComponentServiceHost.relaunchKey),
               previous != Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
                Task {
                    do { try await ComponentRegistration.ensureRegistered() }
                    catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)) }
                    UserDefaults.standard.removeObject(forKey: NetworkComponentServiceHost.relaunchKey)
                    UserDefaults.standard.synchronize()
                    NSApp.terminate(nil)
                }
                return
            }
            let model = ComponentGUIModel(); self.model = model
            showWindow()
            Task { await model.initialize() }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !serviceMode else { return false }
        showWindow(); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !serviceMode }
    private func showWindow() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 448, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = tr("网络监视器")
            window.contentView = NSHostingView(rootView: ComponentView(model: model)
                .environment(\.locale, L10n.locale)
                .environment(\.layoutDirection, L10n.language.isRightToLeft ? .rightToLeft : .leftToRight))
            window.isReleasedWhenClosed = false; window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let host, host.installationPending, !terminationPrepared else { return .terminateNow }
        Task {
            do { try await host.prepareForTermination(); terminationPrepared = true; sender.reply(toApplicationShouldTerminate: true) }
            catch { sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
}

let arguments = CommandLine.arguments
let registrationMode = arguments.contains("--register-service") || arguments.contains("--refresh-service") || arguments.contains("--unregister-service")
// 服务/CLI 输出源文案键；只有独立 GUI 在此处决定显示语言，所有初始化文案都在配置之后创建。
L10n.configure(arguments.contains("--service") || registrationMode
    ? NetworkComponentLocalization.transportLanguage : NetworkComponentLocalization.applicationLanguage)
if registrationMode {
    // 无 GUI、无监听器、无 NE/更新副作用；主应用在后台执行这条短命令并读取 JSON。
    Task {
        var failure: String?
        do {
            if arguments.contains("--unregister-service") { try await ComponentRegistration.unregister() }
            else { try await ComponentRegistration.ensureRegistered(forceRefresh: arguments.contains("--refresh-service")) }
        } catch { failure = error.localizedDescription }
        let result = ComponentRegistrationResult(error: failure)
        if let data = try? JSONEncoder().encode(result) { FileHandle.standardOutput.write(data + Data([10])) }
        exit(failure == nil ? 0 : 1)
    }
    dispatchMain()
} else {
    let app = NSApplication.shared
    let delegate = ComponentAppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(arguments.contains("--service") ? .prohibited : .accessory)
    app.run()
}
