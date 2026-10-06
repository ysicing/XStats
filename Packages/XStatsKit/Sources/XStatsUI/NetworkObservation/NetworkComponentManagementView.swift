// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Localization
import NetworkObservation
import SwiftUI

struct NetworkComponentManagementView: View {
    var onInstalled: () -> Void = {}
    var onClose: () -> Void = {}
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsRemoval = false
    private var component: NetworkComponentController { model.networkComponent }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack {
                Label(tr("网络组件"), systemImage: "network").dsFont(.lg, weight: .semibold)
                Spacer()
                Button(tr("关闭面板")) { onClose(); dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(tr("组件按需运行，负责扩展授权和独立更新；所有连接均放行。"))
                .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            if component.installed {
                if let status = component.status {
                    LabeledContent(tr("组件版本"), value: "\(status.componentVersion) (\(status.componentBuild))")
                    LabeledContent(tr("包内扩展"), value: "\(status.extensionVersion) (\(status.extensionBuild))")
                    LabeledContent(tr("系统过滤配置"), value: status.filterEnabled ? tr("已启用") : tr("未启用"))
                    if status.registration == .requiresApproval {
                        Text(tr("请在系统设置中允许 XStats 网络组件的后台项目。")).foregroundStyle(DS.Palette.warning)
                        Button(tr("打开系统设置")) { component.openBackgroundSettings() }
                    }
                    if let version = status.update.version {
                        LabeledContent(tr("可用更新"), value: version)
                    }
                    if status.update.phase == .checking { Text(tr("正在检查更新")) }
                    if status.update.phase == .upToDate { Text(tr("已是最新版本")) }
                    if status.update.phase == .downloading {
                        ProgressView(value: status.update.progress ?? 0)
                        Button(tr("取消")) { component.cancelUpdate() }
                    }
                    if status.update.phase == .verifying { Text(tr("正在验证更新包与开发者签名…")) }
                    if status.update.phase == .installing { Text(tr("正在更新网络组件…")) }
                    if let error = status.update.error { Text(verbatim: error).foregroundStyle(DS.Palette.error).textSelection(.enabled) }
                }
                HStack {
                    Button(tr("检查更新")) { component.checkUpdates() }.disabled(component.busy)
                    if component.status?.update.phase == .available { Button(tr("一键安装")) { component.installUpdate() }.disabled(component.busy) }
                    Spacer()
                    Button(tr("卸载组件"), role: .destructive) { confirmsRemoval = true }.disabled(component.busy)
                }
            } else {
                Text(tr("尚未安装网络组件")).foregroundStyle(DS.Palette.textSecondary)
                Button(tr("安装组件")) { component.install(onInstalled: onInstalled) }.disabled(component.busy)
            }
            if let progress = model.connectionMonitor.installationProgress {
                ProgressView(value: progress) { Text(tr("正在下载")) }
            }
            if let error = component.error {
                Text(verbatim: error).dsFont(.sm).foregroundStyle(DS.Palette.error).textSelection(.enabled)
                if component.needsBackgroundApproval {
                    Button(tr("打开系统设置")) { component.openBackgroundSettings() }
                }
            }
            if component.busy { ProgressView().controlSize(.small) }
        }.padding(DS.Space.s6).frame(minWidth: 460, idealWidth: 520, maxWidth: 640)
            .fixedSize(horizontal: false, vertical: true).task { component.refresh() }
            .confirmationDialog(tr("卸载网络组件？"), isPresented: $confirmsRemoval, titleVisibility: .visible) {
                Button(tr("卸载组件"), role: .destructive) { component.uninstall() }
                Button(tr("取消"), role: .cancel) {}
            } message: { Text(tr("将停止查看、移除系统扩展和后台项目，并删除伴随应用。")) }
    }
}
