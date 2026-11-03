// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import Metrics
import SwiftUI

struct DNSBenchmarkWindowView: View {
  @Environment(\.locale) private var locale
  @Bindable var controller: DNSBenchmarkController
  @State private var sortByFailure = false

  private var sortedProviders: [DNSBenchmarkController.Provider] {
    controller.providers.sorted {
      let first = $0.result(for: controller.rankingTransport)
      let second = $1.result(for: controller.rankingTransport)
      if sortByFailure {
        let firstFailure = first.flatMap { $0.attempts > 0 ? $0.failureRate : nil } ?? .infinity
        let secondFailure = second.flatMap { $0.attempts > 0 ? $0.failureRate : nil } ?? .infinity
        if firstFailure != secondFailure { return firstFailure < secondFailure }
      }
      let firstLatency = first?.median ?? .infinity
      let secondLatency = second?.median ?? .infinity
      if firstLatency == secondLatency { return $0.id < $1.id }
      return firstLatency < secondLatency
    }
  }

  var body: some View {
    VStack(spacing: 0) {
      header
        .background(DS.Palette.background)
        .zIndex(1)
      PageScroll {
        controls
        if controller.environment?.hasProxy == true {
          InfoBanner(
            icon: "arrow.triangle.branch",
            text: tr("检测到代理或 VPN，测试结果受当前路由影响；DoH 也可能经过系统代理。"))
        }
        if controller.results.contains(where: \.intercepted) {
          InfoBanner(
            icon: "exclamationmark.shield",
            text: tr("普通 DNS 应答可能被沿途接管，相关结果不参与推荐。"))
        }
        if controller.recommendation != nil || controller.plainRecommendation != nil {
          recommendationCard
        }
        if controller.results.isEmpty {
          Text(tr("点击开始测试，并发比较各家 DNS 的四种协议。"))
            .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DS.Space.s4)
        } else {
          results
        }
        Text(tr("四种协议并发实测；握手单独计时，结果仅保留在窗口中。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(DS.Palette.background)
    .ignoresSafeArea()
  }

  private var header: some View {
    HStack(spacing: DS.Space.s3) {
      HStack {
        Text(tr("DNS 测试")).dsFont(.base, weight: .semibold)
        Spacer(minLength: DS.Space.s2)
      }
      .frame(maxHeight: .infinity)
      .background(WindowDragArea())
      Text(status).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).lineLimit(1)
      Button {
        if controller.phase == .running { controller.cancel() } else { controller.start() }
      } label: {
        Label(
          controller.phase == .running ? tr("停止") : tr("开始测试"),
          systemImage: controller.phase == .running ? "stop.fill" : "play.fill"
        )
        .fixedSize()
      }
      .buttonStyle(DSButtonStyle(kind: controller.phase == .running ? .secondary : .primary))
    }
    .padding(.leading, DS.Size.trafficLightsWidth + DS.Space.s4)
    .padding(.trailing, DS.Space.s4)
    .frame(height: DS.Size.windowHeader)
  }

  private var status: String {
    switch controller.phase {
    case .idle: return ""
    case .running:
      return tr(
        "测试中 \(controller.completedQueries.formatted(.number.locale(locale)))/\(controller.totalQueries.formatted(.number.locale(locale)))"
      )
    case .complete: return tr("测试完成")
    case .cancelled: return tr("测试已取消")
    case .failed: return tr("测试未完成，请重试。")
    }
  }

  private var controls: some View {
    Card {
      HStack(spacing: DS.Space.s4) {
        Text(verbatim: "UDP · TCP · DoT · DoH")
          .dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
        Spacer(minLength: 0)
        Picker(tr("测试轮数"), selection: $controller.rounds) {
          ForEach([5, 10, 20], id: \.self) { rounds in
            Text(rounds.formatted(.number.locale(locale))).tag(rounds)
          }
        }
        .pickerStyle(.menu)
      }
      HStack(spacing: DS.Space.s2) {
        TextField(tr("自定义 DNS"), text: $controller.customInput)
          .textFieldStyle(.roundedBorder)
          .onSubmit { controller.addCustomTarget() }
        Button(tr("添加")) { controller.addCustomTarget() }
          .buttonStyle(DSButtonStyle(kind: .secondary))
      }
      .help(tr("最多添加 8 个自定义 DNS"))
      if controller.customError {
        Text(tr(controller.customTargets.count >= 8 ? "最多添加 8 个自定义 DNS" : "DNS 地址格式不正确"))
          .dsFont(.xs).foregroundStyle(.red)
      }
      ForEach(controller.customTargets) { target in
        HStack(spacing: DS.Space.s2) {
          Text(verbatim: target.transport == .udp ? "UDP / TCP" : target.transport.rawValue)
            .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          Text(verbatim: endpointAddress(target))
            .dsFont(.xs).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
          Button {
            controller.removeCustomTarget(target)
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.plain)
          .accessibilityLabel(tr("移除自定义 DNS"))
        }
      }
    }
    .disabled(controller.phase == .running)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var recommendationCard: some View {
    Card {
      if let recommendation = controller.recommendation {
        HStack(alignment: .firstTextBaseline) {
          Text(tr("本次推荐")).dsFont(.sm).foregroundStyle(DS.Palette.textSecondary)
          Text(verbatim: recommendation.target.transport.rawValue)
            .dsFont(.sm, weight: .semibold).foregroundStyle(DS.Palette.primary)
        }
        Text(verbatim: recommendation.target.name).font(.title2.weight(.semibold))
        HStack(spacing: DS.Space.s2) {
          ForEach(DNSBenchmarkProtocol.allCases) { transport in
            VStack(spacing: DS.Space.s1) {
              Text(verbatim: transport.rawValue)
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
              Text(
                milliseconds(
                  controller.providers.first { $0.id == recommendation.target.providerID }?
                    .result(for: transport)?.median)
              )
              .dsFont(.base, weight: .semibold).monospacedDigit()
            }
            .frame(maxWidth: .infinity)
          }
        }
      }
      if let plain = controller.plainRecommendation {
        HStack(spacing: DS.Space.s2) {
          Text(tr("普通 DNS 推荐")).foregroundStyle(DS.Palette.textSecondary)
          Text(verbatim: plain.target.name).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
          Text(verbatim: plain.target.transport.rawValue)
          Text(milliseconds(plain.median)).monospacedDigit()
        }
        .dsFont(.xs)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private var results: some View {
    Card {
      HStack {
        Text(tr("中位延迟")).dsFont(.sm, weight: .semibold)
        Spacer(minLength: 0)
        Picker("", selection: $sortByFailure) {
          Text(tr("按延迟排序")).tag(false)
          Text(tr("按失败率排序")).tag(true)
        }
        .labelsHidden().fixedSize()
      }
      HStack(spacing: DS.Space.s2) {
        Text("DNS").frame(maxWidth: .infinity, alignment: .leading)
        ForEach(DNSBenchmarkProtocol.allCases) { transport in
          Button {
            controller.rankingTransport = transport
            sortByFailure = false
          } label: {
            HStack(spacing: 2) {
              Text(verbatim: transport.rawValue)
              if transport == controller.rankingTransport {
                Image(systemName: "arrow.down").accessibilityHidden(true)
              }
            }
            .frame(width: 64, alignment: .trailing)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help(tr("按延迟排序"))
        }
        column(tr("首次查询"))
          .help(controller.rankingTransport.rawValue)
      }
      .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      ForEach(sortedProviders) { provider in
        Divider()
        DisclosureGroup {
          ForEach(provider.results) { result in
            protocolDetails(result)
          }
        } label: {
          HStack(spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
              Text(verbatim: provider.name).lineLimit(2).truncationMode(.middle)
              if provider.isSystem {
                Text(tr("系统 DNS")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(DNSBenchmarkProtocol.allCases) { transport in
              latencyCell(provider.result(for: transport))
            }
            column(
              milliseconds(
                provider.result(for: controller.rankingTransport)?.firstQueryMilliseconds))
          }
          .dsFont(.sm).monospacedDigit().foregroundStyle(DS.Palette.textPrimary)
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  private func latencyCell(_ result: DNSBenchmarkResult?) -> some View {
    column(
      result?.median != nil
        ? milliseconds(result?.median)
        : result?.attempts == 0 && controller.phase == .running ? "…" : "—"
    )
    .foregroundStyle(
      result?.id == controller.recommendation?.id ? DS.Palette.primary : DS.Palette.textPrimary
    )
    .help(result?.lastFailure.map(failureText) ?? tr("中位延迟"))
  }

  private func protocolDetails(_ result: DNSBenchmarkResult) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s1) {
      Text(verbatim: result.target.transport.rawValue).fontWeight(.semibold)
      Text(verbatim: endpointAddress(result.target))
      ViewThatFits(in: .horizontal) {
        HStack(spacing: DS.Space.s4) { detailMetrics(result) }
        VStack(alignment: .leading, spacing: DS.Space.s1) { detailMetrics(result) }
      }
      if result.intercepted { Text(tr("疑似 DNS 拦截")) }
      if !result.addresses.isEmpty {
        Text(tr("解析结果"))
        Text(verbatim: result.addresses.joined(separator: ", "))
      } else if let failure = result.lastFailure {
        Text(failureText(failure))
      }
    }
    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, DS.Space.s2)
  }

  @ViewBuilder
  private func detailMetrics(_ result: DNSBenchmarkResult) -> some View {
    LabeledContent(tr("P90 延迟"), value: milliseconds(result.p90))
    LabeledContent(
      tr("失败率"),
      value: result.attempts == 0
        ? "—"
        : result.failureRate.formatted(.percent.precision(.fractionLength(0)).locale(locale)))
    LabeledContent(tr("握手耗时"), value: milliseconds(result.handshakeMilliseconds))
  }

  private func column(_ text: String) -> some View {
    Text(text).multilineTextAlignment(.trailing).frame(width: 64, alignment: .trailing)
  }

  private func endpointAddress(_ target: DNSBenchmarkTarget) -> String {
    if let url = target.httpsURL { return url.absoluteString }
    let host = target.host.contains(":") ? "[\(target.host)]" : target.host
    return "\(host):\(target.port)"
  }

  private func milliseconds(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value.formatted(.number.precision(.fractionLength(1)).locale(locale)) + " ms"
  }

  private func tr(_ text: String) -> String {
    L10n.translate(text, language: AppLanguage.resolve(preferredLanguages: [locale.identifier]))
  }

  private func failureText(_ failure: DNSBenchmarkFailure) -> String {
    switch failure {
    case .timeout: return tr("查询超时")
    case .connection: return tr("连接失败")
    case .invalidResponse: return tr("应答无效")
    case .noAnswer: return tr("没有有效应答")
    case .cancelled: return tr("测试已取消")
    }
  }
}
