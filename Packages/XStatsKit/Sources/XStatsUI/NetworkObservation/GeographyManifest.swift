// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Compression
import CryptoKit
import Foundation

struct GeographyManifest: Codable, Sendable {
    static let baseURL = URL(string: "https://c.ysicing.net/oss/apps/macOS/XStats/network-geography/")!
    let schemaVersion: Int
    let version: String
    var files: [GeographyAsset]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 128 * 1024 else { throw CocoaError(.coderReadCorrupt) }
        let manifest = try JSONDecoder().decode(Self.self, from: data)
        guard manifest.schemaVersion == 1, !manifest.version.isEmpty, manifest.version.utf8.count <= 128,
              manifest.files.count == 2,
              Set(manifest.files.map(\.name)) == ["country-ipv4.bin", "country-ipv6.bin"] else { throw CocoaError(.coderReadCorrupt) }
        for file in manifest.files {
            let stride = file.name == "country-ipv4.bin" ? 10 : 34
            let prefix = file.name.replacingOccurrences(of: ".bin", with: "-")
            guard file.bytes > 0, file.bytes <= 32 * 1024 * 1024, file.bytes % stride == 0,
                  file.compressedBytes > 0, file.compressedBytes <= 8 * 1024 * 1024,
                  GeographyAsset.isDigest(file.sha256), GeographyAsset.isDigest(file.compressedSHA256),
                  file.file == "\(prefix)\(file.compressedSHA256).lzfse" else { throw CocoaError(.coderReadCorrupt) }
        }
        return manifest
    }
}

struct GeographyAsset: Codable, Sendable, Equatable {
    let name: String
    var file: String
    var bytes: Int
    var sha256: String
    let compressedBytes: Int
    let compressedSHA256: String

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func isDigest(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    func unpack(_ data: Data) throws -> Data {
        guard bytes > 0, bytes <= 32 * 1024 * 1024, compressedBytes > 0,
              data.count == compressedBytes, Self.hash(data) == compressedSHA256 else { throw CocoaError(.coderReadCorrupt) }
        // 多留一字节检测超出声明大小的解压输出；恶意压缩数据不能触发无界分配。
        var output = Data(count: bytes + 1)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, bytes + 1,
                                          source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == bytes else { throw CocoaError(.coderReadCorrupt) }
        output.removeLast()
        guard Self.hash(output) == sha256 else { throw CocoaError(.coderReadCorrupt) }
        return output
    }
}
