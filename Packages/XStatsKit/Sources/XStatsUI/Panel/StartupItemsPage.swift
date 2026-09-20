import AppKit
import Cleaner
import Localization
import ServiceManagement
import SwiftUI

/// 启动项：LaunchAgents / LaunchDaemons 里的后台项目，当前用户的可以直接停用
@MainActor
@Observable
final class StartupItemsController {
    private(set) var items: [LaunchItem] = []
    private(set) var status = LaunchStatus()
    private(set) var isLoading = false
    private(set) var working: String?
    private(set) var message: (text: String, isError: Bool)?

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let (items, status) = await Task.detached { (LaunchItems.scan(), LaunchItems.status()) }.value
            self.items = items
            self.status = status
            isLoading = false
        }
    }

    func setEnabled(_ enabled: Bool, _ item: LaunchItem) {
        working = item.id
        message = nil
        Task {
            let error = await Task.detached { LaunchItems.setEnabled(enabled, item: item) }.value
            working = nil
            if let error {
                message = (error, true)
            } else {
                Log.app.notice("\(enabled ? "启用" : "停用", privacy: .public)启动项 \(item.label, privacy: .public)")
                message = (tr("已\(enabled ? tr("启用") : tr("停用"))“\(item.label)”"), false)
            }
            isLoading = false
            refresh()
        }
    }
}

struct StartupItemsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let controller = model.startupItems

        PageScroll {
            InfoBanner(icon: "info.circle",
                       text: tr("这里列出资源库里的 LaunchAgents 与 LaunchDaemons。停用只写入系统的停用记录并卸载，不删除文件，随时可以重新启用；登录时打开的应用与后台权限在系统设置里管理。")) {
                Button(tr("登录项设置")) { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
            }
            if let message = controller.message {
                InfoBanner(icon: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                           text: message.text, tone: message.isError ? .error : .success)
            }
            ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                let items = controller.items.filter { $0.scope == scope }
                Card {
                    CardHeader(icon: scope == .system ? "lock.shield" : "person.crop.circle", title: scope.title) {
                        HStack(spacing: DS.Space.s2) {
                            Text(verbatim: scopeDetail(scope, count: items.count))
                                .dsFont(.xs)
                                .foregroundStyle(DS.Palette.textTertiary)
                            if scope == .user {
                                IconButton(systemName: "arrow.clockwise", help: tr("刷新")) { controller.refresh() }
                            }
                        }
                    }
                    if items.isEmpty {
                        Text(controller.isLoading && controller.items.isEmpty ? tr("正在读取…") : tr("没有启动项")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { HairlineDivider() }
                        StartupItemRow(item: item, status: controller.status, isWorking: controller.working == item.id) { enabled in
                            controller.setEnabled(enabled, item)
                        }
                    }
                }
            }
        }
        .onAppear { controller.refresh() }
    }

    private func scopeDetail(_ scope: LaunchItem.Scope, count: Int) -> String {
        switch scope {
        case .user: tr("\(count) 项 · 可直接停用")
        case .allUsers, .system: tr("\(count) 项 · 需要管理员权限，只读")
        }
    }
}

private struct StartupItemRow: View {
    let item: LaunchItem
    let status: LaunchStatus
    let isWorking: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        let disabled = status.isDisabled(item)
        HStack(spacing: DS.Space.s3) {
            AppIconCache.shared.image(bundlePath: item.appBundlePath)
                .resizable()
                .frame(width: DS.Size.iconStandalone + DS.Space.s1, height: DS.Size.iconStandalone + DS.Space.s1)
            VStack(alignment: .leading, spacing: DS.Space.s1 / 2) {
                HStack(spacing: DS.Space.s2) {
                    Text(verbatim: title)
                        .dsFont(.sm, weight: .medium)
                        .foregroundStyle(disabled ? DS.Palette.textTertiary : DS.Palette.textPrimary)
                        .lineLimit(1)
                    badge(disabled: disabled)
                }
                Text(verbatim: [item.label, flags].filter { !$0.isEmpty }.joined(separator: " · "))
                    .dsFont(.xs)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let program = item.program {
                    Text(verbatim: program.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .dsFont(.xs)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(program)
                }
            }
            Spacer(minLength: DS.Space.s2)
            MiniIconButton(systemName: "magnifyingglass", help: tr("在访达中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.plist])
            }
            if item.scope == .user {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    DSToggle(isOn: Binding(get: { !disabled }, set: { setEnabled($0) }), label: tr("启用 \(title)"))
                }
            }
        }
    }

    private var title: String {
        if let bundle = item.appBundlePath {
            return AppNameCache.shared.name(forBundle: bundle)
        }
        return item.program.map { ($0 as NSString).lastPathComponent } ?? item.label
    }

    private var flags: String {
        [item.runAtLoad ? tr("登录时运行") : nil, item.keepAlive ? tr("保持运行") : nil].compactMap { $0 }.joined(separator: tr("、"))
    }

    @ViewBuilder
    private func badge(disabled: Bool) -> some View {
        if disabled {
            StatusBadge(text: tr("已停用"))
        } else if let pid = status.pid(item) {
            StatusBadge(text: tr("运行中 · PID \(pid)"), tone: .success)
        } else if status.isLoaded(item) {
            StatusBadge(text: tr("已加载"), tone: .primary)
        }
    }
}
