// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum NetworkConnectionMode: String, CaseIterable {
  case live, history

  /// 历史截止于已完成的统计桶，翻页时不混入正在写入的区间。
  static func historyEnd(at date: Date = Date()) -> Date {
    Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 5) * 5)
  }
}

enum NetworkRegionHierarchy {
  static func key(_ key: String, at depth: Int) -> String? {
    let parts = key.split(separator: "|").map(String.init)
    guard let root = parts.first else { return nil }
    if depth == 0 { return root }
    guard depth > 0, root == "CN", parts.count > depth, depth <= 2 else { return nil }
    // 直辖市无需重复一层同名城市。
    if depth == 2, parts[1] == parts[2] { return nil }
    return parts.prefix(depth + 1).joined(separator: "|")
  }

  static func matches(_ key: String, selection: String) -> Bool {
    key == selection
      || (selection == "CN" || selection.hasPrefix("CN|"))
        && key.hasPrefix(selection + "|")
  }

  static func depth(_ key: String) -> Int {
    key.split(separator: "|").count - 1
  }
}
