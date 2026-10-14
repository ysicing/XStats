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
        let configuration = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any]
        let listener = NSXPCListener(machServiceName: configuration?["NEMachServiceName"] as? String ?? "")
        guard let team = try? NetworkCodeIdentity.currentTeam() else {
            fatalError("Network observation requires a signed system extension")
        }
        return ObservationServiceHost(listener: listener,
            requiredClientCode: "anchor apple generic and (identifier \"work.12306.xstats.app\" or identifier \"work.12306.xstats.networkmonitor\") and certificate leaf[subject.OU] = \"\(team)\"")
    }()
    private let buffer = ConnectionFilterProvider.host.buffer
    private let lifecycleLock = NSLock()
    private var generation = 0
    private var lifecycle: FilterSettingsLifecycle?
    private static let logger = Logger(subsystem: "work.12306.xstats.app.networkextension", category: "ObservationDemand")

    private var settingsLifecycle: FilterSettingsLifecycle {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        if let lifecycle { return lifecycle }
        let lifecycle = FilterSettingsLifecycle(apply: { [weak self] observing, completion in
            guard let self else { completion(CancellationError()); return }
            let rules: [NEFilterRule]
            if observing { rules = [] }
            else {
                // SDK 要求 defaultAction.allow 至少一条规则；nil 两端匹配任意非 loopback 流，
                // loopback 默认已是 allow，IPv4/IPv6 与 TCP/UDP 都不应再调入 handleNewFlow。
                let any = NENetworkRule(remoteNetworkEndpoint: nil, remotePrefix: 0,
                                        localNetworkEndpoint: nil, localPrefix: 0, protocol: .any, direction: .any)
                rules = [NEFilterRule(networkRule: any, action: .allow)]
            }
            self.apply(NEFilterSettings(rules: rules, defaultAction: observing ? .filterData : .allow)) { error in
                Self.logger.notice("Settings filterData=\(observing) success=\(error == nil)")
                completion(error)
            }
        }, onError: { generation, observing, error in
            let failure = error as NSError
            Self.logger.error("Settings failed generation=\(generation) filterData=\(observing) code=\(failure.code)")
        }, onResult: { generation, requestID, observing, error in
            Self.host.recordSettingsResult(generation: generation, requestID: requestID, observing: observing, error: error)
        })
        self.lifecycle = lifecycle
        return lifecycle
    }

    override func startFilter(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        Self.logger.notice("Filter starting")
        let settings = settingsLifecycle
        let current = Self.host.startFilter(demandChanged: { settings.setDemand($0) })
        lifecycleLock.lock(); generation = current; lifecycleLock.unlock()
        settings.start(generation: current) { error in
            if error != nil { Self.host.beginStoppingFilter(generation: current) }
            completionHandler(error)
            if error != nil { Self.host.finishStoppingFilter(generation: current) }
        }
        settings.setDemand(Self.host.currentDemand)
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping @Sendable () -> Void) {
        Self.logger.notice("Filter stopping reason=\(reason.rawValue)")
        lifecycleLock.lock(); let current = generation; lifecycleLock.unlock()
        Self.host.beginStoppingFilter(generation: current)
        settingsLifecycle.stop(generation: current) {
            completionHandler()
            Self.host.finishStoppingFilter(generation: current)
        }
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // 单次租约截止停止记录并申请还原 allow；GUI 崩溃后不依赖界面清理。
        guard buffer.isObserving(countNewFlow: true), let socket = flow as? NEFilterSocketFlow else { return .allow() }
        let pid = socket.sourceAppAuditToken.flatMap { data -> Int32? in
            guard data.count >= 32 else { return nil }
            return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: Int32.self) }
        } ?? 0
        let endpoint: (String?, UInt16?)
        if case let .hostPort(host, port) = socket.remoteFlowEndpoint {
            endpoint = (String(describing: host).split(separator: "%").first.map(String.init), port.rawValue)
        } else {
            endpoint = (nil, nil)
        }
        let address = ["0.0.0.0", "::", ""].contains(endpoint.0 ?? "") ? nil : endpoint.0
        let hostname = socket.remoteHostname.flatMap { value in
            value.isEmpty || value.hasSuffix(".in-addr.arpa") || value.hasSuffix(".ip6.arpa") ? nil : value
        }
        var path = [CChar](repeating: 0, count: 4096)
        let length = pid > 0 ? proc_pidpath(pid, &path, UInt32(path.count)) : 0
        let executable = length > 0 ? String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        let transport: ConnectionTransport = socket.socketProtocol == IPPROTO_TCP ? .tcp
            : socket.socketProtocol == IPPROTO_UDP ? .udp : .other
        buffer.record(ObservedConnection(id: flow.identifier, timestamp: Date(), processID: pid,
                                        executablePath: executable, address: address, hostname: hostname,
                                        port: endpoint.1, transport: transport,
                                        direction: flow.direction == .outbound ? .outbound : .inbound))
        let verdict = NEFilterNewFlowVerdict.allow()
        // macOS 为 socket 的 allow verdict 投递结束报告；无需查看或缓存通信数据。
        verdict.shouldReport = true
        return verdict
    }

    override func handle(_ report: NEFilterReport) {
        guard report.event == .flowClosed, let flow = report.flow else { return }
        buffer.close(flow.identifier)
    }

}
