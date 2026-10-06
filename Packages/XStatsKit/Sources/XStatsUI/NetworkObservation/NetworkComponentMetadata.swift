// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import NetworkObservation

/// 从磁盘读取已验证组件的配置；NSBundle 会跨实例缓存同一路径，不能用于组件升级后的发现。
struct NetworkComponentMetadata: Sendable {
    let observationMachService: String
    let controlMachService: String?
    let protocolVersion: Int?
    let version: String
    let build: String

    @concurrent static func load(at app: URL) async throws -> Self {
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom: app.appendingPathComponent("Contents/Info.plist"))
        defer { try? file.close() }
        let data = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024,
              let info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == NetworkComponentInstaller.bundleIdentifier,
              let observation = info["NetworkObservationMachService"] as? String, !observation.isEmpty else {
            throw NetworkMonitorError.missingExtension
        }
        return Self(observationMachService: observation,
                    controlMachService: info["NetworkObservationControlMachService"] as? String,
                    protocolVersion: info["NetworkObservationProtocolVersion"] as? Int,
                    version: info["CFBundleShortVersionString"] as? String ?? "",
                    build: info["CFBundleVersion"] as? String ?? "")
    }
}
