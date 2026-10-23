import Foundation
import Darwin
import Localization

/// 基础清理规则；开发者项目集中在 DeveloperCleanupCatalog 中维护。
public enum RuleCatalog {
  /// 通用目录与旧扫描执行都必须让出的预览专属路径。
  /// 仅构造一次配置并提取已登记路径，不调用 locate 或执行目录发现。
  static let previewOnlyReservedPaths = PreviewRuleCatalog.rules.flatMap(\.cacheRelativePaths)

  public static func rules() -> [CleanRule] {
    [userCaches, logs] + ApplicationCacheCatalog.rules + browsers.map(browserRule)
      + DeveloperCleanupCatalog.rules
      + PreviewRuleCatalog.rules
      + [incompleteDownloads, installers, trash]
  }

  // MARK: 系统

  /// 由其他规则单独处理，或清理后会影响系统功能的缓存目录
  static let excludedCacheNames: Set<String> = [
    "Google", "Firefox", "Microsoft Edge", "BraveSoftware", "Arc",
    "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
    "org.mozilla.firefox", "com.apple.Safari", "Homebrew", "Yarn", "go-build", "pip",
  ]

  static let userCaches = CleanRule(
    id: "system.caches", category: .system, title: tr("应用缓存"),
    detail: tr("~/Library/Caches 中各应用的缓存，删除后会按需重建"), symbol: "archivebox",
    checksOwnerApp: true, isGenericLibraryScan: true
  ) { env in
    try children(of: env.home + "/Library/Caches").filter { url in
      let name = url.lastPathComponent
      return !name.hasPrefix("com.apple.") && !excludedCacheNames.contains(name)
    }
  }

  static let logs = CleanRule(
    id: "system.logs", category: .system, title: tr("应用日志与崩溃报告"),
    detail: tr("~/Library/Logs 中的日志和诊断报告"), symbol: "doc.text",
    checksOwnerApp: true, isGenericLibraryScan: true
  ) { env in
    // Homebrew 日志也是原生 cleanup 的候选，避免通用规则绕过其预览直接删除。
    try children(of: env.home + "/Library/Logs").filter { $0.lastPathComponent != "Homebrew" }
  }

  // MARK: 浏览器

  struct Browser: Sendable {
    let id: String
    let name: String
    let bundleID: String
    /// ~/Library/Caches 下的整个缓存目录
    let cacheDirectories: [String]
    /// ~/Library/Application Support 下的用户数据目录（其中的配置目录含 Code Cache 等）
    let userDataDirectory: String?
  }

  static let browsers: [Browser] = [
    Browser(
      id: "chrome", name: "Chrome", bundleID: "com.google.Chrome",
      cacheDirectories: ["Google/Chrome"], userDataDirectory: "Google/Chrome"),
    Browser(
      id: "edge", name: "Edge", bundleID: "com.microsoft.edgemac",
      cacheDirectories: ["Microsoft Edge"], userDataDirectory: "Microsoft Edge"),
    Browser(
      id: "brave", name: "Brave", bundleID: "com.brave.Browser",
      cacheDirectories: ["BraveSoftware/Brave-Browser"],
      userDataDirectory: "BraveSoftware/Brave-Browser"),
    Browser(
      id: "arc", name: "Arc", bundleID: "company.thebrowser.Browser",
      cacheDirectories: ["Arc", "company.thebrowser.Browser"], userDataDirectory: "Arc/User Data"),
    Browser(
      id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox",
      cacheDirectories: [], userDataDirectory: nil),
    Browser(
      id: "safari", name: "Safari", bundleID: "com.apple.Safari",
      cacheDirectories: ["com.apple.Safari"], userDataDirectory: nil),
  ]

  /// Chromium 配置目录内可安全清理的缓存子目录
  static let chromiumProfileCaches = ["Code Cache", "GPUCache", "Service Worker/CacheStorage"]

  static func browserRule(_ browser: Browser) -> CleanRule {
    CleanRule(
      id: "browser.\(browser.id)", category: .browser, title: tr("\(browser.name) 缓存"),
      detail: tr("网页缓存与脚本缓存，不涉及 Cookie、历史记录和密码"), symbol: "globe",
      blockingApps: [(browser.bundleID, browser.name)], minimumAge: 0
    ) { env in
      let fileManager = FileManager.default
      var urls = browser.cacheDirectories
        .map { URL(fileURLWithPath: env.home + "/Library/Caches/" + $0) }
      // 浏览器缓存目录本身属于 ~/Library/Caches 的子目录，逐个校验可读性
      urls = try urls.filter { url in
        guard fileManager.fileExists(atPath: url.path) else { return false }
        _ = try children(of: url.path)
        return true
      }

      if browser.id == "firefox" {
        let profiles = try childrenIfExists(of: env.home + "/Library/Caches/Firefox/Profiles")
        urls += profiles.map { $0.appendingPathComponent("cache2") }
          .filter { fileManager.fileExists(atPath: $0.path) }
      }

      if let userData = browser.userDataDirectory {
        let base = env.home + "/Library/Application Support/" + userData
        let profiles = try childrenIfExists(of: base).filter(isChromiumProfile)
        for profile in profiles {
          urls +=
            chromiumProfileCaches
            .map { profile.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
        }
      }
      return urls
    }
  }

  static func isChromiumProfile(_ url: URL) -> Bool {
    let name = url.lastPathComponent
    guard name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile" else {
      return false
    }
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("Preferences").path)
  }

  // MARK: 下载

  static let incompleteDownloads = CleanRule(
    id: "downloads.incomplete", category: .downloads, title: tr("未完成的下载"),
    detail: tr("超过 1 天未更新的 .crdownload / .part / .download"), symbol: "arrow.down.circle",
    policy: .trash, minimumAge: 86_400
  ) { env in
    try childrenIfExists(of: env.home + "/Downloads")
      .filter { ["crdownload", "part", "download"].contains($0.pathExtension.lowercased()) }
  }

  static let installers = CleanRule(
    id: "downloads.installers", category: .downloads, title: tr("安装包"),
    detail: tr("下载目录中的 .dmg / .pkg / .xip / .iso，移到废纸篓"), symbol: "shippingbox.fill",
    selectedByDefault: false, policy: .trash, minimumAge: 0
  ) { env in
    try childrenIfExists(of: env.home + "/Downloads")
      .filter { ["dmg", "pkg", "xip", "iso"].contains($0.pathExtension.lowercased()) }
  }

  // MARK: 废纸篓

  static let trash = CleanRule(
    id: "trash", category: .trash, title: tr("清空废纸篓"),
    detail: tr("永久删除废纸篓中的内容，无法恢复"), symbol: "trash",
    selectedByDefault: false, minimumAge: 0
  ) { env in
    try childrenIfExists(of: env.home + "/.Trash")
  }

  // MARK: 工具

  /// 增量读取直接子项。直接调用默认限 2,000 条 / 5 秒；扫描内复用发现与计量预算。
  /// 隐藏条目也消耗发现预算，避免过滤过程本身无界；失败不返回部分目录列表。
  static func children(of path: String, budget explicitBudget: ScanBudget? = nil) throws -> [URL] {
    let budget =
      explicitBudget ?? ScanBudget.current
      ?? ScanBudget(limits: ScanLimits(maxEntries: 2_000, maxDuration: 5))
    try budget.check()
    do {
      guard let directory = path.withCString({ opendir($0) }) else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      defer { closedir(directory) }
      let root = URL(fileURLWithPath: path)
      var children: [URL] = []
      while true {
        try budget.check()
        errno = 0
        guard let entry = readdir(directory) else {
          guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
          break
        }
        let nameLength = Int(entry.pointee.d_namlen) + 1
        let name = withUnsafePointer(to: &entry.pointee.d_name) {
          $0.withMemoryRebound(to: CChar.self, capacity: nameLength) {
            String(cString: $0)
          }
        }
        guard name != ".", name != ".." else { continue }
        try budget.visit()
        guard !name.hasPrefix(".") else { continue }
        let child = root.appendingPathComponent(name)
        try budget.visitCandidate(child.standardizedFileURL.path)
        children.append(child)
      }
      try budget.check()
      return children
    } catch let error as NSError
      where error.domain == NSPOSIXErrorDomain
      && [Int(EPERM), Int(EACCES)].contains(error.code)
    {
      throw CleanerAccessError.permissionDenied
    }
  }

  /// 仅不存在的目录视为空；权限、读取、取消及预算错误全部保留。
  static func childrenIfExists(
    of path: String, budget explicitBudget: ScanBudget? = nil
  ) throws -> [URL] {
    do {
      return try children(of: path, budget: explicitBudget)
    } catch let error as POSIXError where error.code == .ENOENT {
      return []
    }
  }
}

public enum CleanerAccessError: Error, Sendable {
  case permissionDenied
}
