// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Localization
import Observation

/// 只在页面展示、手动刷新或操作完成后读取；不创建后台轮询。
@MainActor @Observable
final class HomebrewServicesController {
  private(set) var services: [HomebrewService] = []
  private(set) var isLoading = false
  private(set) var working: String?
  private(set) var error: String?
  private(set) var completion: String?
  private(set) var brewAvailable: Bool
  let homebrewOperations: HomebrewOperationState
  private var visible = false
  private var paused = false
  private var generation = UUID()
  @ObservationIgnored private var readTask: Task<Void, Never>?
  @ObservationIgnored private let checkBrewAvailability: () -> Bool
  @ObservationIgnored private let readInventory: @Sendable () async throws -> [HomebrewService]
  @ObservationIgnored private let performAction:
    @Sendable (HomebrewServices.Action, HomebrewService) async throws -> Void

  init(
    brewAvailable: @escaping () -> Bool = { HomebrewManagement.isAvailable },
    readInventory: @escaping @Sendable () async throws -> [HomebrewService] = {
      try await HomebrewServices.inventory()
    },
    performAction:
      @escaping @Sendable (HomebrewServices.Action, HomebrewService) async throws -> Void = {
        try await HomebrewServices.perform($0, service: $1)
      },
    homebrewOperations: HomebrewOperationState = HomebrewOperationState()
  ) {
    self.brewAvailable = brewAvailable()
    self.checkBrewAvailability = brewAvailable
    self.readInventory = readInventory
    self.performAction = performAction
    self.homebrewOperations = homebrewOperations
  }

  func setVisible(_ value: Bool) {
    visible = value
    if value && !paused { refresh() } else { cancelReading() }
  }

  func showPreview(_ services: [HomebrewService]) {
    self.services = services
  }

  func dismissCompletion(_ completion: String) {
    guard self.completion == completion else { return }
    self.completion = nil
  }

  func setPaused(_ value: Bool) {
    paused = value
    if value { cancelReading() } else if visible { refresh() }
  }

  private func cancelReading() {
    generation = UUID()
    readTask?.cancel()
    readTask = nil
    isLoading = false
  }

  func refresh() {
    guard visible, !paused, !isLoading, working == nil else { return }
    // 安装、卸载或移动 Homebrew 后无需重启应用；仅在页面有需求时重新检查。
    brewAvailable = checkBrewAvailability()
    guard brewAvailable else {
      services = []
      error = nil
      completion = nil
      return
    }
    isLoading = true
    error = nil
    let current = UUID()
    generation = current
    readTask = Task {
      do {
        let result = try await readInventory()
        guard !Task.isCancelled, current == generation, visible, !paused else { return }
        services = result
      } catch {
        guard !Task.isCancelled, current == generation, visible, !paused else { return }
        services = []
        self.error = error.localizedDescription
        Log.app.error(
          "Homebrew 服务读取失败：\(String(error.localizedDescription.prefix(2_000)), privacy: .private)")
      }
      isLoading = false
      readTask = nil
    }
  }

  func perform(_ action: HomebrewServices.Action, service: HomebrewService) {
    guard visible, !paused, !isLoading, working == nil, error == nil,
      service.canManage(), services.contains(service)
    else { return }
    let homebrewOperations = homebrewOperations
    guard homebrewOperations.begin() else { return }
    working = service.id
    completion = nil
    // 用户确认的操作独立收尾，切换页面不打断；完成后仍只在可见时刷新。
    Task {
      defer { homebrewOperations.finish() }
      do {
        try await performAction(action, service)
        completion = tr("服务操作已完成，请以刷新后的状态为准")
        Log.app.notice("Homebrew 服务操作完成：\(action.rawValue, privacy: .public)")
        working = nil
        refresh()
      } catch let timeout as HomebrewOperationTimeout {
        self.error = tr("Homebrew 操作超过 1 小时仍未结束，请在终端核对其状态")
        Log.app.error("Homebrew 服务操作超时：\(action.rawValue, privacy: .public)")
        await timeout.waitForExit()
        working = nil
      } catch {
        working = nil
        self.error = error.localizedDescription
        Log.app.error(
          "Homebrew 服务操作失败：\(String(error.localizedDescription.prefix(2_000)), privacy: .private)")
      }
    }
  }
}
