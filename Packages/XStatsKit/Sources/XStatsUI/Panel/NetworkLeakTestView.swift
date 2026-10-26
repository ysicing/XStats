// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Metrics
import OSLog
import SwiftUI

@MainActor @Observable
final class NetworkLeakTestController {
  enum Mode: String, CaseIterable {
    case webRTC = "WebRTC"
    case dns = "DNS"
  }
  enum Phase { case idle, running, complete, failed, cancelled }
  var phase: Phase = .idle
  var webRTCServices: [WebRTCLeakProbe.ServiceResult] = []
  var httpExit: String?
  var dnsResult: NetworkLeakTest.DNSResult?
  @ObservationIgnored private(set) var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private let webRTCProbe: () async throws -> WebRTCLeakProbe.Result
  @ObservationIgnored private let exitLookup: () async -> String?
  @ObservationIgnored private let dnsProbe: () async throws -> NetworkLeakTest.DNSResult
  @ObservationIgnored private let logger = Logger(
    subsystem: "work.12306.xstats", category: "LeakTest")

  init(
    webRTCProbe: @escaping () async throws -> WebRTCLeakProbe.Result = {
      try await WebRTCLeakProbe().run()
    },
    exitLookup: @escaping () async -> String? = {
      if case .success(let addresses) = await LocalIPQuery.fetch(.ipify) {
        return addresses.ipv4 ?? addresses.ipv6
      }
      return nil
    },
    dnsProbe: @escaping () async throws -> NetworkLeakTest.DNSResult = {
      try await NetworkLeakTest.dns()
    }
  ) {
    self.webRTCProbe = webRTCProbe
    self.exitLookup = exitLookup
    self.dnsProbe = dnsProbe
  }

  func start(_ mode: Mode) {
    cancel()
    webRTCServices = []
    httpExit = nil
    dnsResult = nil
    phase = .running
    let run = generation
    logger.debug("Leak test started: \(mode.rawValue, privacy: .public)")
    task = Task {
      do {
        try Task.checkCancellation()
        if mode == .webRTC {
          let result = try await webRTCProbe()
          try Task.checkCancellation()
          let exit = await exitLookup()
          try Task.checkCancellation()
          guard run == generation else { return }
          httpExit = exit
          webRTCServices = result.services
        } else {
          let result = try await dnsProbe()
          try Task.checkCancellation()
          guard run == generation else { return }
          dnsResult = result
        }
        phase = .complete
        logger.debug("Leak test completed: \(mode.rawValue, privacy: .public)")
      } catch {
        guard run == generation, !Task.isCancelled else { return }
        phase = .failed
        logger.notice("Leak test could not complete: \(mode.rawValue, privacy: .public)")
      }
      if run == generation { task = nil }
    }
  }

  func cancel() {
    generation = UUID()
    task?.cancel()
    task = nil
    if phase == .running {
      phase = .cancelled
      logger.debug("Leak test cancelled")
    }
  }
}

struct NetworkLeakTestView: View {
  let controller: NetworkLeakTestController
  let mode: NetworkLeakTestController.Mode

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      if controller.phase == .complete {
        if mode == .webRTC { webRTCResults } else { dnsResults }
      } else {
        VStack(spacing: DS.Space.s3) {
          if controller.phase == .running { ProgressView().controlSize(.small) }
          Text(tr(status)).foregroundStyle(DS.Palette.textSecondary)
            .multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, minHeight: 220)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(DS.Space.s4)
    .frame(maxWidth: .infinity)
    .onDisappear { controller.cancel() }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
      controller.cancel()
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(
        for: NSWorkspace.sessionDidResignActiveNotification)
    ) { _ in
      controller.cancel()
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
    ) { _ in
      controller.cancel()
    }
  }

  private var status: String {
    switch controller.phase {
    case .idle: "尚未检测"
    case .running: "正在检测…"
    case .failed: "检测未完成，请检查网络或稍后重试。"
    case .cancelled: "检测已取消"
    case .complete: "检测完成"
    }
  }

  private var webRTCResults: some View {
    VStack(alignment: .leading, spacing: DS.Space.s3) {
      Text("HTTP").dsFont(.sm, weight: .semibold)
      address(controller.httpExit)
      Divider()
      ForEach(controller.webRTCServices) { service in
        VStack(alignment: .leading, spacing: DS.Space.s2) {
          Text(verbatim: service.provider.rawValue).dsFont(.sm, weight: .semibold)
          ForEach(service.candidates.filter(\.isReflexive)) { candidate in
            address(candidate.address)
          }
          if service.status != .complete || !service.candidates.contains(where: \.isReflexive) {
            Text(tr(serviceStatus(service)))
              .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
          }
        }.padding(.vertical, DS.Space.s1)
        Divider()
      }
    }
  }

  private func serviceStatus(_ service: WebRTCLeakProbe.ServiceResult) -> String {
    switch service.status {
    case .running: "正在检测…"
    case .complete: "未返回公网地址"
    case .failed: "服务检测失败"
    case .timedOut: "服务检测超时"
    }
  }

  @ViewBuilder private var dnsResults: some View {
    if let result = controller.dnsResult {
      Text(tr("检测服务看到的出口")).dsFont(.sm, weight: .semibold)
      if result.exits.isEmpty { address(nil) }
      ForEach(result.exits, id: \.self) { address($0) }
      Divider()
      Text(tr("实际解析服务器")).dsFont(.sm, weight: .semibold)
      ForEach(result.resolvers) { resolver in
        VStack(alignment: .leading, spacing: DS.Space.s1) {
          address(resolver.address)
          Text(
            verbatim: [resolver.country, resolver.organization].filter { !$0.isEmpty }.joined(
              separator: " · ")
          )
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled)
        }.padding(.vertical, DS.Space.s1)
      }
      Text(tr("请核对解析服务器是否符合你的 VPN 或 DNS 配置；多个服务器不代表泄漏。"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    }
  }

  @ViewBuilder private func address(_ value: String?) -> some View {
    if let value {
      Text(verbatim: value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
    } else {
      Text(tr("未获取到地址")).foregroundStyle(DS.Palette.textSecondary)
    }
  }
}
