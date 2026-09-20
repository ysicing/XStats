import Darwin
import Foundation
import Localization

/// 常用公共 DNS。只用 IPv4 地址：没有 IPv6 的网络里写入 IPv6 服务器会拖慢解析
public enum DNSPreset: String, CaseIterable, Identifiable, Sendable {
    case automatic, cloudflare, google, tencent, aliyun

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: tr("自动")
        case .cloudflare: "Cloudflare"
        case .google: "Google"
        case .tencent: tr("腾讯 DNSPod")
        case .aliyun: tr("阿里云")
        }
    }

    public var servers: [String] {
        switch self {
        case .automatic: []
        case .cloudflare: ["1.1.1.1", "1.0.0.1"]
        case .google: ["8.8.8.8", "8.8.4.4"]
        case .tencent: ["119.29.29.29", "182.254.116.116"]
        case .aliyun: ["223.5.5.5", "223.6.6.6"]
        }
    }

    /// 当前手动设置的地址与哪个预设一致；无手动地址即“自动”
    public static func matching(_ servers: [String]) -> DNSPreset? {
        allCases.first { $0.servers == servers }
    }
}

public enum DNSConfiguration {
    public static let maxServers = 6

    /// 只接受数字形式的 IPv4 / IPv6 地址
    public static func isValidAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// 把用户输入（逗号、空格或换行分隔）拆成地址列表；有无效地址时返回 nil
    public static func parse(_ input: String) -> [String]? {
        let parts = input.split { $0 == "," || $0 == "，" || $0.isWhitespace }.map(String.init)
        guard parts.count <= maxServers, parts.allSatisfy(isValidAddress) else { return nil }
        return parts
    }

    /// 服务名来自系统，可能包含空格或引号；只拒绝控制字符
    public static func isValidServiceName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    public static func networksetupArguments(service: String, servers: [String]) -> [String] {
        ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers)
    }

    /// 未安装辅助工具时通过管理员授权执行的 shell 命令。服务名按单引号转义，地址已校验为纯数字形式
    public static func shellCommand(service: String, servers: [String]) -> String {
        let quoted = "'" + service.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let arguments = ["-setdnsservers", quoted] + (servers.isEmpty ? ["Empty"] : servers)
        return (["/usr/sbin/networksetup"] + arguments).joined(separator: " ")
    }
}
