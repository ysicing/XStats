import AppKit
import Cleaner
import Foundation
import Localization
import Metrics
import Observation

/// 卸载应用：列出已安装的应用，查找残留文件，连同残留一起移到废纸篓，并从程序坞移除图标
@MainActor
@Observable
public final class UninstallerController {
    public private(set) var apps: [InstalledApp] = []
    public private(set) var sizes: [String: UInt64] = [:]
    public private(set) var isLoading = false
    public private(set) var selected: InstalledApp?
    public private(set) var leftovers: [AppLeftover] = []
    public private(set) var isScanning = false
    public private(set) var isRemoving = false
    public private(set) var outcome: (text: String, isError: Bool)?
    var chosen: Set<String> = []
    /// 有应用启动或退出时变化，让“正在运行”的提示跟着刷新
    private var runningRevision = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.runningRevision += 1 }
            })
        }
    }

    var chosenSize: UInt64 {
        leftovers.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func loadApps() {
        guard !isLoading else { return }
        isLoading = true
        let own = Bundle.main.bundleIdentifier.map { Set([$0]) } ?? []
        Task {
            let apps = await Task.detached { AppUninstaller.installedApps(excluding: own) }.value
            self.apps = apps.filter { (try? AppUninstaller.validate($0)) != nil }
            isLoading = false
            // 体积在后台逐个计算，列表先显示出来
            for app in self.apps where sizes[app.id] == nil {
                let url = app.url
                sizes[app.id] = await Task.detached { CleanEngine.allocatedSize(of: url) }.value
            }
        }
    }

    func select(_ app: InstalledApp?) {
        selected = app
        leftovers = []
        chosen = []
        outcome = nil
        guard let app else { return }
        isScanning = true
        Task {
            let found = await Task.detached { AppUninstaller.leftovers(for: app) }.value
            guard selected == app else { return }
            leftovers = found
            chosen = Set(found.map(\.id))
            isScanning = false
        }
    }

    /// 拖进来的 .app
    func select(url: URL) {
        guard let app = AppUninstaller.app(at: url) else {
            outcome = (tr("不是应用程序"), true)
            return
        }
        do {
            try AppUninstaller.validate(app)
            select(app)
        } catch {
            outcome = ("\(error)", true)
        }
    }

    func toggle(_ leftover: AppLeftover) {
        // 应用本体必须一起移除，否则没有意义
        guard leftover.kind != .application else { return }
        if chosen.contains(leftover.id) { chosen.remove(leftover.id) } else { chosen.insert(leftover.id) }
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        _ = runningRevision
        return !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).isEmpty
    }

    func quit(_ app: InstalledApp) {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).forEach { $0.terminate() }
    }

    func uninstall() {
        guard let app = selected, !isRemoving else { return }
        do {
            try AppUninstaller.validate(app)
            guard !isRunning(app) else { throw AppUninstallError.running }
        } catch {
            outcome = ("\(error)", true)
            return
        }
        let urls = leftovers.filter { chosen.contains($0.id) }.map(\.url)
        let freed = chosenSize
        isRemoving = true
        outcome = nil
        // NSWorkspace 负责需要管理员权限的情况（例如 root 拥有的应用），并能在废纸篓中“放回原处”
        NSWorkspace.shared.recycle(urls) { [weak self] moved, error in
            let movedCount = moved.count
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.isRemoving = false
                if movedCount == 0 {
                    self.outcome = (tr("没有移动任何文件\(message.map { tr("：\($0)") } ?? "")"), true)
                    return
                }
                // 应用已经进了废纸篓，程序坞里的图标只会变成问号，一并移除
                let dock = Self.removeDockTile(for: app.url)
                Log.app.notice("卸载 \(app.bundleIdentifier, privacy: .public)，移到废纸篓 \(movedCount) 项")
                let partial = movedCount < urls.count ? tr("，\(urls.count - movedCount) 项未能移动") : ""
                self.outcome = (tr("已将 \(app.name) 与 \(movedCount - 1) 项残留移到废纸篓，约 \(Format.bytes(freed, base: .decimal))\(dock ? tr("，已从程序坞移除") : "")\(partial)。需要时可以在废纸篓里放回。"),
                                message != nil)
                self.selected = nil
                self.leftovers = []
                self.apps.removeAll { $0 == app }
            }
        }
    }

    /// 修改程序坞偏好里的 persistent-apps 并重启程序坞
    private static func removeDockTile(for url: URL) -> Bool {
        let domain = "com.apple.dock" as CFString
        let key = "persistent-apps" as CFString
        guard let tiles = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]],
              let updated = AppUninstaller.removingDockTile(for: url, from: tiles) else { return false }
        CFPreferencesSetAppValue(key, updated as CFArray, domain)
        CFPreferencesAppSynchronize(domain)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["Dock"]
        try? process.run()
        return true
    }
}
