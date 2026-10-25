// SPDX-License-Identifier: AGPL-3.0-or-later

import Observation

/// 包管理、服务管理与 Mole 命令共用执行状态；切换页面不能释放仍在执行的命令。
@MainActor @Observable
final class HomebrewOperationState {
  private(set) var isRunning = false

  func begin() -> Bool {
    guard !isRunning else { return false }
    isRunning = true
    return true
  }

  func finish() {
    isRunning = false
  }
}
