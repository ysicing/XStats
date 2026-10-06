// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import Testing
@testable import XStatsUI

struct NetworkComponentMetadataTests {
    @Test func replacingComponentInfoIsVisibleWithoutRestartingTheReader() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Component-\(UUID().uuidString).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let info = contents.appendingPathComponent("Info.plist")
        var fields: [String: Any] = ["CFBundleIdentifier": "work.12306.xstats.networkmonitor",
            "NetworkObservationMachService": "TEAM.work.12306.xstats.network-observation.ipc.137"]
        try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0).write(to: info, options: .atomic)
        #expect(try await NetworkComponentMetadata.load(at: app).observationMachService.hasSuffix(".137"))
        fields["NetworkObservationMachService"] = "TEAM.work.12306.xstats.network-observation.ipc.138"
        try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0).write(to: info, options: .atomic)
        #expect(try await NetworkComponentMetadata.load(at: app).observationMachService.hasSuffix(".138"))
    }
    @Test func unrelatedBundleAndOversizedMetadataAreRejected() async throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("Component-\(UUID().uuidString).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        let info = contents.appendingPathComponent("Info.plist")
        let fields = ["CFBundleIdentifier": "unrelated", "NetworkObservationMachService": "service"]
        try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0).write(to: info)
        await #expect(throws: (any Error).self) { try await NetworkComponentMetadata.load(at: app) }
        try Data(repeating: 0, count: 1024 * 1024 + 1).write(to: info)
        await #expect(throws: (any Error).self) { try await NetworkComponentMetadata.load(at: app) }
    }
}
