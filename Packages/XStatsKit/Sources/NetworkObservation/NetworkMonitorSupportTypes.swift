// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Localization

public enum NetworkMonitorError: Error, LocalizedError {
    case protocolMismatch, backgroundApproval, unsupportedVersion, missingExtension, unsigned, installLocation, unavailable, timeout, wrongConfiguration, extensionNeedsUpdate, restartRequired

    public var errorDescription: String? {
        switch self {
        case .protocolMismatch: tr("网络组件协议不兼容，请更新 XStats 和网络组件。")
        case .backgroundApproval: tr("请在系统设置中允许 XStats 网络组件的后台项目。")
        case .unsupportedVersion: tr("需要 macOS 15 或更新版本")
        case .missingExtension: tr("此构建未包含网络扩展。")
        case .unsigned: tr("需要包含网络扩展权限的签名构建。")
        case .installLocation: tr("请先将 XStats 安装到应用程序文件夹。")
        case .unavailable: tr("无法连接网络扩展，请重试。")
        case .timeout: tr("网络扩展响应超时，请重试。")
        case .wrongConfiguration: tr("网络过滤配置与此扩展不匹配。")
        case .extensionNeedsUpdate: tr("网络扩展需要更新，请重新启用连接查看。")
        case .restartRequired: tr("需要重启系统")
        }
    }
}

/// XPC 的回复、错误、取消与超时只能完成同一次读取一次；不在主线程阻塞等待。
public final class NetworkMonitorReply: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?

    public func install(_ continuation: CheckedContinuation<Data, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    public func finish(_ result: Result<Data, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
