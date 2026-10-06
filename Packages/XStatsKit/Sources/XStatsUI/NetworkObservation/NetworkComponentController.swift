// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Foundation
import Localization
import NetworkObservation
import Observation

/// 主程序统一管理入口。检查调度来自主更新器，不创建组件后台计时器。
@MainActor @Observable final class NetworkComponentController {
    private(set) var status: NetworkComponentStatus?
    private(set) var installed = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var needsBackgroundApproval = false
    @ObservationIgnored private let backend: any NetworkMonitorBackend
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var viewerSuspendedForUpdate = false
    @ObservationIgnored private var activeCommand: String?
    @ObservationIgnored private var handoff: Task<Void, Never>?
    @ObservationIgnored var onPreparingUpdate: () -> Void = {}
    @ObservationIgnored var onUpdateFinished: () -> Void = {}
    @ObservationIgnored var onUninstalled: () -> Void = {}

    init(backend: any NetworkMonitorBackend) {
        self.backend = backend
        backend.onComponentStatus = { [weak self] in self?.accept($0) }
    }
    func refresh() {
        installed = FileManager.default.fileExists(atPath: NetworkComponentInstaller.componentURL.path)
        guard installed else { status = nil; error = nil; return }
        run("status")
    }
    func install() { run("status") }
    func checkUpdates(background: Bool = false) {
        guard FileManager.default.fileExists(atPath: NetworkComponentInstaller.componentURL.path) else { return }
        run(background ? "checkUpdatesBackground" : "checkUpdates", reportsError: !background)
    }
    func installUpdate() { run("installUpdate") }
    func cancelUpdate() { run("cancelUpdate") }
    func openBackgroundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    /// 系统扩展撤销完成后才删除固定组件包，用户偏好和连接历史不被批量清理。
    func uninstall() {
        guard operation == nil, handoff == nil else { return }
        busy = true; error = nil; activeCommand = "uninstall"
        operation = Task {
            defer { operation = nil; busy = false; activeCommand = nil }
            do {
                let response = try await backend.componentCommand("uninstall")
                guard !response.needsRestart else { throw NetworkMonitorError.restartRequired }
                _ = try await NetworkComponentInstaller.runCommand(
                    NetworkComponentInstaller.componentURL.appendingPathComponent("Contents/MacOS/XStats Network Monitor").path,
                    arguments: ["--unregister-service"], limit: 32 * 1024)
                try await Task.detached(priority: .utility) {
                    let app = NetworkComponentInstaller.componentURL
                    if FileManager.default.fileExists(atPath: app.path) { try FileManager.default.removeItem(at: app) }
                }.value
                status = nil; installed = false; onUninstalled()
            } catch { self.error = error.localizedDescription }
        }
    }
    var terminationRequiresPreparation: Bool { operation != nil || handoff != nil }
    func prepareForTermination() async {
        terminating = true
        // 已开始卸载的SDK/注销/删除事务必须串行收尾；其余准备可取消下载并等待临时文件清理。
        if activeCommand != "uninstall" {
            backend.cancelActivation()
            operation?.cancel()
        }
        await operation?.value
        handoff?.cancel()
        await handoff?.value
    }
    func cancelTermination() {
        terminating = false
        guard viewerSuspendedForUpdate, handoff == nil else { return }
        // 退出被拒绝后，继续验收尚未完成的组件替换；不能遗留主查看器的更新暂停状态。
        if let status, status.update.phase == .installing { accept(status) }
        else { viewerSuspendedForUpdate = false; onUpdateFinished() }
    }
    private func run(_ command: String, reportsError: Bool = true) {
        guard operation == nil else { return }
        busy = true; activeCommand = command
        if reportsError { error = nil; needsBackgroundApproval = false }
        operation = Task {
            defer { operation = nil; busy = false; activeCommand = nil }
            do {
                let response = try await backend.componentCommand(command)
                installed = true
                if let status = response.status { accept(status) }
                if response.needsRestart { throw NetworkMonitorError.restartRequired }
            } catch {
                // SDK接受安装后退出服务是正常handoff；进度推送已启动有界重连验收。
                if handoff == nil, reportsError {
                    self.error = error.localizedDescription
                    if let failure = error as? NetworkMonitorError, case .backgroundApproval = failure { needsBackgroundApproval = true }
                }
            }
        }
    }
    private func accept(_ status: NetworkComponentStatus) {
        self.status = status; installed = true
        if status.update.phase == .installing, handoff == nil {
            viewerSuspendedForUpdate = true
            onPreparingUpdate()
            handoff = Task {
                defer {
                    handoff = nil
                    if !terminating { viewerSuspendedForUpdate = false; onUpdateFinished() }
                }
                do {
                    let clock = ContinuousClock()
                    let deadline = clock.now.advanced(by: .seconds(120))
                    repeat {
                        try Task.checkCancellation()
                        do {
                            let metadata = try await NetworkComponentMetadata.load(at: NetworkComponentInstaller.componentURL)
                            if metadata.build != status.componentBuild || metadata.version != status.componentVersion {
                                let response = try await backend.componentCommand("status")
                                if let fresh = response.status,
                                   fresh.componentBuild == metadata.build, fresh.componentVersion == metadata.version {
                                    self.status = fresh
                                    return
                                }
                            }
                        } catch {
                            if error is CancellationError { throw error }
                            if let failure = error as? NetworkMonitorError {
                                switch failure { case .protocolMismatch, .backgroundApproval, .unsigned: throw error; default: break }
                            }
                            if let failure = error as? NetworkComponentInstallError, failure == .untrustedComponent { throw error }
                            // 替换目录、注销旧agent及launchd拉起之间存在暂态；在安装deadline内重试。
                        }
                        if self.status?.update.phase == .failed || self.status?.update.phase == .available { return }
                        try await Task.sleep(for: .seconds(1), tolerance: .milliseconds(200))
                    } while clock.now < deadline
                    throw NetworkMonitorError.timeout
                } catch is CancellationError {
                    // 退出准备取消验收不是组件安装失败，取消退出会恢复验收或解除暂停。
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
