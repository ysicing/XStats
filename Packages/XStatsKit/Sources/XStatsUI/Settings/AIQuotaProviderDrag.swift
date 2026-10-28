// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// 只对已选服务排序；会话内预览不写偏好，选择或顺序变化后拒绝旧草稿。
struct AIQuotaProviderDrag {
  let provider: String
  let originalOrder: [String]
  var previewOrder: [String]

  init(provider: String, order: [String]) {
    self.provider = provider
    originalOrder = order
    previewOrder = order
  }

  mutating func move(over target: String) {
    guard provider != target,
      let source = previewOrder.firstIndex(of: provider),
      let destination = previewOrder.firstIndex(of: target)
    else { return }
    previewOrder.remove(at: source)
    previewOrder.insert(provider, at: destination)
  }

  func orderToCommit(current: [String]) -> [String]? {
    guard originalOrder == current, originalOrder.contains(provider) else { return nil }
    return previewOrder
  }
}

struct AIQuotaProviderDropDelegate: DropDelegate {
  let provider: String
  @Binding var drag: AIQuotaProviderDrag?
  let commit: (AIQuotaProviderDrag) -> Bool

  func validateDrop(info: DropInfo) -> Bool {
    drag?.originalOrder.contains(provider) == true
  }

  func dropEntered(info: DropInfo) { drag?.move(over: provider) }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: validateDrop(info: info) ? .move : .cancel)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard validateDrop(info: info), let draft = drag else { return false }
    let accepted = commit(draft)
    drag = nil
    return accepted
  }
}
