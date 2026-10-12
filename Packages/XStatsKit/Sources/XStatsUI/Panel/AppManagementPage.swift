// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Localization
import Metrics
import SwiftUI
import UniformTypeIdentifiers

/// 用系统表格处理键盘选择、列排序和滚动；卸载沿用原来的预览与确认。
struct AppManagementPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: AppManagementController.Tab = .apps
    @State private var search = ""
    @State private var selection: String?
    @State private var sortOrder = [KeyPathComparator<ManagedApplicationRow>(\.name)]
    @State private var filter: BrewFilter = .all
    @State private var showsUninstall = false
    @State private var pendingBrew: BrewConfirmation?
    private var controller: AppManagementController { model.appManagement }
    private var isScanning: Bool {
        tab == .apps ? controller.isLoadingApps || controller.isMeasuringApps : controller.isLoadingBrew
    }

    init(tab: AppManagementController.Tab = .apps) { _tab = State(initialValue: tab) }

    var body: some View {
        let rows = visibleRows()
        let selected = rows.first { $0.id == selection }
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            toolbar
            if let error = controller.error {
                InfoBanner(icon: "exclamationmark.triangle", text: error, tone: .error)
            } else if let message = controller.message {
                InfoBanner(icon: "checkmark.circle", text: message, tone: .success)
            }
            if tab == .homebrew, !controller.brewAvailable, !isSnapshot {
                ContentUnavailableView(tr("尚未安装 Homebrew"), systemImage: "shippingbox", description: Text(tr("安装 Homebrew 后，可在这里管理 Formula 与 Cask。")))
                    .frame(maxHeight: .infinity)
                Link(tr("了解 Homebrew"), destination: URL(string: "https://brew.sh")!)
            } else {
                applicationTable(rows)
                footer(rows: rows, selected: selected)
            }
        }
        .padding([.horizontal, .bottom], DS.Space.s3)
        .onAppear { controller.setVisible(model.isMainWindowVisible, tab: tab) }
        .onDisappear { controller.setVisible(false); pendingBrew = nil; model.uninstaller.cancelScanning() }
        .onChange(of: model.isMainWindowVisible) { _, visible in
            controller.setVisible(visible, tab: tab)
            if !visible { pendingBrew = nil; model.uninstaller.cancelScanning() }
        }
        .onChange(of: tab) { _, value in selection = nil; search = ""; controller.selectTab(value) }
        .onChange(of: model.uninstaller.isRemoving) { old, new in
            if old && !new { controller.refresh() }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard controller.operation == nil, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in uninstall(url: url) }
            }
            return true
        }
        .sheet(isPresented: $showsUninstall, onDismiss: { model.uninstaller.select(nil) }) {
            AppUninstallInspector().environment(model).interactiveDismissDisabled(model.uninstaller.isRemoving)
        }
        .sheet(item: $pendingBrew) { confirmation in
            HomebrewConfirmationSheet(confirmation: confirmation) {
                guard !model.uninstaller.isRemoving else { return }
                controller.perform(confirmation.action, package: confirmation.package)
                pendingBrew = nil
            } cancel: { pendingBrew = nil }
        }
    }

    private var toolbar: some View {
        // 宽窗口把查找与操作聚在一起；窄窗口仅让搜索换行，避免挤压分类和操作标签。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s3) {
                categoryPicker
                Spacer(minLength: DS.Space.s4)
                searchField.frame(minWidth: 180, idealWidth: 240, maxWidth: 280)
                toolbarActions
            }
            VStack(spacing: DS.Space.s2) {
                HStack(spacing: DS.Space.s3) {
                    categoryPicker
                    Spacer(minLength: DS.Space.s3)
                    toolbarActions
                }
                searchField
            }
        }.dsFont(.sm)
    }

    private var categoryPicker: some View {
        Picker(tr("应用类型"), selection: $tab) {
            Text("App").tag(AppManagementController.Tab.apps)
            Text("Homebrew").tag(AppManagementController.Tab.homebrew)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.large)
        .frame(width: 175, height: DS.Size.controlHeight)
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.s2) {
            Image(systemName: "magnifyingglass").foregroundStyle(DS.Palette.textTertiary)
            TextField(tr("搜索应用或软件包"), text: $search).textFieldStyle(.plain)
            if !search.isEmpty { MiniIconButton(systemName: "xmark.circle.fill", help: tr("清除搜索")) { search = "" } }
        }
        .padding(.horizontal, DS.Space.s3)
        .frame(height: DS.Size.controlHeight)
        .background(DS.Palette.elevated, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    private var toolbarActions: some View {
        HStack(spacing: DS.Space.s2) {
            if tab == .homebrew {
                Menu {
                    Picker(tr("筛选"), selection: $filter) {
                        ForEach(BrewFilter.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Label(filter.title, systemImage: "line.3.horizontal.decrease")
                        .lineLimit(1).fixedSize()
                }
                .buttonStyle(DSButtonStyle(kind: .secondary))
                .fixedSize()
                .help(tr("筛选"))
                .accessibilityLabel(tr("筛选"))
                Button(tr("检查更新")) { controller.checkBrewUpdates() }
                    .buttonStyle(DSButtonStyle(kind: .secondary))
                    .fixedSize()
                    .disabled(!controller.brewAvailable || controller.isLoadingBrew || controller.operation != nil)
            }
            IconButton(systemName: "arrow.clockwise", help: tr("重新扫描")) { controller.refresh() }
                .opacity(isScanning ? 0 : 1)
                .overlay {
                    if isScanning { ProgressView().controlSize(.small).transition(.opacity) }
                }
                .animation(reduceMotion ? nil : DS.Motion.usageSelection, value: isScanning)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(isScanning ? tr("正在读取…") : tr("重新扫描"))
                .disabled(isScanning || controller.operation != nil || controller.isCheckingUpdates)
        }
    }

    private func applicationTable(_ rows: [ManagedApplicationRow]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(tr("名称"), value: \.name) { row in
                HStack(spacing: DS.Space.s2) {
                    if let path = row.app?.url.path ?? row.package?.applicationURLs.first?.path {
                        AppIconCache.shared.image(bundlePath: path).resizable().frame(width: 18, height: 18)
                    } else { Image(systemName: "shippingbox").foregroundStyle(DS.Palette.textSecondary).frame(width: 18) }
                    Text(verbatim: row.name).lineLimit(1)
                    if row.isRunning {
                        Circle().fill(DS.Palette.success).frame(width: 5, height: 5).accessibilityLabel(tr("正在运行"))
                    }
                    if row.package?.outdated == true {
                        Image(systemName: "arrow.up.circle.fill").foregroundStyle(DS.Palette.primary).help(tr("有可用更新"))
                    }
                    if row.package?.pinned == true {
                        Image(systemName: "pin.fill").foregroundStyle(DS.Palette.textTertiary).help(tr("已固定版本"))
                    }
                }.help(row.app?.url.path ?? row.package?.name ?? row.name)
            }.width(min: 170, ideal: 240)
            TableColumn(tr("版本"), value: \.version) { row in
                Text(verbatim: row.version).lineLimit(1).help(row.version)
            }.width(min: 70, ideal: 110, max: 160)
            TableColumn(tr("大小"), value: \.sizeSort) { row in
                Text(verbatim: row.size.map { Format.bytes($0, base: .decimal) } ?? "—")
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }.width(85)
            TableColumn(tr("类型"), value: \.kind) { row in Text(verbatim: row.kind).lineLimit(1) }.width(min: 85, ideal: 105, max: 150)
            TableColumn(tab == .apps ? tr("上次打开") : tr("最新版本"), value: \.dateSort) { row in
                if tab == .homebrew { Text(verbatim: row.package?.latestVersion ?? "—").lineLimit(1) }
                else if let date = row.lastOpened {
                    Text(date, format: .dateTime.year().month().day().locale(L10n.locale))
                        .help(date.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)))
                } else { Text("—") }
            }.width(min: 100, ideal: 130, max: 170)
            TableColumn(tr("来源"), value: \.source) { row in Text(verbatim: row.source).lineLimit(1).help(row.source) }
                .width(min: 85, ideal: 110, max: 180)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .dsFont(.sm)
        .overlay {
            if rows.isEmpty {
                if controller.error == nil && (isScanning || (tab == .apps && !controller.hasAppInventory)) {
                    ProgressView(tr("正在读取…"))
                } else { ContentUnavailableView.search(text: search) }
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                actions(for: row).disabled(model.uninstaller.isRemoving)
            }
        } primaryAction: { ids in
            if let id = ids.first, let app = rows.first(where: { $0.id == id })?.app { NSWorkspace.shared.open(app.url) }
        }
    }

    private func footer(rows: [ManagedApplicationRow], selected: ManagedApplicationRow?) -> some View {
        HStack(spacing: DS.Space.s3) {
            let count = rows.count.formatted(.number.locale(L10n.locale))
            Text(tr("\(count) 项"))
            let known = rows.compactMap(\.size)
            if !known.isEmpty {
                Text(verbatim: (known.count == rows.count ? "" : tr("已计量") + " ") + Format.bytes(known.reduce(0, +), base: .decimal))
            }
            if controller.isCheckingUpdates { ProgressView().controlSize(.small); Text(tr("正在检查更新")) }
            if let action = controller.operation {
                ProgressView().controlSize(.small)
                Text(action == .upgrade ? tr("正在更新软件包…") : tr("正在卸载软件包…"))
            }
            Spacer(minLength: 0)
            if let selected { actions(for: selected).disabled(model.uninstaller.isRemoving) }
        }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    }

    @ViewBuilder private func actions(for row: ManagedApplicationRow) -> some View {
        if let app = row.app {
            Button(tr("打开")) { NSWorkspace.shared.open(app.url) }
            Button(tr("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            if row.isRunning, let cask = controller.casksByPath[app.id], !controller.isCurrentApp(cask) {
                Button(tr("退出应用")) { model.uninstaller.quit(app) }
            }
            Button(tr("卸载…"), role: .destructive) { uninstall(url: app.url) }
                .disabled(controller.operation != nil || controller.isLoadingBrew || !controller.hasBrewInventory || (row.isRunning && controller.casksByPath[app.id] != nil) || app.bundleIdentifier.hasPrefix("com.apple.") || app.bundleIdentifier.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") == .orderedSame)
        } else if let package = row.package {
            if row.isRunning, !controller.isCurrentApp(package) {
                Button(tr("退出应用")) {
                    for url in package.applicationURLs {
                        if let app = AppUninstaller.app(at: url) { model.uninstaller.quit(app) }
                    }
                }.disabled(controller.operation != nil)
            }
            if package.outdated {
                Button(tr("更新软件包…")) { pendingBrew = BrewConfirmation(package: package, action: .upgrade) }
                    .disabled(package.pinned || row.isRunning || controller.isCurrentApp(package) || controller.operation != nil || controller.isCheckingUpdates)
            }
            if let url = package.installationURLs.first {
                Button(tr("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button(tr("卸载…"), role: .destructive) { pendingBrew = BrewConfirmation(package: package, action: .uninstall) }
                .disabled(row.isRunning || controller.isCurrentApp(package) || controller.operation != nil || controller.isCheckingUpdates)
        }
    }

    private func uninstall(url: URL) {
        guard controller.visible, model.isMainWindowVisible, model.settings.panelTab == .uninstaller,
              controller.operation == nil, !model.uninstaller.isRemoving,
              !controller.isLoadingBrew, controller.hasBrewInventory else { return }
        if let cask = controller.casksByPath[url.standardizedFileURL.path], !controller.isCurrentApp(cask) {
            guard !controller.isRunning(cask) else {
                controller.error = tr("应用正在运行，请先退出")
                return
            }
            pendingBrew = BrewConfirmation(package: cask, action: .uninstall)
            return
        }
        model.uninstaller.select(url: url)
        showsUninstall = model.uninstaller.selected != nil
        if !showsUninstall { controller.error = model.uninstaller.outcome?.text }
    }

    private func visibleRows() -> [ManagedApplicationRow] {
        let rows: [ManagedApplicationRow]
        if tab == .apps {
            rows = controller.apps.map { app in
                let metadata = controller.metadata[app.id]
                return ManagedApplicationRow(id: app.id, name: app.name, version: app.version ?? "—",
                    size: controller.sizes[app.id], kind: metadata?.architecture.title ?? "—", lastOpened: metadata?.lastOpened,
                    source: controller.casksByPath[app.id] != nil ? "Homebrew" : metadata?.isAppStore == true ? "App Store" : "—",
                    isRunning: controller.runningPaths.contains(app.id), app: app, package: nil)
            }
        } else {
            rows = controller.packages.filter { filter.matches($0) }.map { package in
                ManagedApplicationRow(id: package.id, name: package.displayName, version: package.version,
                    size: controller.packageSizes[package.id], kind: package.kind == .formula ? "Formula" : "Cask",
                    lastOpened: nil, source: package.name.contains("/") ? package.name.split(separator: "/").dropLast().joined(separator: "/") : (package.kind == .formula ? "homebrew/core" : "homebrew/cask"),
                    isRunning: package.applicationURLs.contains { controller.runningPaths.contains($0.path) }, app: nil, package: package)
            }
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return rows.filter { query.isEmpty || $0.name.localizedStandardContains(query) || ($0.app?.bundleIdentifier ?? $0.package?.name ?? "").localizedStandardContains(query) }
            .sorted(using: sortOrder)
    }
}

private struct ManagedApplicationRow: Identifiable {
    let id: String
    let name: String
    let version: String
    let size: UInt64?
    var sizeSort: UInt64 { size ?? 0 }
    let kind: String
    let lastOpened: Date?
    var dateSort: String { package?.latestVersion ?? lastOpened.map { String(format: "%020.3f", $0.timeIntervalSince1970) } ?? "" }
    let source: String
    let isRunning: Bool
    let app: InstalledApp?
    let package: HomebrewPackage?
}

private enum BrewFilter: String, CaseIterable, Identifiable {
    case all, formula, cask, updates
    var id: Self { self }
    var title: String {
        switch self { case .all: tr("全部"); case .formula: "Formula"; case .cask: "Cask"; case .updates: tr("有可用更新") }
    }
    func matches(_ package: HomebrewPackage) -> Bool {
        switch self { case .all: true; case .formula: package.kind == .formula; case .cask: package.kind == .cask; case .updates: package.outdated }
    }
}

extension ApplicationMetadata.Architecture {
    var title: String {
        switch self {
        case .appleSilicon: tr("Apple 芯片")
        case .intel: "Intel"
        case .universal: tr("通用架构")
        case .iOS: tr("iPhone 与 iPad")
        case .unknown: "—"
        }
    }
}

private struct BrewConfirmation: Identifiable {
    var id: String { action.rawValue + package.id }
    let package: HomebrewPackage
    let action: HomebrewManagement.Action
}

private struct HomebrewConfirmationSheet: View {
    let confirmation: BrewConfirmation
    let confirm: () -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text(confirmation.action == .upgrade ? tr("更新“\(confirmation.package.displayName)”？") : tr("卸载“\(confirmation.package.displayName)”？"))
                .dsFont(.lg, weight: .semibold)
            Text(confirmation.action == .upgrade ? tr("Homebrew 会更新所选项目及必要的依赖。") : tr("由 Homebrew 卸载所选项目，依赖保护仍然生效。"))
                .dsFont(.sm).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: confirmation.package.name).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            HStack {
                Spacer()
                Button(tr("取消"), action: cancel).keyboardShortcut(.cancelAction)
                Button(confirmation.action == .upgrade ? tr("更新软件包") : tr("卸载"), action: confirm)
                    .buttonStyle(.borderedProminent).tint(confirmation.action == .upgrade ? DS.Palette.primary : DS.Palette.error)
            }
        }.padding(DS.Space.s6).frame(width: 420).appLanguageEnvironment()
    }
}

private struct AppUninstallInspector: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: DS.Space.s3) {
            HStack {
                Text(tr("卸载应用")).dsFont(.lg, weight: .semibold)
                Spacer()
                Button(tr("关闭面板")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.uninstaller.isRemoving)
            }
            ScrollView {
                if let app = model.uninstaller.selected {
                    AppDetailCard(app: app) { model.uninstaller.requestUninstall() }
                }
                if let outcome = model.uninstaller.outcome {
                    InfoBanner(icon: outcome.isError ? "exclamationmark.triangle" : "checkmark.circle", text: outcome.text, tone: outcome.isError ? .error : .success)
                }
            }
        }.padding(DS.Space.s4).frame(width: 560, height: 560)
        .onChange(of: model.isMainWindowVisible) { _, visible in
            if visible, let app = model.uninstaller.selected { model.uninstaller.select(app) }
        }
        .sheet(item: Binding(get: { model.uninstaller.pendingUninstall }, set: { if $0 == nil { model.uninstaller.cancelUninstall() } })) { app in
            UninstallConfirmationSheet(app: app, uninstaller: model.uninstaller)
        }
        .appLanguageEnvironment()
    }
}
