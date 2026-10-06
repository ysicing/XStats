import Foundation

/// 更新 API 返回的版本清单；发版时由 scripts/appcast.py 生成并由 scripts/publish_release.sh 提交
public struct UpdateRelease: Codable, Sendable, Equatable {
    /// 包内网络扩展独立版本；只从已签名更新清单读取。
    public struct NetworkExtension: Codable, Sendable, Equatable {
        public let version: String
        public let build: String
        public init(version: String, build: String) { self.version = version; self.build = build }
    }
    public let networkExtension: NetworkExtension?
    public let version: String
    public let build: String
    public let date: String
    public let minimumSystem: String
    /// 应用内升级下载的 zip（已公证、已装订的 XStats.app）
    public let url: URL
    public let sha256: String
    public let size: Int64
    /// 手动安装用的 DMG
    public let dmg: URL?
    /// 最近更新的摘要，每条一句
    public let notes: [String]
    /// 已签名 XML 中的英文摘要；旧清单没有该字段时继续使用 notes。
    public let englishNotes: [String]?
    public let changelog: URL?
    /// Intel 版安装包。顶层的 url / sha256 / size / dmg 是 Apple 芯片版：0.3.0 只有 Apple 芯片版且只认顶层字段
    public let intel: UpdateAsset?

    public init(version: String, build: String, date: String, minimumSystem: String, url: URL, sha256: String,
                size: Int64, dmg: URL?, notes: [String], changelog: URL?, intel: UpdateAsset? = nil,
                englishNotes: [String]? = nil, networkExtension: NetworkExtension? = nil) {
        self.version = version
        self.build = build
        self.date = date
        self.minimumSystem = minimumSystem
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.dmg = dmg
        self.notes = notes
        self.englishNotes = englishNotes
        self.changelog = changelog
        self.intel = intel
        self.networkExtension = networkExtension
    }

    /// 中文语言统一显示中文，其余语言显示英文；旧清单没有英文时保留原摘要。
    public func notes(for languageCode: String) -> [String] {
        if languageCode == "zh" || languageCode.hasPrefix("zh-") { return notes }
        guard let englishNotes, !englishNotes.isEmpty else { return notes }
        return englishNotes
    }
}

public struct UpdateAsset: Codable, Sendable, Equatable {
    public let url: URL
    public let sha256: String
    public let size: Int64
    public let dmg: URL?

    public init(url: URL, sha256: String, size: Int64, dmg: URL?) {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.dmg = dmg
    }
}

/// 安装包对应的芯片
public enum UpdateArchitecture: Sendable, Equatable {
    case appleSilicon
    case intel

    /// 这台 Mac 的芯片。Intel 版在 Apple 芯片上经 Rosetta 运行时也算 Apple 芯片，升级时顺便换成原生版本
    public static var current: UpdateArchitecture {
        #if arch(arm64)
        return .appleSilicon
        #else
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 else { return .intel }
        return translated == 1 ? .appleSilicon : .intel
        #endif
    }

    /// Bundle.executableArchitectures 里对应的值
    var executableArchitecture: Int {
        switch self {
        case .appleSilicon: NSBundleExecutableArchitectureARM64
        case .intel: NSBundleExecutableArchitectureX86_64
        }
    }
}

public enum UpdateFeed {
    /// XStats 的多应用 API 入口原样返回签名 XML，同时记录检查；JSON POST 协议保持可用。
    public static func sparkleURLs(prefersChina: Bool) -> [URL] {
        checkURLs(prefersChina: prefersChina).map {
            $0.deletingLastPathComponent().appendingPathComponent("appcast.xml")
        }
    }

    private static let globalURL = URL(string: "https://apps.12306.work/api/v1/apps/xstats/update/check")!
    private static let globalBackupURL = URL(string: "https://apps-api.xiai.me/api/v1/apps/xstats/update/check")!
    private static let chinaURL = URL(string: "https://apps.china.12306.work/api/v1/apps/xstats/update/check")!

    public static func prefersChinaEndpoint(locale: Locale = .autoupdatingCurrent) -> Bool {
        locale.region?.identifier.uppercased() == "CN"
    }

    /// 只串行请求：成功后不再访问剩余入口，避免同一次检查跨区域或别名重复统计。
    public static func checkURLs(prefersChina: Bool) -> [URL] {
        prefersChina ? [chinaURL, globalURL, globalBackupURL] : [globalURL, globalBackupURL, chinaURL]
    }

    /// 区域 API 沿用相同的应用与系统版本标识，不启用 Sparkle 系统分析。
    public static func userAgent(currentVersion: String,
                                 operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        var components = [operatingSystemVersion.majorVersion, operatingSystemVersion.minorVersion]
        if operatingSystemVersion.patchVersion > 0 { components.append(operatingSystemVersion.patchVersion) }
        return "XStats/\(currentVersion) (macOS \(components.map(String.init).joined(separator: ".")))"
    }

    public static func checkRequest(
        url: URL,
        currentVersion: String,
        installationID: String,
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) throws -> URLRequest {
        struct Body: Encodable {
            let currentVersion: String
            let installationID: String

            enum CodingKeys: String, CodingKey {
                case currentVersion = "current_version"
                case installationID = "installation_id"
            }
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent(currentVersion: currentVersion, operatingSystemVersion: operatingSystemVersion), forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(Body(currentVersion: currentVersion, installationID: installationID))
        return request
    }

    public static func parse(_ data: Data) -> UpdateRelease? {
        guard let release = try? JSONDecoder().decode(UpdateRelease.self, from: data),
              !release.version.isEmpty, release.sha256.count == 64,
              release.url.scheme == "https" else { return nil }
        return release
    }

    /// 换成这种芯片要下载的安装包；清单里没有这种芯片的安装包时返回 nil，不能拿另一种芯片的包来装
    public static func release(_ release: UpdateRelease, for architecture: UpdateArchitecture) -> UpdateRelease? {
        switch architecture {
        case .appleSilicon:
            return release
        case .intel:
            guard let intel = release.intel, intel.sha256.count == 64, intel.url.scheme == "https" else { return nil }
            return UpdateRelease(version: release.version, build: release.build, date: release.date,
                                 minimumSystem: release.minimumSystem, url: intel.url, sha256: intel.sha256,
                                 size: intel.size, dmg: intel.dmg, notes: release.notes, changelog: release.changelog,
                                 intel: intel, englishNotes: release.englishNotes)
        }
    }

    /// 按数字逐段比较版本号：“0.10.0” 比 “0.9.3” 新，“1.0” 与 “1.0.0” 相同
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(candidate), rhs = components(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// 当前系统是否满足清单要求的最低版本
    public static func systemSatisfies(_ minimum: String, current: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Bool {
        let running = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
        return !isNewer(minimum, than: running)
    }

    private static func components(_ version: String) -> [Int] {
        version.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
    }
}
