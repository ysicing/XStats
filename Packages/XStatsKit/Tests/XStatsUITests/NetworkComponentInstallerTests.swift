// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NetworkObservation
import Testing
@testable import XStatsUI

@Suite(.timeLimit(.minutes(1)))
struct NetworkComponentInstallerTests {
    @Test func firstInstallUsesVersionedReleaseArchive() throws {
        let url = try #require(NetworkComponentInstaller.releaseURL(version: "1.0.0"))
        #expect(url.absoluteString == "https://c.ysicing.net/oss/apps/macOS/XStats/network-monitor/XStats-Network-Monitor-1.0.0-AppleSilicon.zip")
    }

    @Test(arguments: [nil, "", "1.0", "01.0.0", "1.0.0/other", "../1.0.0", "1.0.0?x=1"] as [String?])
    func rejectsInvalidComponentReleaseVersions(_ version: String?) {
        #expect(NetworkComponentInstaller.releaseURL(version: version) == nil)
    }

    @Test @MainActor func missingVersionedURLCannotDownloadOrInstall() async throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        let installer = fixture.installer(download: { _, _, _ in
            Issue.record("缺少发行版本时不能下载")
            return Data()
        }, archiveURL: nil)
        await #expect(throws: NetworkComponentInstallError.untrustedComponent) {
            try await installer.install(progress: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test(arguments: ["../escape", "/absolute", "XStats Network Monitor.app/../escape", "Other.app/Contents/Info.plist", "XStats Network Monitor.app/a\\b", "XStats Network Monitor.app/a\nb"])
    func rejectsUnsafeArchivePaths(_ path: String) {
        #expect(throws: NetworkComponentInstallError.invalidArchive) {
            _ = try NetworkComponentArchive.inspect(componentArchive([(path, Data(), 0o100644)]))
        }
    }

    @Test func rejectsDuplicatePathsSpecialFilesAndOversizedExpansion() {
        let path = "XStats Network Monitor.app/Contents/Info.plist"
        #expect(throws: NetworkComponentInstallError.invalidArchive) {
            _ = try NetworkComponentArchive.inspect(componentArchive([(path, Data(), 0o100644), (path, Data(), 0o100644)]))
        }
        #expect(throws: NetworkComponentInstallError.invalidArchive) {
            _ = try NetworkComponentArchive.inspect(componentArchive([(path, Data(), 0o020644)]))
        }
        #expect(throws: NetworkComponentInstallError.invalidArchive) {
            _ = try NetworkComponentArchive.inspect(componentArchive([(path, Data(), 0o100644)], claimedSize: 512 * 1024 * 1024))
        }
    }

    @Test(arguments: ["../../../../outside", "/Applications/Other.app", "", "../Versions/../../../../outside"])
    func rejectsEscapingSymlinkTargets(_ target: String) {
        #expect(throws: NetworkComponentInstallError.invalidArchive) {
            try NetworkComponentArchive.validateSymlink(path: "XStats Network Monitor.app/Contents/Frameworks/Current", target: target)
        }
    }

    @Test func acceptsInternalFrameworkSymlink() throws {
        try NetworkComponentArchive.validateSymlink(path: "XStats Network Monitor.app/Contents/Frameworks/Sparkle.framework/Versions/Current", target: "B")
    }

    @Test func validatesArchiveCreatedBySystemDittoWithFrameworkLinks() throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        let app = fixture.root.appendingPathComponent("XStats Network Monitor.app")
        try fixture.makeBundle(at: app)
        let versions = app.appendingPathComponent("Contents/Frameworks/Example.framework/Versions")
        try FileManager.default.createDirectory(at: versions.appendingPathComponent("B"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: versions.appendingPathComponent("Current").path, withDestinationPath: "B")
        let archive = fixture.root.appendingPathComponent("actual.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--keepParent", app.path, archive.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let entries = try NetworkComponentArchive.inspect(Data(contentsOf: archive))
        #expect(entries.contains { $0.path.hasSuffix("Versions/Current") && $0.isSymlink })
    }

    @Test func rejectsEntriesNestedBelowSymlink() {
        #expect(throws: NetworkComponentInstallError.invalidArchive) {
            _ = try NetworkComponentArchive.inspect(componentArchive([
                ("XStats Network Monitor.app/Contents/link", Data("directory".utf8), 0o120755),
                ("XStats Network Monitor.app/Contents/link/child", Data(), 0o100644)
            ]))
        }
    }

    @Test func rejectsAmbiguousFileModesAndSymlinkDirectoryNames() {
        #expect(throws: NetworkComponentInstallError.invalidArchive) {
            _ = try NetworkComponentArchive.inspect(componentArchive([("XStats Network Monitor.app/file", Data(), 0)]))
        }
        #expect(throws: NetworkComponentInstallError.invalidArchive) {
            _ = try NetworkComponentArchive.inspect(componentArchive([("XStats Network Monitor.app/link/", Data("directory".utf8), 0o120755)]))
        }
    }

    @Test @MainActor func rejectsForgedExpandedSizeBeforeWritingBundle() async throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        let app = fixture.root.appendingPathComponent("XStats Network Monitor.app")
        try fixture.makeBundle(at: app, marker: String(repeating: "0", count: 1024 * 1024))
        let archive = fixture.root.appendingPathComponent("forged.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--keepParent", app.path, archive.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        var payload = try Data(contentsOf: archive)
        let name = Data("XStats Network Monitor.app/marker".utf8)
        let header = try #require((0..<(payload.count - 46 - name.count)).first {
            payload[$0..<($0 + 4)] == Data([0x50, 0x4b, 0x01, 0x02]) && payload[($0 + 46)..<($0 + 46 + name.count)] == name
        })
        payload.replaceSubrange((header + 24)..<(header + 28), with: [1, 0, 0, 0])
        // unzip -t 对这种元数据不一致仍返回成功；安装器必须实际限量展开后才能使用 ditto。
        await #expect(throws: NetworkComponentInstallError.invalidArchive) {
            try await fixture.installer(archivePayload: payload, realArchiveCommands: true).install(progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
    }

    @Test @MainActor func installsOnlyAfterIdentityAndTrustChecks() async throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        let installer = fixture.installer()
        try await installer.install(progress: { _ in })
        #expect(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("Contents/Info.plist").path))
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("marker")) == Data("new".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
    }

    @Test(arguments: ["wrong-id", "wrong-team", "unsigned-host", "codesign", "gatekeeper", "not-notarized"])
    @MainActor func rejectsUntrustedComponentWithoutInstalling(_ failure: String) async throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        await #expect(throws: NetworkComponentInstallError.untrustedComponent) {
            try await fixture.installer(failure: failure).install(progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
    }

    @Test(arguments: ["newer-protocol", "wrong-control-service"])
    @MainActor func rejectsIncompatibleComponentBeforeInstalling(_ failure: String) async throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        await #expect(throws: NetworkMonitorError.protocolMismatch) {
            try await fixture.installer(failure: failure).install(progress: { _ in })
        }
        // 不兼容组件不能落盘，否则后续安装只校验不替换，组件也无法通过控制服务卸载。
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path).isEmpty)
    }

    // root 会忽略目录权限位，无法模拟标准账户。
    @Test(.enabled(if: getuid() != 0)) @MainActor func readOnlyApplicationsReportsAdministratorRequirement() async throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        let applications = fixture.destination.deletingLastPathComponent()
        // 模拟标准账户对 /Applications 没有写权限。
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: applications.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path) }
        await #expect(throws: NetworkComponentInstallError.requiresAdministrator) {
            try await fixture.installer().install(progress: { _ in })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
    }

    @Test @MainActor func neverReplacesExistingComponentOrItsFiles() async throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        try fixture.makeBundle(at: fixture.destination, marker: "old")
        let installer = fixture.installer(failure: "download")
        try await installer.install(progress: { _ in })
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("marker")) == Data("old".utf8))
        await #expect(throws: NetworkComponentInstallError.untrustedComponent) {
            try await fixture.installer(failure: "wrong-team").install(progress: { _ in })
        }
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("marker")) == Data("old".utf8))
    }

    @Test @MainActor func refusesRunningComponent() async throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        await #expect(throws: NetworkComponentInstallError.runningComponent) {
            try await fixture.installer(running: true).install(progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    @Test @MainActor func cancelledDownloadCannotInstallLatePayload() async throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        let gate = ComponentDownloadGate()
        let installer = fixture.installer(download: gate.download)
        let task = Task { try await installer.install(progress: { _ in }) }
        while await !gate.entered { await Task.yield() }
        task.cancel()
        await gate.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty)
    }

    @Test @MainActor func componentAppearingDuringDownloadCannotBeReplaced() async throws {
        let fixture = try ComponentInstallFixture()
        defer { fixture.remove() }
        let gate = ComponentDownloadGate()
        let installer = fixture.installer(download: gate.download)
        let task = Task { try await installer.install(progress: { _ in }) }
        while await !gate.entered { await Task.yield() }
        try fixture.makeBundle(at: fixture.destination, marker: "arrived")
        await gate.resume()
        await #expect(throws: POSIXError(.EEXIST)) { try await task.value }
        #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("marker")) == Data("arrived".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path) == ["XStats Network Monitor.app"])
    }
}

private struct ComponentInstallFixture: Sendable {
    let root: URL
    let temporary: URL
    let destination: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporary = root.appendingPathComponent("temporary")
        destination = root.appendingPathComponent("Applications/XStats Network Monitor.app")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func makeBundle(at url: URL, id: String = "work.12306.xstats.networkmonitor", marker: String = "new",
                    protocolVersion: Int = NetworkObservationProtocol.version, controlTeam: String = "TEAM123") throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": id, "CFBundlePackageType": "APPL",
            "NetworkObservationMachService": "TEAM123.work.12306.xstats.network-observation.ipc.1",
            "NetworkObservationControlMachService": NetworkObservationProtocol.controlServiceName(team: controlTeam),
            "NetworkObservationProtocolVersion": protocolVersion,
        ], format: .xml, options: 0)
        try info.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
    }
    @MainActor func installer(failure: String = "", running: Bool = false, archivePayload: Data? = nil, realArchiveCommands: Bool = false,
                             download: NetworkComponentInstaller.Dependencies.Download? = nil,
                             archiveURL: URL? = NetworkComponentInstaller.releaseURL(version: "1.0.0")) -> NetworkComponentInstaller {
        let dependencies = NetworkComponentInstaller.Dependencies(
            download: download ?? { _, _, _ in
                if failure == "download" { throw URLError(.notConnectedToInternet) }
                return archivePayload ?? componentArchive([("XStats Network Monitor.app/Contents/Info.plist", Data(), 0o100644)])
            },
            command: { executable, arguments, limit in
                if realArchiveCommands && (executable == "/usr/bin/ditto" || executable == "/usr/bin/unzip") {
                    return try await NetworkComponentInstaller.runCommand(executable, arguments: arguments, limit: limit)
                }
                if executable == "/usr/bin/ditto" {
                    let directory = URL(fileURLWithPath: arguments.last!)
                    try makeBundle(at: directory.appendingPathComponent("XStats Network Monitor.app"), id: failure == "wrong-id" ? "other.bundle" : "work.12306.xstats.networkmonitor",
                                   protocolVersion: failure == "newer-protocol" ? NetworkObservationProtocol.version + 1 : NetworkObservationProtocol.version,
                                   controlTeam: failure == "wrong-control-service" ? "OTHER456" : "TEAM123")
                }
                if (executable == "/usr/bin/codesign" && failure == "codesign") || (executable == "/usr/sbin/spctl" && failure == "gatekeeper") {
                    throw NetworkComponentInstallError.untrustedComponent
                }
                if executable == "/usr/sbin/spctl" {
                    return Data("accepted\nsource=\(failure == "not-notarized" ? "Developer ID" : "Notarized Developer ID")\n".utf8)
                }
                return Data()
            },
            teamIdentifier: { url in
                if url.path == "/host.app" { return failure == "unsigned-host" ? nil : "TEAM123" }
                return failure == "wrong-team" ? "OTHER456" : "TEAM123"
            },
            isRunning: { running },
            archiveURL: archiveURL
        )
        return NetworkComponentInstaller(destination: destination, temporaryRoot: temporary, hostApp: URL(fileURLWithPath: "/host.app"), dependencies: dependencies)
    }
}

private actor ComponentDownloadGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func download(_ url: URL, _ maximum: Int, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        entered = true
        await withCheckedContinuation { continuation = $0 }
        return componentArchive([("XStats Network Monitor.app/Contents/Info.plist", Data(), 0o100644)])
    }
    func resume() { continuation?.resume(); continuation = nil }
}

/// 直接构造无压缩 ZIP，测试恶意元数据而不依赖压缩工具对路径的预先规范化。
private func componentArchive(_ entries: [(String, Data, UInt32)], claimedSize: UInt32? = nil) -> Data {
    var local = Data(), central = Data()
    for (path, content, mode) in entries {
        let name = Data(path.utf8), offset = UInt32(local.count)
        local.appendLE(UInt32(0x04034b50)); local.appendLE(UInt16(20)); local.appendLE(UInt16(0x800))
        local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0)); local.appendLE(UInt32(0))
        local.appendLE(UInt32(content.count)); local.appendLE(claimedSize ?? UInt32(content.count))
        local.appendLE(UInt16(name.count)); local.appendLE(UInt16(0)); local.append(name); local.append(content)
        central.appendLE(UInt32(0x02014b50)); central.appendLE(UInt16(0x0314)); central.appendLE(UInt16(20))
        central.appendLE(UInt16(0x800)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
        central.appendLE(UInt32(0)); central.appendLE(UInt32(content.count)); central.appendLE(claimedSize ?? UInt32(content.count))
        central.appendLE(UInt16(name.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
        central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(mode << 16); central.appendLE(offset); central.append(name)
    }
    let centralOffset = UInt32(local.count)
    local.append(central)
    local.appendLE(UInt32(0x06054b50)); local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
    local.appendLE(UInt16(entries.count)); local.appendLE(UInt16(entries.count))
    local.appendLE(UInt32(central.count)); local.appendLE(centralOffset); local.appendLE(UInt16(0))
    return local
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var bytes = value.littleEndian
        Swift.withUnsafeBytes(of: &bytes) { append(contentsOf: $0) }
    }
}
