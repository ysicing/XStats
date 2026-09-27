// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Localization
import Metrics
import SwiftUI

struct ProjectPurgeWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var showingPaths = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("项目产物"))
                    .dsFont(.base, weight: .semibold)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Button { showingPaths = true } label: {
                    Label(tr("扫描位置"), systemImage: "folder")
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .disabled(model.projectPurge.isBusy)
            }
            .padding(.leading, DS.Size.trafficLightsWidth + DS.Space.s4)
            .padding(.trailing, DS.Space.s3)
            .frame(height: DS.Size.windowHeader)
            .background(WindowDragArea())
            .background(DS.Palette.background)
            .zIndex(1)

            if model.projectPurge.phase == .idle && model.projectPurge.result == nil {
                ProjectPurgeEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PageScroll { ProjectPurgeCard() }
            }
        }
        .background(DS.Palette.background)
        .ignoresSafeArea()
        .appLanguageEnvironment()
        .sheet(isPresented: $showingPaths) { ProjectPurgePathsSheet() }
    }
}

private struct ProjectPurgePathsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var addFailed = false

    var body: some View {
        let purge = model.projectPurge
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Text(tr("扫描目录"))
                .dsFont(.base, weight: .semibold)
            Text(tr("仅扫描列表中的目录。移除后可通过“恢复默认”找回默认位置。"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)

            if !purge.pathsLoaded {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.s4)
            } else if purge.roots.isEmpty {
                Text(tr("没有扫描目录"))
                    .dsFont(.sm).foregroundStyle(DS.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DS.Space.s4)
            } else {
                ScrollView {
                    VStack(spacing: DS.Space.s1) {
                        ForEach(purge.roots, id: \.path) { root in
                            HStack(spacing: DS.Space.s2) {
                                Image(systemName: "folder").foregroundStyle(DS.Palette.textSecondary)
                                Text(root.path).dsFont(.sm)
                                    .lineLimit(1).truncationMode(.middle).help(root.path)
                                Spacer(minLength: DS.Space.s2)
                                Button { purge.removeRoot(root) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .help(tr("移除目录"))
                                .accessibilityLabel(tr("移除目录"))
                                .disabled(purge.isBusy || purge.isLoadingPaths)
                            }
                            .padding(.vertical, DS.Space.s1)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            if addFailed {
                Text(tr("目录无效或已经添加"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.warning)
            }

            HStack {
                Button(tr("添加目录…")) { chooseDirectories() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(purge.isBusy || !purge.pathsLoaded || purge.isLoadingPaths)
                Button(tr("恢复默认")) {
                    addFailed = false
                    Task { await purge.restoreDefaults() }
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .disabled(purge.isBusy || purge.isLoadingPaths || purge.isUsingDefaults)
                Spacer()
                Button(tr("完成")) { dismiss() }
                    .buttonStyle(DSButtonStyle(kind: .primary))
            }
        }
        .padding(DS.Space.s4)
        .frame(width: 580)
        .onAppear { Task { await model.projectPurge.loadPaths() } }
    }

    private func chooseDirectories() {
        let panel = NSOpenPanel()
        panel.title = tr("选择项目目录")
        panel.prompt = tr("添加")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        addFailed = false
        for url in panel.urls {
            if !model.projectPurge.addRoot(url) { addFailed = true }
        }
    }
}

private struct ProjectPurgeEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: DS.Space.s3) {
            Image(systemName: "shippingbox")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(DS.Palette.textTertiary)
            Text(tr("尚未扫描项目"))
                .dsFont(.base, weight: .semibold)
                .foregroundStyle(DS.Palette.textPrimary)
            Text(tr("按需扫描项目构建产物，逐项选择后移到废纸篓。"))
                .dsFont(.sm)
                .foregroundStyle(DS.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button(tr("扫描项目")) { model.projectPurge.scan() }
                .buttonStyle(DSButtonStyle(kind: .primary))
        }
        .frame(maxWidth: 440)
        .padding(DS.Space.s4)
    }
}

// MARK: - 项目产物

private struct ProjectPurgeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let purge = model.projectPurge
        Card(padding: DS.Space.s3, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Text(tr("按需扫描项目构建产物，逐项选择后移到废纸篓。"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                Spacer(minLength: DS.Space.s2)
                if let result = purge.result {
                    Text(verbatim: tr("\(result.items.count) 项 · \(Format.bytes(result.items.reduce(0) { $0 + $1.bytes }, base: .decimal))"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                }
            }

            HStack(spacing: DS.Space.s2) {
                if purge.phase == .scanning {
                    ProgressView().controlSize(.small)
                    Text(tr("正在扫描项目…")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    Button(tr("取消")) { purge.cancelScan() }.buttonStyle(DSButtonStyle(kind: .secondary))
                } else if purge.phase == .cleaning {
                    ProgressView().controlSize(.small)
                    Text(tr("正在清理…")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    Button(tr("取消")) { purge.cancelClean() }.buttonStyle(DSButtonStyle(kind: .secondary))
                } else {
                    Button(purge.result == nil ? tr("扫描项目") : tr("重新扫描")) { purge.scan() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                    if purge.result != nil {
                        Button(tr("移到废纸篓 \(Format.bytes(purge.selectedBytes, base: .decimal))")) { purge.requestClean() }
                            .buttonStyle(DSButtonStyle(kind: .primary))
                            .disabled(purge.selectedItems.isEmpty)
                    }
                }
                Spacer()
            }

            if purge.isConfirming {
                let selected = purge.selectedItems
                let warnings = [selected.contains(where: \.isRecent) ? tr("所选内容包含最近 7 天有活动的项目，清理后需要重新构建。") : nil,
                                selected.contains(where: \.isCloud) ? tr("云盘项目可能同步删除。") : nil].compactMap { $0 }
                let text = ([tr("将 \(selected.count) 项移到废纸篓，清空前可以恢复。")] + warnings).joined(separator: " ")
                InfoBanner(icon: "exclamationmark.triangle.fill", text: text, tone: .warning) {
                    Button(tr("取消")) { purge.isConfirming = false }.buttonStyle(DSButtonStyle(kind: .secondary))
                    Button(tr("确认清理")) { purge.confirmClean() }.buttonStyle(DSButtonStyle(kind: .primary))
                }
            }

            if let report = purge.report, purge.phase == .finished {
                Text(tr("已移到废纸篓 \(report.trashedCount) 项 · \(Format.bytes(report.trashedBytes, base: .decimal))"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.success)
                if report.skippedCount > 0 || !report.failures.isEmpty {
                    Text(tr("跳过 \(report.skippedCount) 项 · 失败 \(report.failures.count) 项"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.warning)
                }
            }

            if let result = purge.result {
                if !result.failedRoots.isEmpty {
                    Text(tr("\(result.failedRoots.count) 个目录未完成扫描，结果已排除"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.warning)
                    ForEach(result.failedRoots, id: \.path) { root in
                        Text(root.path).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                            .lineLimit(1).truncationMode(.middle).help(root.path)
                    }
                }
                if result.protectedCount > 0 {
                    Text(tr("\(result.protectedCount) 项含手写或被 Git 跟踪的内容，已保护"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                }
                if result.unverifiedCount > 0 {
                    Text(result.developerToolsMissing
                         ? tr("未安装 Xcode 命令行工具，无法确认 Git 仓库中的 \(result.unverifiedCount) 项是否被跟踪，已保留")
                         : tr("\(result.unverifiedCount) 项无法确认，已保留"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if result.items.isEmpty && result.failedRoots.isEmpty {
                    Text(tr("没有发现可清理的项目产物"))
                        .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
                }
                LazyVStack(alignment: .leading, spacing: DS.Space.s2) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: DS.Space.s1) {
                            HStack {
                                Text(group.project.path).dsFont(.xs, weight: .semibold)
                                    .lineLimit(1).truncationMode(.middle).help(group.project.path)
                                Spacer()
                                Text(verbatim: Format.bytes(group.bytes, base: .decimal))
                                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                            }
                            ForEach(group.items) { item in
                                ProjectPurgeRow(item: item)
                            }
                        }
                        .padding(.top, DS.Space.s1)
                    }
                }
            }
        }
    }

    private var groups: [ProjectPurgeGroup] {
        let items = model.projectPurge.result?.items ?? []
        // 扫描结果已按项目总大小排好，这里保持首次出现的顺序
        let grouped = Dictionary(grouping: items, by: \.project.path)
        var seen = Set<String>()
        return items.compactMap { item in
            guard seen.insert(item.project.path).inserted, let members = grouped[item.project.path] else { return nil }
            return ProjectPurgeGroup(project: item.project, items: members)
        }
    }
}

private struct ProjectPurgeGroup: Identifiable {
    var id: String { project.path }
    let project: URL
    let items: [ProjectPurgeItem]
    var bytes: UInt64 { items.reduce(0) { $0 + $1.bytes } }
}

private struct ProjectPurgeRow: View {
    @Environment(AppModel.self) private var model
    let item: ProjectPurgeItem

    var body: some View {
        let purge = model.projectPurge
        HStack(spacing: DS.Space.s2) {
            DSCheckbox(isOn: purge.selection.contains(item.id)) { purge.toggle(item) }
                .disabled(purge.isBusy)
            Image(systemName: "folder").foregroundStyle(DS.Palette.textSecondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.url.lastPathComponent).dsFont(.sm, weight: .medium)
                HStack(spacing: DS.Space.s1) {
                    Text(item.isRecent ? tr("最近 7 天有活动") : tr("超过 7 天未使用"))
                    if item.isCloud { Text(tr("云盘")) }
                    if item.isWorktree { Text(tr("Agent 工作树")) }
                }
                .dsFont(.xs).foregroundStyle(item.isRecent || item.isCloud ? DS.Palette.warning : DS.Palette.textTertiary)
            }
            Spacer()
            Text(verbatim: Format.bytes(item.bytes, base: .decimal)).dsFont(.sm).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                Image(systemName: "arrow.up.forward.square")
            }
            .buttonStyle(.plain).help(tr("在访达中显示"))
        }
    }
}
