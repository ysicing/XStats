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
  private var section: AppServicesSection { model.settings.appServicesSection }
  private var tab: AppManagementController.Tab { section == .homebrew ? .homebrew : .apps }
  private struct BrowsingState {
    var search = ""
    var selection: String?
    var sortOrder = [KeyPathComparator<ManagedApplicationRow>(\.name)]
    var filter: BrewFilter = .all
  }
  @State private var browsingStates: [AppServicesSection: BrowsingState] = [:]
  @State private var search = ""
  @FocusState private var isSearchFocused: Bool
  @State private var selection: String?
  @State private var sortOrder = [KeyPathComparator<ManagedApplicationRow>(\.name)]
  @State private var filter: BrewFilter = .all
  @State private var showsUninstall = false
  @State private var pendingBrew: BrewConfirmation?
  private var controller: AppManagementController { model.appManagement }
  private var checkingUpdates: Bool {
    tab == .apps ? controller.isCheckingAppStore : controller.isCheckingUpdates
  }
  private var isScanning: Bool {
    tab == .apps ? controller.isLoadingApps || controller.isMeasuringApps : controller.isLoadingBrew
  }
  private var showsRefreshProgress: Bool {
    tab == .apps
      ? !controller.isRestoringAppCache
        && (controller.isRefreshingApps || (!controller.hasAppInventory && isScanning)) : isScanning
  }

  var body: some View {
    let rows = section.managesApplications ? visibleRows() : []
    let selected = rows.first { $0.id == selection }
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      toolbar
      if section == .services {
        HomebrewServicesPage(search: search)
      } else if section == .startup {
        StartupItemsPage(section: section, search: search)
      } else {
        if let error = controller.error {
          InfoBanner(icon: "exclamationmark.triangle", text: error, tone: .error)
        }
        if tab == .apps, controller.brewInventoryFailed {
          // 清单失败时普通卸载降级可用；如实提示 Cask 安装的应用此时不会走 Homebrew 卸载。
          Label(tr("无法识别 Homebrew 来源，由 Homebrew 安装的应用请在终端卸载"), systemImage: "info.circle")
            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        }
        if tab == .homebrew, !controller.brewAvailable, !isSnapshot {
          ContentUnavailableView(
            tr("尚未安装 Homebrew"), systemImage: "shippingbox",
            description: Text(tr("安装 Homebrew 后，可在这里管理 Formula 与 Cask。"))
          )
          .frame(maxHeight: .infinity)
          Link(tr("了解 Homebrew"), destination: URL(string: "https://brew.sh")!)
        } else {
          applicationTable(rows)
          footer(rows: rows, selected: selected)
        }
      }
    }
    .padding([.horizontal, .bottom], DS.Space.s3)
    .overlay(alignment: .bottom) {
      ZStack {
        if section.managesApplications, let completion = controller.completion {
          Label {
            Text(completion.text).foregroundStyle(DS.Palette.textPrimary)
          } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Badge.successText)
          }
          .dsFont(.sm)
          .lineLimit(2)
          .padding(.horizontal, DS.Space.s4).padding(.vertical, DS.Space.s3)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
          .dsShadow(DS.Shadow.level1)
          .frame(maxWidth: 420)
          .padding(.horizontal, DS.Space.s4).padding(.bottom, DS.Space.s12)
          .id(completion.id)
          .transition(.opacity)
        }
      }
      .animation(reduceMotion ? nil : DS.Motion.quick, value: controller.completion?.id)
      .allowsHitTesting(false)
    }
    .task(id: controller.completion?.id) {
      guard let id = controller.completion?.id else { return }
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      controller.dismissCompletion(id)
    }
    .onAppear {
      controller.setVisible(model.isMainWindowVisible && section.managesApplications, tab: tab)
    }
    .onDisappear {
      controller.setVisible(false)
      pendingBrew = nil
      model.uninstaller.cancelScanning()
    }
    .onChange(of: model.isMainWindowVisible) { _, visible in
      controller.setVisible(visible && section.managesApplications, tab: tab)
      if !visible {
        pendingBrew = nil
        model.uninstaller.cancelScanning(preservingConfirmation: true)
      }
    }
    .onChange(of: section) { previous, current in
      browsingStates[previous] = BrowsingState(
        search: search, selection: selection, sortOrder: sortOrder, filter: filter)
      let state = browsingStates[current] ?? BrowsingState()
      search = state.search
      selection = state.selection
      sortOrder = state.sortOrder
      filter = state.filter
      pendingBrew = nil
      Task { @MainActor in
        // 分类更新可能处于布局周期内；延后控制器更新，避免在 AppKit 布局中再次使约束失效。
        await Task.yield()
        guard model.settings.panelTab == .uninstaller,
          model.settings.appServicesSection == current
        else { return }
        controller.setVisible(false)
        controller.selectTab(tab)
        controller.setVisible(
          model.isMainWindowVisible && current.managesApplications, tab: tab)
      }
    }
    .onChange(of: model.uninstaller.isRemoving) { old, new in
      if old && !new { controller.reloadInventory() }
    }
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      guard section.managesApplications, controller.operation == nil, let provider = providers.first
      else { return false }
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        guard let url else { return }
        Task { @MainActor in uninstall(url: url) }
      }
      return true
    }
    .sheet(isPresented: $showsUninstall, onDismiss: { model.uninstaller.select(nil) }) {
      AppUninstallInspector().environment(model).interactiveDismissDisabled(
        model.uninstaller.isRemoving)
    }
    .sheet(item: $pendingBrew) { confirmation in
      HomebrewConfirmationSheet(confirmation: confirmation) {
        guard !model.uninstaller.isRemoving else { return }
        controller.perform(confirmation.action, package: confirmation.package)
        pendingBrew = nil
      } cancel: {
        pendingBrew = nil
      }
    }
  }

  private var toolbar: some View {
    // 分类与搜索之间留出分组间距，切换标签时位置稳定；窄窗口让搜索换行。
    ViewThatFits(in: .horizontal) {
      HStack(spacing: DS.Space.s6) {
        categoryPicker
        searchField.frame(width: 280)
        Spacer(minLength: DS.Space.s4)
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
    }
    .dsFont(.sm)
    // 与 PageScroll 的内容边距对齐，也为原生控件的边缘留出空间。
    .padding(.horizontal, DS.Space.s3)
    // 顶栏位于页面上方，给玻璃按钮的上缘和阴影留出空间，避免被顶栏遮住。
    .padding(.top, DS.Space.s2)
  }

  private var categoryPicker: some View {
    @Bindable var settings = model.settings
    return Picker(tr("应用服务"), selection: $settings.appServicesSection) {
      ForEach(AppServicesSection.allCases, id: \.self) { value in
        Text(value.title).tag(value)
      }
    }
    .pickerStyle(.segmented).labelsHidden().controlSize(.large)
    .fixedSize(horizontal: true, vertical: false)
    .frame(height: DS.Size.controlHeight)
    .disabled(model.uninstaller.isRemoving)
    .accessibilityIdentifier("app-services-category")
  }

  private var searchField: some View {
    HStack(spacing: DS.Space.s2) {
      Image(systemName: "magnifyingglass").foregroundStyle(DS.Palette.textTertiary)
      TextField(section.searchPrompt, text: $search)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
      if !search.isEmpty {
        MiniIconButton(systemName: "xmark.circle.fill", help: tr("清除搜索")) { search = "" }
      }
    }
    .padding(.horizontal, DS.Space.s4)
    .frame(height: DS.Size.controlHeight)
    .background(DS.Palette.surface, in: Capsule())
    .overlay {
      Capsule()
        .strokeBorder(
          isSearchFocused ? DS.Palette.primary : DS.Palette.border, lineWidth: DS.Size.stroke
        )
        .allowsHitTesting(false)
    }
  }

  private var toolbarActions: some View {
    HStack(spacing: DS.Space.s2) {
      if section == .services {
        IconButton(systemName: "arrow.clockwise", help: tr("刷新")) {
          model.homebrewServices.refresh()
        }
        .disabled(
          model.homebrewServices.isLoading || model.homebrewServices.working != nil)
      } else if section == .startup {
        Button(tr("登录项设置")) { model.helper.openLoginItemsSettings() }
          .buttonStyle(DSButtonStyle(kind: .secondary))
          .fixedSize()
        IconButton(systemName: "arrow.clockwise", help: tr("刷新")) { model.startupItems.refresh() }
          .disabled(model.startupItems.isLoading || model.startupItems.working != nil)
      } else {
        if tab == .homebrew {
          Menu {
            Picker(tr("筛选"), selection: $filter) {
              ForEach(BrewFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
          } label: {
            Label(filter.title, systemImage: "line.3.horizontal.decrease")
              .lineLimit(1).fixedSize()
          }
          .buttonStyle(DSButtonStyle(kind: .secondary))
          .fixedSize()
          .help(tr("筛选"))
          .accessibilityLabel(tr("筛选"))
          .accessibilityValue(filter.title)
        }
        Button {
          if tab == .apps {
            controller.checkAppStoreUpdates(force: true)
          } else {
            controller.checkBrewUpdates()
          }
        } label: {
          Text(tr("检查更新"))
            .opacity(checkingUpdates ? 0 : 1)
            .overlay {
              if checkingUpdates { ProgressView().controlSize(.small).transition(.opacity) }
            }
        }
        .buttonStyle(DSButtonStyle(kind: .secondary))
        .fixedSize()
        .animation(reduceMotion ? nil : DS.Motion.usageSelection, value: checkingUpdates)
        .help(tab == .apps ? tr("检查 App Store 更新") : tr("检查 Homebrew 更新"))
        .accessibilityLabel(
          checkingUpdates
            ? tr("正在检查更新") : (tab == .apps ? tr("检查 App Store 更新") : tr("检查 Homebrew 更新"))
        )
        .disabled(
          checkingUpdates || controller.operation != nil || model.uninstaller.isRemoving
            || (tab == .homebrew && controller.homebrewOperations.isRunning)
            || (tab == .apps
              ? controller.isLoadingApps || !controller.hasAppInventory
              : !controller.brewAvailable || controller.isLoadingBrew)
        )
        IconButton(systemName: "arrow.clockwise", help: tr("刷新本地清单")) { controller.refresh() }
          .opacity(showsRefreshProgress ? 0 : 1)
          .overlay {
            if showsRefreshProgress { ProgressView().controlSize(.small).transition(.opacity) }
          }
          .animation(reduceMotion ? nil : DS.Motion.usageSelection, value: showsRefreshProgress)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(showsRefreshProgress ? tr("正在读取…") : tr("刷新本地清单"))
          .disabled(
            showsRefreshProgress || (tab == .apps && controller.isRestoringAppCache)
              || controller.operation != nil || checkingUpdates)
      }
    }
  }

  private func applicationTable(_ rows: [ManagedApplicationRow]) -> some View {
    Group {
      // 两个页面使用固定列组合，避免条件列在宽窗口留下空白占位；兼容 macOS 14.0。
      if tab == .apps {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
          applicationColumns
          sizeColumn
          kindColumn
          lastOpenedColumn
          sourceColumn
        }
      } else {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
          applicationColumns
          kindColumn
          sizeColumn
          installedAtColumn
          sourceColumn
          descriptionColumn
        }
      }
    }
    .tableStyle(.inset(alternatesRowBackgrounds: true))
    .dsFont(.sm)
    .overlay {
      if rows.isEmpty {
        if controller.error == nil && (isScanning || (tab == .apps && !controller.hasAppInventory))
        {
          if tab != .apps || !controller.isRestoringAppCache { ProgressView(tr("正在读取…")) }
        } else if controller.error != nil
          && (tab == .apps ? !controller.hasAppInventory : !controller.hasBrewInventory)
        {
          ContentUnavailableView(tr("暂时无法读取清单"), systemImage: "exclamationmark.triangle")
        } else if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          ContentUnavailableView.search(text: search)
        } else if tab == .homebrew {
          if controller.packages.isEmpty {
            ContentUnavailableView(tr("尚未安装软件包"), systemImage: "shippingbox")
          } else if filter == .updates {
            // outdated 来自本地索引，不把尚未刷新远端的清单描述为“已是最新”。
            ContentUnavailableView(
              tr("没有可用更新"), systemImage: "checkmark.circle",
              description: Text(tr("当前清单中没有需要更新的软件包，可点击“检查更新”刷新。")))
          } else {
            ContentUnavailableView(
              tr("没有匹配的软件包"), systemImage: "line.3.horizontal.decrease",
              description: Text(tr("尝试选择其他筛选条件。")))
          }
        } else {
          ContentUnavailableView(tr("没有找到应用"), systemImage: "app.dashed")
        }
      }
    }
    .contextMenu(forSelectionType: String.self) { ids in
      if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
        actions(for: row).disabled(model.uninstaller.isRemoving)
      }
    } primaryAction: { ids in
      if let id = ids.first, let app = rows.first(where: { $0.id == id })?.app {
        NSWorkspace.shared.open(app.url)
      }
    }
  }

  @TableColumnBuilder<ManagedApplicationRow, KeyPathComparator<ManagedApplicationRow>>
  private var applicationColumns:
    some TableColumnContent<ManagedApplicationRow, KeyPathComparator<ManagedApplicationRow>>
  {
    TableColumn(tr("名称"), value: \.name) { row in
      HStack(spacing: DS.Space.s2) {
        if let path = row.app?.url.path ?? row.package?.applicationURLs.first?.path {
          AppIconCache.shared.image(bundlePath: path).resizable().frame(width: 18, height: 18)
        } else {
          Image(systemName: "shippingbox").foregroundStyle(DS.Palette.textSecondary).frame(
            width: 18)
        }
        Text(verbatim: row.name).lineLimit(1)
        if row.isRunning {
          Circle().fill(DS.Palette.success).frame(width: 5, height: 5).accessibilityLabel(
            tr("正在运行"))
        }
        if row.package?.pinned == true {
          Image(systemName: "pin.fill").foregroundStyle(DS.Palette.textTertiary).help(tr("已固定版本"))
        }
      }.help(row.app?.url.path ?? row.package?.name ?? row.name)
    }.width(min: 170, ideal: 240)
    TableColumn(tr("版本"), value: \.version) { row in
      HStack(spacing: DS.Space.s2) {
        HStack(spacing: DS.Space.s1) {
          Text(verbatim: row.version)
            .foregroundStyle(
              row.availableVersion == nil ? DS.Palette.textPrimary : DS.Palette.textSecondary)
          if let latest = row.availableVersion {
            Text(verbatim: "→").foregroundStyle(DS.Palette.textTertiary).accessibilityHidden(true)
            Text(verbatim: latest)
          }
        }
        .lineLimit(1).help(row.versionDisplay)
        .environment(\.layoutDirection, .leftToRight)
        if let package = row.package, package.outdated {
          let updating =
            controller.operation == .upgrade && controller.operationPackage?.id == package.id
          Button {
            pendingBrew = BrewConfirmation(package: package, action: .upgrade)
          } label: {
            ZStack {
              Text(tr("更新")).hidden()
              Text(tr("更新中…")).hidden()
              Text(updating ? tr("更新中…") : tr("更新"))
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : DS.Motion.usageSelection, value: updating)
            }
            .dsFont(.sm)
          }
          .buttonStyle(.bordered).tint(DS.Palette.primary).controlSize(.small).fixedSize()
          .help(tr("更新软件包…"))
          .accessibilityLabel(updating ? tr("更新中…") : tr("更新软件包…"))
          .disabled(upgradeIsDisabled(for: row))
        }
        if let app = row.app, row.storeUpdate != nil {
          Button(tr("更新")) { controller.openAppStoreUpdate(for: app) }
            .buttonStyle(.bordered).tint(DS.Palette.primary).controlSize(.small).fixedSize()
            .help(tr("在 App Store 更新"))
            .accessibilityLabel(tr("在 App Store 更新"))
            .disabled(controller.operation != nil || model.uninstaller.isRemoving)
        }
      }
    }.width(min: 150, ideal: 200, max: 360)
  }

  private var sizeColumn:
    some TableColumnContent<ManagedApplicationRow, KeyPathComparator<ManagedApplicationRow>>
  {
    TableColumn(tr("大小"), value: \.sizeSort) { row in
      Text(verbatim: row.size.map { Format.bytes($0, base: .decimal) } ?? "—")
        .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }.width(85)
  }

  private var kindColumn:
    some TableColumnContent<ManagedApplicationRow, KeyPathComparator<ManagedApplicationRow>>
  {
    TableColumn(tr("类型"), value: \.kind) { row in
      Text(verbatim: row.kind).lineLimit(1)
        .help(row.package?.kind == .formula ? "Formula · " + row.kind : row.kind)
    }.width(min: 85, ideal: 105, max: 160)
  }

  private var installedAtColumn:
    some TableColumnContent<ManagedApplicationRow, KeyPathComparator<ManagedApplicationRow>>
  {
    TableColumn(tr("安装日期"), value: \.installationDateSort) { row in
      if let date = row.package?.installedAt {
        Text(date, format: .dateTime.year().month().day().locale(L10n.locale))
          .lineLimit(1)
          .help(date.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)))
      } else {
        Text("—")
      }
    }.width(min: 100, ideal: 130, max: 180)
  }

  private var descriptionColumn:
    some TableColumnContent<ManagedApplicationRow, KeyPathComparator<ManagedApplicationRow>>
  {
    TableColumn(tr("描述"), value: \.summary) { row in
      Text(verbatim: row.summary).lineLimit(1).help(row.summary)
        .foregroundStyle(DS.Palette.textSecondary)
    }.width(min: 150, ideal: 240)
  }

  private var sourceColumn:
    some TableColumnContent<ManagedApplicationRow, KeyPathComparator<ManagedApplicationRow>>
  {
    TableColumn(tr("来源"), value: \.source) { row in
      Text(verbatim: row.source).lineLimit(1).help(row.source)
    }
    .width(min: 85, ideal: 110, max: 180)
  }

  private var lastOpenedColumn:
    some TableColumnContent<ManagedApplicationRow, KeyPathComparator<ManagedApplicationRow>>
  {
    TableColumn(tr("上次打开"), value: \.dateSort) { row in
      if let date = row.lastOpened {
        Text(date, format: .dateTime.year().month().day().locale(L10n.locale))
          .help(date.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)))
      } else {
        Text("—")
      }
    }.width(min: 100, ideal: 130, max: 170)
  }

  private func footer(rows: [ManagedApplicationRow], selected: ManagedApplicationRow?) -> some View
  {
    HStack(spacing: DS.Space.s3) {
      let count = rows.count.formatted(.number.locale(L10n.locale))
      Text(tr("\(count) 项"))
      let known = rows.compactMap(\.size)
      if !known.isEmpty {
        let bytes = Format.bytes(known.reduce(0, +), base: .decimal)
        Text(verbatim: known.count == rows.count ? bytes : tr("已计量 \(bytes)"))
      }
      if checkingUpdates {
        ProgressView().controlSize(.small)
        Text(tr("正在检查更新"))
      }
      if let action = controller.operation {
        ProgressView().controlSize(.small)
        Text(action == .upgrade ? tr("正在更新软件包…") : tr("正在卸载软件包…"))
      }
      Spacer(minLength: 0).frame(height: 20)
      if let selected { actions(for: selected).disabled(model.uninstaller.isRemoving) }
    }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
  }

  @ViewBuilder private func actions(for row: ManagedApplicationRow) -> some View {
    if let app = row.app {
      if row.storeUpdate != nil {
        Button(tr("在 App Store 更新")) { controller.openAppStoreUpdate(for: app) }
          .disabled(controller.operation != nil)
      }
      Button(tr("打开")) { NSWorkspace.shared.open(app.url) }
      Button(tr("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
      if row.isRunning, let cask = controller.casksByPath[app.id], !controller.isCurrentApp(cask) {
        Button(tr("退出应用")) { model.uninstaller.quit(app) }
      }
      Button(tr("卸载…"), role: .destructive) { uninstall(url: app.url) }
        .disabled(
          controller.operation != nil || controller.isLoadingBrew || !controller.hasBrewInventory
            || (controller.casksByPath[app.id] != nil && controller.homebrewOperations.isRunning)
            || (row.isRunning && controller.casksByPath[app.id] != nil)
            || app.bundleIdentifier.hasPrefix("com.apple.")
            || app.bundleIdentifier.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "")
              == .orderedSame
        )
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
          .disabled(upgradeIsDisabled(for: row))
      }
      if let url = package.installationURLs.first {
        Button(tr("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
      }
      Button(tr("卸载…"), role: .destructive) {
        pendingBrew = BrewConfirmation(package: package, action: .uninstall)
      }
      .disabled(
        row.isRunning || controller.isCurrentApp(package) || controller.homebrewOperations.isRunning
          || controller.isCheckingUpdates)
    }
  }

  private func upgradeIsDisabled(for row: ManagedApplicationRow) -> Bool {
    guard let package = row.package else { return true }
    return package.pinned || row.isRunning || controller.isCurrentApp(package)
      || controller.homebrewOperations.isRunning || controller.isCheckingUpdates
      || model.uninstaller.isRemoving
  }

  private func uninstall(url: URL) {
    guard section.managesApplications, controller.visible, model.isMainWindowVisible,
      model.settings.panelTab == .uninstaller,
      controller.operation == nil, !model.uninstaller.isRemoving,
      !controller.isLoadingBrew, controller.hasBrewInventory
    else { return }
    if let cask = controller.casksByPath[url.standardizedFileURL.path],
      !controller.isCurrentApp(cask)
    {
      guard !controller.homebrewOperations.isRunning else { return }
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
        return ManagedApplicationRow(
          id: app.id, name: app.name, version: app.version ?? "—",
          size: controller.sizes[app.id], kind: metadata?.architecture.title ?? "—",
          lastOpened: metadata?.lastOpened,
          source: controller.homebrewAppPaths.contains(app.id)
            ? "Homebrew" : metadata?.isAppStore == true ? "App Store" : "—",
          isRunning: controller.runningAppIDs.contains(app.id), app: app, package: nil,
          storeUpdate: controller.homebrewAppPaths.contains(app.id)
            ? nil : controller.appStoreUpdates[app.id])
      }
    } else {
      rows = controller.packages.filter { filter.matches($0) }.map { package in
        let kind: String
        if package.kind == .cask {
          kind = "Cask"
        } else {
          kind =
            switch package.installReason {
            case .requested: tr("手动安装")
            case .dependency: tr("依赖")
            case .unknown: tr("未知")
            }
        }
        return ManagedApplicationRow(
          id: package.id, name: package.displayName, version: package.version,
          size: controller.packageSizes[package.id], kind: kind,
          lastOpened: nil,
          source: package.name.contains("/")
            ? package.name.split(separator: "/").dropLast().joined(separator: "/")
            : (package.kind == .formula ? "homebrew/core" : "homebrew/cask"),
          isRunning: controller.runningPackageIDs.contains(package.id), app: nil, package: package)
      }
    }
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return rows.filter {
      query.isEmpty || $0.name.localizedStandardContains(query)
        || ($0.app?.bundleIdentifier ?? $0.package?.name ?? "").localizedStandardContains(query)
        || ($0.package?.summary?.localizedStandardContains(query) == true)
    }
    .sorted(using: sortOrder)
  }
}

private struct ManagedApplicationRow: Identifiable {
  let id: String
  let name: String
  let version: String
  var availableVersion: String? {
    if let storeUpdate { return storeUpdate.version }
    guard let package, package.outdated, let latest = package.latestVersion,
      !latest.isEmpty, latest != version
    else { return nil }
    return latest
  }
  var versionDisplay: String {
    guard let latest = availableVersion else { return version }
    return "\(version) → \(latest)"
  }
  let size: UInt64?
  var sizeSort: UInt64 { size ?? 0 }
  let kind: String
  let lastOpened: Date?
  var dateSort: String {
    lastOpened.map { String(format: "%020.3f", $0.timeIntervalSince1970) } ?? ""
  }
  let source: String
  let isRunning: Bool
  let app: InstalledApp?
  let package: HomebrewPackage?
  var storeUpdate: AppStoreUpdates.Entry? = nil
  var installationDateSort: Date { package?.installedAt ?? .distantPast }
  var summary: String { package?.summary ?? "—" }
}

private enum BrewFilter: String, CaseIterable, Identifiable {
  case all, formula, cask, updates
  var id: Self { self }
  var title: String {
    switch self {
    case .all: tr("全部")
    case .formula: "Formula"
    case .cask: "Cask"
    case .updates: tr("有可用更新")
    }
  }
  func matches(_ package: HomebrewPackage) -> Bool {
    switch self {
    case .all: true
    case .formula: package.kind == .formula
    case .cask: package.kind == .cask
    case .updates: package.outdated
    }
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
    VStack(alignment: .leading, spacing: DS.Space.s6) {
      VStack(alignment: .leading, spacing: DS.Space.s2) {
        Text(
          confirmation.action == .upgrade
            ? tr("更新“\(confirmation.package.displayName)”？")
            : tr("卸载“\(confirmation.package.displayName)”？")
        )
        .dsFont(.lg, weight: .semibold)
        .fixedSize(horizontal: false, vertical: true)
        Text(
          confirmation.action == .upgrade
            ? tr("Homebrew 会更新所选项目及必要的依赖。") : tr("将通过 Homebrew 从电脑中卸载此项目。")
        )
        .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        // 标题已说明对象；仅在完整标识不同（如自定义 tap）时补充，避免重复显示。
        if confirmation.package.name != confirmation.package.displayName {
          Text(verbatim: confirmation.package.name)
            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.layoutDirection, .leftToRight)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: DS.Space.s2) {
        Spacer()
        Button(action: cancel) {
          Text(tr("取消")).frame(minWidth: 64)
        }
        .buttonStyle(.bordered).keyboardShortcut(.cancelAction)
        Button(
          role: confirmation.action == .uninstall ? .destructive : nil, action: confirm
        ) {
          Text(confirmation.action == .upgrade ? tr("更新软件包") : tr("卸载"))
            .frame(minWidth: 64)
        }
        .buttonStyle(.borderedProminent).tint(
          confirmation.action == .upgrade ? DS.Palette.primary : DS.Palette.error)
      }
      .controlSize(.large).fixedSize(horizontal: false, vertical: true)
    }
    .padding(DS.Space.s6).frame(width: 420)
    .fixedSize(horizontal: false, vertical: true).appLanguageEnvironment()
  }
}

struct AppUninstallInspector: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  private var showsResultOnly: Bool {
    model.uninstaller.selected == nil && model.uninstaller.outcome?.isError == true
  }

  var body: some View {
    VStack(spacing: DS.Space.s3) {
      HStack {
        Text(tr("卸载应用")).dsFont(.lg, weight: .semibold)
        Spacer()
        MiniIconButton(systemName: "xmark", help: tr("关闭面板")) { dismiss() }
          .keyboardShortcut(.cancelAction)
          .disabled(model.uninstaller.isRemoving)
      }
      if showsResultOnly {
        outcomeBanner
        Button(tr("完成")) { dismiss() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .frame(maxWidth: .infinity, alignment: .trailing)
      } else {
        ScrollView {
          if let app = model.uninstaller.selected {
            AppDetailCard(app: app) { model.uninstaller.requestUninstall() }
          }
          outcomeBanner
        }
      }
    }.padding(DS.Space.s4).frame(width: 560, height: showsResultOnly ? nil : 560)
      // 错误结果没有可重试项目时按内容收紧，成功结果直接关闭面板。
      .fixedSize(horizontal: false, vertical: true)
      .onChange(of: model.uninstaller.selected) { previous, current in
        guard let previous, current == nil, !model.uninstaller.isRemoving,
          let outcome = model.uninstaller.outcome, !outcome.isError
        else { return }
        // 仅全部处理成功时返回列表；部分失败与未处理残留仍留在面板内。
        model.appManagement.showUninstallCompletion(for: previous)
        dismiss()
      }
      .onChange(of: model.isMainWindowVisible) { _, visible in
        if visible { model.uninstaller.resumeSelectionScan() }
      }
      .sheet(
        item: Binding(
          get: { model.uninstaller.pendingUninstall },
          set: { if $0 == nil { model.uninstaller.cancelUninstall() } })
      ) { app in
        UninstallConfirmationSheet(app: app, uninstaller: model.uninstaller)
      }
      .appLanguageEnvironment()
  }

  @ViewBuilder private var outcomeBanner: some View {
    if let outcome = model.uninstaller.outcome {
      InfoBanner(
        icon: outcome.isError ? "exclamationmark.triangle" : "checkmark.circle",
        text: outcome.text, tone: outcome.isError ? .error : .success)
    }
  }
}
