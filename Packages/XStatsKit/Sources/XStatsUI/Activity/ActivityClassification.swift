// SPDX-License-Identifier: AGPL-3.0-or-later

enum ActivityClassification: String, CaseIterable, Sendable {
  case programming, office, design, learning, games, media, utilities
  case work, entertainment, communication, browsing, other

  var category: ActivityPageAnalytics.Category {
    switch self {
    case .programming, .office, .design, .learning, .work: .work
    case .games, .media, .entertainment: .entertainment
    case .communication: .communication
    case .browsing: .browsing
    case .utilities, .other: .other
    }
  }

  static func custom(appID: String, overrides: [String: String]) -> Self? {
    overrides[appID.lowercased()].flatMap(Self.init(rawValue:))
  }

  static func knownApplication(_ id: String) -> Self? {
    switch id.lowercased() {
    case "com.apple.finder", "com.apple.preview", "com.apple.systempreferences",
      "com.apple.activitymonitor", "com.apple.diskutility", "com.ysicing.xsourcetree",
      "work.12306.xstats.app", "work.12306.xstats.capture", "work.12306.xstats.networkmonitor":
      .utilities
    case "com.valvesoftware.steam", "com.epicgames.epicgameslauncher": .games
    case "com.apple.safari", "com.google.chrome", "org.mozilla.firefox", "com.microsoft.edgemac",
      "company.thebrowser.browser", "com.brave.browser", "org.torproject.torbrowser":
      .browsing
    case "com.apple.mail", "com.apple.ichat", "com.tinyspeck.slackmacgap", "com.tencent.xinwechat",
      "com.alibaba.dingtalkmac", "com.microsoft.teams2", "us.zoom.xos", "com.electron.lark",
      "com.tencent.weworkmac", "com.tencent.qq", "ru.keepcoder.telegram", "org.telegram.desktop",
      "com.tdesktop.telegram":
      .communication
    case "com.apple.terminal", "com.googlecode.iterm2", "com.apple.dt.xcode",
      "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "dev.zed.zed", "com.openai.codex",
      "com.google.antigravity-ide":
      .programming
    case "com.apple.notes", "com.apple.iwork.pages", "com.apple.iwork.numbers",
      "com.apple.iwork.keynote", "com.microsoft.word", "com.microsoft.excel",
      "com.microsoft.powerpoint", "com.anthropic.claudefordesktop", "com.openai.chat":
      .office
    case "com.figma.desktop", "com.bohemiancoding.sketch3", "com.apple.photos": .design
    case "com.apple.ibooksx", "com.apple.dictionary": .learning
    case "com.apple.music", "com.apple.quicktimeplayerx", "com.spotify.client",
      "com.colliderli.iina", "org.videolan.vlc", "com.bilibili.bilibilipc",
      "com.bytedance.douyin.desktop", "com.netease.163music":
      .media
    default: nil
    }
  }

  static func automatic(appID: String, storeCategory: String?) -> Self {
    if let known = knownApplication(appID) { return known }
    let prefix = "public.app-category."
    guard let storeCategory, storeCategory.hasPrefix(prefix) else { return .other }
    let category = storeCategory.dropFirst(prefix.count)
    if category == "games" || category.hasSuffix("-games") { return .games }
    switch category {
    case "developer-tools": return .programming
    case "productivity", "business", "finance": return .office
    case "graphics-design", "photography": return .design
    case "education", "reference", "books": return .learning
    case "music", "video": return .media
    case "entertainment", "sports": return .entertainment
    case "utilities": return .utilities
    case "social-networking": return .communication
    default: return .other
    }
  }
}
