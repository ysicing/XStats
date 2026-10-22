// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Localization
import SwiftUI

struct HomebrewServicesPage: View {
  @Environment(AppModel.self) private var model
  @Environment(\.isSnapshot) private var isSnapshot
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let search: String
  @State private var pendingAction: HomebrewServices.Action?
  @State private var pendingService: HomebrewService?

  var body: some View {
    let controller = model.homebrewServices
    let services = Self.filteredServices(controller.services, search: search)
    PageScroll {
      if let error = controller.error {
        InfoBanner(icon: "exclamationmark.triangle", text: error, tone: .error)
      }
      if !controller.brewAvailable && !isSnapshot {
        ContentUnavailableView(
          tr("尚未安装 Homebrew"), systemImage: "shippingbox",
          description: Text(tr("安装 Homebrew 后，可在这里管理服务。")))
      } else {
        Card(padding: 0, spacing: 0) {
          CardHeader(icon: "server.rack", title: tr("Homebrew 服务")) {
            if controller.isLoading && !services.isEmpty {
              ProgressView().controlSize(.small).accessibilityLabel(tr("正在读取…"))
            } else if !controller.isLoading {
              Text(services.count, format: .number)
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            }
          }
          .padding(DS.Space.s4)
          HairlineDivider()
          if controller.isLoading && services.isEmpty {
            ProgressView(tr("正在读取…")).controlSize(.small)
              .padding(DS.Space.s4)
          } else if services.isEmpty && controller.error == nil {
            Text(search.isEmpty ? tr("没有 Homebrew 服务") : tr("没有匹配的项目"))
              .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
              .padding(DS.Space.s4)
          }
          ForEach(Array(services.enumerated()), id: \.element.id) { index, service in
            if index > 0 {
              HairlineDivider().padding(.leading, DS.Space.s4 + DS.Size.controlHeight + DS.Space.s3)
            }
            HomebrewServiceRow(
              service: service, isWorking: controller.working == service.id,
              canManage: service.canManage(currentUser: isSnapshot ? "demo" : NSUserName()),
              actionsDisabled: controller.isLoading || controller.working != nil
                || controller.error != nil
            ) { action in
              pendingService = service
              pendingAction = action
            }
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        Label(
          tr("管理当前用户的 Homebrew 服务；系统级服务只读。"), systemImage: "info.circle"
        )
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DS.Space.s1)
      }
    }
    .overlay(alignment: .bottom) {
      ZStack {
        if controller.error == nil, let completion = controller.completion {
          InfoBanner(icon: "checkmark.circle", text: completion, tone: .success)
            .frame(maxWidth: DS.Size.windowDefaultContentWidth)
            .padding(DS.Space.s4)
            .transition(.opacity)
        }
      }
      .animation(reduceMotion ? nil : DS.Motion.quick, value: controller.completion)
      .allowsHitTesting(false)
    }
    .task(id: controller.completion) {
      guard let completion = controller.completion else { return }
      do { try await Task.sleep(for: .seconds(3)) } catch { return }
      controller.dismissCompletion(completion)
    }
    .confirmationDialog(
      pendingService.map { tr("管理服务“\($0.name)”") } ?? "",
      isPresented: Binding(
        get: { pendingAction != nil },
        set: {
          if !$0 {
            pendingAction = nil
            pendingService = nil
          }
        }),
      titleVisibility: .visible
    ) {
      if let action = pendingAction, let service = pendingService {
        Button(Self.actionTitle(action)) { controller.perform(action, service: service) }
      }
      Button(tr("取消"), role: .cancel) {}
    } message: {
      Text(tr("启动或重启可能同时开启登录时自动启动；停止会取消自动启动。"))
    }
    .onAppear {
      if !isSnapshot { controller.setVisible(model.isMainWindowVisible) }
    }
    .onDisappear {
      if !isSnapshot { controller.setVisible(false) }
      if let completion = controller.completion { controller.dismissCompletion(completion) }
      pendingAction = nil
      pendingService = nil
    }
    .onChange(of: model.isMainWindowVisible) { _, visible in
      if !isSnapshot { controller.setVisible(visible) }
      if !visible {
        pendingAction = nil
        pendingService = nil
      }
    }
  }

  static func filteredServices(_ services: [HomebrewService], search: String) -> [HomebrewService] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return services }
    return services.filter {
      $0.name.localizedStandardContains(query)
        || ($0.user?.localizedStandardContains(query) ?? false)
    }
  }

  static func actionTitle(_ action: HomebrewServices.Action) -> String {
    switch action {
    case .start: tr("启动服务")
    case .stop: tr("停止服务")
    case .restart: tr("重启服务")
    }
  }

  static func primaryAction(_ service: HomebrewService) -> HomebrewServices.Action {
    switch service.status {
    case "started", "scheduled": .stop
    case "error": .restart
    default: .start
    }
  }

  static func statusTitle(_ service: HomebrewService) -> String {
    switch service.status {
    case "started": tr("服务运行中")
    case "scheduled": tr("已安排定时运行")
    case "stopped": tr("服务已停止")
    case "none": tr("服务未启动")
    case "error":
      service.exitCode.map { tr("服务异常（退出码 \($0)）") } ?? tr("服务异常")
    default: tr("未知")
    }
  }
}

private struct HomebrewServiceRow: View {
  let service: HomebrewService
  let isWorking: Bool
  let canManage: Bool
  let actionsDisabled: Bool
  let onAction: (HomebrewServices.Action) -> Void

  var body: some View {
    HStack(spacing: DS.Space.s3) {
      Image(systemName: "server.rack")
        .font(.system(size: DS.Size.iconInline, weight: .medium))
        .foregroundStyle(DS.Palette.textSecondary)
        .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
        .background(DS.Palette.elevated, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: DS.Space.s1) {
        Text(verbatim: service.name)
          .dsFont(.sm, weight: .medium)
          .foregroundStyle(DS.Palette.textPrimary)
          .lineLimit(2)
          .help(service.name)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: DS.Space.s3) {
            status
            owner
          }
          VStack(alignment: .leading, spacing: DS.Space.s1) {
            status
            owner
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if canManage {
        let primary = HomebrewServicesPage.primaryAction(service)
        let primaryIcon =
          switch primary {
          case .start: "play.fill"
          case .stop: "stop.fill"
          case .restart: "arrow.clockwise"
          }
        HStack(spacing: DS.Space.s2) {
          Button {
            onAction(primary)
          } label: {
            HStack(spacing: DS.Space.s1) {
              ZStack {
                Image(systemName: primaryIcon).opacity(isWorking ? 0 : 1)
                if isWorking { ProgressView().controlSize(.mini) }
              }
              .frame(width: DS.Size.iconInline, height: DS.Size.iconInline)
              Text(HomebrewServicesPage.actionTitle(primary))
            }
            .dsFont(.xs, weight: .medium)
          }
          .buttonStyle(.bordered).controlSize(.small)
          Menu {
            ForEach(HomebrewServices.Action.allCases, id: \.self) { action in
              Button(HomebrewServicesPage.actionTitle(action)) { onAction(action) }
            }
          } label: {
            Image(systemName: "ellipsis")
              .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
              .contentShape(Rectangle())
          }
          .menuStyle(.borderlessButton).menuIndicator(.hidden)
          .help(tr("管理服务"))
          .accessibilityLabel(tr("管理服务“\(service.name)”"))
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(actionsDisabled)
      } else {
        Label(tr("只读"), systemImage: "lock")
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          .fixedSize()
      }
    }
    .padding(.horizontal, DS.Space.s4)
    .padding(.vertical, DS.Space.s3)
  }

  private var status: some View {
    Label(HomebrewServicesPage.statusTitle(service), systemImage: statusIcon)
      .dsFont(.xs, weight: .medium)
      .foregroundStyle(statusTone.color)
      .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var owner: some View {
    if let user = service.user {
      Text(tr("用户 \(user)"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var statusIcon: String {
    switch service.status {
    case "started": "checkmark.circle.fill"
    case "scheduled": "clock.fill"
    case "error": "exclamationmark.triangle.fill"
    default: "circle"
    }
  }

  private var statusTone: Tone {
    switch service.status {
    case "started": .success
    case "scheduled": .primary
    case "error": .error
    default: .neutral
    }
  }
}
