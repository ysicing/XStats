// OpenStats source retained under MIT; XStats adaptations Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Network

// MARK: - 线路

/// 测速走哪条线路
public enum SpeedRoute: String, Sendable, Codable, CaseIterable {
    /// 绑定物理网卡、忽略系统代理：绕开 VPN 与代理，测的是本机宽带
    case direct
    /// 按系统设置发出：开着 VPN 或代理就经过它，测的是代理线路
    case proxy
}

/// 按当前网络环境定下来的一条测速线路。
///
/// 开着 Surge、Clash 这类代理时，连接先到本机的代理或隧道，TCP 握手由它当场应答，
/// 握手计时只剩零点几毫秒，与目标远近无关。所以要么绑定物理网卡绕开代理（直连），
/// 要么经代理时改用 HTTP 往返计时（请求必须真的到达目标、拿回响应）
public struct SpeedPath: @unchecked Sendable {
    // NWInterface 没有标 Sendable，但它是不可变的值，跨任务传递是安全的

    /// 绑定的物理网卡；nil 表示按系统路由与代理设置
    let interface: NWInterface?
    /// 物理网卡上的 DNS 也被代理改成了 fake-ip 或本机地址：直连前先经这块网卡用 DoH 自己解析
    let resolvesItself: Bool
    /// 这条线路经过代理或隧道，延迟只能用 HTTP 往返计时
    public let isProxied: Bool
    /// 开着代理时这次实际走的线路；没有代理时为 nil，两条线路没有区别
    public let route: SpeedRoute?

    /// 没有代理：按系统路由走，TCP 握手计时就是真实往返
    public static let system = SpeedPath(interface: nil, resolvesItself: false, isProxied: false, route: nil)

    /// 选直连但找不到物理网卡（例如 VPN 不允许绕开）时退回经代理，`route` 如实记为 `.proxy`
    public static func make(route: SpeedRoute, details: NetworkDetails, environment: ProxyEnvironment) async -> SpeedPath {
        guard environment.hasProxy else { return .system }
        if route == .direct, let interface = await EgressProber.physicalInterface(named: environment.physicalInterface) {
            let hijacked = (details.physical?.manualDNS ?? []).contains(where: Self.isHijackedDNS)
            return SpeedPath(interface: interface, resolvesItself: hijacked, isProxied: false, route: .direct)
        }
        return SpeedPath(interface: nil, resolvesItself: false, isProxied: true, route: .proxy)
    }

    /// fake-ip 或本机回环：绑定物理网卡后这类 DNS 要么查不到、要么给出假地址
    static func isHijackedDNS(_ server: String) -> Bool {
        ProxyEnvironment.isFakeIP(server) || server.hasPrefix("127.") || server == "::1"
    }

    func apply(to parameters: NWParameters) {
        guard let interface else { return }
        parameters.requiredInterface = interface
        parameters.preferNoProxies = true
    }

    /// 需要自己解析时返回目标 IP；不需要时返回主机名本身，交给系统（绑定网卡后按这块网卡的 DNS 解析）
    func address(for host: String) async -> String? {
        guard resolvesItself, let interface, !PublicAddressLookup.isAddress(host) else { return host }
        return await EgressProber.resolve(host, ipv6: false, interface: interface)
    }
}

// MARK: - HTTP 连接

/// 测速用的 HTTP/1.1 连接，建在 Network.framework 上：能绑定物理网卡、绕开系统代理（URLSession 做不到），
/// 一条连接上可以接连发多个请求。只实现测速用得到的部分：请求头、定长或读到关闭为止的响应体、上传定长数据。
///
/// 同一时间只由一个任务使用；取消靠 `cancel()`，挂着的收发会立刻以失败返回
final class SpeedConnection: @unchecked Sendable {
    struct Response {
        var status: Int
        var headers: [String: String]

        /// chunked 编码不解析，按读到关闭为止处理
        var contentLength: Int? {
            headers["transfer-encoding"]?.lowercased().contains("chunked") == true
                ? nil : headers["content-length"].flatMap { Int($0) }
        }

        /// 读完响应体后这条连接还能接着发下一个请求
        var isReusable: Bool {
            contentLength != nil && headers["connection"]?.lowercased() != "close"
        }
    }

    let url: URL
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "work.12306.xstats.speedtest.http", qos: .utility)
    /// 已收到、还没交给调用方的字节
    private var buffer = Data()

    private init(url: URL, connection: NWConnection) {
        self.url = url
        self.connection = connection
    }

    /// 建连（HTTPS 含 TLS 握手）；连不上返回 nil
    static func open(_ url: URL, path: SpeedPath, timeout: TimeInterval) async -> SpeedConnection? {
        guard let host = url.host, let scheme = url.scheme, let address = await path.address(for: host) else { return nil }
        let secure = scheme == "https"
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = Int(timeout.rounded(.up))
        var tls: NWProtocolTLS.Options?
        if secure {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
            // 连的是自己解析出的 IP 时，证书校验与 SNI 仍按域名
            if address != host { sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host) }
            tls = options
        }
        let parameters = NWParameters(tls: tls, tcp: tcp)
        path.apply(to: parameters)
        guard let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (secure ? 443 : 80))) else { return nil }
        let result = SpeedConnection(url: url, connection: NWConnection(host: NWEndpoint.Host(address), port: port,
                                                                         using: parameters))
        guard await result.start(timeout: timeout) else {
            result.cancel()
            return nil
        }
        return result
    }

    func cancel() {
        connection.cancel()
    }

    private func start(timeout: TimeInterval) async -> Bool {
        let gate = ContinuationGate<Bool>()
        let ready = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.attach(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.resume(true)
                    // 路由不可达、被拒、等网络：都算连不上，不干等超时
                    case .waiting, .failed, .cancelled: gate.resume(false)
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) { gate.resume(false) }
            }
        } onCancel: {
            gate.resume(false)
        }
        connection.stateUpdateHandler = nil
        return ready
    }

    // MARK: 收发

    func send(_ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    /// 收下一段数据；对方关闭、出错或连接被取消时返回 nil
    private func receive() async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, _, _ in
                continuation.resume(returning: data.flatMap { $0.isEmpty ? nil : $0 })
            }
        }
    }

    // MARK: HTTP

    /// 发请求头；上传的请求体由调用方随后用 `sendBody` 发
    func sendRequest(_ method: String, headers: [(String, String)] = []) async -> Bool {
        var target = url.path(percentEncoded: true)
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true) { target += "?" + query }
        var host = url.host ?? ""
        if host.contains(":") { host = "[\(host)]" }
        if let port = url.port { host += ":\(port)" }
        let lines = ["\(method) \(target) HTTP/1.1", "Host: \(host)", "User-Agent: XStats", "Accept: */*",
                     "Accept-Encoding: identity", "Cache-Control: no-cache"]
            + headers.map { "\($0.0): \($0.1)" }
        return await send(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    }

    /// 读到响应头结束；多收到的字节留在缓冲区，作为响应体的开头
    func readResponse() async -> Response? {
        let separator = Data("\r\n\r\n".utf8)
        var end = buffer.range(of: separator)
        while end == nil {
            // 响应头不会这么大，多半不是 HTTP
            guard buffer.count < 64 * 1024, let data = await receive() else { return nil }
            buffer.append(data)
            end = buffer.range(of: separator)
        }
        guard let end else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer = Data(buffer[end.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ") ?? []
        guard status.count >= 2, status[0].hasPrefix("HTTP/"), let code = Int(status[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // 同名的头（例如两行 Server-Timing）按 HTTP 的规矩用逗号拼起来
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        return Response(status: code, headers: headers)
    }

    /// 读响应体：每收到一段就把字节数交给 `consume`，它返回 false 就不再往下读（这条连接也就不能再用）。
    /// 返回是否读完了整个响应体
    func readBody(_ response: Response, method: String = "GET", consume: (Int) -> Bool = { _ in true }) async -> Bool {
        if method == "HEAD" || response.status == 204 || response.status == 304 { return true }
        let length = response.contentLength
        var remaining = length ?? .max
        if !buffer.isEmpty {
            let take = min(buffer.count, remaining)
            buffer = Data(buffer.dropFirst(take))
            remaining -= take
            if !consume(take) { return remaining == 0 }
        }
        while remaining > 0 {
            // 没有长度的响应读到对方关闭为止
            guard let data = await receive() else { return length == nil }
            let take = min(data.count, remaining)
            if take < data.count { buffer.append(data.dropFirst(take)) }
            remaining -= take
            if !consume(take) { return remaining == 0 }
        }
        return true
    }

    /// 上传定长的空数据，分段发，每段交给协议栈后把字节数交给 `consume`；它返回 false 就停下。
    /// 返回是否整段发完
    func sendBody(bytes total: Int, consume: (Int) -> Bool) async -> Bool {
        let chunk = Data(count: 64 * 1024)
        var sent = 0
        while sent < total {
            let size = min(chunk.count, total - sent)
            guard await send(size == chunk.count ? chunk : chunk.prefix(size)) else { return false }
            sent += size
            if !consume(size) { return sent == total }
        }
        return true
    }

    /// 在这条连接上接连发 `count` 个请求，返回每次的响应与从发出到读完响应的毫秒数；中途失败就停下
    func roundTrips(_ count: Int, method: String) async -> [(response: Response, milliseconds: Double)] {
        let clock = ContinuousClock()
        var trips: [(response: Response, milliseconds: Double)] = []
        for _ in 0..<count {
            if Task.isCancelled { break }
            let start = clock.now
            guard await sendRequest(method), let response = await readResponse(),
                  await readBody(response, method: method) else { break }
            trips.append((response, Self.milliseconds(clock.now - start)))
            if method != "HEAD", !response.isReusable { break }
        }
        return trips
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

// MARK: - 工具

/// 状态回调、超时与取消都可能同时到达，续体只能恢复一次；取消可能在续体挂上之前就到，先记下结果
final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var done = false
    private var pending: Value?

    func attach(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        if let pending {
            lock.unlock()
            continuation.resume(returning: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ value: Value) {
        lock.lock()
        guard !done else { return lock.unlock() }
        done = true
        guard let continuation else {
            pending = value
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

/// 当前在用的连接：任务取消或超时看门狗触发时从别的线程把它掐断
final class ConnectionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: SpeedConnection?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// 已经取消过就立刻掐断新连接
    func hold(_ connection: SpeedConnection) {
        lock.lock()
        self.connection = connection
        let cancelled = cancelled
        lock.unlock()
        if cancelled { connection.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let connection = connection
        lock.unlock()
        connection?.cancel()
    }
}
