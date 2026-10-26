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
  var candidates: [NetworkLeakTest.Candidate] = []
  var httpExit: String?
  var dnsResult: NetworkLeakTest.DNSResult?
  var timedOut = false
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private let logger = Logger(
    subsystem: "work.12306.xstats", category: "LeakTest")

  func start(_ mode: Mode) {
    cancel()
    candidates = []
    httpExit = nil
    dnsResult = nil
    timedOut = false
    phase = .running
    let run = generation
    logger.debug("Leak test started: \(mode.rawValue, privacy: .public)")
    task = Task {
      do {
        if mode == .webRTC {
          let result = try await WebRTCLeakProbe().run()
          try Task.checkCancellation()
          let exit = await LocalIPQuery.fetch(.ipify)
          try Task.checkCancellation()
          guard run == generation else { return }
          if case .success(let addresses) = exit { httpExit = addresses.ipv4 ?? addresses.ipv6 }
          candidates = result.candidates
          timedOut = result.timedOut
        } else {
          let result = try await NetworkLeakTest.dns()
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
  @Binding var hideIP: Bool
  @State private var showsInformation = false

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      ScrollView {
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
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Toggle(tr("隐藏 IP"), isOn: $hideIP).toggleStyle(.checkbox)
        MiniIconButton(systemName: "info.circle", help: tr("检测说明")) {
          showsInformation.toggle()
        }
        .popover(isPresented: $showsInformation) {
          Text(
            tr(
              mode == .webRTC
                ? "检测 XStats 内 WebKit 暴露的地址，不代表其他浏览器。开始后连接 Cloudflare、Google、BlackBerry、Twilio STUN 与 ipify。"
                : "通过 bash.ws 观察本次请求的 DNS 解析服务器；结果受系统代理与分流影响。")
          )
          .dsFont(.sm)
          .fixedSize(horizontal: false, vertical: true)
          .padding(DS.Space.s4)
          .frame(width: 360)
        }
        Spacer()
        if controller.phase == .running {
          Button(tr("取消")) { controller.cancel() }
        } else {
          Button(tr("开始检测")) { controller.start(mode) }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(DS.Space.s4)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DS.Palette.background)
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
    case .idle: "点击开始检测，结果仅保留在当前窗口。"
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
      Text("WebRTC / ICE").dsFont(.sm, weight: .semibold)
      ForEach(controller.candidates) { candidate in
        HStack(alignment: .top) {
          address(candidate.address)
          Spacer()
          VStack(alignment: .trailing, spacing: DS.Space.s1) {
            Text(verbatim: candidate.kind).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            if let matches = NetworkLeakTest.matchesExit(candidate, exit: controller.httpExit) {
              Text(tr(matches ? "与 HTTP 出口一致" : "与 HTTP 出口不同，请核对代理路线"))
                .dsFont(.xs).foregroundStyle(
                  matches ? DS.Palette.textSecondary : DS.Palette.warning
                )
                .multilineTextAlignment(.trailing)
            }
          }
        }.padding(.vertical, DS.Space.s1)
      }
      if !controller.candidates.contains(where: \.isReflexive) {
        Text(tr("未取得 STUN 公网地址，无法判断是否存在泄漏。"))
          .dsFont(.sm).foregroundStyle(DS.Palette.warning)
      } else if controller.timedOut {
        Text(tr("检测超时，以下仅为已收到的部分结果。"))
          .dsFont(.sm).foregroundStyle(DS.Palette.warning)
      }
      Text(tr("仅比较同一地址族；地址不同可能来自分流，不直接代表泄漏。"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
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
          if !hideIP {
            Text(
              verbatim: [resolver.country, resolver.organization].filter { !$0.isEmpty }.joined(
                separator: " · ")
            )
            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled)
          }
        }.padding(.vertical, DS.Space.s1)
      }
      Text(tr("请核对解析服务器是否符合你的 VPN 或 DNS 配置；多个服务器不代表泄漏。"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    }
  }

  @ViewBuilder private func address(_ value: String?) -> some View {
    if hideIP {
      Text(tr("信息已隐藏")).foregroundStyle(DS.Palette.textSecondary)
    } else if let value {
      Text(verbatim: value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
    } else {
      Text(tr("未获取到地址")).foregroundStyle(DS.Palette.textSecondary)
    }
  }
}
