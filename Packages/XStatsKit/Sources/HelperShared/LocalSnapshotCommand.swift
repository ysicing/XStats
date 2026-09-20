import Foundation

/// Time Machine 本地快照的删除命令。辅助工具与未安装辅助工具时的授权回退共用同一份参数校验：
/// 快照只能用形如 2026-09-14-120000 的时间标识指定，不接受任何其他字符
public enum LocalSnapshotCommand {
    public static let tool = "/usr/bin/tmutil"
    public static let maxCount = 64

    public static func isValidIdentifier(_ identifier: String) -> Bool {
        let scalars = Array(identifier.unicodeScalars)
        guard scalars.count == 17 else { return false }
        for (index, scalar) in scalars.enumerated() {
            if index == 4 || index == 7 || index == 10 {
                guard scalar == "-" else { return false }
            } else {
                guard ("0"..."9").contains(scalar) else { return false }
            }
        }
        return true
    }

    public static func arguments(identifier: String) -> [String] {
        ["deletelocalsnapshots", identifier]
    }

    /// 授权回退用的一整条 shell；调用前必须已用 isValidIdentifier 校验
    public static func shellCommand(identifiers: [String]) -> String {
        identifiers.map { "\(tool) deletelocalsnapshots \($0)" }.joined(separator: "; ")
    }
}
