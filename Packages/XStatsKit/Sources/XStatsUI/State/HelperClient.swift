import Foundation
import HelperShared
import Localization
import Observation
import ServiceManagement

/// 与 root 辅助工具的连接。安装通过 SMAppService.daemon，用户需在“登录项”中批准一次。
@MainActor
@Observable
public final class HelperClient {
    public enum Status: Equatable {
        case notInstalled
        case requiresApproval
        case enabled
        case unavailable(String)

        var title: String {
            switch self {
            case .notInstalled: tr("未安装")
            case .requiresApproval: tr("等待批准")
            case .enabled: tr("已启用")
            case .unavailable: tr("不可用")
            }
        }
    }

    public private(set) var status: Status = .notInstalled
    public private(set) var isWorking = false
    public private(set) var lastError: String?
    /// 正在运行的辅助工具比应用旧：登记的是另一份应用包里的辅助工具，或替换应用后旧进程还没退出
    public private(set) var isOutdated = false

    /// 连接中断后重新连上时回调，用于重新下发风扇 / 防休眠状态
    @ObservationIgnored var onReconnect: (() -> Void)?

    @ObservationIgnored private var connection: NSXPCConnection?
    @ObservationIgnored private let service = SMAppService.daemon(plistName: HelperConstants.launchdPlistName)

    public init() {}

    public var isReady: Bool { status == .enabled }

    static var outdatedMessage: String { tr("辅助工具版本比应用旧，部分功能可能无法使用，请重新安装一次（需要管理员授权）。") }

    /// 未安装、待批准或版本过旧，需要用户处理
    var needsAttention: Bool { !isReady || isOutdated }

    public func refreshStatus() {
        switch service.status {
        case .enabled: status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notRegistered: status = .notInstalled
        case .notFound:
            // 首次注册前系统同样返回 notFound，需结合包内文件判断
            let plist = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperConstants.launchdPlistName)")
            status = FileManager.default.fileExists(atPath: plist.path)
                ? .notInstalled
                : .unavailable(tr("应用包内未找到辅助工具，请使用完整构建的 XStats.app"))
        @unknown default: status = .unavailable(tr("未知状态"))
        }
    }

    public func install() {
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        do {
            try service.register()
        } catch {
            lastError = tr("安装失败：\(error.localizedDescription)")
            Log.helper.error("安装失败：\(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
        if status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    public func uninstall() async {
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        connection?.invalidate()
        connection = nil
        do {
            // 使用回调版本：不把非 Sendable 的 SMAppService 跨隔离域传递
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                service.unregister { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            lastError = tr("卸载失败：\(error.localizedDescription)")
            Log.helper.error("卸载失败：\(error.localizedDescription, privacy: .public)")
        }
        refreshStatus()
    }

    /// 卸载后重新登记，让 launchd 运行当前应用包里的辅助工具
    public func reinstall() async {
        await uninstall()
        install()
        await verifyVersion(allowRestart: false)
    }

    /// 核对辅助工具的协议版本。版本旧通常是替换应用后旧的辅助工具进程还在运行（新应用一连上它就不会空闲退出）：
    /// 先断开连接让它空闲 30 秒后退出，再连接时 launchd 会启动应用包里的新版本；仍然旧才提示重新安装
    func verifyVersion(allowRestart: Bool = true) async {
        let remote = await remoteProtocolVersion()
        Log.helper.info("辅助工具状态 \(self.status.title, privacy: .public)，协议版本 \(remote.map(String.init) ?? "未连接", privacy: .public)")
        guard let version = remote, version < HelperConstants.protocolVersion else {
            isOutdated = false
            return
        }
        guard allowRestart else {
            isOutdated = true
            return
        }
        connection?.invalidate()
        connection = nil
        try? await Task.sleep(for: .seconds(40))
        guard let again = await remoteProtocolVersion() else { return }
        isOutdated = again < HelperConstants.protocolVersion
        if isOutdated {
            Log.helper.error("辅助工具协议版本 \(again) 低于应用的 \(HelperConstants.protocolVersion)")
        } else {
            // 新的辅助工具进程没有之前的风扇与睡眠设置，重新下发
            onReconnect?()
        }
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: 远程调用

    func setFanTarget(fan: Int, rpm: Double) async -> String? {
        await call { proxy, reply in proxy.setFanTarget(fan: fan, rpm: rpm, reply: reply) }
    }

    func setFanAutomatic(fan: Int) async -> String? {
        await call { proxy, reply in proxy.setFanAutomatic(fan: fan, reply: reply) }
    }

    func resetAllFans() async -> String? {
        await call { proxy, reply in proxy.resetAllFans(reply: reply) }
    }

    func setSleepDisabled(_ disabled: Bool) async -> String? {
        await call { proxy, reply in proxy.setSleepDisabled(disabled, reply: reply) }
    }

    func run(_ command: MaintenanceCommand) async -> String? {
        switch command {
        case .flushDNS: await call { proxy, reply in proxy.flushDNSCache(reply: reply) }
        case .purgeMemory: await call { proxy, reply in proxy.purgeMemory(reply: reply) }
        }
    }

    func setDNSServers(service: String, servers: [String]) async -> String? {
        await call { proxy, reply in proxy.setDNSServers(service: service, servers: servers, reply: reply) }
    }

    func deleteLocalSnapshots(identifiers: [String]) async -> String? {
        await call { proxy, reply in proxy.deleteLocalSnapshots(identifiers: identifiers, reply: reply) }
    }

    /// 已安装的辅助工具的协议版本；旧版本不认识新增的方法，调用前先确认
    func remoteProtocolVersion() async -> Int? {
        refreshStatus()
        guard isReady else { return nil }
        let connection = ensureConnection()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
            let once = ResumeOnceValue<Int?>(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(nil) } as? XStatsHelperProtocol
            guard let proxy else { return once.resume(nil) }
            proxy.protocolVersion { once.resume($0) }
        }
    }

    /// 退出应用时使用：同步恢复风扇与睡眠设置。
    ///
    /// 在主线程上阻塞，因此总等待时间设上限；每一步互相独立——取代理失败只跳过当前这步，
    /// 不能提前 return，否则第一步失败就会连带跳过“恢复睡眠设置”，让 Mac 保持禁止睡眠。
    func restoreDefaultsSynchronously() {
        guard isReady else { return }
        let connection = ensureConnection()
        let steps: [(XStatsHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void] = [
            { proxy, reply in proxy.resetAllFans(reply: reply) },
            { proxy, reply in proxy.setSleepDisabled(false, reply: reply) },
        ]
        let deadline = DispatchTime.now() + Self.restoreBudget
        for step in steps {
            let semaphore = DispatchSemaphore(value: 0)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in semaphore.signal() })
                    as? XStatsHelperProtocol else { continue }
            step(proxy) { _ in semaphore.signal() }
            _ = semaphore.wait(timeout: deadline)
        }
    }

    /// 退出时为恢复操作预留的总时长；辅助工具无响应时不让退出卡住超过这个值
    private static let restoreBudget: DispatchTimeInterval = .milliseconds(1500)

    private func call(_ body: (XStatsHelperProtocol, @escaping @Sendable (String?) -> Void) -> Void) async -> String? {
        refreshStatus()
        guard isReady else { return tr("辅助工具未启用") }
        let connection = ensureConnection()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                Log.helper.error("XPC 调用失败：\(error.localizedDescription, privacy: .public)")
                once.resume(tr("无法连接辅助工具：\(error.localizedDescription)"))
            } as? XStatsHelperProtocol
            guard let proxy else {
                once.resume(tr("无法连接辅助工具"))
                return
            }
            body(proxy) { once.resume($0) }
        }
    }

    private func ensureConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(machServiceName: HelperConstants.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: XStatsHelperProtocol.self)
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.onReconnect?() }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }
}

private typealias ResumeOnce = ResumeOnceValue<String?>

/// XPC 的错误回调和正常回调可能都会触发，保证 continuation 只恢复一次
private final class ResumeOnceValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
