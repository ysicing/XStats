import Foundation
import Testing
@testable import Updates

@Suite struct UpdateFeedTests {
    @Test func comparesVersionsNumerically() {
        #expect(UpdateFeed.isNewer("0.10.0", than: "0.9.3"))
        #expect(UpdateFeed.isNewer("0.2.1", than: "0.2.0"))
        #expect(!UpdateFeed.isNewer("0.2.0", than: "0.2.0"))
        #expect(!UpdateFeed.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateFeed.isNewer("0.1.9", than: "0.2.0"))
    }

    @Test func checksMinimumSystem() {
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        #expect(UpdateFeed.systemSatisfies("14.0", current: sonoma))
        #expect(!UpdateFeed.systemSatisfies("15.0", current: sonoma))
    }

    @Test func parsesAndRejectsBadFeeds() throws {
        let good = #"{"version":"0.3.0","build":"3","date":"2026-09-20","minimumSystem":"14.0","url":"https://getopenstats.com/download/OpenStats-0.3.0.zip","sha256":"\#(String(repeating: "a", count: 64))","size":123,"dmg":"https://getopenstats.com/download/OpenStats-0.3.0.dmg","notes":["新增在线升级"],"changelog":null}"#
        let release = try #require(UpdateFeed.parse(Data(good.utf8)))
        #expect(release.version == "0.3.0")
        #expect(release.notes == ["新增在线升级"])
        let insecure = good.replacingOccurrences(of: "https://getopenstats.com/download/OpenStats-0.3.0.zip", with: "http://example.com/x.zip")
        #expect(UpdateFeed.parse(Data(insecure.utf8)) == nil)
        let badHash = good.replacingOccurrences(of: String(repeating: "a", count: 64), with: "abc")
        #expect(UpdateFeed.parse(Data(badHash.utf8)) == nil)
    }

    @Test func picksInstallerForChip() throws {
        let hash = String(repeating: "a", count: 64), intelHash = String(repeating: "b", count: 64)
        let base = #"{"version":"0.3.1","build":"51","date":"2026-09-16","minimumSystem":"14.0","url":"https://getopenstats.com/download/OpenStats-0.3.1-AppleSilicon.zip","sha256":"\#(hash)","size":1,"dmg":null,"notes":[],"changelog":null"#
        // 0.3.0 那样只有 Apple 芯片版的清单：Intel 上不提供升级
        let appleOnly = try #require(UpdateFeed.parse(Data((base + "}").utf8)))
        #expect(UpdateFeed.release(appleOnly, for: .appleSilicon) == appleOnly)
        #expect(UpdateFeed.release(appleOnly, for: .intel) == nil)

        let both = try #require(UpdateFeed.parse(Data((base + #","intel":{"url":"https://getopenstats.com/download/OpenStats-0.3.1-Intel.zip","sha256":"\#(intelHash)","size":2,"dmg":"https://getopenstats.com/download/OpenStats-0.3.1-Intel.dmg"}}"#).utf8)))
        #expect(UpdateFeed.release(both, for: .appleSilicon)?.sha256 == hash)
        let intel = try #require(UpdateFeed.release(both, for: .intel))
        #expect(intel.url.lastPathComponent == "OpenStats-0.3.1-Intel.zip")
        #expect(intel.sha256 == intelHash && intel.size == 2 && intel.version == "0.3.1")
    }
}

@Suite struct UpdateInstallerTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xstats-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func hashesFiles() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("abc".utf8).write(to: file)
        #expect(try UpdateInstaller.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func replacesAndKeepsOldOnFailure() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("App.app")
        let candidate = dir.appendingPathComponent("New.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("v"))
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: candidate.appendingPathComponent("v"))

        try UpdateInstaller.replace(current, with: candidate, backupDirectory: dir)
        #expect(String(decoding: try Data(contentsOf: current.appendingPathComponent("v")), as: UTF8.self) == "new")
        #expect(!FileManager.default.fileExists(atPath: candidate.path))

        // 新版不存在时移动失败，旧版应还原到原位置
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.replace(current, with: dir.appendingPathComponent("Missing.app"), backupDirectory: dir)
        }
        #expect(String(decoding: try Data(contentsOf: current.appendingPathComponent("v")), as: UTF8.self) == "new")
    }

    @Test func extractsSingleApp() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("src/Demo.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("Demo.zip")
        #expect(UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", dir.appendingPathComponent("src/Demo.app").path, zip.path]).status == 0)
        let extracted = try UpdateInstaller.extractApp(from: zip, into: dir)
        #expect(extracted.lastPathComponent == "Demo.app")
    }

    @Test func rejectsUnsignedBundle() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("Demo.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "work.12306.xstats.app", "CFBundleShortVersionString": "9.9.9", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(throws: UpdateError.self) {
            try UpdateInstaller.verify(app, bundleIdentifier: "work.12306.xstats.app", version: "9.9.9", teamIdentifier: "ABCDE12345")
        }
        #expect(throws: UpdateError.invalidBundle("版本是 9.9.9，清单写的是 1.0.0")) {
            try UpdateInstaller.verify(app, bundleIdentifier: "work.12306.xstats.app", version: "1.0.0", teamIdentifier: "ABCDE12345")
        }
    }

    @Test func rejectsPreviousProductIdentity() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("OpenStats.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.openstats.app", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        #expect(throws: UpdateError.invalidBundle("包名是 com.openstats.app")) {
            try UpdateInstaller.verify(app, bundleIdentifier: "work.12306.xstats.app", version: "0.6.1", teamIdentifier: "ABCDE12345")
        }
    }
}
