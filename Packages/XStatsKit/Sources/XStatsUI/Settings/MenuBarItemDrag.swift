// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// 拖动期间只调整可见草稿；落下后替换可编辑位置，保留硬件不可用项目的位置。
struct MenuBarItemDrag {
  let item: MenuBarItem
  let originalOrder: [MenuBarItem]
  let availableOrder: [MenuBarItem]
  var previewOrder: [MenuBarItem]

  init(item: MenuBarItem, order: [MenuBarItem], available: [MenuBarItem]) {
    self.item = item
    originalOrder = order
    availableOrder = order.filter { available.contains($0) }
    previewOrder = availableOrder
  }

  mutating func move(over target: MenuBarItem) {
    guard item != target,
      let source = previewOrder.firstIndex(of: item),
      let destination = previewOrder.firstIndex(of: target)
    else { return }
    previewOrder.remove(at: source)
    previewOrder.insert(item, at: destination)
  }

  func orderToCommit(current: [MenuBarItem], available: [MenuBarItem]) -> [MenuBarItem]? {
    guard current == originalOrder,
      current.filter({ available.contains($0) }) == availableOrder,
      availableOrder.contains(item)
    else { return nil }
    var result = current
    let indices = result.indices.filter { availableOrder.contains(result[$0]) }
    for (index, replacement) in zip(indices, previewOrder) { result[index] = replacement }
    return result
  }
}

struct MenuBarItemDropDelegate: DropDelegate {
  let item: MenuBarItem
  @Binding var drag: MenuBarItemDrag?
  let commit: (MenuBarItemDrag) -> Bool

  func validateDrop(info: DropInfo) -> Bool { drag?.availableOrder.contains(item) == true }

  func dropEntered(info: DropInfo) { drag?.move(over: item) }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: validateDrop(info: info) ? .move : .cancel)
  }

  func performDrop(info: DropInfo) -> Bool {
    guard let draft = drag else { return false }
    let accepted = commit(draft)
    drag = nil
    return accepted
  }
}
