import Foundation
import Security

public enum HelperConstants {
    public static let machServiceName = "work.12306.xstats.helper"
    public static let launchdPlistName = "work.12306.xstats.helper.plist"
    public static let appBundleIdentifier = "work.12306.xstats.app"
    /// 与 App 版本同步；App 发现辅助工具版本不一致时提示重新安装
    public static let protocolVersion = 4

    /// 辅助工具对调用方的签名要求：与辅助工具自身同一团队签名的 XStats。
    ///
    /// ad-hoc 签名的开发构建没有团队，此时返回 nil 表示“无法安全鉴权”。不能退化成只校验
    /// bundle identifier：单独的 `identifier` 不含 anchor 约束，任何进程 `codesign -s -`
    /// 伪造同一个 identifier 即可通过校验，进而以 root 驱动 DNS、睡眠、快照与风扇。
    /// 在线升级在 ad-hoc 下同样是直接禁用（见 UpdateController），两处保持一致。
    public static func clientRequirement(teamIdentifier: String?) -> String? {
        guard let teamIdentifier, !teamIdentifier.isEmpty else { return nil }
        return "identifier \"\(appBundleIdentifier)\" and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

public enum CodeSigningInfo {
    /// 当前进程签名所属的 Team ID；ad-hoc 签名时为 nil
    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// 辅助工具以 root 运行，只暴露固定的少量操作，不提供任意命令执行能力。
/// 所有回调中的 `String?` 为错误描述，nil 表示成功。
@objc public protocol XStatsHelperProtocol {
    func protocolVersion(reply: @escaping @Sendable (Int) -> Void)
    func setFanTarget(fan: Int, rpm: Double, reply: @escaping @Sendable (String?) -> Void)
    func setFanAutomatic(fan: Int, reply: @escaping @Sendable (String?) -> Void)
    func resetAllFans(reply: @escaping @Sendable (String?) -> Void)
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (String?) -> Void)
    func flushDNSCache(reply: @escaping @Sendable (String?) -> Void)
    func purgeMemory(reply: @escaping @Sendable (String?) -> Void)
    /// 为指定网络服务设置 DNS；`servers` 为空表示恢复自动获取。辅助工具会校验服务名与每个地址
    func setDNSServers(service: String, servers: [String], reply: @escaping @Sendable (String?) -> Void)
    /// 删除 Time Machine 本地快照；每个标识都按固定格式校验，逐个执行
    func deleteLocalSnapshots(identifiers: [String], reply: @escaping @Sendable (String?) -> Void)
}

/// 需要管理员权限的系统维护命令。辅助工具与未安装辅助工具时的授权回退共用同一份固定命令
public enum MaintenanceCommand: String, Sendable, CaseIterable {
    case flushDNS, purgeMemory

    public var steps: [(path: String, arguments: [String])] {
        switch self {
        case .flushDNS: [("/usr/bin/dscacheutil", ["-flushcache"]), ("/usr/bin/killall", ["-HUP", "mDNSResponder"])]
        case .purgeMemory: [("/usr/sbin/purge", [])]
        }
    }

    public var shellCommand: String {
        steps.map { ([$0.path] + $0.arguments).joined(separator: " ") }.joined(separator: "; ")
    }
}
