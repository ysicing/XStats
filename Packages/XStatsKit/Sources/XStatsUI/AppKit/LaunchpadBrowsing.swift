// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum LaunchpadIconSize: String, CaseIterable, Sendable {
  case small
  case large

  static let preferenceKey = "launchpadIconSize"

  var titleKey: String { self == .small ? "小图标" : "大图标" }
  var points: CGFloat { self == .small ? 64 : 96 }
}

enum LaunchpadGridLayout: String, CaseIterable, Sendable {
  case automatic
  case sevenByFive
  case eightByFive
  case eightBySix

  static let preferenceKey = "launchpadGridLayout"

  var titleKey: String {
    switch self {
    case .automatic: "自动"
    case .sevenByFive: "7 × 5"
    case .eightByFive: "8 × 5"
    case .eightBySix: "8 × 6"
    }
  }

  var maximumColumns: Int { self == .sevenByFive ? 7 : 8 }
  var maximumRows: Int { self == .sevenByFive || self == .eightByFive ? 5 : 6 }
}

enum LaunchpadBrowsingMode: String, CaseIterable, Sendable {
  case grid
  case list
  case categories

  static let preferenceKey = "launchpadBrowsingMode"

  var titleKey: String {
    switch self {
    case .grid: "网格"
    case .list: "列表"
    case .categories: "分类"
    }
  }
}

enum LaunchpadApplicationCategory: CaseIterable, Hashable, Sendable {
  case productivity
  case development
  case creative
  case utilities
  case games
  case education
  case lifestyle
  case other

  init(_ identifier: String?) {
    let identifier = identifier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let prefix = "public.app-category."
    guard identifier.hasPrefix(prefix) else {
      self = .other
      return
    }
    let category = String(identifier.dropFirst(prefix.count))
    switch category {
    case "business", "productivity", "finance": self = .productivity
    case "developer-tools": self = .development
    case "graphics-design", "photography", "music", "video", "entertainment": self = .creative
    case "utilities": self = .utilities
    case "games", "action-games", "adventure-games", "arcade-games", "board-games", "card-games",
      "casino-games", "dice-games", "educational-games", "family-games", "kids-games",
      "music-games",
      "puzzle-games", "racing-games", "role-playing-games", "simulation-games", "sports-games",
      "strategy-games", "trivia-games", "word-games":
      self = .games
    case "education", "reference", "books", "medical": self = .education
    case "lifestyle", "travel", "sports", "healthcare-fitness", "health-fitness",
      "social-networking", "news", "weather", "shopping", "food-drink":
      self = .lifestyle
    default: self = .other
    }
  }

  var titleKey: String {
    switch self {
    case .productivity: "工作效率"
    case .development: "开发工具"
    case .creative: "创作与媒体"
    case .utilities: "实用工具"
    case .games: "游戏"
    case .education: "教育与参考"
    case .lifestyle: "生活"
    case .other: "其他"
    }
  }
}

struct LaunchpadBrowsingPage: Sendable {
  let commands: [AppCommand]
  let category: LaunchpadApplicationCategory?
}

enum LaunchpadBrowsing {
  /// 派生浏览始终从原布局展开，文件夹内顺序也不改写回布局。
  static func applications(
    in layout: LaunchpadLayout, catalog: [String: AppCommand]
  ) -> [AppCommand] {
    layout.pages.joined().flatMap(\.apps).compactMap { catalog[$0] }
  }

  static func pages(
    applications: [AppCommand], mode: LaunchpadBrowsingMode, capacity: Int
  ) -> [LaunchpadBrowsingPage] {
    guard mode == .categories else {
      return LaunchpadLayout.paginate(applications, capacity: capacity).map {
        LaunchpadBrowsingPage(commands: $0, category: nil)
      }
    }
    let groups = Dictionary(grouping: applications) {
      LaunchpadApplicationCategory($0.applicationCategory)
    }
    return LaunchpadApplicationCategory.allCases.flatMap { category in
      LaunchpadLayout.paginate(groups[category] ?? [], capacity: capacity).map {
        LaunchpadBrowsingPage(commands: $0, category: category)
      }
    }
  }
}
