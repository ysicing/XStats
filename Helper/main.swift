//
//  XStatsHelper
//
//  以 root 运行的辅助工具，由 SMAppService.daemon 注册。
//  只做固定的几件事：设置风扇转速、切换“合盖不睡眠”、刷新 DNS、释放内存、设置 DNS 服务器，
//  并在客户端断开时恢复风扇与睡眠设置。
//

import Foundation
import HelperShared
import os
import SMC

/// 写入系统统一日志，应用“导出诊断信息”时一并收集
private let log = Logger(subsystem: "work.12306.xstats.helper", category: "helper")

final class HelperService: NSObject, NSXPCListenerDelegate, XStatsHelperProtocol, @unchecked Sendable {
    /// 所有可变状态只在该队列上访问
    private let queue = DispatchQueue(label: "work.12306.xstats.helper.state")
    private let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
    private let stateURL = URL(fileURLWithPath: "/Library/Application Support/XStats/helper-state.plist")
    private let idleTimeout: TimeInterval = 30
    /// 只接受与辅助工具自身同一团队签名的调用方
    private let clientRequirement = HelperConstants.clientRequirement(teamIdentifier: CodeSigningInfo.currentTeamIdentifier())

    private var connections: Set<ObjectIdentifier> = []
    private var fans: FanControl?
    private var manualFans: Set<Int> = []
    private var sleepDisabledByHelper = false
    private var idleExit: DispatchWorkItem?

    func run() {
        log.notice("辅助工具启动，协议版本 \(HelperConstants.protocolVersion)")
        queue.sync {
            fans = (try? SMCConnection()).map(FanControl.init)
            if fans == nil { log.error("无法打开 SMC") }
            recoverFromPreviousRun()
            scheduleIdleExit()
        }
        listener.delegate = self
        listener.resume()
        dispatchMain()
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // 系统在收到消息前校验调用方签名，不符合要求的连接会被直接失效
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: XStatsHelperProtocol.self)
        connection.exportedObject = self

        let id = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.queue.async { self.connectionClosed(id) }
        }
        queue.sync {
            connections.insert(id)
            idleExit?.cancel()
        }
        connection.resume()
        return true
    }

    // MARK: XStatsHelperProtocol

    func protocolVersion(reply: @escaping @Sendable (Int) -> Void) {
        reply(HelperConstants.protocolVersion)
    }

    func setFanTarget(fan: Int, rpm: Double, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard let fans else { return reply("无法访问 SMC") }
            guard (0..<fans.fanCount).contains(fan), rpm.isFinite, rpm > 0 else { return reply("无效的风扇参数") }
            do {
                try fans.setManual(fan: fan, rpm: rpm)
                manualFans.insert(fan)
                reply(nil)
            } catch {
                log.error("设置风扇 \(fan) 失败：\(String(describing: error), privacy: .public)")
                reply("设置风扇失败：\(error)")
            }
        }
    }

    func setFanAutomatic(fan: Int, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard let fans else { return reply("无法访问 SMC") }
            guard (0..<fans.fanCount).contains(fan) else { return reply("无效的风扇编号") }
            do {
                try fans.setAutomatic(fan: fan)
                manualFans.remove(fan)
                reply(nil)
            } catch {
                log.error("恢复风扇 \(fan) 失败：\(String(describing: error), privacy: .public)")
                reply("恢复风扇失败：\(error)")
            }
        }
    }

    func resetAllFans(reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            reply(resetFans())
        }
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            reply(applySleepDisabled(disabled))
        }
    }

    func flushDNSCache(reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in reply(run(.flushDNS)) }
    }

    func purgeMemory(reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in reply(run(.purgeMemory)) }
    }

    func setDNSServers(service: String, servers: [String], reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard DNSConfiguration.isValidServiceName(service), servers.count <= DNSConfiguration.maxServers,
                  servers.allSatisfy(DNSConfiguration.isValidAddress) else { return reply("无效的 DNS 参数") }
            // 服务名必须是系统里已有的网络服务
            let list = runTool("/usr/sbin/networksetup", ["-listallnetworkservices"])
            let names = list.output.split(whereSeparator: \.isNewline).dropFirst()
                .map { $0.hasPrefix("*") ? String($0.dropFirst()) : String($0) }
            guard list.status == 0, names.contains(service) else { return reply("找不到网络服务“\(service)”") }

            let result = runTool("/usr/sbin/networksetup", DNSConfiguration.networksetupArguments(service: service, servers: servers))
            guard result.status == 0 else {
                log.error("networksetup 失败：\(result.output, privacy: .public)")
                return reply("networksetup 执行失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            reply(run(.flushDNS))
        }
    }

    func deleteLocalSnapshots(identifiers: [String], reply: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard !identifiers.isEmpty, identifiers.count <= LocalSnapshotCommand.maxCount,
                  identifiers.allSatisfy(LocalSnapshotCommand.isValidIdentifier) else { return reply("无效的快照标识") }
            for identifier in identifiers {
                let result = runTool(LocalSnapshotCommand.tool, LocalSnapshotCommand.arguments(identifier: identifier))
                guard result.status == 0 else {
                    log.error("删除快照失败：\(result.output, privacy: .public)")
                    return reply("tmutil 执行失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
            log.notice("已删除 \(identifiers.count) 个本地快照")
            reply(nil)
        }
    }

    // MARK: 状态恢复

    private func connectionClosed(_ id: ObjectIdentifier) {
        connections.remove(id)
        guard connections.isEmpty else { return }
        // 应用已退出或崩溃：把系统恢复到默认状态
        log.info("客户端全部断开，恢复风扇与睡眠设置")
        _ = resetFans()
        if sleepDisabledByHelper { _ = applySleepDisabled(false) }
        scheduleIdleExit()
    }

    private func recoverFromPreviousRun() {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? PropertyListDecoder().decode(PersistedState.self, from: data) else { return }
        log.notice("上次异常退出，恢复风扇与睡眠设置")
        if state.sleepDisabled {
            sleepDisabledByHelper = true
            _ = applySleepDisabled(false)
        }
        if state.fansOverridden { _ = resetFans() }
    }

    private func scheduleIdleExit() {
        idleExit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.connections.isEmpty else { return }
            log.info("空闲退出")
            exit(0)
        }
        idleExit = work
        queue.asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }

    // MARK: 风扇

    private func resetFans() -> String? {
        guard let fans else { return manualFans.isEmpty ? nil : "无法访问 SMC" }
        do {
            try fans.resetAll()
            manualFans.removeAll()
            persist()
            return nil
        } catch {
            return "恢复风扇失败：\(error)"
        }
    }

    // MARK: 睡眠

    private func applySleepDisabled(_ disabled: Bool) -> String? {
        let result = runTool("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
        guard result.status == 0 else {
            return "pmset 执行失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        sleepDisabledByHelper = disabled
        persist()
        return nil
    }

    // MARK: 系统维护

    private func run(_ command: MaintenanceCommand) -> String? {
        for step in command.steps {
            let result = runTool(step.path, step.arguments)
            // killall 在 mDNSResponder 恰好重启时可能返回非 0，不视为失败
            if result.status != 0, step.path != "/usr/bin/killall" {
                return "\((step.path as NSString).lastPathComponent) 执行失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
        }
        return nil
    }

    private func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    // MARK: 持久化

    private struct PersistedState: Codable {
        var sleepDisabled: Bool
        var fansOverridden: Bool
    }

    private func persist() {
        let state = PersistedState(sleepDisabled: sleepDisabledByHelper, fansOverridden: !manualFans.isEmpty)
        guard state.sleepDisabled || state.fansOverridden else {
            try? FileManager.default.removeItem(at: stateURL)
            return
        }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PropertyListEncoder().encode(state).write(to: stateURL, options: .atomic)
    }
}

HelperService().run()
