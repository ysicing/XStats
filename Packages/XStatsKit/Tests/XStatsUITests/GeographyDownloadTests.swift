// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation
import Testing
@testable import XStatsUI

@Suite(.timeLimit(.minutes(1)))
struct GeographyDownloadTests {
    private let v4 = Data([8, 8, 8, 0, 8, 8, 8, 255, 85, 83])
    private var v6: Data { Data([0x20] + Array(repeating: 0, count: 15) + [0x3f] + Array(repeating: 255, count: 15) + [85, 83]) }

    @Test func validatesManifestPathsAndFamilyCompleteness() throws {
        let fixture = try GeographyFixture(v4: v4, v6: v6)
        #expect(throws: (any Error).self) { try GeographyManifest.decode(Data("{}".utf8)) }
        var invalid = fixture.manifest
        invalid.files[0].file = "../country-ipv4.bin"
        #expect(throws: (any Error).self) { try GeographyManifest.decode(JSONEncoder().encode(invalid)) }
        invalid = fixture.manifest
        invalid.files = [invalid.files[0], invalid.files[0]]
        #expect(throws: (any Error).self) { try GeographyManifest.decode(JSONEncoder().encode(invalid)) }
    }

    @Test func downloadsCachesAndReadsBothAddressFamiliesWithoutNetworkOnWarmStart() async throws {
        let fixture = try GeographyFixture(v4: v4, v6: v6)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = OfflineGeography(cacheRoot: directory, download: fixture.download)
        _ = try await service.prepare()
        let result = await service.resolve(["8.8.8.8", "2606:4700:4700::1111", "::ffff:8.8.8.8", "192.168.1.1", "fe80::1", "203.0.113.10", "not-an-ip"])
        #expect(result.count == 3)
        #expect(result["8.8.8.8"] == "US")
        let reopened = OfflineGeography(cacheRoot: directory, download: { _, _, _ in throw URLError(.notConnectedToInternet) })
        _ = try await reopened.prepare()
        #expect(await reopened.resolve(["8.8.8.8"])["8.8.8.8"] == "US")
        #expect(await reopened.world().contains { $0.code == "US" })
    }

    @Test func rejectedUpdateKeepsOldCacheAndCannotCommitOneFamilyAlone() async throws {
        let original = try GeographyFixture(v4: v4, v6: v6)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = OfflineGeography(cacheRoot: directory, download: original.download)
        _ = try await service.prepare()
        var changed = v4; changed[8] = 67; changed[9] = 65
        let broken = try GeographyFixture(v4: changed, v6: v6, corruptV6: true)
        let updater = OfflineGeography(cacheRoot: directory, download: broken.download)
        await #expect(throws: (any Error).self) { try await updater.prepare(force: true) }
        let reader = OfflineGeography(cacheRoot: directory, download: { _, _, _ in throw URLError(.notConnectedToInternet) })
        _ = try await reader.prepare()
        #expect(await reader.resolve(["8.8.8.8"])["8.8.8.8"] == "US")
    }

    @Test @MainActor func closingAndReopeningDoesNotPublishLateDownloadOrInstallCancelledCache() async throws {
        let fixture = try GeographyFixture(v4: v4, v6: v6)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = GeographyDownloadGate(fixture: fixture)
        let service = OfflineGeography(cacheRoot: directory, download: gate.download)
        let controller = NetworkGeographyController(service: service)
        controller.setDemand(enabled: true)
        while await gate.requests < 2 { try Task.checkCancellation(); await Task.yield() }
        controller.setDemand(enabled: false)
        #expect(controller.state == .idle && !controller.hasData)
        controller.setDemand(enabled: true)
        while await gate.requests < 4 { try Task.checkCancellation(); await Task.yield() }
        await gate.resumeFirst()
        for _ in 0..<20 { await Task.yield() }
        #expect(controller.state.isDownloading && !controller.hasData)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("current.json").path))
        controller.setDemand(enabled: false)
        await gate.resumeFirst()
        #expect(controller.state == .idle && !controller.hasData)
    }

    @Test func rejectsOversizedDecompressedPayloadAndHashMismatch() throws {
        let fixture = try GeographyFixture(v4: v4, v6: v6)
        var asset = fixture.manifest.files[0]
        asset.bytes = 1
        #expect(throws: (any Error).self) { try asset.unpack(fixture.payloads[asset.file]!) }
        asset = fixture.manifest.files[0]
        asset.sha256 = String(repeating: "0", count: 64)
        #expect(throws: (any Error).self) { try asset.unpack(fixture.payloads[asset.file]!) }
    }
}

private struct GeographyFixture: Sendable {
    var manifest: GeographyManifest
    let payloads: [String: Data]

    init(v4: Data, v6: Data, corruptV6: Bool = false) throws {
        var payloads: [String: Data] = [:]
        var assets: [GeographyAsset] = []
        for (name, data) in [("country-ipv4.bin", v4), ("country-ipv6.bin", v6)] {
            let compressed = try (data as NSData).compressed(using: .lzfse) as Data
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let compressedHash = SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined()
            let file = name.replacingOccurrences(of: ".bin", with: "-\(compressedHash).lzfse")
            assets.append(GeographyAsset(name: name, file: file, bytes: data.count, sha256: hash,
                                         compressedBytes: compressed.count, compressedSHA256: SHA256.hash(data: compressed).map { String(format: "%02x", $0) }.joined()))
            payloads[file] = corruptV6 && name == "country-ipv6.bin" ? Data([0]) : compressed
        }
        manifest = GeographyManifest(schemaVersion: 1, version: "test-1", files: assets)
        self.payloads = payloads
    }

    @Sendable func download(_ url: URL, _ maximum: Int, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let data = url.lastPathComponent == "current.json" ? try JSONEncoder().encode(manifest) : payloads[url.lastPathComponent] ?? Data()
        guard data.count <= maximum else { throw URLError(.dataLengthExceedsMaximum) }
        progress(1)
        return data
    }
}

private actor GeographyDownloadGate {
    private let fixture: GeographyFixture
    private(set) var requests = 0
    private var pending: [CheckedContinuation<Void, Never>] = []
    init(fixture: GeographyFixture) { self.fixture = fixture }
    func download(_ url: URL, _ maximum: Int, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        requests += 1
        if url.lastPathComponent != "current.json" { await withCheckedContinuation { pending.append($0) } }
        // 故意不响应取消，覆盖旧请求晚到时不能写缓存/覆盖新下载状态的边界。
        return try await fixture.download(url, maximum, progress)
    }
    func resumeFirst() { guard !pending.isEmpty else { return }; pending.removeFirst().resume() }
}
