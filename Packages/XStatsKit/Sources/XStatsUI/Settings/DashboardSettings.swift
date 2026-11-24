// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Metrics
import Network
import SwiftUI
import notify

struct DashboardSettings: View {
  @Environment(AppModel.self) private var model
  @State private var showsOptions = false

  var body: some View {
    @Bindable var settings = model.settings
    SettingsGroup {
      GroupRow(showsDivider: false) {
        SettingRow(
          title: tr("监控大屏"),
          subtitle: tr("同一局域网内可免登录查看这台 Mac 的只读监控数据。"),
          icon: "rectangle.inset.filled"
        ) {
          HStack(spacing: DS.Space.s2) {
            Button(tr("设置")) { showsOptions = true }
              .buttonStyle(DSButtonStyle(kind: .secondary))
              .popover(isPresented: $showsOptions, arrowEdge: .top) {
                DashboardOptionsPopover()
              }
            DSToggle(isOn: $settings.dashboardEnabled, label: tr("监控大屏"))
          }
        }
      }
    }
  }

  nonisolated static func webAddresses(for interfaces: [LocalNetworkInterface]) -> [String] {
    var result: [String] = []
    for interface in interfaces where interface.kind == .wifi || interface.kind == .ethernet {
      for address in interface.ipv4 + interface.ipv6 + interface.linkLocal {
        guard !address.contains("%"), DashboardPeer(NWEndpoint.Host(address)) == .local,
          !result.contains(address)
        else { continue }
        result.append(address)
      }
    }
    return result
  }
}

private struct DashboardOptionsPopover: View {
  @Environment(AppModel.self) private var model
  @State private var portText = ""
  @State private var lanAddresses: [String] = []

  private var proposedPort: UInt16? {
    UInt16(portText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
  }

  private var canSavePort: Bool {
    guard let proposedPort else { return false }
    return proposedPort != model.settings.dashboardPort
      && !DashboardController.browserBlockedPorts.contains(proposedPort)
  }

  var body: some View {
    @Bindable var settings = model.settings
    let port = settings.dashboardPort
    let dashboardStatus = model.dashboard.status
    let listening = settings.dashboardEnabled && dashboardStatus == .listening
    let observeAddresses = listening && model.isMainWindowVisible
    let tailscaleIPv4Addresses =
      settings.dashboardTailscaleEnabled
      ? model.dashboard.tailscaleAddresses.filter { IPv4Address($0) != nil } : []
    SettingsGroup {
      GroupRow(showsDivider: false) {
        SettingRow(
          title: tr("监听端口"),
          subtitle: portStatus(dashboardStatus, enabled: settings.dashboardEnabled)
        ) {
          HStack(spacing: DS.Space.s2) {
            TextField(tr("监听端口"), text: $portText)
              .labelsHidden()
              .textFieldStyle(.roundedBorder)
              .monospacedDigit()
              .frame(width: 76)
              .onSubmit(savePort)
            Button(tr("保存"), action: savePort)
              .buttonStyle(DSButtonStyle(kind: .secondary))
              .disabled(!canSavePort)
          }
        }
      }
      GroupRow {
        SettingRow(title: tr("允许通过 Tailscale 访问"), subtitle: tailscaleSubtitle(listening)) {
          DSToggle(isOn: $settings.dashboardTailscaleEnabled, label: tr("允许通过 Tailscale 访问"))
        }
      }
      if listening {
        let localWebAddresses = lanAddresses.isEmpty ? ["127.0.0.1"] : lanAddresses
        GroupRow {
          SettingRow(title: tr("网页地址")) {
            VStack(alignment: .trailing, spacing: DS.Space.s1) {
              ForEach(localWebAddresses + tailscaleIPv4Addresses, id: \.self) { address in
                let text = addressURL(address, port: port, path: "/")
                if let url = URL(string: text) {
                  Link(text, destination: url)
                    .monospacedDigit()
                    .environment(\.layoutDirection, .leftToRight)
                }
              }
            }
          }
        }
        GroupRow {
          SettingRow(title: tr("MCP 地址")) {
            VStack(alignment: .trailing, spacing: DS.Space.s1) {
              ForEach(["127.0.0.1"] + tailscaleIPv4Addresses, id: \.self) { address in
                copyAddress(addressURL(address, port: port, path: "/mcp"))
              }
            }
          }
        }
      }
    }
    .padding(DS.Space.s4)
    .frame(width: 540)
    .onChange(of: port, initial: true) { _, newPort in portText = String(newPort) }
    .task(id: observeAddresses) {
      lanAddresses = []
      guard observeAddresses else { return }
      let (changes, continuation) = AsyncStream<Void>.makeStream(
        bufferingPolicy: .bufferingNewest(1))
      var token: Int32 = 0
      let registered = notify_register_dispatch(kNotifySCNetworkChange, &token, .main) { _ in
        continuation.yield(())
      }
      defer {
        if registered == NOTIFY_STATUS_OK { notify_cancel(token) }
      }
      continuation.yield(())
      if registered != NOTIFY_STATUS_OK { continuation.finish() }
      for await _ in changes {
        let addresses = await Task.detached(priority: .utility) {
          DashboardSettings.webAddresses(
            for: NetworkDetailsReader.readLocalInterfaces(includeLinkLocalIPv4Only: true))
        }.value
        guard !Task.isCancelled else { return }
        lanAddresses = addresses
      }
    }
  }

  private func tailscaleSubtitle(_ listening: Bool) -> String? {
    if listening && model.settings.dashboardTailscaleEnabled
      && model.dashboard.tailscaleStatus == .failed
    {
      return tr("没有可用的 Tailscale 监听地址，请检查连接。")
    }
    return nil
  }

  private func addressURL(_ address: String, port: UInt16, path: String) -> String {
    let host = address.contains(":") ? "[\(address)]" : address
    return "http://\(host):\(port)\(path)"
  }

  private func copyAddress(_ address: String) -> some View {
    HStack(spacing: DS.Space.s2) {
      Text(address)
        .monospacedDigit()
        .textSelection(.enabled)
        .environment(\.layoutDirection, .leftToRight)
      Button(tr("复制")) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
      }
      .buttonStyle(DSButtonStyle(kind: .secondary))
    }
  }

  private func portStatus(_ status: DashboardController.Status, enabled: Bool) -> String? {
    if proposedPort == nil && !portText.isEmpty { return tr("输入 1–65535 之间的端口号。") }
    if let proposedPort, DashboardController.browserBlockedPorts.contains(proposedPort) {
      return tr("浏览器会阻止访问此端口，请选择其他端口。")
    }
    guard enabled else { return nil }
    if status == .listening { return nil }
    if status == .failed { return tr("无法监听此端口，请更换端口或重新开启。") }
    return tr("正在启动监控大屏…")
  }

  private func savePort() {
    guard canSavePort, let proposedPort else { return }
    model.settings.dashboardPort = proposedPort
    portText = String(proposedPort)
  }
}
