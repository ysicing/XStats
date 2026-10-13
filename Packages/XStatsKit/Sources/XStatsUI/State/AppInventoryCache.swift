// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation

/// 可丢弃的展示快照，不保存卸载计划或授权状态。读写由控制器的 utility 任务执行。
struct AppInventoryCache: Codable, Sendable {
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumEntries = 10_000
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    static let measurementLifetime: TimeInterval = 24 * 60 * 60
    static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            // v1 会把符号链接应用的体积记成 0，并在一天内重复使用。换文件名后重新计量。
            .appendingPathComponent("XStats/AppInventory-v2.json")
    }

    struct Fingerprint: Codable, Sendable, Equatable {
        let bundleModified: Date?
        let infoModified: Date?

        static func read(_ app: InstalledApp) -> Self {
            Self(bundleModified: try? app.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                 infoModified: try? app.url.appendingPathComponent("Contents/Info.plist")
                    .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
    }

    struct Entry: Codable, Sendable {
        let path: String
        let name: String
        let bundleIdentifier: String
        let version: String?
        let teamIdentifier: String?
        let architecture: String?
        let lastOpened: Date?
        let isAppStore: Bool?
        let appStoreID: String?
        let isHomebrew: Bool?
        let size: UInt64?
        let measuredAt: Date?
        let fingerprint: Fingerprint?

        init(app: InstalledApp, metadata: ApplicationMetadata?, size: UInt64?, measuredAt: Date?, fingerprint: Fingerprint?, isHomebrew: Bool? = nil) {
            path = app.id; name = app.name; bundleIdentifier = app.bundleIdentifier
            version = app.version; teamIdentifier = app.teamIdentifier
            architecture = metadata?.architecture.rawValue; lastOpened = metadata?.lastOpened; isAppStore = metadata?.isAppStore
            appStoreID = metadata?.appStoreID
            self.size = size; self.measuredAt = measuredAt; self.fingerprint = fingerprint
            self.isHomebrew = isHomebrew
        }

        var app: InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: path), name: name, bundleIdentifier: bundleIdentifier,
                         version: version, teamIdentifier: teamIdentifier)
        }
        var metadata: ApplicationMetadata? {
            guard let architecture, let kind = ApplicationMetadata.Architecture(rawValue: architecture) else { return nil }
            return ApplicationMetadata(architecture: kind, lastOpened: lastOpened, isAppStore: isAppStore ?? false, appStoreID: appStoreID)
        }
    }

    let schema: Int
    let savedAt: Date
    let entries: [Entry]

    init(entries: [Entry], savedAt: Date = Date()) {
        schema = 1; self.savedAt = savedAt; self.entries = entries
    }

    static func load(from url: URL, now: Date = Date()) throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { return nil }
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.schema == 1, snapshot.entries.count <= maximumEntries,
              now.timeIntervalSince(snapshot.savedAt) >= 0, now.timeIntervalSince(snapshot.savedAt) <= lifetime,
              Set(snapshot.entries.map(\.path)).count == snapshot.entries.count,
              snapshot.entries.allSatisfy({ $0.path.hasPrefix("/") && $0.path.hasSuffix(".app") }) else { return nil }
        return snapshot
    }

    func save(to url: URL) throws {
        try Task.checkCancellation()
        guard entries.count <= Self.maximumEntries else { return }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
