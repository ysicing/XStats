import Darwin
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

    @Test func buildsAnAnonymousInstallationCheckRequest() throws {
        let endpoint = try #require(URL(string: "https://x-stats.china.12306.work/api/v1/update/check"))
        let request = try UpdateFeed.checkRequest(
            url: endpoint,
            currentVersion: "2026.09.21.02",
            installationID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            operatingSystemVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 7, patchVersion: 0)
        )
        #expect(request.url == endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "XStats/2026.09.21.02 (macOS 15.7)")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json == [
            "current_version": "2026.09.21.02",
            "installation_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ])
    }

    @Test func ordersRegionalEndpointsWithoutDuplicatingRequests() {
        let global = "https://xstats-apps.12306.work/api/v1/update/check"
        let china = "https://x-stats.china.12306.work/api/v1/update/check"
        #expect(UpdateFeed.checkURLs(prefersChina: true).map(\.absoluteString) == [china, global])
        #expect(UpdateFeed.checkURLs(prefersChina: false).map(\.absoluteString) == [global, china])
        #expect(UpdateFeed.prefersChinaEndpoint(locale: Locale(identifier: "zh_CN")))
        #expect(!UpdateFeed.prefersChinaEndpoint(locale: Locale(identifier: "en_US")))
    }

    @Test func parsesAndRejectsBadFeeds() throws {
        let good = #"{"version":"0.3.0","build":"3","date":"2026-09-20","minimumSystem":"14.0","url":"https://getopenstats.com/download/OpenStats-0.3.0.zip","sha256":"\#(String(repeating: "a", count: 64))","size":123,"dmg":"https://getopenstats.com/download/OpenStats-0.3.0.dmg","notes":["新增在线升级"],"changelog":null}"#
        let release = try #require(UpdateFeed.parse(Data(good.utf8)))
        #expect(release.version == "0.3.0")
        #expect(release.notes == ["新增在线升级"])
        #expect(release.englishNotes == nil)
        #expect(release.notes(for: "en") == release.notes)
        let insecure = good.replacingOccurrences(of: "https://getopenstats.com/download/OpenStats-0.3.0.zip", with: "http://example.com/x.zip")
        #expect(UpdateFeed.parse(Data(insecure.utf8)) == nil)
        let badHash = good.replacingOccurrences(of: String(repeating: "a", count: 64), with: "abc")
        #expect(UpdateFeed.parse(Data(badHash.utf8)) == nil)
    }

    @Test func chineseLanguagesUseChineseAndOtherLanguagesUseEnglish() throws {
        let json = #"{"version":"1.0.0","build":"200","date":"2026-09-30","minimumSystem":"14.0","url":"https://example.test/update.zip","sha256":"\#(String(repeating: "a", count: 64))","size":1000,"notes":["source"],"englishNotes":["English"]}"#
        let release = try #require(UpdateFeed.parse(Data(json.utf8)))
        for code in ["zh", "zh-Hans", "zh-Hant", "zh-CN", "zh-TW"] {
            #expect(release.notes(for: code) == ["source"])
        }
        for code in ["en", "ja", "ko", "de", "es", "fr", "ar", "unsupported"] {
            #expect(release.notes(for: code) == ["English"])
        }
        let withoutEnglish = json.replacingOccurrences(of: #","englishNotes":["English"]"#, with: "")
        let chineseFallback = try #require(UpdateFeed.parse(Data(withoutEnglish.utf8)))
        #expect(chineseFallback.notes(for: "de") == ["source"])
        let emptyEnglish = json.replacingOccurrences(of: #""englishNotes":["English"]"#, with: #""englishNotes":[]"#)
        #expect(try #require(UpdateFeed.parse(Data(emptyEnglish.utf8))).notes(for: "de") == ["source"])
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

    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    /// CI 不能可靠运行改名后的 Apple 平台二进制；编译普通替身，保留真实的进程路径检查。
    private func makeSleepingExecutable(at url: URL) throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("xstats-widget-fixture-\(UUID().uuidString).c")
        defer { try? FileManager.default.removeItem(at: source) }
        try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let compile = run("/usr/bin/xcrun", ["clang", "-x", "c", source.path, "-o", url.path])
        try #require(compile.status == 0, "测试替身编译失败：\(compile.output)")
        let sign = run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        try #require(sign.status == 0, "测试替身签名失败：\(sign.output)")
    }

    @Test func stopsOnlyThisInstallationsWidgetExtension() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("XStats.app")
        let executable = current.appendingPathComponent("Contents/PlugIns/XStatsWidget.appex/Contents/MacOS/XStatsWidget")
        let otherExecutable = dir.appendingPathComponent("Other.app/Contents/PlugIns/XStatsWidget.appex/Contents/MacOS/XStatsWidget")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeSleepingExecutable(at: executable)
        try FileManager.default.createDirectory(at: otherExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeSleepingExecutable(at: otherExecutable)

        let process = Process()
        process.executableURL = executable
        process.arguments = ["30"]
        try process.run()
        let otherProcess = Process()
        otherProcess.executableURL = otherExecutable
        otherProcess.arguments = ["30"]
        try otherProcess.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            if otherProcess.isRunning { otherProcess.terminate() }
            otherProcess.waitUntilExit()
        }

        // 两个进程都必须真的在运行，否则下面“已退出”的断言会不经检验就通过。
        #expect(process.isRunning && otherProcess.isRunning, "测试替身进程未能启动")
        var runningPath = [CChar](repeating: 0, count: 4096)
        let pathLength = proc_pidpath(process.processIdentifier, &runningPath, UInt32(runningPath.count))
        #expect(pathLength > 0)

        try UpdateInstaller.stopWidgetExtension(in: current)
        #expect(!process.isRunning, "替换应用前应退出旧版小组件扩展")
        #expect(otherProcess.isRunning, "不得退出其他应用的同名进程")
    }

}
