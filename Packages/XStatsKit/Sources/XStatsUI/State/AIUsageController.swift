// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Foundation
import Observation
import WidgetData
import WidgetKit
import os

/// Magpie 只读统计的低频刷新入口，统一管理调度、取消与失败后保留旧值。
@MainActor
@Observable
public final class AIUsageController {
  public private(set) var lastAttemptAt: Date?
  public private(set) var magpieQuotas: [MagpieQuota] = []
  public private(set) var magpieQuotaFailure: MagpieFailure?
  public private(set) var magpieQuotaUpdatedAt: Date?
  public private(set) var magpieUsage: [MagpiePeriod: MagpieUsageSummary] = [:]
  public private(set) var magpieUsageFailures: [MagpiePeriod: MagpieFailure] = [:]
  public private(set) var magpieUsageUpdatedAt: [MagpiePeriod: Date] = [:]
  public private(set) var magpieRefreshing = false
  @ObservationIgnored private let magpieClient: any MagpieFetching
  @ObservationIgnored private var magpiePeriod = MagpiePeriod.daily
  /// 沿用现有刷新周期查询安装需求，不为没有使用累计小组件的用户增加统计请求。
  @ObservationIgnored var cumulativeWidgetIsInstalled: @MainActor () async -> Bool = {
    await withCheckedContinuation { continuation in
      WidgetCenter.shared.getCurrentConfigurations { result in
        let installed = (try? result.get().contains { $0.kind == WidgetKind.todayTokens }) ?? false
        continuation.resume(returning: installed)
      }
    }
  }
  private static let logger = Logger(subsystem: Log.subsystem, category: "ai-usage")

  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private var cadenceTask: Task<Void, Never>?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var refreshTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var paused = false

  public init(
    settings: AppSettings, magpieClient: any MagpieFetching,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.settings = settings
    self.magpieClient = magpieClient
    self.now = now
  }

  public var isRefreshing: Bool { magpieRefreshing }

  public var todayTokens: Int? { magpieSummary(for: .daily)?.total }

  public func start() {
    cadenceTask?.cancel()
    cadenceTask = nil
    // 调度重建也代表新的配置代次。仅取消 cadence 不会传递到独立的刷新任务；
    // 功能关闭后快速重新启用时，旧请求即使忽略取消也不能回写到新状态。
    generation += 1
    for task in refreshTasks.values { task.cancel() }
    refreshTask?.cancel()
    refreshTask = nil
    magpieRefreshing = false
    if !settings.aiUsageShowsLocalUsage {
      magpieUsage.removeAll()
      magpieUsageFailures.removeAll()
      magpieUsageUpdatedAt.removeAll()
    }
    guard settings.aiUsageEnabled, !paused else {
      if !settings.aiUsageEnabled {
        magpieQuotas = []
        magpieQuotaFailure = nil
        magpieQuotaUpdatedAt = nil
        magpieUsage = [:]
        magpieUsageFailures = [:]
        magpieUsageUpdatedAt = [:]
        magpieRefreshing = false
      }
      return
    }
    let seconds = settings.aiUsageRefreshMinutes * 60
    cadenceTask = Task { [weak self] in
      guard !Task.isCancelled else { return }
      await self?.refresh()
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        guard !Task.isCancelled else { return }
        await self?.refresh()
      }
    }
  }

  public func stop() {
    magpieRefreshing = false
    generation += 1
    cadenceTask?.cancel()
    cadenceTask = nil
    for task in refreshTasks.values { task.cancel() }
    refreshTask?.cancel()
    refreshTask = nil
  }

  /// 系统唤醒会连发屏幕唤醒与系统唤醒两个通知，重复的恢复不能再排一次查询
  public func setPaused(_ value: Bool) {
    guard value != paused else { return }
    paused = value
    if value { stop() } else { start() }
  }

  /// 刷新串行排队。旧实现遇到在途刷新就直接返回，而轮询任务把这次返回当成“首次刷新已完成”，
  /// 接着睡满整个周期（最长 60 分钟）；那次在途刷新的结果又会因 generation 变化被丢弃，
  /// 于是关掉再打开统计后页面会一直空着。链上的任务是非结构化的，stop() 必须显式取消它。
  public func refresh() async {
    let previous = refreshTask
    let id = UUID()
    let task = Task { @MainActor [weak self] in
      await previous?.value
      guard !Task.isCancelled else { return }
      await self?.performRefresh()
    }
    refreshTask = task
    refreshTasks[id] = task
    await task.value
    refreshTasks[id] = nil
  }

  private func performRefresh() async {
    guard settings.aiUsageEnabled, !paused, !Task.isCancelled else { return }
    await refreshMagpie(magpieClient)
  }

  public func magpieSummary(for period: MagpiePeriod) -> MagpieUsageSummary? {
    guard settings.aiUsageEnabled, settings.aiUsageShowsLocalUsage else { return nil }
    // 午夜后不能把离线保存的昨日总量重新写进“今日”菜单栏或 Widget。
    if period == .daily {
      guard let updated = magpieUsageUpdatedAt[period],
        Calendar.current.isDate(updated, inSameDayAs: now())
      else { return nil }
    }
    return magpieUsage[period]
  }

  /// 默认和已选服务始终可编辑，其余候选来自 Magpie；同服务多账户合并成一个选项。
  var availableMenuBarQuotaProviders: [String] {
    let available = Set(magpieQuotas.map(\.provider))
      .union(AIServiceBrand.defaultMenuBarProviders).union(settings.aiMenuBarProviders)
    return AIServiceBrand.menuBarOrder.filter { available.contains($0) }
      + available.subtracting(AIServiceBrand.menuBarOrder).sorted()
  }

  func menuBarMagpieQuotas(at date: Date = Date()) -> [MenuBarQuota] {
    let readings = magpieQuotaReadings(at: date)
    return readings.filter { settings.aiMenuBarProviders.contains($0.sourceName) }
  }

  /// 菜单栏与小组件共用首选账号，显式选择不可用时不回退。
  func magpieQuotaReadings(at date: Date = Date()) -> [MenuBarQuota] {
    let allAccounts = widgetQuotaAccounts(at: date)
    return availableMenuBarQuotaProviders.compactMap { provider in
      let accounts = allAccounts.filter { $0.provider == provider }
      let account: WidgetSnapshot.QuotaAccount?
      if let id = settings.aiPreferredAccounts[provider] {
        let matching = accounts.filter { $0.id == id }
        account = matching.count == 1 ? matching.first : nil
      } else {
        account = accounts.first
      }
      guard let quota = account?.quota, quota.remainingPercent.isFinite else { return nil }
      return MenuBarQuota(
        provider: AIProviderID(rawValue: provider),
        window: AIQuotaWindow(
          kind: .weekly, usedPercent: 100 - quota.remainingPercent, resetsAt: quota.resetsAt),
        fetchedAt: quota.fetchedAt, isStale: quota.isStale,
        magpieName: provider, magpieWindow: quota.kind)
    }
  }

  /// Widget 保留所有账号；Magpie 的当前登录账号排在前面，last 仅表示最近处理请求。
  func widgetQuotaAccounts(at date: Date) -> [WidgetSnapshot.QuotaAccount] {
    guard settings.aiUsageEnabled else { return [] }
    return magpieQuotas.map { account in
      // 长度前缀避免分隔符碰撞；有用户身份时改别名、调整顺序不会改变选择。
      let identity = [
        account.provider, account.kind, account.from ?? "", account.user ?? account.name,
      ]
      .map { "\($0.utf8.count):\($0)" }.joined()
      let name = account.alias ?? account.user ?? account.name
      let displayName = account.from.map { "\(name) · \($0)" } ?? name
      let windows = account.windows.filter {
        $0.unlimited != true && $0.remaining != nil && ($0.resetsAt.map { $0 > date } ?? true)
      }
      let window = windows.first { $0.name == "7 days" } ?? windows.first
      let quota: WidgetSnapshot.Quota?
      if account.error == nil, let window, let remaining = window.remaining {
        quota = .init(
          provider: account.provider, kind: window.name, remainingPercent: remaining,
          resetsAt: window.resetsAt, fetchedAt: account.readAt ?? magpieQuotaUpdatedAt ?? date,
          isStale: magpieQuotaFailure != nil)
      } else {
        quota = nil
      }
      return .init(id: identity, provider: account.provider, name: displayName, quota: quota)
    }
  }

  /// 可见页请求所选周期；今日供菜单栏、累计按已安装的小组件需求读取，最多保留四个摘要。
  public func selectMagpiePeriod(_ period: MagpiePeriod) async {
    magpiePeriod = period
    let epoch = generation
    await refreshTask?.value
    guard generation == epoch, !Task.isCancelled, magpiePeriod == period, settings.aiUsageEnabled,
      !paused
    else { return }
    // 切换周期复用最近的摘要；快速连续切换时不为已离开的周期排队查询。
    if let updated = magpieUsageUpdatedAt[period], magpieUsageFailures[period] == nil,
      now().timeIntervalSince(updated) < Double(settings.aiUsageRefreshMinutes * 60),
      magpieSummary(for: period) != nil
    {
      return
    }
    await refresh()
  }

  private func refreshMagpie(_ client: any MagpieFetching) async {
    let epoch = generation
    let attempt = now()
    let period = magpiePeriod
    magpieRefreshing = true
    defer { if generation == epoch { magpieRefreshing = false } }
    let needsCumulative =
      settings.aiUsageShowsLocalUsage ? await cumulativeWidgetIsInstalled() : false
    guard generation == epoch, settings.aiUsageEnabled, !paused, !Task.isCancelled else { return }
    // 端点失败独立处理：额度不可用不应抹去仍可读取的 Token 统计，反之亦然。
    async let quotas: Result<[MagpieQuota], MagpieFailure> = Self.readMagpieQuotas(client)
    var periods: [MagpiePeriod] = []
    if settings.aiUsageShowsLocalUsage {
      periods = [.daily]
      if period != .daily { periods.append(period) }
      if needsCumulative && !periods.contains(.cumulative) { periods.append(.cumulative) }
    }
    // 额度与统计最多并发两个请求；多个统计周期依次读取，取消后不再调度下一项。
    var usage: [(MagpiePeriod, Result<MagpieUsageSummary, MagpieFailure>)] = []
    for period in periods {
      guard !Task.isCancelled, generation == epoch, !paused,
        settings.aiUsageEnabled, settings.aiUsageShowsLocalUsage
      else { break }
      do { usage.append((period, .success(try await client.usage(period: period)))) } catch let
        failure
        as MagpieFailure
      {
        usage.append((period, .failure(failure)))
      } catch {
        usage.append((period, .failure(.unavailable)))
      }
    }
    let quotaResult = await quotas
    guard generation == epoch, settings.aiUsageEnabled, !paused, !Task.isCancelled else { return }
    let wasUnavailable = magpieQuotaFailure != nil || !magpieUsageFailures.isEmpty
    switch quotaResult {
    case .success(let value):
      magpieQuotas = value
      magpieQuotaFailure = nil
      magpieQuotaUpdatedAt = attempt
      // 仅成功读取账号列表后清除已删除的身份；请求失败或额度不可用不代表账号删除。
      let identities = Dictionary(grouping: widgetQuotaAccounts(at: attempt), by: \.provider)
        .mapValues { Set($0.map(\.id)) }
      let preferred = settings.aiPreferredAccounts.filter { provider, id in
        identities[provider]?.contains(id) == true
      }
      if preferred != settings.aiPreferredAccounts {
        settings.aiPreferredAccounts = preferred
      }
    case .failure(let failure): magpieQuotaFailure = failure
    }
    if settings.aiUsageShowsLocalUsage {
      for (period, result) in usage {
        switch result {
        case .success(let value):
          magpieUsage[period] = value
          magpieUsageFailures[period] = nil
          magpieUsageUpdatedAt[period] = attempt
        case .failure(let failure): magpieUsageFailures[period] = failure
        }
      }
    }
    let unavailable = magpieQuotaFailure != nil || !magpieUsageFailures.isEmpty
    if unavailable != wasUnavailable {
      if unavailable {
        Self.logger.error("Magpie read failed; retaining last successful values")
      } else {
        Self.logger.info("Magpie connection recovered")
      }
    }
    lastAttemptAt = attempt
  }

  private static func readMagpieQuotas(_ client: any MagpieFetching) async -> Result<
    [MagpieQuota], MagpieFailure
  > {
    do { return .success(try await client.quotas()) } catch let failure as MagpieFailure {
      return .failure(failure)
    } catch { return .failure(.unavailable) }
  }

}
