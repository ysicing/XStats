// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Network
import NetworkExtension
import NetworkObservation
import Security

/// 观察模式从不请求数据过滤或暂停：任何状态、任何错误路径都返回 allow。
final class ConnectionFilterProvider: NEFilterDataProvider, NSXPCListenerDelegate, @unchecked Sendable {
    private let buffer = ObservationBuffer()
    private let listener: NSXPCListener
    private let listenerLock = NSLock()
    private let connectionLock = NSLock()
    private var connection: NSXPCConnection?
    private var filterActive = false
    private var listening = false

    override init() {
        let configuration = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any]
        listener = NSXPCListener(machServiceName: configuration?["NEMachServiceName"] as? String ?? "")
        super.init()
        listener.delegate = self
    }

    override func startFilter(completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        connectionLock.lock()
        filterActive = true
        connectionLock.unlock()
        setListening(true)
        apply(NEFilterSettings(rules: [], defaultAction: .filterData)) { [weak self] error in
            if error != nil, let self { self.deactivate() }
            completionHandler(error)
        }
    }

    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        deactivate()
        completionHandler()
    }

    /// 启动失败时系统不保证再调用 stopFilter，失败路径与停止路径共用同一收尾。
    private func deactivate() {
        connectionLock.lock()
        filterActive = false
        buffer.stop()
        let previous = connection
        connection = nil
        connectionLock.unlock()
        setListening(false)
        previous?.invalidate()
    }

    /// NSXPCListener 的 resume/suspend 按次数配对；重复停止不能多挂起一次，否则下次启动后仍不接受连接。
    private func setListening(_ value: Bool) {
        listenerLock.lock()
        defer { listenerLock.unlock() }
        guard listening != value else { return }
        // 状态和底层调用必须一起串行化；先解锁会让下一次 resume 越过尚未执行的 suspend。
        // 独立于会话锁，避免 listener 操作与连接回调竞争同一把锁。
        listening = value
        if value { listener.resume() } else { listener.suspend() }
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

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection candidate: NSXPCConnection) -> Bool {
        var ownCode: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        // macOS 在每条 XPC 消息上校验代码要求，不以可复用的 PID 作为信任依据。
        candidate.setCodeSigningRequirement("anchor apple generic and identifier \"work.12306.xstats.app\" and certificate leaf[subject.OU] = \"\(team)\"")
        candidate.exportedInterface = NSXPCInterface(with: NetworkObservationService.self)
        // 连接建立不等于认证通过。只有 macOS 校验签名后分发的首次读取才能替换观察者，
        // 未认证客户端不能通过反复连接来关闭现有观察或夺走其租约。
        candidate.exportedObject = ConnectionObservationSession { [weak self] candidate, firstRead, cursor, epoch in
            guard let self else { return nil }
            self.connectionLock.lock()
            guard self.filterActive, firstRead || self.connection === candidate else {
                self.connectionLock.unlock()
                return nil
            }
            let previous = firstRead ? self.connection : nil
            if firstRead { self.connection = candidate }
            // 不能在检查当前会话后解锁再 read，否则失效的旧读取能在 stop 之后重新续租。
            let batch = self.buffer.read(after: cursor, epoch: epoch)
            self.connectionLock.unlock()
            previous?.invalidate()
            return batch
        }
        candidate.invalidationHandler = { [weak self, weak candidate] in
            guard let self, let candidate else { return }
            self.connectionLock.lock()
            let isCurrent = self.connection === candidate
            if isCurrent {
                self.connection = nil
                self.buffer.endLease()
            }
            self.connectionLock.unlock()
        }
        candidate.resume()
        return true
    }
}
