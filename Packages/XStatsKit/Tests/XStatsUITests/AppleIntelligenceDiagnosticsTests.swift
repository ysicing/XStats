// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Darwin
import Testing
@testable import XStatsUI

struct AppleIntelligenceDiagnosticsTests {
    @Test(arguments: ["", "not-json", "{", "{}"])
    func emptyOrMalformedReaderOutputReturnsUnreadable(output: String) async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: script) }
        let escapedOutput = output.replacingOccurrences(of: "'", with: "'\\''")
        try "#!/bin/sh\nprintf '%s' '\(escapedOutput)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        #expect(try await AppleIntelligenceDiagnostics.load(executableURL: script) == .unreadable)
    }

    @Test func readerFinishingAfterDeadlineCannotPublishValidReport() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: script) }
        let encoded = try JSONEncoder().encode(AppleIntelligenceDiagnostics.Report.example).base64EncodedString()
        let command = """
        #!/bin/sh
        /bin/sleep 0.05
        printf '%s' '\(encoded)' | /usr/bin/base64 --decode
        """
        try command.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        // 子进程在读取器的旧轮询间隔内退出，也不能绕过截止时间发布结果。
        #expect(try await AppleIntelligenceDiagnostics.load(executableURL: script, timeout: .milliseconds(1)) == .unreadable)
    }

    @Test func missingOrMalformedInventoryDoesNotMeanZeroBytes() {
        #expect(AppleIntelligenceDiagnostics.parseInventory([:]) == nil)
        #expect(AppleIntelligenceDiagnostics.parseInventory(["SystemAssets": "unexpected"]) == nil)
        #expect(AppleIntelligenceDiagnostics.parseInventory(["SystemAssets": [["isPresentOnDevice": true]]]) == nil)
    }

    @Test func emptyInventoryAndInstalledAssetsRemainDistinct() throws {
        let empty = try #require(AppleIntelligenceDiagnostics.parseInventory(["SystemAssets": [[String: Any]]()]))
        #expect(empty.isEmpty)
        let assets: [[String: Any]] = [
            ["isPresentOnDevice": true, "metadata": ["AssetType": "model", "_UnarchivedSize": 12]],
            ["isPresentOnDevice": true, "metadata": ["AssetType": "model", "com.apple.UnifiedAssetFramework.UnarchivedSize": 8]],
            ["isPresentOnDevice": false, "metadata": ["AssetType": "model", "_UnarchivedSize": 999]]
        ]
        let inventory = try #require(AppleIntelligenceDiagnostics.parseInventory(["SystemAssets": assets]))
        #expect(inventory["model"] == 20)
    }

    @Test func unknownSizesAndOverflowDoNotProduceMisleadingTotals() {
        #expect(AppleIntelligenceDiagnostics.total([0, 0, 0]) == 0)
        #expect(AppleIntelligenceDiagnostics.total([12, nil]) == nil)
        #expect(AppleIntelligenceDiagnostics.total([Int64.max, 1]) == nil)
        #expect(AppleIntelligenceDiagnostics.total([-1]) == nil)
        #expect(AppleIntelligenceDiagnostics.parseInventory(["SystemAssets": [
            ["isPresentOnDevice": true, "metadata": ["AssetType": "model", "_UnarchivedSize": -1]]
        ]]) == nil)
    }

    @Test func configurationStateMatchesRemoveMacAIIncludingAbsentAndPartialValues() {
        typealias Value = AppleIntelligenceDiagnostics.SettingValue
        let missing = Value(value: nil)
        let off = Value(value: true)
        #expect(AppleIntelligenceDiagnostics.featureState(restrictions: [missing], preferences: []) == .on)
        #expect(AppleIntelligenceDiagnostics.featureState(restrictions: [], preferences: [missing]) == .on)
        #expect(AppleIntelligenceDiagnostics.featureState(restrictions: [], preferences: [off, missing]) == .on)
        #expect(AppleIntelligenceDiagnostics.featureState(restrictions: [], preferences: [off, off]) == .off)
        #expect(AppleIntelligenceDiagnostics.featureState(restrictions: [Value(value: false)], preferences: []) == .on)
        #expect(AppleIntelligenceDiagnostics.featureState(restrictions: [Value(value: false, isForced: true)], preferences: []) == .lockedOff)
        #expect(AppleIntelligenceDiagnostics.featureState(
            restrictions: [Value(value: false, isForced: true)], preferences: [Value(value: true, isForced: true)]) == .lockedOff)
        #expect(AppleIntelligenceDiagnostics.featureState(
            restrictions: [Value(value: false, isForced: true)], preferences: [off]) == .off)
        #expect(AppleIntelligenceDiagnostics.featureState(
            restrictions: [Value(value: false, isForced: true), Value(value: true, isForced: true)], preferences: []) == .on)
    }

    @Test func modelOnlyFeaturesRespectOccupancyUnknownsAndProfileLocks() {
        #expect(AppleIntelligenceDiagnostics.featureState(restrictions: [], preferences: [], modelBytes: [0]) == .off)
        #expect(AppleIntelligenceDiagnostics.featureState(restrictions: [], preferences: [], modelBytes: [1, nil]) == .on)
        #expect(AppleIntelligenceDiagnostics.featureState(restrictions: [], preferences: [], modelBytes: [0, nil]) == .unknown)
        #expect(AppleIntelligenceDiagnostics.featureState(restrictions: [], preferences: [], modelBytes: [nil], profileLocksModel: true) == .lockedOff)
        #expect(AppleIntelligenceDiagnostics.featureState(
            restrictions: [.init(value: nil)], preferences: [], modelBytes: [0], profileLocksModel: true) == .on)
    }

    @Test func modelInventoryTakesPrecedenceAndFallsBackOnlyWhenUnavailable() {
        #expect(AppleIntelligenceDiagnostics.modelBytes(assetType: "model", inventory: ["model": 10]) { 0 } == 10)
        #expect(AppleIntelligenceDiagnostics.modelBytes(assetType: "model", inventory: [:]) { 99 } == 0)
        #expect(AppleIntelligenceDiagnostics.modelBytes(assetType: "model", inventory: nil) { 12 } == 12)
        #expect(AppleIntelligenceDiagnostics.modelBytes(assetType: "model", inventory: nil) { -1 } == nil)
        #expect(AppleIntelligenceDiagnostics.modelBytes(assetType: "model", inventory: nil) { nil } == nil)
    }

    @Test func reportContainsTheRequestedCatalogAndRoundTrips() throws {
        let report = AppleIntelligenceDiagnostics.Report.example
        #expect(report.features.count == 14)
        #expect(report.models.count == 5)
        #expect(AppleIntelligenceDiagnostics.total(report.models.map(\.bytes)) == 0)
        let data = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(AppleIntelligenceDiagnostics.Report.self, from: data) == report)
    }

    @Test func timedOutAndCancelledReadersTerminateTheirOwnProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("reader.sh")
        let pidFile = directory.appendingPathComponent("pid")
        let escapedPath = pidFile.path.replacingOccurrences(of: "'", with: "'\\''")
        let command = """
        #!/bin/sh
        printf '%s' "$$" > '\(escapedPath)'
        exec /bin/sleep 30
        """
        try command.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        // 全套用例并行运行时启动也会排队，避免把冷启动速度当作回收行为的断言。
        let timeout = try await AppleIntelligenceDiagnostics.load(executableURL: script, timeout: .seconds(2))
        #expect(timeout == .unreadable)
        let timedOutPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(timedOutPID, 0) == -1)
        try FileManager.default.removeItem(at: pidFile)

        let task = Task { try await AppleIntelligenceDiagnostics.load(executableURL: script) }
        defer { task.cancel() }
        var cancelledPID: Int32?
        // 文件可能已创建但尚未写入 PID；必须等到完整启动标记再取消，避免误判回收失败。
        for _ in 0..<200 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) {
                cancelledPID = pid
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(cancelledPID)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) == -1)
    }

    @Test func validReaderRoundTripsAndOversizedOutputIsRejected() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: script) }
        let expected = AppleIntelligenceDiagnostics.Report.example
        let encoded = try JSONEncoder().encode(expected).base64EncodedString()
        let valid = """
        #!/bin/sh
        printf '%s' '\(encoded)' | /usr/bin/base64 --decode
        """
        try valid.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        #expect(try await AppleIntelligenceDiagnostics.load(executableURL: script) == expected)
        let invalid = AppleIntelligenceDiagnostics.Report(
            reason: expected.reason, features: expected.features,
            models: expected.models.enumerated().map { index, model in
                .init(id: model.id, title: model.title, bytes: index == 0 ? -1 : model.bytes)
            }, inventoryIssue: nil)
        let invalidData = try JSONEncoder().encode(invalid).base64EncodedString()
        try valid.replacingOccurrences(of: encoded, with: invalidData).write(to: script, atomically: true, encoding: .utf8)
        #expect(try await AppleIntelligenceDiagnostics.load(executableURL: script) == .unreadable)
        let oversized = """
        #!/bin/sh
        printf '%070000d' 0
        """
        try oversized.write(to: script, atomically: true, encoding: .utf8)
        #expect(try await AppleIntelligenceDiagnostics.load(executableURL: script) == .unreadable)
    }
}
