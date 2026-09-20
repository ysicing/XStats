import Foundation
import Network

/// 强制走 IPv4 或 IPv6 发一个 HTTPS GET。
///
/// cleanip.io 只查请求方自己的出口，结果取决于这次连接用的是哪一族；URLSession 没法指定地址族，
/// 双栈网络下系统通常优先 IPv6，所以用 Network.framework 自己建连接、锁定 IP 版本，
/// 请求写成最简单的 HTTP/1.1（Connection: close，不要压缩），读到对方关闭为止。
/// 这一族没有路由时连接会进入 waiting，直接当失败处理，不干等超时。
enum AddressFamilyRequest {
    /// 出口检测用的额外选项：默认与查纯净度时一样，走系统路由、只锁定地址族
    struct Options: @unchecked Sendable {
        /// 绑定到这块网卡发出，绕开 VPN 隧道
        var interface: NWInterface?
        /// 直接连这个 IP，TLS 与 Host 仍用 URL 里的域名。绑定物理网卡时系统 DNS 可能被代理改成 fake-ip，只能自己解析
        var address: String?
        /// 忽略系统里配置的代理
        var bypassProxies = false
        var accept = "application/json"
    }

    /// 返回响应体与状态码；连接失败时状态码为 0
    static func get(_ url: URL, ipv6: Bool, timeout: TimeInterval = 10, options: Options = Options()) async -> (Data?, Int) {
        // IPv6 字面量的 host 可能带着方括号
        guard url.scheme == "https",
              let host = url.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else { return (nil, 0) }
        var path = url.path.isEmpty ? "/" : url.path
        if let query = url.query { path += "?" + query }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        if options.address != nil {
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        }
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout)
        let parameters = NWParameters(tls: tls, tcp: tcp)
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = ipv6 ? .v6 : .v4
        }
        if let interface = options.interface { parameters.requiredInterface = interface }
        parameters.preferNoProxies = options.bypassProxies
        let connection = NWConnection(host: NWEndpoint.Host(options.address ?? host), port: .https, using: parameters)
        let hostHeader = host.contains(":") ? "[\(host)]" : host
        let request = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nUser-Agent: XStats\r\nAccept: \(options.accept)\r\nConnection: close\r\n\r\n"
        guard let raw = await Exchange(connection: connection, request: Data(request.utf8), timeout: timeout).run() else {
            return (nil, 0)
        }
        return parse(raw)
    }

    /// 拆出状态码与响应体，处理 chunked 与 Content-Length
    static func parse(_ raw: Data) -> (Data?, Int) {
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: raw[raw.startIndex..<separator.lowerBound], encoding: .utf8) else { return (nil, 0) }
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else { return (nil, 0) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(raw[separator.upperBound...])
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decoded = dechunk(body) else { return (nil, status) }
            body = decoded
        } else if let length = headers["content-length"].flatMap({ Int($0) }) {
            guard body.count >= length else { return (nil, status) }
            body = body.prefix(length)
        }
        return (body, status)
    }

    /// 解开 chunked 编码；数据不完整时返回 nil
    static func dechunk(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var output = Data()
        var index = 0
        while index < bytes.count {
            guard let lineEnd = (index..<max(index, bytes.count - 1)).first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 }),
                  let sizeText = String(bytes: bytes[index..<lineEnd], encoding: .ascii)?
                    .split(separator: ";").first?.trimmingCharacters(in: .whitespaces),
                  let size = Int(sizeText, radix: 16) else { return nil }
            index = lineEnd + 2
            if size == 0 { return output }
            guard bytes.count - index >= size else { return nil }
            output.append(contentsOf: bytes[index..<index + size])
            index += size + 2
        }
        return nil
    }
}

/// 一次连接的收发。所有状态只在自己的串行队列上改，结果只回调一次
private final class Exchange: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "XStats.AddressFamilyRequest")
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data?, Never>?

    /// 响应超过 2 MB 就不要了，cleanip.io 的 JSON 通常几 KB
    private static let limit = 2 << 20

    init(connection: NWConnection, request: Data, timeout: TimeInterval) {
        self.connection = connection
        self.request = request
        self.timeout = timeout
    }

    func run() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready: send()
                    case .waiting, .failed, .cancelled: finish(nil)
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + self.timeout) { [self] in finish(nil) }
            }
        }
    }

    private func send() {
        connection.send(content: request, completion: .contentProcessed { [self] error in
            if error != nil { finish(nil) } else { receive() }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if buffer.count > Self.limit { finish(nil); return }
            // 对方关闭连接（或关闭时带出 TLS 错误）就是读完了，完整性交给 parse 判断
            if isComplete || error != nil { finish(buffer.isEmpty ? nil : buffer); return }
            receive()
        }
    }

    private func finish(_ result: Data?) {
        guard let continuation else { return }
        self.continuation = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: result)
    }
}
