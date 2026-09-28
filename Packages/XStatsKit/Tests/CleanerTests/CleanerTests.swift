import Foundation
import Testing
@testable import Cleaner

actor CleanProgressCapture {
    private var updates: [CleanProgress] = []

    func record(_ progress: CleanProgress) { updates.append(progress) }
    func values() -> [CleanProgress] { updates }
}

/// 在临时目录中构造一个假的家目录
private struct FakeHome {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("xstats-cleaner-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var path: String { root.path }

    @discardableResult
    func file(_ relative: String, bytes: Int = 4096, age: TimeInterval = 3600) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        let date = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.deletingLastPathComponent().path)
        return url
    }

    @discardableResult
    func executable(_ name: String, script: String) throws -> URL {
        let url = root.appendingPathComponent(".local/bin/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func environment(running: Set<String> = [], now: Date = Date()) -> CleanEnvironment {
        CleanEnvironment(home: path, runningBundleIdentifiers: { running }, now: { now })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("安全守卫")
struct SafetyGuardTests {
    let guardian = SafetyGuard(home: "/Users/tester")

    @Test func allowsItemsInsideRoots() throws {
        try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/Caches/com.example.app"))
        try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/Logs/DiagnosticReports"))
        try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Google/Chrome/Default/Code Cache"))
        try guardian.validate(URL(fileURLWithPath: "/Users/tester/go/pkg/mod/cache/download/example.zip"))
        try guardian.validate(URL(fileURLWithPath: "/Users/tester/go/pkg/mod/github.com/example/module"))
        try guardian.validate(URL(fileURLWithPath: "/Users/tester/.cargo/registry/cache/index.crates.io"))
        try guardian.validate(URL(fileURLWithPath: "/Users/tester/.cargo/git/db/example"))
        try guardian.validate(URL(fileURLWithPath: "/Users/tester/.cache/uv/archive-v0"))
    }

    @Test func rejectsRootsAndOutsidePaths() {
        #expect(throws: SafetyError.isRoot) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/Caches")) }
        #expect(throws: SafetyError.isRoot) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/go/pkg/mod")) }
        #expect(throws: SafetyError.isRoot) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/.cargo/registry")) }
        #expect(throws: SafetyError.isRoot) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/.cargo/git")) }
        #expect(throws: SafetyError.isRoot) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/.cache/uv")) }
        #expect(throws: SafetyError.outsideAllowedRoots) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/Documents/a")) }
        #expect(throws: SafetyError.outsideAllowedRoots) { try guardian.validate(URL(fileURLWithPath: "/System/Library/Caches/x")) }
        #expect(throws: SafetyError.outsideAllowedRoots) { try guardian.validate(URL(fileURLWithPath: "/Users/other/Library/Caches/x")) }
        #expect(throws: SafetyError.outsideAllowedRoots) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/go/src/project")) }
        #expect(throws: SafetyError.outsideAllowedRoots) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/.cargo/bin/cargo")) }
        #expect(throws: SafetyError.outsideAllowedRoots) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/.cache/pip/http-v2")) }
    }

    @Test func rejectsTraversalAndControlCharacters() {
        #expect(throws: SafetyError.traversal) {
            try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/Caches/../../Documents"))
        }
        #expect(throws: SafetyError.controlCharacter) {
            try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/Caches/a\u{0007}b"))
        }
    }

    @Test func rejectsProtectedNames() {
        #expect(throws: SafetyError.protectedName("1password")) {
            try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/Caches/com.1password.1password"))
        }
        #expect(throws: SafetyError.protectedName("cookies")) {
            try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/Caches/Cookies"))
        }
    }

    @Test func applicationSupportOnlyAllowsCacheFolders() {
        #expect(throws: SafetyError.applicationSupportNotCache) {
            try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/Application Support/Google/Chrome/Default"))
        }
    }

    @Test func protectsCurrentAndPreviousProductData() {
        for (name, keyword) in [("XStats", "xstats"), ("OpenStats", "openstats")] {
            for directory in ["Logs", "Caches", "Application Support"] {
                #expect(throws: SafetyError.protectedName(keyword)) {
                    try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/\(directory)/\(name)/Cache"))
                }
            }
        }
    }

    @Test func rejectsSymlinkEscapingRoots() throws {
        let home = try FakeHome()
        defer { home.remove() }
        let outside = try home.file("Documents/secret.txt")
        let link = home.root.appendingPathComponent("Library/Caches/link")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(throws: SafetyError.outsideAllowedRoots) { try SafetyGuard(home: home.path).validate(link) }
    }
}

@Suite("开发工具缓存规则")
struct DeveloperCacheRuleTests {
    @Test func catalogIncludesPackageManagerCaches() {
        let rules = Dictionary(uniqueKeysWithValues: RuleCatalog.rules().map { ($0.id, $0) })

        for id in ["developer.npm", "developer.yarn", "developer.pnpm", "developer.bun",
                   "developer.go", "developer.rust", "developer.uv", "developer.homebrew"] {
            #expect(rules[id]?.category == .developer)
            #expect(rules[id]?.selectedByDefault == false)
        }
    }

    @Test func homebrewUsesNativePreviewAndCleanup() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        let cached = try home.file("Library/Caches/Homebrew/downloads/cached.tar.gz")
        try home.file("Library/Logs/Homebrew/tool/build.log")
        let cellar = home.root.appendingPathComponent("custom prefix/Cellar/tool/1.0")
        let environment = CleanEnvironment(
            home: home.path, runningBundleIdentifiers: { [] }, isToolAvailable: { $0 == "brew" },
            runTool: { tool, arguments in
                #expect(tool == "brew")
                if arguments == ["cleanup", "--prune=30", "--dry-run"] {
                    return ToolRunResult(status: 0, output: "Would remove: \(cellar.path) (12 files, 1.2MB)\n==> This operation would free approximately 1.2MB of disk space.")
                }
                #expect(arguments == ["cleanup", "--prune=30"])
                return ToolRunResult(status: 0, output: "Removing: \(cellar.path)... (12 files, 1.1MB)\n==> This operation has freed approximately 1.1MB of disk space.")
            })
        let scans = await CleanEngine.scan([RuleCatalog.homebrewCache], environment: environment)
        let scan = try #require(scans.first)
        #expect(scan.items.map(\.url) == [cellar])
        #expect(scan.totalSize == 1_200_000)
        #expect(scan.rule.usesToolCleaner)
        let logURL = home.root.appendingPathComponent("cleanup.log")
        let report = await CleanEngine.clean(scans, selected: [scan.id], preferTrash: true,
                                             environment: environment, log: CleanLog(url: logURL))
        #expect(report.freedBytes == 1_100_000)
        #expect(report.removedCount == 1)
        #expect(report.trashedBytes == 0)
        #expect(report.failures.isEmpty)
        let logData = try Data(contentsOf: logURL)
        let entries = try logData.split(separator: 0x0A).map {
            try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        #expect(entries.count == 1)
        #expect(entries.first?["action"] as? String == "tool")
        #expect(entries.first?["bytes"] as? Int == 1_100_000)
        #expect(entries.first?["removedCount"] as? Int == 1)
        #expect(entries.first?["path"] == nil)
        #expect(FileManager.default.fileExists(atPath: cached.path))
        let generic = try RuleCatalog.userCaches.locate(environment)
        #expect(!generic.contains { $0.lastPathComponent == "Homebrew" })
        let logs = try RuleCatalog.logs.locate(environment)
        #expect(!logs.contains { $0.lastPathComponent == "Homebrew" })
    }

    @Test func missingHomebrewBlocksPreviewEvenWithoutDefaultCache() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        let environment = CleanEnvironment(home: home.path, runningBundleIdentifiers: { [] },
                                           isToolAvailable: { _ in false },
                                           runTool: { _, _ in throw TestError.unexpectedToolRun })
        let scan = await CleanEngine.scan([RuleCatalog.homebrewCache], environment: environment)
        #expect(scan.first?.blocked == .toolUnavailable("brew"))
    }

    @Test func packageManagerCachesUseTheirBrandLogos() {
        let rules = Dictionary(uniqueKeysWithValues: RuleCatalog.rules().map { ($0.id, $0) })
        let expected = [
            "developer.npm": "tool-npm",
            "developer.yarn": "tool-yarn",
            "developer.pnpm": "tool-pnpm",
            "developer.bun": "tool-bun",
            "developer.go": "tool-go",
            "developer.rust": "tool-rust",
            "developer.uv": "tool-uv",
        ]

        for (id, logo) in expected {
            #expect(rules[id]?.symbol == logo)
        }
    }

    @Test func rulesOnlyLocateRegenerableCacheDirectories() throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Library/Caches/go-build/compile-cache/action")
        try home.file("go/pkg/mod/cache/download/example.zip")
        try home.file("go/pkg/mod/github.com/example/module@v1.0.0/source.go")
        try home.file("go/src/project/main.go")
        try home.file(".cargo/registry/cache/index.crates.io/package.crate")
        try home.file(".cargo/registry/src/index.crates.io/package/src/lib.rs")
        try home.file(".cargo/git/db/example/objects/pack/data")
        try home.file(".cargo/git/checkouts/example/revision/src/lib.rs")
        try home.file(".cargo/bin/cargo")
        try home.file(".cache/uv/archive-v0/package/module.py")
        try home.file(".cache/pip/http-v2/response")
        try home.file("Library/Caches/Yarn/v6/npm-example/package.tgz")
        try home.file(".yarn/berry/cache/example.zip")
        try home.file("Library/pnpm/store/v11/files/example")
        try home.file(".pnpm-store/v3/files/example")
        try home.file(".bun/install/cache/example/package.tgz")

        let rules = Dictionary(uniqueKeysWithValues: RuleCatalog.rules().map { ($0.id, $0) })
        let goRule = try #require(rules["developer.go"])
        let rustRule = try #require(rules["developer.rust"])
        let uvRule = try #require(rules["developer.uv"])
        let yarnRule = try #require(rules["developer.yarn"])
        let pnpmRule = try #require(rules["developer.pnpm"])
        let bunRule = try #require(rules["developer.bun"])

        #expect(try relativePaths(goRule.locate(home.environment()), home: home) == [
            "Library/Caches/go-build", "go/pkg/mod/cache", "go/pkg/mod/github.com",
        ])
        #expect(try relativePaths(rustRule.locate(home.environment()), home: home) == [
            ".cargo/git/checkouts", ".cargo/git/db", ".cargo/registry/cache", ".cargo/registry/src",
        ])
        #expect(try relativePaths(uvRule.locate(home.environment()), home: home) == [
            ".cache/uv/archive-v0",
        ])
        #expect(try relativePaths(yarnRule.locate(home.environment()), home: home) == [
            ".yarn/berry/cache/example.zip", "Library/Caches/Yarn/v6",
        ])
        #expect(try relativePaths(pnpmRule.locate(home.environment()), home: home) == [
            ".pnpm-store/v3", "Library/pnpm/store/v11",
        ])
        #expect(try relativePaths(bunRule.locate(home.environment()), home: home) == [
            ".bun/install/cache/example",
        ])
    }

    @Test func packageManagerCachesUseToolsInsteadOfDirectDeletion() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        let marker = home.root.appendingPathComponent("tool-invocations.txt")
        let script = """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          echo "1.22.22"
          exit 0
        fi
        printf '%s|%s\\n' "$(basename "$0")" "$*" >> "\(marker.path)"
        """
        for tool in ["npm", "yarn", "pnpm", "bun", "go", "cargo-cache", "uv"] {
            try home.executable(tool, script: script)
        }

        let cacheFiles = [
            try home.file(".npm/_cacache/content/data"),
            try home.file("Library/Caches/Yarn/v6/npm-example/package.tgz"),
            try home.file("Library/pnpm/store/v11/files/data"),
            try home.file(".bun/install/cache/example/package.tgz"),
            try home.file("Library/Caches/go-build/action/data"),
            try home.file("go/pkg/mod/cache/download/data"),
            try home.file(".cargo/registry/cache/index/package.crate"),
            try home.file(".cache/uv/archive-v0/package/data"),
        ]
        let ids = Set(["developer.npm", "developer.yarn", "developer.pnpm", "developer.bun",
                       "developer.go", "developer.rust", "developer.uv"])
        let rules = RuleCatalog.rules().filter { ids.contains($0.id) }
        let environment = home.environment(now: Date().addingTimeInterval(86_400))
        let scans = await CleanEngine.scan(rules, environment: environment)

        let report = await CleanEngine.clean(scans, selected: ids, preferTrash: false,
                                             environment: environment, log: nil)

        #expect(report.failures.isEmpty)
        #expect(cacheFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let invocations = try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n").map(String.init).sorted()
        #expect(invocations == [
            "bun|pm cache rm",
            "cargo-cache|-r all",
            "go|clean -cache -modcache",
            "npm|cache clean --force",
            "pnpm|store prune",
            "uv|cache clean",
            "yarn|cache clean",
        ])
    }

    @Test func missingToolBlocksCacheWithoutDeletingIt() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        let cache = try home.file(".npm/_cacache/content/data")
        let environment = CleanEnvironment(
            home: home.path,
            runningBundleIdentifiers: { [] },
            isToolAvailable: { _ in false },
            runTool: { _, _ in throw TestError.unexpectedToolRun }
        )

        let scans = await CleanEngine.scan([RuleCatalog.npmCache], environment: environment)

        #expect(scans.first?.blocked == .toolUnavailable("npm"))
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func failedToolCommandReportsFailureWithoutDeletingCache() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.executable("npm", script: "#!/bin/sh\necho 'simulated failure' >&2\nexit 7\n")
        let cache = try home.file(".npm/_cacache/content/data")
        let environment = home.environment(now: Date().addingTimeInterval(86_400))
        let scans = await CleanEngine.scan([RuleCatalog.npmCache], environment: environment)

        let report = await CleanEngine.clean(scans, selected: [RuleCatalog.npmCache.id], preferTrash: false,
                                             environment: environment, log: nil)

        #expect(report.failures.count == 1)
        #expect(report.failures.first?.contains("simulated failure") == true)
        #expect(report.failures.first?.contains("7") == true)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func toolManagedCacheDoesNotTreatPackageNamesAsProtectedAppData() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.executable("bun", script: "#!/bin/sh\nexit 0\n")
        try home.file(".bun/install/cache/xstats-package/data")

        let scans = await CleanEngine.scan([RuleCatalog.bunCache], environment: home.environment())

        #expect(scans.first?.skippedCount == 0)
        #expect(scans.first?.items.map(\.url.lastPathComponent) == ["xstats-package"])
    }

    private func relativePaths(_ urls: [URL], home: FakeHome) throws -> [String] {
        let prefix = home.path + "/"
        return try urls.map { url in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { throw TestError.outsideHome }
            return String(path.dropFirst(prefix.count))
        }.sorted()
    }

    private enum TestError: Error {
        case outsideHome
        case unexpectedToolRun
    }
}

@Suite("扫描与清理", .serialized)
struct CleanEngineTests {
    @Test func scanSkipsRunningAppsAndAppleCaches() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Library/Caches/com.example.idle/data.bin", bytes: 8192)
        try home.file("Library/Caches/com.example.busy/data.bin")
        try home.file("Library/Caches/com.apple.Music/data.bin")
        try home.file("Library/Caches/com.1password.1password/data.bin")

        let scans = await CleanEngine.scan([RuleCatalog.userCaches], environment: home.environment(running: ["com.example.busy"]))
        let scan = try #require(scans.first)
        #expect(scan.items.map(\.url.lastPathComponent) == ["com.example.idle"])
        #expect(scan.totalSize >= 8192)
        #expect(scan.skippedCount == 2)  // 运行中的应用 + 受保护的密码管理器；com.apple.* 在列出时即排除
    }

    @Test func recentlyModifiedItemsAreSkipped() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Library/Caches/com.example.fresh/data.bin", age: 5)

        let scans = await CleanEngine.scan([RuleCatalog.userCaches], environment: home.environment())
        #expect(scans.first?.items.isEmpty == true)
        #expect(scans.first?.skippedCount == 1)
    }

    @Test func browserRuleIsBlockedWhileRunning() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Library/Caches/Google/Chrome/Default/Cache/data")
        let chrome = try #require(RuleCatalog.browsers.first { $0.id == "chrome" }).rule

        let blocked = await CleanEngine.scan([chrome], environment: home.environment(running: ["com.google.Chrome"]))
        #expect(blocked.first?.blocked == .appRunning("Chrome"))

        let idle = await CleanEngine.scan([chrome], environment: home.environment())
        #expect(idle.first?.blocked == nil)
        #expect(idle.first?.items.count == 1)
    }

    @Test func cleanDeletesOnlySelectedRules() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        let cache = try home.file("Library/Caches/com.example.app/data.bin")
        let log = try home.file("Library/Logs/com.example.app/app.log")

        let environment = home.environment()
        let scans = await CleanEngine.scan([RuleCatalog.userCaches, RuleCatalog.logs], environment: environment)
        let report = await CleanEngine.clean(scans, selected: [RuleCatalog.userCaches.id], preferTrash: false,
                                             environment: environment, log: nil)

        #expect(report.removedCount == 1)
        #expect(report.freedBytes > 0)
        #expect(!FileManager.default.fileExists(atPath: cache.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: log.path))
    }

    @Test func cleaningProgressCountsSelectedFileItems() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        try home.file("Library/Caches/com.example.first/data.bin")
        try home.file("Library/Caches/com.example.second/data.bin")
        try home.file("Library/Logs/com.example.app/app.log")
        let environment = home.environment()
        let scans = await CleanEngine.scan([RuleCatalog.userCaches, RuleCatalog.logs], environment: environment)
        let capture = CleanProgressCapture()

        _ = await CleanEngine.clean(scans, selected: [RuleCatalog.userCaches.id], preferTrash: false,
                                    environment: environment, log: nil,
                                    onProgress: { await capture.record($0) })

        let updates = await capture.values()
        #expect(updates.map(\.completed) == [0, 1, 2])
        #expect(updates.allSatisfy { $0.total == 2 && $0.currentRule == RuleCatalog.userCaches.title })
    }

    @Test func cleanRechecksRunningAppsBeforeDeleting() async throws {
        let home = try FakeHome()
        defer { home.remove() }
        let cache = try home.file("Library/Caches/com.example.app/data.bin")

        let scans = await CleanEngine.scan([RuleCatalog.userCaches], environment: home.environment())
        // 扫描后应用启动了
        let report = await CleanEngine.clean(scans, selected: [RuleCatalog.userCaches.id], preferTrash: false,
                                             environment: home.environment(running: ["com.example.app"]), log: nil)
        #expect(report.removedCount == 0)
        #expect(report.skippedCount == 1)
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }
}

extension RuleCatalog.Browser {
    var rule: CleanRule { RuleCatalog.browserRule(self) }
}
