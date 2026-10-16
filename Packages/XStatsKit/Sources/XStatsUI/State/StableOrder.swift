// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

/// 保留仍在前 N 名的条目的位置；只在离榜时替换，数值始终使用最新读数。
enum StableOrder {
  static func arrange<Item, ID: Hashable>(
    _ ranked: [Item], previous: [ID], limit: Int, id: (Item) -> ID
  ) -> [Item] {
    guard limit > 0 else { return [] }
    let top = Array(ranked.prefix(limit))
    let byID = Dictionary(top.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    let retained = Set(previous.prefix(limit).filter { byID[$0] != nil })
    var newcomers = top.filter { !retained.contains(id($0)) }[...]
    var shown: [Item] = []
    for key in previous.prefix(limit) {
      if let item = byID[key] {
        shown.append(item)
      } else if let next = newcomers.popFirst() {
        shown.append(next)
      }
    }
    shown.append(contentsOf: newcomers)
    return shown
  }
}
