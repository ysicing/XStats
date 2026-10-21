// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.
import NetworkObservation
import Localization
import Metrics
import SwiftUI

/// 功能页的本地导航状态，不写入偏好或设置备份。
enum FeatureSettingsTab: String, CaseIterable, Identifiable {
  case basic, optional, experimental
  var id: String { rawValue }
  var title: String {
    switch self {
    case .basic: tr("基础功能")
    case .optional: tr("可选功能")
    case .experimental: tr("实验性功能")
    }
  }
}

/// 分类紧邻所控制的内容；使用原生分段控件保留键盘导航与辅助功能语义。
struct FeatureSettingsTabPicker: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Picker(
      tr("功能"),
      selection: Binding(
        get: { model.featureSettingsTab },
        set: { tab in
          DS.Motion.select { model.featureSettingsTab = tab }
        })
    ) {
      ForEach(FeatureSettingsTab.allCases) { tab in Text(tab.title).tag(tab) }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .controlSize(.large)
    .fixedSize(horizontal: true, vertical: false)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("feature-settings-category")
  }
}

/// 功能开关按基础、可选和实验性分类；切换分类不改变任何功能或采样偏好。
struct FeatureSettings: View {
  @Environment(AppModel.self) private var model
  @State private var managesNetworkComponent = false
  @State private var enablesAfterComponentInstall = false

  @Environment(\.isSnapshot) private var isSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if isSnapshot {
        Text(tr("功能")).dsFont(.sm, weight: .semibold)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, DS.Space.s3)
          .frame(height: DS.Size.windowHeader)
      }
      FeatureSettingsTabPicker()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s3)
      // 内容只做短淡入淡出，保持固定视口；选中状态、滚动起点与开关立即更新。
      ZStack(alignment: .topLeading) {
        SettingsTabPage {
          switch model.featureSettingsTab {
          case .basic: basicFeatures
          case .optional: optionalFeatures
          case .experimental: experimentalFeatures
          }
        }
        .id(model.featureSettingsTab)
        .transition(.opacity)
      }
      .dsSelectionAnimation(DS.Motion.usageSelection, value: model.featureSettingsTab)
    }
    .sheet(
      isPresented: $managesNetworkComponent, onDismiss: { enablesAfterComponentInstall = false }
    ) {
      NetworkComponentManagementView(
        onInstalled: {
          guard enablesAfterComponentInstall else { return }
          enablesAfterComponentInstall = false
          managesNetworkComponent = false
          model.enableNetworkObservation()
        }, onClose: { enablesAfterComponentInstall = false }
      ).environment(model)
    }
    .onDisappear { enablesAfterComponentInstall = false }
  }

  private var basicFeatures: some View {
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      SettingsGroup {
        ForEach(
          MonitoringModule.allCases.filter {
            $0 != .display && ($0 != .thermal || model.store.supportsFans)
          }
        ) { module in
          GroupRow(showsDivider: module != .cpu) { MonitoringFeatureRow(module: module) }
        }
      }
      Text(tr("取消菜单栏显示不会关闭对应功能。系统小组件会继续独立刷新。"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
    }
  }

  private var optionalFeatures: some View {
    @Bindable var settings = model.settings
    return VStack(alignment: .leading, spacing: DS.Space.s4) {
      SettingsGroup {
        GroupRow(showsDivider: false) {
          CaptureFeatureSettings()
        }
      }
      SettingsGroup {
        if #available(macOS 15, *) {
          GroupRow(showsDivider: false) {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
              SettingRow(title: tr("网络监视器"), subtitle: tr("只读查看应用的新连接，所有连接均放行。"), icon: "network") {
                HStack(spacing: DS.Space.s3) {
                  ViewThatFits(in: .horizontal) {
                    Button {
                      managesNetworkComponent = true
                    } label: {
                      HStack(spacing: DS.Space.s1) {
                        Text(tr("管理组件"))
                        if model.networkComponent.status?.update.phase == .available {
                          Image(systemName: "arrow.down.circle")
                            .foregroundStyle(DS.Palette.primary)
                            .accessibilityLabel(tr("网络组件有更新"))
                        }
                      }
                    }
                    .fixedSize()
                    Button {
                      managesNetworkComponent = true
                    } label: {
                      Image(
                        systemName: model.networkComponent.status?.update.phase == .available
                          ? "arrow.down.circle" : "gearshape")
                    }
                    .fixedSize()
                    .accessibilityLabel(tr("管理组件"))
                    .help(tr("管理组件"))
                  }
                  .buttonStyle(DSButtonStyle(kind: .secondary))
                  DSToggle(
                    isOn: Binding(
                      get: { settings.networkConnectionsEnabled },
                      set: { enabled in
                        if !enabled {
                          enablesAfterComponentInstall = false
                          settings.networkConnectionsEnabled = false
                        } else if model.networkComponent.requiresInstallation {
                          enablesAfterComponentInstall = true
                          managesNetworkComponent = true
                        } else {
                          model.enableNetworkObservation()
                        }
                      }), label: tr("网络监视器"))
                }
              }
              if let error = model.connectionMonitor.error {
                Text(verbatim: error).dsFont(.xs).foregroundStyle(DS.Palette.error)
                  .padding(.leading, DS.Size.iconStandalone + DS.Space.s3)
              }
            }
          }
        }
        GroupRow(showsDivider: NetworkMonitorSupport.isAvailable) {
          SettingRow(
            title: tr("进程"),
            subtitle: tr("查看全部进程、搜索排序与结束进程。") + "\n"
              + tr("刷新进程列表会增加 CPU 等资源消耗。"),
            icon: "list.bullet.rectangle"
          ) {
            DSToggle(isOn: $settings.processesEnabled, label: tr("进程"))
          }
        }
        GroupRow {
          SettingRow(
            title: tr("端口"),
            subtitle: tr("查看监听端口、已建立的连接及占用进程，可结束占用端口的进程。"),
            icon: "point.3.connected.trianglepath.dotted"
          ) {
            DSToggle(isOn: $settings.portsEnabled, label: tr("端口"))
          }
        }
        GroupRow {
          SettingRow(
            title: tr("应用"), subtitle: tr("浏览应用信息，管理 Homebrew，并预览卸载残留。"), icon: "square.grid.2x2"
          ) {
            DSToggle(isOn: $settings.uninstallerEnabled, label: tr("应用"))
              .disabled(model.uninstaller.isRemoving || model.appManagement.operation != nil)
          }
        }
        GroupRow {
          SettingRow(
            title: tr("清理"),
            subtitle: tr("按需扫描缓存、日志与项目产物，清理前逐项确认。"),
            icon: "eraser"
          ) {
            DSToggle(isOn: $settings.cleanerEnabled, label: tr("清理"))
          }
        }
      }
      SettingsGroup {
        GroupRow(showsDivider: false) {
          VStack(alignment: .leading, spacing: DS.Space.s2) {
            SettingRow(
              title: tr("AI 用量"),
              subtitle: tr("查看 AI 服务的 Token 用量与账户额度。"),
              icon: "sparkles"
            ) {
              DSToggle(isOn: $settings.aiUsageEnabled, label: tr("AI 用量"))
            }
            FeatureMenuBarToggle(item: .aiUsage)
              .padding(.leading, DS.Size.iconStandalone + DS.Space.s3)
          }
        }
        GroupRow {
          VStack(alignment: .leading, spacing: DS.Space.s2) {
            SettingRow(title: tr("音频"), subtitle: tr("系统音量、音频设备与应用音量"), icon: "speaker.wave.2") {
              DSToggle(isOn: $settings.audioEnabled, label: tr("音频"))
            }
            FeatureMenuBarToggle(item: .audio)
              .padding(.leading, DS.Size.iconStandalone + DS.Space.s3)
          }
        }
        GroupRow {
          MonitoringFeatureRow(module: .display)
        }
      }
      SettingsGroup {
        GroupRow(showsDivider: false) {
          SettingRow(
            title: tr("计时"),
            subtitle: tr("倒计时、番茄钟、秒表与护眼提醒。"),
            icon: "eye"
          ) {
            HStack(spacing: DS.Space.s2) {
              if settings.restEnabled { RestOptionsButton() }
              DSToggle(isOn: $settings.restEnabled, label: tr("计时"))
            }
          }
        }
      }
      SettingsGroup {
        GroupRow(showsDivider: false) {
          SettingRow(
            title: tr("菜单栏日历"),
            subtitle: tr("独立显示日期，点击打开月历；不受指标合并布局影响"),
            icon: "calendar"
          ) {
            HStack(spacing: DS.Space.s2) {
              if settings.calendarEnabled { CalendarOptionsButton() }
              DSToggle(isOn: $settings.calendarEnabled, label: tr("菜单栏日历"))
            }
          }
        }
      }
    }
  }

  private var experimentalFeatures: some View {
    @Bindable var settings = model.settings
    return VStack(alignment: .leading, spacing: DS.Space.s4) {
      Text(tr("实验性功能仍在探索中，可能存在兼容性或稳定性问题，后续更新中可能调整或移除。"))
        .dsFont(.xs)
        .foregroundStyle(DS.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      SettingsGroup {
        GroupRow(showsDivider: false) {
          SettingRow(
            title: tr("Agent 数据"),
            subtitle: tr("在清理页查看已安装的 AI 工具及关联数据目录，并管理 worktree。"),
            icon: "terminal"
          ) {
            DSToggle(isOn: $settings.agentDataEnabled, label: tr("Agent 数据"))
          }
        }
      }
      SettingsGroup {
        if #available(macOS 27, *) {
          MenuBarApplicationFoldingSettings()
        } else {
          GroupRow(showsDivider: false) {
            SettingRow(
              title: tr("折叠菜单栏图标"),
              subtitle: tr("按住 ⌘ 将不常用图标拖到透明分隔区左侧，保留箭头在右侧。点击箭头收起或展开；效果取决于屏幕空间。"),
              icon: "menubar.arrow.up.rectangle"
            ) {
              DSToggle(isOn: $settings.menuBarFoldingEnabled, label: tr("折叠菜单栏图标"))
            }
          }
        }
      }
    }
  }
}

/// 功能启用与菜单栏展示分开控制，不再用文字重复陈述开关状态。
private struct MonitoringFeatureRow: View {
  @Environment(AppModel.self) private var model
  let module: MonitoringModule

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s2) {
      SettingRow(
        title: module.title,
        subtitle: module == .display
          ? tr("允许调节亮度、对比度和音量")
          : module == .battery ? tr("采集温度、功耗、App 能耗和电量历史；关闭后仍显示电池基础信息") : nil,
        icon: module.symbol
      ) {
        DSToggle(
          isOn: Binding(
            get: { model.settings.isModuleEnabled(module) },
            set: { enabled in
              model.settings.setModuleEnabled(module, enabled)
            }), label: tr("启用 \(module.title)")
        )
        .disabled(module == .thermal && model.fans.isApplying)
      }
      // 展示选项直接可见，使用复选框区别于右侧的功能启用开关。
      ViewThatFits(in: .horizontal) {
        HStack(spacing: DS.Space.s4) { menuBarToggles }
        VStack(alignment: .leading, spacing: DS.Space.s2) { menuBarToggles }
      }
      .padding(.leading, DS.Size.iconStandalone + DS.Space.s3)
      if module == .thermal, let notice = model.fans.notice, model.fans.noticeIsError {
        Text(notice).dsFont(.xs).foregroundStyle(DS.Palette.error)
      }
    }
  }

  private var menuBarToggles: some View {
    ForEach(module.menuBarItems.filter { model.availableMenuBarItems.contains($0) }) { item in
      FeatureMenuBarToggle(item: item, showsItemName: module.menuBarItems.count > 1)
    }
  }
}

/// 各功能共用的展示开关，移出菜单栏仍保留功能启用状态。
private struct FeatureMenuBarToggle: View {
  @Environment(AppModel.self) private var model
  let item: MenuBarItem
  var showsItemName = false

  var body: some View {
    Toggle(
      showsItemName ? tr("在菜单栏显示\(item.popoverTitle)") : tr("在菜单栏显示"),
      isOn: Binding(
        get: { model.settings.isEnabled(item) },
        set: { model.settings.setEnabled(item, $0) })
    )
    .toggleStyle(.checkbox)
    .dsFont(.xs)
    .accessibilityLabel(tr("在菜单栏显示\(item.popoverTitle)"))
    .help(item == .display ? tr("只显示信息，参数控制在功能设置中启用") : tr("加入菜单栏时会同时启用功能"))
  }
}

/// 监控关闭时保留基础信息，不挂载实时图表、排行或控制视图。
struct DisabledMonitoringPage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
  let module: MonitoringModule

  var body: some View {
    PageScroll {
      MonitoringEnableCard(module: module)
      SectionCard(title: module.title) { information }
    }
    // 两个已关闭模块页之间切换时视图会被复用，需按模块重新读取基础信息。
    .task(id: module) {
      guard !isSnapshot else { return }
      if module == .disk { await model.store.refreshDiskCapacity() }
      if module == .network { await model.network.refreshDetails(basicOnly: true) }
    }
  }

  @ViewBuilder private var information: some View {
    let store = model.store
    switch module {
    case .cpu:
      InfoRow(label: tr("芯片"), text: store.topology.brand)
      InfoRow(label: tr("核心"), text: tr("\(store.topology.logicalCores) 核"))
      MainActorForEach(store.topology.clusters) { cluster in
        InfoRow(label: cluster.name, text: tr("\(cluster.coreIndices.count) 核"))
      }
    case .gpu:
      InfoRow(label: tr("型号"), text: store.system.gpuName ?? store.topology.brand)
      InfoRow(label: tr("图形核心"), text: store.system.gpuCoreCount.map { tr("\($0) 核") } ?? "—")
    case .memory:
      InfoRow(label: tr("内存"), text: Format.bytes(ProcessInfo.processInfo.physicalMemory))
      InfoRow(label: tr("内存类型"), text: tr("统一内存（CPU 与 GPU 共享）"))
    case .disk:
      if let disk = store.disk {
        InfoRow(label: tr("卷"), text: disk.volumeName)
        InfoRow(label: tr("容量"), text: Format.bytes(disk.total, base: .decimal))
        InfoRow(label: tr("可用"), text: Format.bytes(disk.available, base: .decimal))
      } else {
        Text(tr("正在读取…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
      }
    case .network:
      if let details = model.network.details {
        if let physical = details.physical {
          InfoRow(label: tr("接口"), text: tr("\(physical.displayName)（\(physical.bsdName)）"))
          InfoRow(label: tr("物理地址")) { CopyableText(text: physical.hardwareAddress ?? "—") }
          InfoRow(label: "IPv4") { CopyableText(text: physical.ipv4.joined(separator: ", ")) }
          InfoRow(label: "IPv6") { CopyableText(text: physical.ipv6.joined(separator: ", ")) }
        } else {
          Text(tr("未连接网络")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
        }
        InfoRow(label: "DNS") { CopyableText(text: details.dnsServers.joined(separator: ", ")) }
      } else {
        Text(tr("正在读取…")).dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
      }
    case .thermal:
      InfoRow(label: tr("芯片"), text: store.topology.brand)
      if let count = store.fanCount {
        InfoRow(label: tr("风扇"), text: count.formatted(.number.locale(L10n.locale)))
      }
    // 能耗页关闭时仍由 EnergyPage 展示基础电池信息和启用入口，不经过此页。
    case .battery: EmptyView()
    case .display: DisplayDetails()
    }
  }
}

/// 已关闭监控模块的启用入口；紧凑样式用于在保留基础信息的页面顶部提示。
struct MonitoringEnableCard: View {
  @Environment(AppModel.self) private var model
  let module: MonitoringModule
  var compact = false

  var body: some View {
    Card(padding: DS.Space.s4, spacing: compact ? DS.Space.s2 : DS.Space.s3) {
      if compact {
        HStack(spacing: DS.Space.s3) {
          Label(module.title, systemImage: module.symbol).dsFont(.sm, weight: .semibold)
          Spacer(minLength: DS.Space.s2)
          enableButton
        }
        if module == .battery {
          Text(tr("采集温度、功耗、App 能耗和电量历史；关闭后仍显示电池基础信息"))
            .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        Label(module.title, systemImage: module.symbol).dsFont(.lg, weight: .semibold)
        enableButton
      }
    }
  }

  private var enableButton: some View {
    Button(tr("启用 \(module.title)")) { model.settings.setModuleEnabled(module, true) }
      .buttonStyle(DSButtonStyle(kind: .primary))
      .fixedSize()
  }
}
