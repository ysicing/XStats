// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

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

final class HelperService: NSObject, NSXPCListenerDelegate, XStatsHelperProtocol,
  @unchecked Sendable
{
  /// 所有可变状态只在该队列上访问
  private let queue = DispatchQueue(label: "work.12306.xstats.helper.state")
  // 磁盘/网络维护不得占住风扇与断连恢复使用的状态队列。
  private let maintenanceQueue = DispatchQueue(label: "work.12306.xstats.helper.maintenance")
  private var activeMaintenance = 0
  private let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
  private let stateURL = URL(
    fileURLWithPath: "/Library/Application Support/XStats/helper-state.plist")
  private let idleTimeout: TimeInterval = 30
  /// 只接受与辅助工具自身同一团队签名的调用方
  private let clientRequirement = HelperConstants.clientRequirement(
    teamIdentifier: CodeSigningInfo.currentTeamIdentifier())

  private var connections: Set<ObjectIdentifier> = []
  private var fans: FanControl?
  private var recoveryState = HelperRecoveryState()
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

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection)
    -> Bool
  {
    // 没有团队签名（ad-hoc 开发构建）时无法安全鉴别调用方，一律拒绝服务。
    // 客户端禁用安装与风扇/合盖控制；支持回退的维护操作走一次性管理员授权。
    guard let clientRequirement else {
      log.error("辅助工具未经团队签名，拒绝 XPC 连接")
      return false
    }
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
      // 读取失败不等于零个风扇，不能把硬件访问故障报告为调用参数错误。
      guard let count = fans.detectedFanCount else { return reply("无法访问 SMC") }
      guard (0..<count).contains(fan), rpm.isFinite, rpm > 0 else {
        return reply("无效的风扇参数")
      }
      do {
        // 写入可能部分生效后抛错；先落盘意图，断连或异常重启仍能恢复。
        recoveryState.recordFanOverride(fan)
        persist()
        try fans.setManual(fan: fan, rpm: rpm)
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
      // 读取失败不等于零个风扇，不能把硬件访问故障报告为调用参数错误。
      guard let count = fans.detectedFanCount else { return reply("无法访问 SMC") }
      guard (0..<count).contains(fan) else { return reply("无效的风扇编号") }
      do {
        try fans.setAutomatic(fan: fan)
        recoveryState.recordFanRestored(fan)
        persist()
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
    performMaintenance { [self] in reply(run(.flushDNS)) }
  }

  func purgeMemory(reply: @escaping @Sendable (String?) -> Void) {
    performMaintenance { [self] in reply(run(.purgeMemory)) }
  }

  func setDNSServers(
    service: String, servers: [String], reply: @escaping @Sendable (String?) -> Void
  ) {
    performMaintenance { [self] in
      guard DNSConfiguration.isValidServiceName(service),
        servers.count <= DNSConfiguration.maxServers,
        servers.allSatisfy(DNSConfiguration.isValidAddress)
      else { return reply("无效的 DNS 参数") }
      // 服务名必须是系统里已有的网络服务
      let list = runTool("/usr/sbin/networksetup", ["-listallnetworkservices"])
      let names = list.output.split(whereSeparator: \.isNewline).dropFirst()
        .map { $0.hasPrefix("*") ? String($0.dropFirst()) : String($0) }
      guard list.status == 0, names.contains(service) else { return reply("找不到网络服务“\(service)”") }

      let result = runTool(
        "/usr/sbin/networksetup",
        DNSConfiguration.networksetupArguments(service: service, servers: servers))
      guard result.status == 0 else {
        log.error("networksetup 失败：\(result.output, privacy: .public)")
        return reply(
          "networksetup 执行失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
      }
      reply(run(.flushDNS))
    }
  }

  func deleteLocalSnapshots(identifiers: [String], reply: @escaping @Sendable (String?) -> Void) {
    performMaintenance { [self] in
      guard !identifiers.isEmpty, identifiers.count <= LocalSnapshotCommand.maxCount,
        identifiers.allSatisfy(LocalSnapshotCommand.isValidIdentifier)
      else { return reply("无效的快照标识") }
      for identifier in identifiers {
        let result = runTool(
          LocalSnapshotCommand.tool, LocalSnapshotCommand.arguments(identifier: identifier),
          timeout: 120)
        guard result.status == 0 else {
          log.error("删除快照失败：\(result.output, privacy: .public)")
          return reply(
            "tmutil 执行失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
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
    if let error = resetFans() { log.error("恢复风扇失败：\(error, privacy: .public)") }
    if recoveryState.sleepDisabled { _ = applySleepDisabled(false) }
    scheduleIdleExit()
  }

  private func recoverFromPreviousRun() {
    // /Library/Application Support 对 admin 组可写；拒绝符号链接，避免跟随到其他文件。
    var information = stat()
    guard stateURL.path.withCString({ lstat($0, &information) }) == 0,
      information.st_mode & S_IFMT != S_IFLNK
    else { return }
    guard let data = try? Data(contentsOf: stateURL),
      let state = try? PropertyListDecoder().decode(HelperRecoveryState.self, from: data)
    else { return }
    log.notice("上次异常退出，恢复风扇与睡眠设置")
    // 任一恢复都会持久化当前状态，必须先完整接回所有未恢复标记。
    recoveryState = state
    if state.sleepDisabled {
      _ = applySleepDisabled(false)
    }
    if state.fansOverridden { _ = resetFans() }
  }

  private func scheduleIdleExit() {
    idleExit?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.connections.isEmpty, self.activeMaintenance == 0 else { return }
      log.info("空闲退出")
      exit(0)
    }
    idleExit = work
    queue.asyncAfter(deadline: .now() + idleTimeout, execute: work)
  }

  // MARK: 风扇

  private func resetFans() -> String? {
    guard let fans else { return recoveryState.fansOverridden ? "无法访问 SMC" : nil }
    do {
      try fans.resetAll()
      recoveryState.recordAllFansRestored()
      persist()
      return nil
    } catch {
      return "恢复风扇失败：\(error)"
    }
  }

  // MARK: 睡眠

  private func applySleepDisabled(_ disabled: Bool) -> String? {
    // 先记录接管意图：pmset 已生效但超时/退出异常时，也必须在断连后尝试恢复。
    if disabled {
      recoveryState.sleepDisabled = true
      persist()
    }
    let result = runTool(
      "/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"], timeout: 5)
    guard result.status == 0 else {
      return "pmset 执行失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    recoveryState.sleepDisabled = disabled
    persist()
    return nil
  }

  // MARK: 系统维护

  private func run(_ command: MaintenanceCommand) -> String? {
    for step in command.steps {
      let result = runTool(step.path, step.arguments)
      // killall 在 mDNSResponder 恰好重启时可能返回非 0，不视为失败
      if result.status != 0, step.path != "/usr/bin/killall" {
        return
          "\((step.path as NSString).lastPathComponent) 执行失败：\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
      }
    }
    return nil
  }

  private func performMaintenance(_ operation: @escaping @Sendable () -> Void) {
    queue.async { [self] in
      activeMaintenance += 1
      idleExit?.cancel()
      maintenanceQueue.async { [self] in
        operation()
        queue.async { [self] in
          activeMaintenance -= 1
          if connections.isEmpty { scheduleIdleExit() }
        }
      }
    }
  }

  private func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval = 30)
    -> (status: Int32, output: String)
  {
    let result = HelperToolRunner.run(path: path, arguments: arguments, timeout: timeout)
    if result.timedOut {
      log.error("辅助命令超时：\((path as NSString).lastPathComponent, privacy: .public)")
      return (-1, "ETIMEDOUT")
    }
    return (result.status, result.output)
  }

  // MARK: 持久化

  private func persist() {
    guard recoveryState.hasPendingRecovery else {
      try? FileManager.default.removeItem(at: stateURL)
      return
    }
    try? FileManager.default.createDirectory(
      at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? PropertyListEncoder().encode(recoveryState).write(to: stateURL, options: .atomic)
  }
}

HelperService().run()
