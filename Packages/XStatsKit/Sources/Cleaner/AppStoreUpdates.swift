// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 只读商店目录查询；安装始终由 App Store 管理，不访问账户或下载应用。
public enum AppStoreUpdates {
    public struct Candidate: Sendable, Hashable {
        public let bundleIdentifier: String
        public let version: String
        public let storeID: String?

        public init(bundleIdentifier: String, version: String, storeID: String?) {
            self.bundleIdentifier = bundleIdentifier; self.version = version; self.storeID = storeID
        }
    }

    public struct Entry: Sendable, Equatable {
        public let bundleIdentifier: String
        public let version: String
        public let minimumSystemVersion: String
        public let storeID: String?

        public init(bundleIdentifier: String, version: String, minimumSystemVersion: String, storeID: String?) {
            self.bundleIdentifier = bundleIdentifier; self.version = version
            self.minimumSystemVersion = minimumSystemVersion; self.storeID = storeID
        }

        public var storeURL: URL {
            if let storeID, AppStoreUpdates.validStoreID(storeID) {
                return URL(string: "macappstore://itunes.apple.com/app/id\(storeID)")!
            }
            return URL(string: "macappstore://showUpdatesPage")!
        }

        public func update(for candidate: Candidate, systemVersion: String) -> Self? {
            guard candidate.bundleIdentifier == bundleIdentifier,
                  AppStoreUpdates.isNewer(version, than: candidate.version),
                  AppStoreUpdates.numericVersion(systemVersion), AppStoreUpdates.numericVersion(minimumSystemVersion),
                  !AppStoreUpdates.isNewer(minimumSystemVersion, than: systemVersion) else { return nil }
            return self
        }
    }

    public struct Report: Sendable {
        public let entries: [String: Entry]
        public let failedRequests: Int
        public init(entries: [String: Entry], failedRequests: Int = 0) {
            self.entries = entries; self.failedRequests = failedRequests
        }
    }

    static let maximumResponseBytes = 2 * 1_024 * 1_024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration)
    }()

    @concurrent
    public static func check(_ candidates: [Candidate], country: String,
                             fetch: (@Sendable (URL) async throws -> Data)? = nil) async throws -> Report {
        let fetch = fetch ?? { try await response(from: $0) }
        var seen = Set<String>()
        let candidates = candidates.filter {
            !$0.bundleIdentifier.isEmpty && $0.bundleIdentifier.utf8.count <= 255
                && numericVersion($0.version) && seen.insert($0.bundleIdentifier).inserted
        }
        var entries: [String: Entry] = [:]
        var failures = 0
        // 顺序执行有界批次，不随应用数量同时发起大量连接。
        for useIDs in [true, false] {
            let pending = candidates.filter {
                if useIDs { return $0.storeID.map(validStoreID) == true }
                return entries[$0.bundleIdentifier] == nil
            }
            for start in stride(from: 0, to: pending.count, by: 20) {
                try Task.checkCancellation()
                let batch = Array(pending[start..<min(start + 20, pending.count)])
                var url = URLComponents(string: useIDs
                    ? "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup"
                    : "https://itunes.apple.com/lookup")!
                let region = country.count == 2 && country.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) })
                    ? country.lowercased() : "us"
                url.queryItems = useIDs ? [
                    .init(name: "id", value: batch.compactMap(\.storeID).joined(separator: ",")),
                    .init(name: "version", value: "2"), .init(name: "p", value: "mdm-lockup"),
                    .init(name: "caller", value: "MDM"), .init(name: "platform", value: "macappstore"),
                    .init(name: "cc", value: region)
                ] : [
                    .init(name: "bundleId", value: batch.map(\.bundleIdentifier).joined(separator: ",")),
                    .init(name: "entity", value: "macSoftware"), .init(name: "country", value: region)
                ]
                do {
                    let data = try await fetch(url.url!)
                    try Task.checkCancellation()
                    let result = try parse(data, usingStoreIDs: useIDs)
                    let requested = Set(batch.map(\.bundleIdentifier))
                    entries.merge(result.filter { requested.contains($0.key) }) { first, _ in first }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    failures += 1
                }
            }
        }
        return Report(entries: entries, failedRequests: failures)
    }

    private static func response(from url: URL) async throws -> Data {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= maximumResponseBytes else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard data.count < maximumResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    static func parse(_ data: Data, usingStoreIDs: Bool) throws -> [String: Entry] {
        guard data.count <= maximumResponseBytes,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        let records: [(String?, [String: Any])]
        if usingStoreIDs {
            guard let results = root["results"] as? [String: [String: Any]] else { throw URLError(.cannotParseResponse) }
            records = results.map { ($0.key, $0.value) }
        } else {
            guard let results = root["results"] as? [[String: Any]] else { throw URLError(.cannotParseResponse) }
            records = results.map { (($0["trackId"] as? NSNumber)?.stringValue, $0) }
        }
        var entries: [String: Entry] = [:]
        for (storeID, record) in records {
            guard let bundle = record["bundleId"] as? String, !bundle.isEmpty else { continue }
            let version: String?
            let minimum: String?
            if usingStoreIDs {
                guard (record["deviceFamilies"] as? [String])?.contains("mac") == true else { continue }
                minimum = record["minimumOSVersion"] as? String
                version = (record["offers"] as? [[String: Any]])?.compactMap { offer -> String? in
                    guard (offer["assets"] as? [[String: Any]])?.contains(where: { $0["flavor"] as? String == "macSoftware" }) == true,
                          let value = (offer["version"] as? [String: Any])?["display"] as? String,
                          numericVersion(value) else { return nil }
                    return value
                }.max { isNewer($1, than: $0) }
            } else {
                guard record["kind"] as? String == "mac-software" else { continue }
                version = record["version"] as? String
                minimum = record["minimumOsVersion"] as? String
            }
            guard let version, numericVersion(version), let minimum, numericVersion(minimum) else { continue }
            entries[bundle] = Entry(bundleIdentifier: bundle, version: version, minimumSystemVersion: minimum,
                                    storeID: storeID.flatMap { validStoreID($0) ? $0 : nil })
        }
        return entries
    }

    static func validStoreID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 20 && id.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func numericVersion(_ version: String) -> Bool {
        !version.isEmpty && version.count <= 64
            && version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
            }
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard numericVersion(candidate), numericVersion(installed) else { return false }
        let lhs = candidate.split(separator: "."); let rhs = installed.split(separator: ".")
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? String(lhs[index]) : "0"
            let b = index < rhs.count ? String(rhs[index]) : "0"
            let order = a.compare(b, options: .numeric)
            if order != .orderedSame { return order == .orderedDescending }
        }
        return false
    }
}
