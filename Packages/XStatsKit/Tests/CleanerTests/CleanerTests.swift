import Foundation
import Testing
@testable import Cleaner

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

    func environment(running: Set<String> = []) -> CleanEnvironment {
        CleanEnvironment(home: path, runningBundleIdentifiers: { running })
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
    }

    @Test func rejectsRootsAndOutsidePaths() {
        #expect(throws: SafetyError.isRoot) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/Library/Caches")) }
        #expect(throws: SafetyError.outsideAllowedRoots) { try guardian.validate(URL(fileURLWithPath: "/Users/tester/Documents/a")) }
        #expect(throws: SafetyError.outsideAllowedRoots) { try guardian.validate(URL(fileURLWithPath: "/System/Library/Caches/x")) }
        #expect(throws: SafetyError.outsideAllowedRoots) { try guardian.validate(URL(fileURLWithPath: "/Users/other/Library/Caches/x")) }
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
