// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Foundation
import Observation
import os

public struct AIUsageProviderState: Equatable, Sendable {
  public let provider: AIProviderID
  public var snapshot: AIUsageSnapshot?
  public var failure: AIUsageFailure?
  public var isRefreshing = false

  public init(provider: AIProviderID) { self.provider = provider }
}

public struct AIQuotaProviderState: Equatable, Sendable {
  public let provider: AIProviderID
  public var snapshot: AIQuotaSnapshot?
  public var failure: AIQuotaFailure?
  /// 最近一次完成额度查询的发起时间；与快照的上次成功时间分别显示。
  public var lastAttemptAt: Date?
  /// 快照来自磁盘，或本次查询失败后保留的上次成功值。
  public var isStale = false
  public var isRefreshing = false

  public init(provider: AIProviderID) { self.provider = provider }
}

/// 本机用量的低频刷新入口。Provider 只负责一次只读扫描；调度与“保留旧值”策略集中在这里。
@MainActor
@Observable
public final class AIUsageController {
  public private(set) var states: [AIProviderID: AIUsageProviderState]
  public private(set) var quotaStates: [AIProviderID: AIQuotaProviderState]
  /// 供 AppController 观察的刷新脉冲；各额度来源另有自己的 lastAttemptAt。
  public private(set) var lastAttemptAt: Date?
  public var usesMagpie: Bool { magpieClient != nil }
  public private(set) var magpieQuotas: [MagpieQuota] = []
  public private(set) var magpieQuotaFailure: MagpieFailure?
  public private(set) var magpieQuotaUpdatedAt: Date?
  public private(set) var magpieUsage: [MagpiePeriod: MagpieUsageSummary] = [:]
  public private(set) var magpieUsageFailures: [MagpiePeriod: MagpieFailure] = [:]
  public private(set) var magpieUsageUpdatedAt: [MagpiePeriod: Date] = [:]
  public private(set) var magpieRefreshing = false
  @ObservationIgnored private let magpieClient: (any MagpieFetching)?
  @ObservationIgnored private var magpiePeriod = MagpiePeriod.daily
  private static let logger = Logger(subsystem: Log.subsystem, category: "ai-usage")

  public private(set) var costReferences = AICostReferenceSnapshot(catalog: nil, exchangeRate: nil)
  private var costRefreshCount = 0
  public var isRefreshingCostReferences: Bool { costRefreshCount > 0 }
  @ObservationIgnored private var costTasks: [UUID: Task<AICostReferenceSnapshot, Never>] = [:]
  @ObservationIgnored private let costReferenceStore: AICostReferenceStore?

  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let providers: [any AIUsageProvider]
  @ObservationIgnored private let quotaProviders: [any AIQuotaProvider]
  @ObservationIgnored private let quotaCache: AIQuotaCacheStore?
  @ObservationIgnored private let now: @Sendable () -> Date
  @ObservationIgnored private var cadenceTask: Task<Void, Never>?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var refreshTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var paused = false

  public init(
    settings: AppSettings,
    providers: [any AIUsageProvider] = [CodexLocalUsageProvider(), ClaudeLocalUsageProvider()],
    quotaProviders: [any AIQuotaProvider] = [],
    quotaCacheURL: URL? = nil, costReferenceStore: AICostReferenceStore? = nil,
    magpieClient: (any MagpieFetching)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.settings = settings
    self.magpieClient = magpieClient
    self.costReferenceStore = costReferenceStore
    self.providers = providers
    self.quotaProviders = quotaProviders
    quotaCache = quotaCacheURL.flatMap { try? AIQuotaCacheStore(url: $0) }
    self.now = now
    states = Dictionary(
      uniqueKeysWithValues: providers.map { ($0.id, AIUsageProviderState(provider: $0.id)) })
    quotaStates = Dictionary(
      uniqueKeysWithValues: quotaProviders.map { ($0.id, AIQuotaProviderState(provider: $0.id)) })
    restoreCachedQuotas()
  }

  /// 由可见的用量页请求；复用价格/汇率缓存，取消随视图任务传播，不增加轮询。
  /// 离屏演示的虚构单价，不读取缓存或请求价格服务。
  func showPreview(costReferences: AICostReferenceSnapshot) {
    self.costReferences = costReferences
  }

  public func refreshCostReferences() async {
    guard !usesMagpie, let costReferenceStore, settings.aiUsageEnabled,
      settings.aiUsageShowsLocalUsage, !paused,
      localReport(for: nil)?.rows.contains(where: { $0.input > 0 || $0.output > 0 }) == true
    else { return }
    let epoch = generation
    let id = UUID()
    let needsExchangeRate = settings.aiUsageCurrency == .cny
    let task = Task { await costReferenceStore.refresh(needsExchangeRate: needsExchangeRate) }
    costTasks[id] = task
    costRefreshCount += 1
    defer {
      costTasks[id] = nil
      costRefreshCount -= 1
    }
    // 视图消失与系统暂停都必须取消实际请求，不能只丢弃最终结果。
    let incoming = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    guard !Task.isCancelled, generation == epoch, settings.aiUsageEnabled,
      settings.aiUsageShowsLocalUsage, !paused
    else { return }
    // 多个可见窗口可能并发读取；较早返回的美元请求不能清掉新汇率。
    let catalog = [costReferences.catalog, incoming.catalog].compactMap { $0 }.max {
      $0.fetchedAt < $1.fetchedAt
    }
    let rate = [costReferences.exchangeRate, incoming.exchangeRate].compactMap { $0 }.max {
      $0.fetchedAt < $1.fetchedAt
    }
    let merged = AICostReferenceSnapshot(catalog: catalog, exchangeRate: rate)
    if merged != costReferences { costReferences = merged }
  }

  public func estimatedCost(_ rows: [ModelTokenUsage]) -> AICostEstimate {
    if rows.allSatisfy({ $0.input == 0 && $0.output == 0 && $0.cached == 0 && $0.cacheCreated == 0 }
    ) {
      return AICostEstimate(usd: 0, unpricedModels: [])
    }
    return costReferences.catalog?.estimate(rows)
      ?? AICostEstimate(
        usd: nil,
        unpricedModels: Array(
          Set(
            rows.filter {
              $0.input != 0 || $0.output != 0 || $0.cached != 0 || $0.cacheCreated != 0
            }.map(\.model))
        ).sorted())
  }

  private func restoreCachedQuotas() {
    guard !usesMagpie, let cached = try? quotaCache?.load() else { return }
    for provider in quotaProviders where settings.aiUsageSources.contains(provider.id) {
      guard var state = quotaStates[provider.id], state.snapshot == nil,
        let snapshot = cached[provider.id]
      else { continue }
      state.snapshot = snapshot
      state.isStale = true
      quotaStates[provider.id] = state
    }
  }

  public func state(for provider: AIProviderID) -> AIUsageProviderState {
    states[provider] ?? AIUsageProviderState(provider: provider)
  }

  public func quotaState(for provider: AIProviderID) -> AIQuotaProviderState {
    quotaStates[provider] ?? AIQuotaProviderState(provider: provider)
  }

  public func visibleQuotaState(for provider: AIProviderID) -> AIQuotaProviderState {
    guard !usesMagpie, settings.aiUsageEnabled, settings.aiUsageSources.contains(provider) else {
      return AIQuotaProviderState(provider: provider)
    }
    return quotaState(for: provider)
  }

  public func visibleQuotaProviders(for selection: AIProviderID?) -> [AIProviderID] {
    guard !usesMagpie, settings.aiUsageEnabled else { return [] }
    return AIProviderID.allCases.filter { id in
      guard settings.aiUsageSources.contains(id), selection == nil || selection == id,
        let state = quotaStates[id]
      else { return false }
      return state.snapshot != nil || state.failure != .notConfigured
    }
  }

  public var isRefreshing: Bool {
    magpieRefreshing || states.values.contains(where: \.isRefreshing)
      || quotaStates.values.contains(where: \.isRefreshing)
  }

  public var todayTokens: Int? {
    if usesMagpie {
      return settings.aiUsageEnabled && settings.aiUsageShowsLocalUsage
        ? magpieSummary(for: .daily)?.total : nil
    }
    guard settings.aiUsageEnabled, settings.aiUsageShowsLocalUsage,
      let report = localReport(for: nil)
    else { return nil }
    return LocalUsageReport.total(report.selected(days: 1, now: now())).total
  }

  public func localReport(for provider: AIProviderID?) -> LocalUsageReport? {
    guard !usesMagpie, settings.aiUsageShowsLocalUsage else { return nil }
    let reports = states.values.filter {
      settings.aiUsageSources.contains($0.provider) && (provider == nil || $0.provider == provider)
    }
    .compactMap { $0.snapshot?.localUsage }
    .filter { !$0.rows.isEmpty || $0.fileCount > 0 }
    guard !reports.isEmpty else { return nil }
    return LocalUsageReport(
      rows: reports.flatMap(\.rows), fileCount: reports.reduce(0) { $0 + $1.fileCount },
      unreadableFiles: reports.reduce(0) { $0 + $1.unreadableFiles })
  }

  public func localState(for provider: AIProviderID?) -> (stale: Bool, updated: Date?) {
    guard !usesMagpie, settings.aiUsageShowsLocalUsage else { return (false, nil) }
    let selected = states.values.filter {
      settings.aiUsageSources.contains($0.provider) && (provider == nil || $0.provider == provider)
    }
    return (
      selected.contains { $0.failure != nil }, selected.compactMap { $0.snapshot?.fetchedAt }.min()
    )
  }

  public func start() {
    cadenceTask?.cancel()
    cadenceTask = nil
    // 调度重建也代表新的配置代次。仅取消 cadence 不会传递到独立的刷新任务；
    // 来源关闭后快速重新启用时，旧请求即使忽略取消也不能回写到新状态。
    generation += 1
    for task in refreshTasks.values { task.cancel() }
    refreshTask?.cancel()
    refreshTask = nil
    magpieRefreshing = false
    for id in states.keys { states[id]?.isRefreshing = false }
    for id in quotaStates.keys { quotaStates[id]?.isRefreshing = false }
    if !settings.aiUsageShowsLocalUsage {
      magpieUsage.removeAll()
      magpieUsageFailures.removeAll()
      magpieUsageUpdatedAt.removeAll()
      for task in costTasks.values { task.cancel() }
    }
    for provider in providers
    where !settings.aiUsageShowsLocalUsage || !settings.aiUsageSources.contains(provider.id) {
      states[provider.id] = AIUsageProviderState(provider: provider.id)
    }
    for provider in quotaProviders where !settings.aiUsageSources.contains(provider.id) {
      quotaStates[provider.id] = AIQuotaProviderState(provider: provider.id)
    }
    guard settings.aiUsageEnabled, usesMagpie || !settings.aiUsageSources.isEmpty, !paused else {
      for task in costTasks.values { task.cancel() }
      if !settings.aiUsageEnabled {
        magpieQuotas = []
        magpieQuotaFailure = nil
        magpieQuotaUpdatedAt = nil
        magpieUsage = [:]
        magpieUsageFailures = [:]
        magpieUsageUpdatedAt = [:]
        magpieRefreshing = false
        states = Dictionary(
          uniqueKeysWithValues: providers.map { ($0.id, AIUsageProviderState(provider: $0.id)) })
        quotaStates = Dictionary(
          uniqueKeysWithValues: quotaProviders.map {
            ($0.id, AIQuotaProviderState(provider: $0.id))
          })
      }
      return
    }
    restoreCachedQuotas()
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
    for task in costTasks.values { task.cancel() }
    generation += 1
    cadenceTask?.cancel()
    cadenceTask = nil
    for task in refreshTasks.values { task.cancel() }
    refreshTask?.cancel()
    refreshTask = nil
    for id in states.keys { states[id]?.isRefreshing = false }
    for id in quotaStates.keys { quotaStates[id]?.isRefreshing = false }
  }

  /// 系统唤醒会连发屏幕唤醒与系统唤醒两个通知，重复的恢复不能再排一次扫描
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
    if let magpieClient {
      await refreshMagpie(magpieClient)
      return
    }
    let currentGeneration = generation
    defer {
      // 旧请求可以晚于新请求退出，不能清掉新代次正在刷新的状态。
      if currentGeneration == generation {
        for id in states.keys { states[id]?.isRefreshing = false }
        for id in quotaStates.keys { quotaStates[id]?.isRefreshing = false }
      }
    }
    let attempt = now()

    let selectedQuotaProviders = quotaProviders.filter { settings.aiUsageSources.contains($0.id) }
    for provider in selectedQuotaProviders { quotaStates[provider.id]?.isRefreshing = true }
    // 在线额度查询与本机日志扫描并行；扫描慢时不额外推迟网络请求。
    async let quotaResults = Self.fetchQuotas(selectedQuotaProviders)

    for provider in providers {
      guard settings.aiUsageShowsLocalUsage, settings.aiUsageSources.contains(provider.id) else {
        states[provider.id] = AIUsageProviderState(provider: provider.id)
        continue
      }
      var state = state(for: provider.id)
      state.isRefreshing = true
      states[provider.id] = state
      do {
        let snapshot = try await provider.fetch()
        guard currentGeneration == generation, settings.aiUsageEnabled, !Task.isCancelled else {
          return
        }
        guard settings.aiUsageShowsLocalUsage, settings.aiUsageSources.contains(provider.id) else {
          states[provider.id] = AIUsageProviderState(provider: provider.id)
          continue
        }
        state.snapshot = snapshot
        state.failure = nil
      } catch let failure as AIUsageFailure {
        guard currentGeneration == generation, settings.aiUsageEnabled, !Task.isCancelled else {
          return
        }
        guard settings.aiUsageShowsLocalUsage, settings.aiUsageSources.contains(provider.id) else {
          states[provider.id] = AIUsageProviderState(provider: provider.id)
          continue
        }
        // 扫描失败不代表日志消失了，保留上一次的统计结果并在页面上标注为旧数据。
        state.failure = failure
      } catch {
        guard currentGeneration == generation, settings.aiUsageEnabled, !Task.isCancelled else {
          return
        }
        guard settings.aiUsageShowsLocalUsage, settings.aiUsageSources.contains(provider.id) else {
          states[provider.id] = AIUsageProviderState(provider: provider.id)
          continue
        }
        state.failure = .network
      }
      state.isRefreshing = false
      states[provider.id] = state
    }
    for (id, result) in await quotaResults {
      guard currentGeneration == generation, settings.aiUsageEnabled, !Task.isCancelled else {
        return
      }
      guard settings.aiUsageSources.contains(id) else {
        quotaStates[id] = AIQuotaProviderState(provider: id)
        continue
      }
      var state = quotaState(for: id)
      switch result {
      case .success(let snapshot):
        state.snapshot = snapshot
        state.failure = nil
        state.isStale = false
        try? quotaCache?.save(snapshot)
      case .failure(let failure):
        if failure.preservesLastGood {
          state.isStale = state.snapshot != nil
        } else {
          state.snapshot = nil
          state.isStale = false
          try? quotaCache?.clear(id)
        }
        state.failure = failure
      }
      state.lastAttemptAt = attempt
      state.isRefreshing = false
      quotaStates[id] = state
    }
    lastAttemptAt = attempt
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

  /// 只列出 Magpie 实际返回的服务，已知品牌保持稳定顺序，同服务多账户合并成一个选项。
  var availableMenuBarQuotaProviders: [String] {
    guard usesMagpie else { return [] }
    let available = Set(magpieQuotas.map(\.provider))
    return AIServiceBrand.menuBarOrder.filter { available.contains($0) }
      + available.subtracting(AIServiceBrand.menuBarOrder).sorted()
  }

  func menuBarMagpieQuotas(at date: Date = Date()) -> [MenuBarQuota] {
    let readings = magpieQuotaReadings(at: date)
    if settings.aiMenuBarProvidersFollowLegacyOrder {
      let legacy = Set(readings.map(\.sourceName).sorted().prefix(3))
      return readings.filter { legacy.contains($0.sourceName) }
    }
    return readings.filter { settings.aiMenuBarProviders.contains($0.sourceName) }
  }

  /// 每个服务取一个有效账户，优先最近账户；Widget 使用完整摘要，不受菜单栏选择影响。
  func magpieQuotaReadings(at date: Date = Date()) -> [MenuBarQuota] {
    guard usesMagpie, settings.aiUsageEnabled else { return [] }
    var selected: [String: MenuBarQuota] = [:]
    let accounts = magpieQuotas.enumerated().sorted {
      let leftIsLast = $0.element.last == true
      let rightIsLast = $1.element.last == true
      return leftIsLast == rightIsLast ? $0.offset < $1.offset : leftIsLast
    }.map(\.element)
    for account in accounts where selected[account.provider] == nil && account.error == nil {
      let windows = account.windows.filter {
        $0.unlimited != true && $0.remaining != nil && ($0.resetsAt.map { $0 > date } ?? true)
      }
      guard let window = windows.first(where: { $0.name == "7 days" }) ?? windows.first,
        let remaining = window.remaining
      else { continue }
      selected[account.provider] = MenuBarQuota(
        provider: AIProviderID(rawValue: account.provider),
        window: AIQuotaWindow(
          kind: .weekly, usedPercent: 100 - remaining, resetsAt: window.resetsAt),
        fetchedAt: account.readAt ?? magpieQuotaUpdatedAt ?? date,
        isStale: magpieQuotaFailure != nil,
        magpieName: account.provider, magpieWindow: window.name)
    }
    return availableMenuBarQuotaProviders.compactMap { selected[$0] }
  }

  /// 可见页只请求所选周期；今日摘要供菜单栏使用，最多保留四个周期，不读取请求明细。
  public func selectMagpiePeriod(_ period: MagpiePeriod) async {
    guard usesMagpie else { return }
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
    // 端点失败独立处理：额度不可用不应抹去仍可读取的 Token 统计，反之亦然。
    async let quotas: Result<[MagpieQuota], MagpieFailure> = Self.readMagpieQuotas(client)
    let periods: [MagpiePeriod] =
      settings.aiUsageShowsLocalUsage ? (period == .daily ? [.daily] : [.daily, period]) : []
    let usage = await withTaskGroup(
      of: (MagpiePeriod, Result<MagpieUsageSummary, MagpieFailure>).self
    ) { group in
      for period in periods {
        group.addTask {
          do { return (period, .success(try await client.usage(period: period))) } catch let failure
            as MagpieFailure
          { return (period, .failure(failure)) } catch { return (period, .failure(.unavailable)) }
        }
      }
      var results: [(MagpiePeriod, Result<MagpieUsageSummary, MagpieFailure>)] = []
      for await result in group { results.append(result) }
      return results
    }
    let quotaResult = await quotas
    guard generation == epoch, settings.aiUsageEnabled, !paused, !Task.isCancelled else { return }
    let wasUnavailable = magpieQuotaFailure != nil || !magpieUsageFailures.isEmpty
    switch quotaResult {
    case .success(let value):
      magpieQuotas = value
      magpieQuotaFailure = nil
      magpieQuotaUpdatedAt = attempt
    case .failure(let failure): magpieQuotaFailure = failure
    }
    // 升级后首次读到有效额度时，把旧版实际显示的服务保存为选择，之后由用户自行调整。
    if settings.aiMenuBarProvidersFollowLegacyOrder {
      let legacy = magpieQuotaReadings(at: attempt).map(\.sourceName).sorted().prefix(3)
      if !legacy.isEmpty { settings.aiMenuBarProviders = Set(legacy) }
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

  private static func fetchQuotas(_ providers: [any AIQuotaProvider]) async -> [(
    AIProviderID, Result<AIQuotaSnapshot, AIQuotaFailure>
  )] {
    await withTaskGroup(of: (AIProviderID, Result<AIQuotaSnapshot, AIQuotaFailure>).self) { group in
      for provider in providers {
        group.addTask {
          do { return (provider.id, .success(try await provider.fetch())) } catch let failure
            as AIQuotaFailure
          { return (provider.id, .failure(failure)) } catch {
            return (provider.id, .failure(.network))
          }
        }
      }
      var results: [(AIProviderID, Result<AIQuotaSnapshot, AIQuotaFailure>)] = []
      for await result in group { results.append(result) }
      return results
    }
  }
}
