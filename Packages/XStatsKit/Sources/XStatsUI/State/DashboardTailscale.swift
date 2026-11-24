// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import HelperShared
import Metrics
import Network
import notify

struct DashboardTailscaleEndpoint: Hashable, Sendable {
  let address: String
  let host: NWEndpoint.Host
  let interface: NWInterface

  static func discover(on interfaces: [NWInterface]) -> Set<Self> {
    let tunnels = interfaces.filter { $0.type == .other && $0.name.hasPrefix("utun") }
    guard !tunnels.isEmpty else { return [] }
    let addresses = NetworkDetailsReader.readLocalInterfaces()
    var local: [NWEndpoint.Host: NWInterface] = [:]
    for interface in addresses where interface.kind == .tunnel {
      guard let tunnel = tunnels.first(where: { $0.name == interface.bsdName }) else { continue }
      for address in interface.ipv4 + interface.ipv6 {
        let host = NWEndpoint.Host(address)
        if DashboardPeer.isTailscaleAddress(host) { local[host] = tunnel }
      }
    }
    guard !local.isEmpty else { return [] }
    for command in [
      "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
      "/opt/homebrew/bin/tailscale",
      "/usr/local/bin/tailscale",
    ] where FileManager.default.isExecutableFile(atPath: command) {
      guard !Task.isCancelled else { return [] }
      let result = HelperToolRunner.run(
        path: command, arguments: ["ip"], timeout: 2, maximumOutputBytes: 4096)
      guard result.status == 0 else { continue }
      // 地址必须同时由 Tailscale 报告，并实际配置在本机的同名隧道上。
      let endpoints = result.output.split(whereSeparator: \.isNewline).compactMap { line -> Self? in
        let address = line.trimmingCharacters(in: .whitespaces)
        let host = NWEndpoint.Host(address)
        guard let interface = local[host] else { return nil }
        return Self(address: address, host: host, interface: interface)
      }
      if !endpoints.isEmpty { return Set(endpoints) }
    }
    return []
  }

  static func watch(_ onChange: @MainActor (Set<Self>) -> Void) async {
    let monitor = NWPathMonitor(requiredInterfaceType: .other)
    let (changes, continuation) = AsyncStream<[NWInterface]>.makeStream(
      bufferingPolicy: .bufferingNewest(1))
    monitor.pathUpdateHandler = { path in continuation.yield(path.availableInterfaces) }
    monitor.start(queue: .global(qos: .utility))
    var token: Int32 = 0
    let registered = notify_register_dispatch(kNotifySCNetworkChange, &token, .main) { _ in
      continuation.yield(monitor.currentPath.availableInterfaces)
    }
    defer {
      if registered == NOTIFY_STATUS_OK { notify_cancel(token) }
      monitor.cancel()
      continuation.finish()
    }
    for await interfaces in changes {
      guard !Task.isCancelled else { return }
      let probe = Task.detached(priority: .utility) { discover(on: interfaces) }
      let endpoints = await withTaskCancellationHandler {
        await probe.value
      } onCancel: {
        probe.cancel()
      }
      guard !Task.isCancelled else { return }
      await onChange(endpoints)
    }
  }
}
