import Darwin
import Foundation

/// 用 ICMP 回显（ping）测量到目标地址的往返延迟。
/// macOS 允许普通用户创建 SOCK_DGRAM 类型的 ICMP 套接字，不需要 root，也不经过 shell。
public enum ConnectivityProbe {
    /// 发送一次回显请求，返回往返毫秒数；超时或不可达时返回 nil。调用会阻塞，最长 `timeout`。
    public static func ping(_ address: String, sequence: UInt16, timeout: TimeInterval) -> Double? {
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_addr = v4
            return withUnsafeBytes(of: &target) { raw in
                send(family: AF_INET, proto: IPPROTO_ICMP, target: raw, sequence: sequence, timeout: timeout)
            }
        }
        if inet_pton(AF_INET6, address, &v6) == 1 {
            var target = sockaddr_in6()
            target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            target.sin6_family = sa_family_t(AF_INET6)
            target.sin6_addr = v6
            return withUnsafeBytes(of: &target) { raw in
                send(family: AF_INET6, proto: IPPROTO_ICMPV6, target: raw, sequence: sequence, timeout: timeout)
            }
        }
        return nil
    }

    private static let echoRequest: [Int32: UInt8] = [AF_INET: 8, AF_INET6: 128]
    private static let echoReply: [Int32: UInt8] = [AF_INET: 0, AF_INET6: 129]
    private static let payloadSize = 16

    private static func send(family: Int32, proto: Int32, target: UnsafeRawBufferPointer,
                             sequence: UInt16, timeout: TimeInterval) -> Double? {
        let socketFD = socket(family, SOCK_DGRAM, proto)
        guard socketFD >= 0 else { return nil }
        defer { close(socketFD) }

        // 内核会改写标识符，所以用序号 + 随机令牌匹配应答
        let token = UInt32.random(in: .min ... .max)
        var packet = [UInt8](repeating: 0, count: 8 + payloadSize)
        packet[0] = echoRequest[family] ?? 8
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)
        withUnsafeBytes(of: token.bigEndian) { packet.replaceSubrange(8..<12, with: $0) }
        if family == AF_INET {
            // ICMPv6 的校验和由内核填写
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8)
            packet[3] = UInt8(sum & 0xFF)
        }

        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let sent = target.withMemoryRebound(to: sockaddr.self) { address in
            sendto(socketFD, packet, packet.count, 0, address.baseAddress, socklen_t(target.count))
        }
        guard sent == packet.count else { return nil }

        let deadline = start + UInt64(timeout * 1_000_000_000)
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            guard now < deadline else { return nil }
            var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
            let waitMilliseconds = Int32(max(1, (deadline - now) / 1_000_000))
            guard poll(&descriptor, 1, waitMilliseconds) > 0 else { return nil }
            let count = recv(socketFD, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            if matches(buffer, count: count, family: family, sequence: sequence, token: token) {
                return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000_000
            }
        }
    }

    static func matches(_ buffer: [UInt8], count: Int, family: Int32, sequence: UInt16, token: UInt32) -> Bool {
        // IPv4 的 DGRAM 套接字在 macOS 上会带回 IP 头
        var offset = 0
        if family == AF_INET, count > 0, buffer[0] >> 4 == 4 {
            offset = Int(buffer[0] & 0x0F) * 4
        }
        guard count >= offset + 12, buffer[offset] == echoReply[family] else { return false }
        let replySequence = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
        let replyToken = buffer[(offset + 8)..<(offset + 12)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return replySequence == sequence && replyToken == token
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
