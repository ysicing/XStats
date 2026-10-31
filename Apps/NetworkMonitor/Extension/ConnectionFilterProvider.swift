// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Network
import NetworkExtension
import NetworkObservation
import OSLog

/// filterData 设置仅请求新流元数据回调；任何状态/错误均给 allow verdict，不请求通信内容。
final class ConnectionFilterProvider: NEFilterDataProvider, @unchecked Sendable {
  // 监听服务与扩展进程同寿命，停用过滤器后仍可确认 stopFilter 已完成。
  static let host: ObservationServiceHost = {
    let configuration =
      Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any]
    let listener = NSXPCListener(
      machServiceName: configuration?["NEMachServiceName"] as? String ?? "")
    guard let team = try? NetworkCodeIdentity.currentTeam() else {
      fatalError("Network observation requires a signed system extension")
    }
    return ObservationServiceHost(
      listener: listener,
      requiredClientCode:
        "anchor apple generic and (identifier \"work.12306.xstats.app\" or identifier \"work.12306.xstats.networkmonitor\") and certificate leaf[subject.OU] = \"\(team)\""
    )
  }()
  private let buffer = ConnectionFilterProvider.host.buffer
  private let lifecycleLock = NSLock()
  private var generation = 0
  private var lifecycle: FilterSettingsLifecycle?
  // 单次状态/判决更新串行；批量切换在每条流之间释放锁，不能阻塞新连接或悄悄丢弃。
  private let trafficLock = NSLock()
  private var reportingEnabled = false
  private var reportingRevision: UInt64 = 0
  private var reportingFlows: [UUID: NEFilterSocketFlow] = [:]
  private static let logger = Logger(
    subsystem: "work.12306.xstats.app.networkextension", category: "ObservationDemand")

  private var settingsLifecycle: FilterSettingsLifecycle {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    if let lifecycle { return lifecycle }
    let lifecycle = FilterSettingsLifecycle(
      apply: { [weak self] observing, completion in
        guard let self else {
          completion(CancellationError())
          return
        }
        let rules: [NEFilterRule]
        if observing {
          rules = []
        } else {
          // SDK 要求 defaultAction.allow 至少一条规则；nil 两端匹配任意非 loopback 流，
          // loopback 默认已是 allow，IPv4/IPv6 与 TCP/UDP 都不应再调入 handleNewFlow。
          let any = NENetworkRule(
            remoteNetworkEndpoint: nil, remotePrefix: 0,
            localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .any)
          rules = [NEFilterRule(networkRule: any, action: .allow)]
        }
        self.apply(NEFilterSettings(rules: rules, defaultAction: observing ? .filterData : .allow))
        { error in
          self.setTrafficReporting(observing && error == nil)
          Self.logger.notice("Settings filterData=\(observing) success=\(error == nil)")
          completion(error)
        }
      },
      onError: { generation, observing, error in
        let failure = error as NSError
        Self.logger.error(
          "Settings failed generation=\(generation) filterData=\(observing) code=\(failure.code)")
      },
      onResult: { generation, requestID, observing, error in
        Self.host.recordSettingsResult(
          generation: generation, requestID: requestID, observing: observing, error: error)
      })
    self.lifecycle = lifecycle
    return lifecycle
  }

  override func startFilter(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
    Self.logger.notice("Filter starting")
    let settings = settingsLifecycle
    let current = Self.host.startFilter(demandChanged: { settings.setDemand($0) })
    lifecycleLock.lock()
    generation = current
    lifecycleLock.unlock()
    settings.start(generation: current) { error in
      if error != nil { Self.host.beginStoppingFilter(generation: current) }
      completionHandler(error)
      if error != nil { Self.host.finishStoppingFilter(generation: current) }
    }
    settings.setDemand(Self.host.currentDemand)
  }

  override func stopFilter(
    with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void
  ) {
    Self.logger.notice("Filter stopping reason=\(reason.rawValue)")
    lifecycleLock.lock()
    let current = generation
    lifecycleLock.unlock()
    Self.host.beginStoppingFilter(generation: current)
    settingsLifecycle.stop(generation: current) {
      self.trafficLock.lock()
      self.reportingFlows.removeAll(keepingCapacity: true)
      self.reportingEnabled = false
      self.reportingRevision &+= 1
      self.trafficLock.unlock()
      completionHandler()
      Self.host.finishStoppingFilter(generation: current)
    }
  }

  override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
    // 单次租约截止停止记录并申请还原 allow；GUI 崩溃后不依赖界面清理。
    guard buffer.isObserving(countNewFlow: true), let socket = flow as? NEFilterSocketFlow else {
      return .allow()
    }
    let pid =
      socket.sourceAppAuditToken.flatMap { data -> Int32? in
        guard data.count >= 32 else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: Int32.self) }
      } ?? 0
    let endpoint: (String?, UInt16?)
    if case .hostPort(let host, let port) = socket.remoteFlowEndpoint {
      endpoint = (
        String(describing: host).split(separator: "%").first.map(String.init), port.rawValue
      )
    } else {
      endpoint = (nil, nil)
    }
    let address = ["0.0.0.0", "::", ""].contains(endpoint.0 ?? "") ? nil : endpoint.0
    let hostname = socket.remoteHostname.flatMap { value in
      value.isEmpty || value.hasSuffix(".in-addr.arpa") || value.hasSuffix(".ip6.arpa")
        ? nil : value
    }
    var path = [CChar](repeating: 0, count: 4096)
    let length = pid > 0 ? proc_pidpath(pid, &path, UInt32(path.count)) : 0
    let executable =
      length > 0
      ? String(
        decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
    let transport: ConnectionTransport =
      socket.socketProtocol == IPPROTO_TCP
      ? .tcp
      : socket.socketProtocol == IPPROTO_UDP ? .udp : .other
    // 采集登记必须原子完成，不能因列表换页或锁竞争丢掉仍活动的连接。
    trafficLock.lock()
    defer { trafficLock.unlock() }
    let recorded = buffer.record(
      ObservedConnection(
        id: flow.identifier, timestamp: Date(), processID: pid,
        executablePath: executable, address: address, hostname: hostname,
        port: endpoint.1, transport: transport,
        direction: flow.direction == .outbound ? .outbound : .inbound))
    guard recorded else { return .allow() }
    let verdict = NEFilterNewFlowVerdict.allow()
    // macOS 为 socket 的 allow verdict 投递结束报告；无需查看或缓存通信数据。
    verdict.shouldReport = true
    reportingFlows[flow.identifier] = socket
    // 返回 verdict 由系统在回调返回后应用；初始低频报告避免旧 none 覆盖恢复操作。
    // 暂停后的尾部报告在核对当前状态后停报。
    verdict.statisticsReportFrequency = .low
    return verdict
  }

  override func handle(_ report: NEFilterReport) {
    guard let flow = report.flow else { return }
    if report.event == .flowClosed {
      buffer.close(
        flow.identifier, receivedBytes: UInt64(report.bytesInboundCount),
        sentBytes: UInt64(report.bytesOutboundCount))
      trafficLock.lock()
      reportingFlows.removeValue(forKey: flow.identifier)
      trafficLock.unlock()
    } else if report.event == .statistics {
      guard let socket = flow as? NEFilterSocketFlow else { return }
      trafficLock.lock()
      defer { trafficLock.unlock() }
      guard let observing = buffer.trafficDemand() else { return }
      guard observing, reportingEnabled, reportingFlows[flow.identifier] != nil else {
        updateTrafficReporting(socket, enabled: false)
        return
      }
      buffer.updateTraffic(
        flow.identifier, receivedBytes: UInt64(report.bytesInboundCount),
        sentBytes: UInt64(report.bytesOutboundCount))
    }
  }

  /// 已放行的长连接也要跟随观察需求停报；只保留有界 socket 引用，不请求数据回调。
  private func setTrafficReporting(_ enabled: Bool) {
    trafficLock.lock()
    reportingEnabled = enabled
    reportingRevision &+= 1
    let revision = reportingRevision
    let flows = Array(reportingFlows.values)
    trafficLock.unlock()
    for flow in flows {
      trafficLock.lock()
      if reportingRevision == revision, reportingFlows[flow.identifier] != nil {
        updateTrafficReporting(flow, enabled: enabled)
      }
      trafficLock.unlock()
    }
  }

  private func updateTrafficReporting(_ flow: NEFilterSocketFlow, enabled: Bool) {
    let verdict = NEFilterDataVerdict.allow()
    verdict.shouldReport = true
    verdict.statisticsReportFrequency = enabled ? .low : .none
    update(flow, using: verdict, for: .any)
  }
}
