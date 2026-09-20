import Darwin
import Foundation
import Localization
import SystemConfiguration

public struct NetworkSampler {
    private var last: (download: UInt64, upload: UInt64, time: UInt64)?

    public init() {}

    /// `getifaddrs` 中的 `if_data.ifi_ibytes` 只有 32 位，超过 4 GiB 会回绕；
    /// 这里用 NET_RT_IFLIST2 读取 `if_data64`。
    private static func counters() -> (download: UInt64, upload: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var download: UInt64 = 0
        var upload: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let header2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if header2.ifm_flags & IFF_LOOPBACK == 0 {
                        download += header2.ifm_data.ifi_ibytes
                        upload += header2.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (download, upload)
    }

    public mutating func sample() -> NetworkRate? {
        guard let now = Self.counters() else { return nil }
        let time = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        defer { last = (now.download, now.upload, time) }
        guard let last, time > last.time else { return nil }
        let seconds = Double(time - last.time) / 1_000_000_000
        // 接口重置时计数器可能变小，此时本次速率记为 0
        let down = now.download >= last.download ? Double(now.download - last.download) / seconds : 0
        let up = now.upload >= last.upload ? Double(now.upload - last.upload) / seconds : 0
        return NetworkRate(downloadBytesPerSecond: down, uploadBytesPerSecond: up,
                           totalDownloaded: now.download, totalUploaded: now.upload)
    }

    public static func primaryInterface() -> NetworkInterfaceInfo? {
        guard let store = SCDynamicStoreCreate(nil, "XStats" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let bsdName = global["PrimaryInterface"] as? String else { return nil }

        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let systemName = interfaces
            .first { SCNetworkInterfaceGetBSDName($0) as String? == bsdName }
            .flatMap { SCNetworkInterfaceGetLocalizedDisplayName($0) as String? }
        // utun / ipsec / ppp 是 VPN 或代理隧道，系统不提供显示名
        let tunnelPrefixes = ["utun", "ipsec", "ppp"]
        let displayName = systemName
            ?? (tunnelPrefixes.contains { bsdName.hasPrefix($0) } ? tr("VPN 隧道") : bsdName)

        let state = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(bsdName)/IPv4" as CFString) as? [String: Any]
        let address = (state?["Addresses"] as? [String])?.first
        return NetworkInterfaceInfo(bsdName: bsdName, displayName: displayName, ipv4: address)
    }
}
