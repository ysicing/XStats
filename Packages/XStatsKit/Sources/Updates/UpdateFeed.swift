import Foundation

/// 官网上的版本清单（https://getopenstats.com/download/appcast.json），由 Scripts/publish_release.sh 生成
public struct UpdateRelease: Codable, Sendable, Equatable {
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
    public let changelog: URL?
    /// Intel 版安装包。顶层的 url / sha256 / size / dmg 是 Apple 芯片版：0.3.0 只有 Apple 芯片版且只认顶层字段
    public let intel: UpdateAsset?

    public init(version: String, build: String, date: String, minimumSystem: String, url: URL, sha256: String,
                size: Int64, dmg: URL?, notes: [String], changelog: URL?, intel: UpdateAsset? = nil) {
        self.version = version
        self.build = build
        self.date = date
        self.minimumSystem = minimumSystem
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.dmg = dmg
        self.notes = notes
        self.changelog = changelog
        self.intel = intel
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
    public static let url = URL(string: "https://getopenstats.com/download/appcast.json")!

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
                                 intel: intel)
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
