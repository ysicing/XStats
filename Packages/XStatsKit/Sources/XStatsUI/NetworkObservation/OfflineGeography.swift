// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

struct NetworkCountry: Codable, Sendable, Equatable {
    let code: String
    let longitude: Double
    let latitude: Double
    let rings: [[[Double]]]
}

/// 离线、国家级查询。映射只读范围表，不向服务商发送目标 IP；按需在后台 actor 加载。
actor OfflineGeography {
    static let shared = OfflineGeography()
    typealias Download = @Sendable (URL, Int, @escaping @Sendable (Double) -> Void) async throws -> Data
    private struct CacheRecord: Codable {
        var manifest: GeographyManifest
        var directory: String
        var checkedAt: Date
    }
    private let cacheRoot: URL
    private let download: Download
    private var cache: CacheRecord?
    private var didLoadCache = false

    init(cacheRoot: URL? = nil, download: Download? = nil) {
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("XStats/NetworkGeography", isDirectory: true)
        self.download = download ?? downloadGeography
    }

    func loadCached() -> Bool {
        guard !didLoadCache else { return cache != nil }
        didLoadCache = true
        do {
            let handle = try FileHandle(forReadingFrom: cacheRoot.appendingPathComponent("current.json"))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 128 * 1024 + 1) ?? Data()
            guard data.count <= 128 * 1024 else { return false }
            let record = try JSONDecoder().decode(CacheRecord.self, from: data)
            _ = try GeographyManifest.decode(JSONEncoder().encode(record.manifest))
            guard GeographyAsset.isDigest(record.directory) else { return false }
            let directory = cacheRoot.appendingPathComponent(record.directory, isDirectory: true)
            let pair = try record.manifest.files.map { try read($0, directory: directory) }
            install(record, pair: pair)
        } catch { return false }
        return true
    }

    /// 只在可见且已启用的监视器中检查。30天内复用缓存，无后台更新定时器。
    func prepare(force: Bool = false, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> String {
        _ = loadCached()
        if let cache, !force, Date().timeIntervalSince(cache.checkedAt) < 30 * 24 * 60 * 60 { return cache.manifest.version }
        let manifestData = try await download(GeographyManifest.baseURL.appendingPathComponent("current.json"), 128 * 1024, { _ in })
        try Task.checkCancellation()
        let manifest = try GeographyManifest.decode(manifestData)
        if var current = cache, current.manifest.files == manifest.files {
            current.checkedAt = Date(); current.manifest = manifest
            try JSONEncoder().encode(current).write(to: cacheRoot.appendingPathComponent("current.json"), options: .atomic)
            cache = current
            return manifest.version
        }
        var pair: [Data] = []
        let total = manifest.files.reduce(0) { $0 + $1.compressedBytes }
        var completed = 0
        for file in manifest.files {
            let completedBytes = completed
            let compressed = try await download(GeographyManifest.baseURL.appendingPathComponent(file.file), file.compressedBytes) { value in
                progress((Double(completedBytes) + value * Double(file.compressedBytes)) / Double(total))
            }
            try Task.checkCancellation()
            pair.append(try file.unpack(compressed))
            completed += file.compressedBytes
        }
        try Task.checkCancellation()
        let directoryName = GeographyAsset.hash(manifestData)
        let directory = cacheRoot.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            for (file, data) in zip(manifest.files, pair) {
                try Task.checkCancellation()
                try data.write(to: directory.appendingPathComponent(file.name), options: .atomic)
            }
            let record = CacheRecord(manifest: manifest, directory: directoryName, checkedAt: Date())
            // 两个文件均验证完成后才原子切换索引；更新失败不会把IPv4新库与IPv6旧库混用。
            let mapped = try manifest.files.map { try read($0, directory: directory) }
            // 切换索引前最后一次响应取消；之后索引与内存必须一起提交。
            try Task.checkCancellation()
            try JSONEncoder().encode(record).write(to: cacheRoot.appendingPathComponent("current.json"), options: .atomic)
            install(record, pair: mapped)
            removeOlderDirectories(except: directoryName)
            progress(1)
            return manifest.version
        } catch {
            if cache?.directory != directoryName { try? FileManager.default.removeItem(at: directory) }
            throw error
        }
    }

    private func read(_ file: GeographyAsset, directory: URL) throws -> Data {
        let url = directory.appendingPathComponent(file.name)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == file.bytes else { throw CocoaError(.coderReadCorrupt) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard GeographyAsset.hash(data) == file.sha256 else { throw CocoaError(.coderReadCorrupt) }
        return data
    }

    private func install(_ record: CacheRecord, pair: [Data]) {
        cache = record
        v4 = pair[record.manifest.files.firstIndex { $0.name == "country-ipv4.bin" }!]
        v6 = pair[record.manifest.files.firstIndex { $0.name == "country-ipv6.bin" }!]
    }

    private func removeOlderDirectories(except current: String) {
        let items = (try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent != current && GeographyAsset.isDigest(item.lastPathComponent) {
            try? FileManager.default.removeItem(at: item)
        }
    }
    private var v4: Data?
    private var v6: Data?
    private var countries: [NetworkCountry]?

    func world() -> [NetworkCountry] {
        if let countries { return countries }
        guard let url = Bundle.module.url(forResource: "world-countries", withExtension: "json", subdirectory: "NetworkGeography"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([NetworkCountry].self, from: data) else { return [] }
        countries = decoded
        return decoded
    }

    func resolve(_ addresses: [String]) -> [String: String] {
        guard !addresses.isEmpty else { return [:] }
        _ = loadCached()
        var result: [String: String] = [:]
        for address in Set(addresses) {
            if Task.isCancelled { break }
            if let country = lookup(address) { result[address] = country }
        }
        return result
    }

    private func lookup(_ address: String) -> String? {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            guard !Self.isLocalV4(bytes) else { return nil }
            return find(bytes, data: v4 ?? Data())
        }
        guard inet_pton(AF_INET6, address, &ipv6) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            let mapped = Array(bytes.suffix(4))
            return Self.isLocalV4(mapped) ? nil : find(mapped, data: v4 ?? Data())
        }
        // 只有全球单播可定位。排除 ULA、链路本地、组播、环回及文档地址。
        guard bytes[0] & 0xe0 == 0x20,
              !(bytes[0...3] == [0x20, 0x01, 0x0d, 0xb8]) else { return nil }
        return find(bytes, data: v6 ?? Data())
    }

    private static func isLocalV4(_ bytes: [UInt8]) -> Bool {
        let a = bytes[0], b = bytes[1], c = bytes[2]
        return a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && b >= 64 && b <= 127)
            || (a == 169 && b == 254) || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168)
            || (a == 192 && b == 0 && c == 2) || (a == 198 && (b == 18 || b == 19))
            || (a == 198 && b == 51 && c == 100) || (a == 203 && b == 0 && c == 113)
    }

    /// 固定宽度、大端范围记录的二分查找；不解码整张 CSV，也不创建每条范围对象。
    private func find(_ bytes: [UInt8], data: Data) -> String? {
        let width = bytes.count, stride = width * 2 + 2
        var low = 0, high = data.count / stride
        while low < high {
            let middle = (low + high) / 2, offset = middle * stride
            let start = data[offset..<(offset + width)]
            let end = data[(offset + width)..<(offset + width * 2)]
            if bytes.lexicographicallyPrecedes(start) { high = middle }
            else if end.lexicographicallyPrecedes(bytes) { low = middle + 1 }
            else { return String(decoding: data[(offset + width * 2)..<(offset + stride)], as: UTF8.self) }
        }
        return nil
    }
}
