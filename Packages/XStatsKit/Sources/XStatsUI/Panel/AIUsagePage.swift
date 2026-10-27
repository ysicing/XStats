// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import AppKit
import Localization
import SwiftUI

extension EnvironmentValues {
  @Entry var aiUsageWesternUnits = false
}

struct AIUsagePage: View {
  var initialActivityMode = UsageActivityMode.daily
  @Environment(AppModel.self) private var model
  var body: some View {
    PageScroll {
      MagpieUsageContent(compact: false, initialActivityMode: initialActivityMode)
    }
  }
}
struct AIUsagePopover: View {
  @Environment(AppModel.self) private var model
  var body: some View {
    MagpieUsageContent(compact: true)
  }
}

private struct MagpieUsageContent: View {
  @Environment(\.isSnapshot) private var isSnapshot
  let compact: Bool
  @Environment(AppModel.self) private var model
  @State private var activityMode: UsageActivityMode

  init(compact: Bool, initialActivityMode: UsageActivityMode = .daily) {
    self.compact = compact
    _activityMode = State(
      initialValue: UsageChartPresentation.mode(initialActivityMode, compact: compact))
  }

  private var period: MagpiePeriod {
    switch activityMode {
    case .daily: .daily
    case .weekly: .weekly
    case .monthly: .monthly
    case .cumulative: .cumulative
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      HStack {
        Text(tr("数据来源") + " · Magpie").dsFont(.sm, weight: .semibold)
        Spacer()
        if !compact {
          AIUsageRefreshButton()
          AIUsageSettingsButton()
        }
      }
      if !model.settings.aiUsageEnabled {
        Card {
          Text(tr("尚未启用")).dsFont(.xs)
          Button(tr("启用 AI 用量")) { model.settings.aiUsageEnabled = true }
            .buttonStyle(DSButtonStyle(kind: .primary))
        }
      } else if model.aiUsage.magpieQuotas.isEmpty,
        model.aiUsage.magpieSummary(for: period) == nil,
        model.aiUsage.magpieQuotaFailure == .unavailable,
        !model.settings.aiUsageShowsLocalUsage
          || model.aiUsage.magpieUsageFailures[period] == .unavailable
      {
        MagpieConnectionGuide()
      } else {
        quotas
        if !compact,
          !model.aiUsage.magpieQuotas.isEmpty || !model.settings.aiPreferredAccounts.isEmpty
        {
          preferredAccounts
        }
        if model.settings.aiUsageShowsLocalUsage {
          if let summary = model.aiUsage.magpieSummary(for: period) {
            usageSummary(summary)
          } else if model.aiUsage.magpieRefreshing {
            ProgressView().frame(maxWidth: .infinity).padding()
          } else if model.aiUsage.magpieUsageFailures[period] == nil {
            Text(tr("暂无数据")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          }
          MagpieActivityPanel(
            summary: model.aiUsage.magpieSummary(for: period), compact: compact, mode: $activityMode
          )
          if let failure = model.aiUsage.magpieUsageFailures[period] {
            connectionStatus(failure, stale: model.aiUsage.magpieSummary(for: period) != nil)
          }
          if let summary = model.aiUsage.magpieSummary(for: period), !summary.models.isEmpty {
            Card(spacing: DS.Space.s2) {
              Text(tr("模型用量")).dsFont(.sm, weight: .semibold)
              ForEach(summary.models.sorted { $0.total > $1.total }) { item in
                HStack(alignment: .firstTextBaseline) {
                  Text(item.provider + " · " + item.model)
                    .lineLimit(1).help(item.provider + " · " + item.model)
                  Spacer(minLength: DS.Space.s2)
                  Text(
                    UsageNumber.short(
                      item.total, westernUnits: model.settings.aiUsageWesternUnits)
                  )
                  .monospacedDigit().help(UsageNumber.exact(item.total) + " Tokens")
                }.dsFont(.xs)
              }
            }
          }
        }
      }
    }
    .environment(\.aiUsageWesternUnits, model.settings.aiUsageWesternUnits)
    .task(id: period) {
      guard !isSnapshot else { return }
      await model.aiUsage.selectMagpiePeriod(period)
    }
  }

  private var quotas: some View {
    Card(spacing: DS.Space.s3) {
      Text(tr("订阅额度")).dsFont(.sm, weight: .semibold)
      if model.aiUsage.magpieQuotas.isEmpty && model.aiUsage.magpieQuotaFailure == nil {
        Text(tr("暂无额度数据")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
      Text(tr("额度按账户分别显示；菜单栏和小组件使用首选账号。"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if !model.aiUsage.magpieQuotas.isEmpty {
        MagpieQuotaAccounts(accounts: model.aiUsage.magpieQuotas, settings: model.settings)
      }
      if let failure = model.aiUsage.magpieQuotaFailure {
        connectionStatus(failure, stale: !model.aiUsage.magpieQuotas.isEmpty)
      }
    }
  }

  @ViewBuilder private var preferredAccounts: some View {
    let accounts = model.aiUsage.widgetQuotaAccounts(at: .now)
    let providers = Set(
      Dictionary(grouping: accounts, by: \.provider)
        .filter { $0.value.count > 1 }.keys)
    let ordered =
      AIServiceBrand.menuBarOrder.filter { providers.contains($0) }
      + providers.subtracting(AIServiceBrand.menuBarOrder).sorted()
    if !ordered.isEmpty {
      Card(spacing: DS.Space.s3) {
        Text(tr("首选账号")).dsFont(.sm, weight: .semibold)
        ForEach(ordered, id: \.self) { provider in
          let candidates = accounts.filter { $0.provider == provider }
          let counts = Dictionary(grouping: candidates, by: \.id)
          let selected = model.settings.aiPreferredAccounts[provider] ?? ""
          SettingRow(title: AIServiceBrand.title(provider), subtitle: nil) {
            Picker(
              tr("首选账号"),
              selection: Binding(
                get: { model.settings.aiPreferredAccounts[provider] ?? "" },
                set: { id in
                  model.settings.aiPreferredAccounts[provider] = id.isEmpty ? nil : id
                })
            ) {
              Text(tr("跟随 Magpie")).tag("")
              ForEach(candidates.filter { counts[$0.id]?.count == 1 }) { account in
                Text(account.name).tag(account.id)
              }
              if !selected.isEmpty, counts[selected]?.count != 1 {
                Text(tr("账号不可用")).tag(selected)
              }
            }.labelsHidden()
          }
        }
      }
    }
  }

  private func usageSummary(_ summary: MagpieUsageSummary) -> some View {
    Card(spacing: DS.Space.s3) {
      Text(tr("Token 用量")).dsFont(.sm, weight: .semibold)
      Text(UsageNumber.short(summary.total, westernUnits: model.settings.aiUsageWesternUnits))
        .dsFont(.xl, weight: .semibold).monospacedDigit()
        .help(UsageNumber.exact(summary.total) + " Tokens")
      LazyVGrid(
        columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading,
        spacing: DS.Space.s2
      ) {
        metric(tr("输入"), summary.input)
        metric(tr("输出"), summary.output)
        metric(tr("缓存读取"), summary.cacheRead)
        metric(tr("缓存写入"), summary.cacheWrite)
      }
      HStack {
        Text(tr("请求数"))
        Spacer()
        Text(UsageNumber.exact(summary.calls)).monospacedDigit()
      }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      HStack {
        Text(tr("估算费用"))
        Spacer()
        Text(
          summary.cost.formatted(
            .currency(code: "USD").precision(.fractionLength(2...4)).locale(L10n.locale))
        ).monospacedDigit()
      }.dsFont(.sm)
      if summary.unpriced > 0 {
        Text(tr("部分请求缺少价格，费用估算不完整。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
      Text(tr("Magpie 的 Token 总量不包含缓存读写；仅统计经过 Magpie 的请求。"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func metric(_ title: String, _ value: Int) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s1) {
      Text(title).foregroundStyle(DS.Palette.textSecondary)
      Text(UsageNumber.short(value, westernUnits: model.settings.aiUsageWesternUnits))
        .monospacedDigit().help(UsageNumber.exact(value))
    }.dsFont(.xs)
  }

  private func connectionStatus(_ failure: MagpieFailure, stale: Bool) -> some View {
    VStack(alignment: .leading, spacing: DS.Space.s1) {
      Text(tr(failure == .unavailable ? "无法连接 Magpie，请确认它已运行。" : "Magpie 数据无法读取，请检查版本或数据大小。"))
      if stale { Text(tr("显示上次成功读取的数据。")) }
    }.dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct MagpieConnectionGuide: View {
  @Environment(AppModel.self) private var model
  @State private var guidance: MagpieInstallation.Guidance?
  @State private var opening = false
  @State private var launchFailed = false

  var body: some View {
    Card(spacing: DS.Space.s3) {
      Text(
        tr(
          guidance == .install
            ? "AI 用量需要安装并运行 Magpie。"
            : "无法连接 Magpie，请确认它已运行并开启本地接口。")
      )
      .dsFont(.sm).fixedSize(horizontal: false, vertical: true)
      if launchFailed {
        Text(tr("无法打开 Magpie，请手动启动后重试。"))
          .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      }
      HStack(spacing: DS.Space.s2) {
        if guidance == .install {
          Link(tr("安装 Magpie"), destination: URL(string: "https://usemagpie.ai")!)
            .buttonStyle(DSButtonStyle(kind: .primary))
        } else if case .launch(let application) = guidance {
          Button(tr("打开 Magpie")) {
            opening = true
            launchFailed = false
            Task {
              do {
                _ = try await NSWorkspace.shared.openApplication(
                  at: application, configuration: .init())
                await model.aiUsage.refresh()
              } catch { launchFailed = true }
              opening = false
            }
          }.buttonStyle(DSButtonStyle(kind: .primary))
        }
        Button(tr("重新检测")) {
          detect()
          Task { await model.aiUsage.refresh() }
        }.buttonStyle(DSButtonStyle())
        if model.aiUsage.isRefreshing || opening {
          ProgressView().controlSize(.small).accessibilityLabel(tr("正在刷新"))
        }
      }
      .disabled(model.aiUsage.isRefreshing || opening)
    }
    .task { detect() }
    .onChange(of: model.aiUsage.lastAttemptAt) { _, _ in detect() }
  }

  private func detect() {
    // 安装检测只用于失败后的操作引导；真实接口可用时不依赖安装路径。
    guidance = MagpieInstallation.guidance(
      previouslyConnected: model.aiUsage.magpieQuotaUpdatedAt != nil
        || !model.aiUsage.magpieUsageUpdatedAt.isEmpty)
  }
}

private struct MagpieActivityPanel: View {
  let summary: MagpieUsageSummary?
  let compact: Bool
  @Binding var mode: UsageActivityMode
  @State private var hovered: String?
  @State private var metric = UsageActivityMetric.tokens

  var body: some View {
    Card(spacing: DS.Space.s2) {
      ViewThatFits(in: .horizontal) {
        HStack {
          metricChoices.fixedSize()
          Spacer(minLength: DS.Space.s2)
          periodChoices.fixedSize()
        }
        VStack(alignment: .leading, spacing: DS.Space.s2) {
          metricChoices
          HStack {
            Spacer(minLength: 0)
            periodChoices
          }
        }
      }
      if let summary {
        Text(
          hovered
            ?? tr(summary.bucket == "week" ? "按周统计" : summary.bucket == "hour" ? "按小时统计" : "按天统计")
        )
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        if summary.series.contains(where: { metric.value($0) != nil }) {
          UsageBarChart(
            buckets: summary.series.sorted { $0.time < $1.time },
            hourly: summary.bucket == "hour", metric: metric, hovered: $hovered)
        } else {
          Text(tr("暂无数据")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 140)
        }
      } else {
        Text(tr("暂无数据")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
          .frame(maxWidth: .infinity, minHeight: 140)
      }
    }
    .onChange(of: mode) { _, _ in hovered = nil }
    .onChange(of: metric) { _, _ in hovered = nil }
    .onChange(of: summary) { _, _ in hovered = nil }
  }

  private var metricChoices: some View {
    UsageChoices(
      selection: $metric, options: UsageActivityMetric.allCases.map { ($0, $0.title) },
      label: tr("活动走势"), equalWidth: false)
  }

  private var periodChoices: some View {
    let periods: [(UsageActivityMode, String)] = [
      (.daily, tr("今天")), (.weekly, tr("7 天")), (.monthly, tr("30 天")),
    ]
    return UsageChoices(
      selection: $mode, options: compact ? periods : periods + [(.cumulative, tr("累计"))],
      label: tr("活动走势"), equalWidth: false)
  }
}

enum UsageActivityMetric: CaseIterable, Hashable {
  case tokens, cost, calls, speed

  var title: String {
    switch self {
    case .tokens: "Token"
    case .cost: tr("费用")
    case .calls: tr("请求")
    case .speed: tr("速度")
    }
  }

  func value(_ bucket: MagpieUsageBucket) -> Double? {
    switch self {
    case .tokens: Double(bucket.input + bucket.output)
    case .cost: bucket.cost
    case .calls: bucket.calls.map(Double.init)
    case .speed: bucket.tokensPerSecond
    }
  }

  func formatted(_ value: Double, westernUnits: Bool, exact: Bool = false) -> String {
    switch self {
    case .tokens, .calls:
      let count = Int(value)
      let text =
        exact ? UsageNumber.exact(count) : UsageNumber.short(count, westernUnits: westernUnits)
      return self == .tokens && exact ? text + " Tokens" : text
    case .cost:
      return value.formatted(
        .currency(code: "USD").precision(.fractionLength(2...4)).locale(L10n.locale))
    case .speed:
      return value.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale))
        + " Token/s"
    }
  }
}

/// 摘要、选项和图表共享的显示边界，首次测量时也必须使用同一模式。
enum UsageChartPresentation {
  static func mode(_ selected: UsageActivityMode, compact: Bool) -> UsageActivityMode {
    compact && selected == .cumulative ? .monthly : selected
  }

  static func tickIndices(count: Int, narrow: Bool) -> [Int] {
    guard count > 0 else { return [] }
    let candidates =
      narrow
      ? [0, count / 2, count - 1]
      : count == 7
        ? [0, 2, 4, 6]
        : [0, count / 4, count / 2, count * 3 / 4, count - 1]
    return Array(Set(candidates)).sorted()
  }
}

private struct UsageChoices<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [(Value, String)]
  let label: String
  var equalWidth = true
  @State private var pointerSelection = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: DS.Space.s1 / 2) {
      ForEach(options, id: \.0) { value, title in
        Button {
          pointerSelection = true
          selection = value
        } label: {
          Text(title).dsFont(.xs, weight: selection == value ? .semibold : .medium)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(selection == value ? DS.Palette.textPrimary : DS.Palette.textSecondary)
            .frame(minWidth: equalWidth ? nil : 36, maxWidth: equalWidth ? .infinity : nil)
            .padding(.horizontal, equalWidth ? 0 : DS.Space.s1)
            .padding(.vertical, DS.Space.s2)
            .contentShape(Rectangle())
            .background {
              RoundedRectangle(cornerRadius: DS.Radius.md)
                .fill(DS.Palette.elevated)
                .opacity(selection == value ? 1 : 0)
                .animation(
                  pointerSelection
                    ? (reduceMotion ? DS.Motion.quick : DS.Motion.usageSelection) : nil,
                  value: selection)
            }
        }
        .buttonStyle(UsagePressStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
        .onKeyPress(.space) {
          selectWithKeyboard(value)
          return .handled
        }
        .onKeyPress(.return) {
          selectWithKeyboard(value)
          return .handled
        }
      }
    }
    .padding(DS.Space.s1 / 2)
    .background(DS.Palette.track, in: RoundedRectangle(cornerRadius: DS.Radius.md))
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }

  private func selectWithKeyboard(_ value: Value) {
    pointerSelection = false
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) { selection = value }
  }
}

private struct UsagePressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
  }
}

/// 所有数字和日期都跟随应用语言（`L10n.locale`），不跟随系统语言：
/// 否则中文系统 + 英文界面下，坐标轴、悬停提示和时间会夹在英文文案里显示中文。
enum UsageNumber {
  static func exact(_ value: Int, locale: Locale = L10n.locale) -> String {
    value.formatted(.number.locale(locale))
  }

  /// 同年省略年份，跨年保留；判断与显示使用同一个日历、时区，避免年末边界不一致。
  static func quotaDate(
    _ date: Date, includesTime: Bool, now: Date = Date(),
    locale: Locale = L10n.locale, calendar: Calendar = .current
  ) -> String {
    var style = Date.FormatStyle(
      date: .omitted, time: .omitted, locale: locale,
      calendar: calendar, timeZone: calendar.timeZone
    ).month(.abbreviated).day()
    if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
    if includesTime { style = style.hour().minute() }
    return date.formatted(style)
  }

  static func short(_ value: Int, locale: Locale = L10n.locale, westernUnits: Bool = false)
    -> String
  {
    AIUsageFormat.tokens(value, westernUnits: westernUnits, locale: locale)
  }
}

private struct UsageBarChart: View {
  @Environment(\.aiUsageWesternUnits) private var westernUnits
  let buckets: [MagpieUsageBucket]
  let hourly: Bool
  let metric: UsageActivityMetric
  @Binding var hovered: String?

  var body: some View {
    let maximum = buckets.compactMap { metric.value($0) }.max() ?? 0
    let peak = maximum > 0 ? maximum : 1
    VStack(spacing: DS.Space.s1) {
      HStack(spacing: DS.Space.s2) {
        VStack(alignment: .trailing) {
          Text(metric.formatted(peak, westernUnits: westernUnits))
          Spacer()
          Text(metric.formatted(peak / 2, westernUnits: westernUnits))
          Spacer()
          Text("0")
        }.dsFont(.xs).foregroundStyle(DS.Palette.textTertiary)
          .lineLimit(1).minimumScaleFactor(0.65)
          .frame(width: 64, alignment: .trailing).accessibilityHidden(true)
        GeometryReader { geometry in
          ZStack {
            VStack {
              HairlineDivider()
              Spacer()
              HairlineDivider()
              Spacer()
              HairlineDivider()
            }
            .accessibilityHidden(true)
            HStack(alignment: .bottom, spacing: DS.Space.s1 / 2) {
              ForEach(buckets, id: \.time) { bucket in
                let value = metric.value(bucket)
                let label =
                  bucket.time.formatted(
                    hourly
                      ? .dateTime.month().day().hour().minute().timeZone().locale(L10n.locale)
                      : .dateTime.month().day().locale(L10n.locale))
                  + " · "
                  + (value.map { metric.formatted($0, westernUnits: westernUnits, exact: true) }
                    ?? tr("暂无数据"))
                RoundedRectangle(cornerRadius: DS.Space.s1 / 2)
                  .fill(DS.Palette.primary.opacity(0.8))
                  .frame(maxWidth: 24)
                  .frame(
                    height: (value ?? 0) == 0
                      ? 0 : max(2, geometry.size.height * (value ?? 0) / peak)
                  )
                  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                  .contentShape(Rectangle())
                  .onHover { active in hovered = active ? label : nil }
                  .accessibilityElement(children: .ignore).accessibilityLabel(label)
              }
            }
          }
        }
      }.frame(height: 140)
      GeometryReader { geometry in
        let indices = UsageChartPresentation.tickIndices(
          count: buckets.count, narrow: geometry.size.width < 240)
        ForEach(indices, id: \.self) { index in
          if buckets.indices.contains(index) {
            Text(
              buckets[index].time.formatted(
                hourly
                  ? .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(
                    L10n.locale)
                  : .dateTime.month(.twoDigits).day(.twoDigits).locale(L10n.locale))
            )
            .position(
              x: min(
                geometry.size.width - 20,
                max(20, geometry.size.width * (Double(index) + 0.5) / Double(buckets.count))), y: 9)
          }
        }
      }.frame(height: 20).padding(.leading, 64 + DS.Space.s2)
        .dsFont(.xs).foregroundStyle(DS.Palette.textTertiary).accessibilityHidden(true)
    }
    // 时间轴固定从左到右，阿拉伯语标签仍按其文字方向排版。
    .environment(\.layoutDirection, .leftToRight)
  }
}

struct AIUsageRefreshButton: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ZStack {
      MiniIconButton(systemName: "arrow.clockwise", help: tr("立即刷新")) {
        Task { await model.aiUsage.refresh() }
      }
      .opacity(model.aiUsage.isRefreshing ? 0 : 1)
      .disabled(
        !model.settings.aiUsageEnabled
          || model.aiUsage.isRefreshing)
      if model.aiUsage.isRefreshing {
        ProgressView().controlSize(.small).accessibilityLabel(tr("正在刷新"))
      }
    }
    .frame(width: DS.Size.controlHeight, height: DS.Size.controlHeight)
  }
}

struct AIUsageSettingsButton: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    MiniIconButton(systemName: "slider.horizontal.3", help: tr("AI 用量") + " · " + tr("设置")) {
      model.openAIUsageSettings()
    }
  }
}

struct AIUsageSettingsPanel: View {
  var body: some View {
    ScrollView { UsageSettings().padding(DS.Space.s4) }
      .frame(minWidth: 390, minHeight: 480)
      .background(DS.Palette.background)
      .appLanguageEnvironment()
  }
}

private struct UsageSettings: View {
  @Environment(AppModel.self) private var model
  var body: some View {
    @Bindable var settings = model.settings
    VStack(alignment: .leading, spacing: DS.Space.s4) {
      Text(tr("设置")).dsFont(.base, weight: .semibold)
      SettingRow(title: tr("AI 用量"), subtitle: nil) {
        DSToggle(isOn: $settings.aiUsageEnabled, label: tr("AI 用量"))
      }
      SettingRow(
        title: tr("显示 Token 用量"),
        subtitle: tr("从 Magpie 读取 Token 与费用；关闭后只读取额度。")
      ) {
        DSToggle(
          isOn: $settings.aiUsageShowsLocalUsage,
          label: tr("显示 Token 用量"))
      }
      HairlineDivider()
      Text(tr("数据来源")).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
      SettingRow(title: "Magpie", subtitle: nil) { EmptyView() }
      HairlineDivider()
      SettingRow(title: tr("刷新间隔"), subtitle: tr("AI 用量与额度共用此间隔；新数据到达后更新菜单栏。")) {
        Picker(tr("刷新间隔"), selection: $settings.aiUsageRefreshMinutes) {
          ForEach(AppSettings.aiUsageRefreshOptions, id: \.self) { value in
            Text(tr("\(value) 分钟")).tag(value)
          }
        }.labelsHidden()
      }
      SettingRow(title: tr("额度显示"), subtitle: nil) {
        Picker(tr("额度显示"), selection: $settings.aiQuotaShowsRemaining) {
          Text(tr("已用")).tag(false)
          Text(tr("剩余")).tag(true)
        }.labelsHidden()
      }
      if settings.language.resolved.isChinese {
        SettingRow(title: tr("数字单位"), subtitle: nil) {
          Picker(tr("数字单位"), selection: $settings.aiUsageWesternUnits) {
            Text(tr("万 / 亿")).tag(false)
            Text("K / M / B").tag(true)
          }.labelsHidden()
        }
      }
      SettingRow(title: tr("小组件圆环"), subtitle: nil) {
        Picker(tr("小组件圆环"), selection: $settings.aiWidgetShowsResetRing) {
          Text(tr("单圈")).tag(false)
          Text(tr("双圈")).tag(true)
        }.labelsHidden()
      }
      Text(tr("费用由 Magpie 估算，以美元显示；不代表订阅账单。"))
        .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
