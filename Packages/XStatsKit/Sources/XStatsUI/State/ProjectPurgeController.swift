// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Observation

/// 项目扫描只由清理页的按钮启动，不参与普通缓存的自动扫描。
@MainActor
@Observable
final class ProjectPurgeController {
    enum Phase { case idle, scanning, ready, cleaning, finished }

    private(set) var phase: Phase = .idle
    private(set) var result: ProjectPurgeScan?
    private(set) var report: ProjectPurgeReport?
    private(set) var roots: [URL] = []
    private(set) var pathsLoaded = false
    private(set) var isLoadingPaths = false
    var selection: Set<String> = []
    var isConfirming = false
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let home: String
    @ObservationIgnored private var task: Task<Void, Never>?

    init(settings: AppSettings, home: String = NSHomeDirectory()) {
        self.settings = settings
        self.home = home
        if let configured = settings.projectPurgeConfiguredPaths {
            roots = configured.map { URL(fileURLWithPath: $0) }
            pathsLoaded = true
        }
    }

    var isBusy: Bool { phase == .scanning || phase == .cleaning }
    var isUsingDefaults: Bool { settings.projectPurgeConfiguredPaths == nil }
    var selectedItems: [ProjectPurgeItem] { result?.items.filter { selection.contains($0.id) } ?? [] }
    var selectedBytes: UInt64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    /// 只在打开目录设置时发现默认位置；磁盘遍历放在 utility 子任务，避免阻塞主线程。
    func loadPaths() async {
        guard !pathsLoaded, !isLoadingPaths else { return }
        if let configured = settings.projectPurgeConfiguredPaths {
            roots = configured.map { URL(fileURLWithPath: $0) }
            pathsLoaded = true
            return
        }
        isLoadingPaths = true
        let home = home
        let discovered = await withTaskGroup(of: [URL].self) { group in
            group.addTask(priority: .utility) {
                ProjectPurge.defaultSearchRoots(home: home)
            }
            return await group.next() ?? []
        }
        roots = discovered
        pathsLoaded = true
        isLoadingPaths = false
    }

    @discardableResult
    func addRoot(_ url: URL) -> Bool {
        guard pathsLoaded, !isLoadingPaths, !isBusy,
              let root = ProjectPurge.validatedAdditionalRoot(url, home: home),
              !roots.contains(where: { ProjectPurge.sameRoot($0, root) }) else { return false }
        roots.insert(root, at: 0)
        settings.projectPurgeConfiguredPaths = roots.map(\.path)
        invalidateScan()
        return true
    }

    func removeRoot(_ url: URL) {
        guard pathsLoaded, !isLoadingPaths, !isBusy else { return }
        let before = roots.count
        roots.removeAll { ProjectPurge.sameRoot($0, url) }
        guard roots.count != before else { return }
        settings.projectPurgeConfiguredPaths = roots.map(\.path)
        invalidateScan()
    }

    func restoreDefaults() async {
        guard !isBusy, !isLoadingPaths else { return }
        settings.projectPurgeConfiguredPaths = nil
        roots = []
        pathsLoaded = false
        invalidateScan()
        await loadPaths()
    }

    private func invalidateScan() {
        selection.removeAll()
        result = nil
        report = nil
        isConfirming = false
        phase = .idle
    }

    func scan() {
        guard !isBusy else { return }
        phase = .scanning
        isConfirming = false
        selection.removeAll()
        result = nil
        report = nil
        let configuredRoots = settings.projectPurgeConfiguredPaths.map { $0.map { URL(fileURLWithPath: $0) } }
            ?? (pathsLoaded ? roots : nil)
        let home = home
        task = Task {
            let scan = await ProjectPurge.scan(home: home, configuredRoots: configuredRoots)
            guard !Task.isCancelled else { phase = .idle; return }
            result = scan
            phase = .ready
        }
    }

    func cancelScan() {
        guard phase == .scanning else { return }
        task?.cancel()
    }

    func toggle(_ item: ProjectPurgeItem) {
        guard !isBusy else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        isConfirming = false
    }

    func requestClean() {
        guard !isBusy, !selectedItems.isEmpty else { return }
        isConfirming = true
    }

    func confirmClean() {
        guard isConfirming, let scan = result, !selectedItems.isEmpty else { return }
        isConfirming = false
        phase = .cleaning
        let selected = selection
        task = Task {
            let report = await ProjectPurge.clean(scan, selected: selected)
            self.report = report
            // 只去掉已移到废纸篓的项，不整体重扫；被跳过的项保留，用户可随时重新扫描
            result = scan.removing(report.trashedIDs)
            selection.removeAll()
            phase = .finished
        }
    }

    func cancelClean() {
        guard phase == .cleaning else { return }
        task?.cancel()
    }
}
