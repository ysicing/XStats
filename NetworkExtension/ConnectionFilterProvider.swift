// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Network
import NetworkExtension
import NetworkObservation
import Security

/// 观察模式从不请求数据过滤或暂停：任何状态、任何错误路径都返回 allow。
final class ConnectionFilterProvider: NEFilterDataProvider, @unchecked Sendable {
    // 监听服务与扩展进程同寿命，停用过滤器后仍可确认 stopFilter 已完成。
    static let host: ObservationServiceHost = {
        let configuration = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any]
        let listener = NSXPCListener(machServiceName: configuration?["NEMachServiceName"] as? String ?? "")
        var ownCode: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else {
            fatalError("Network observation requires a signed system extension")
        }
        return ObservationServiceHost(listener: listener,
            requiredClientCode: "anchor apple generic and (identifier \"work.12306.xstats.app\" or identifier \"work.12306.xstats.networkmonitor\") and certificate leaf[subject.OU] = \"\(team)\"")
    }()
    private let buffer = ConnectionFilterProvider.host.buffer
    private let lifecycleLock = NSLock()
    private var generation = 0

    override func startFilter(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        let current = Self.host.startFilter()
        lifecycleLock.lock(); generation = current; lifecycleLock.unlock()
        apply(NEFilterSettings(rules: [], defaultAction: .filterData)) { error in
            if error != nil { Self.host.beginStoppingFilter(generation: current) }
            completionHandler(error)
            if error != nil { Self.host.finishStoppingFilter(generation: current) }
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lifecycleLock.lock(); let current = generation; lifecycleLock.unlock()
        Self.host.beginStoppingFilter(generation: current)
        completionHandler()
        Self.host.finishStoppingFilter(generation: current)
    }

    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        // 租约由可见页面的增量读取续期。App 崩溃/休眠后无需计时器即可停止记录。
        guard buffer.isObserving(), let socket = flow as? NEFilterSocketFlow else { return .allow() }
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
