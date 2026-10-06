#!/usr/bin/env swift
// SPDX-License-Identifier: AGPL-3.0-or-later
import Compression
import Foundation

// 发布侧使用系统 LZFSE，并验证客户端 compression_decode_buffer 能完整还原原始记录。
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: compress_network_geography.swift input.bin output.lzfse")
}
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let raw = try Data(contentsOf: input)
guard !raw.isEmpty, raw.count <= 32 * 1024 * 1024 else {
    fatalError("Country database must be nonempty and at most 32 MiB")
}
let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
var decoded = Data(count: raw.count)
let count = decoded.withUnsafeMutableBytes { destination in
    compressed.withUnsafeBytes { source in
        compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                  source.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                                  nil, COMPRESSION_LZFSE)
    }
}
guard count == raw.count, decoded == raw else {
    fatalError("LZFSE round-trip mismatch")
}
try compressed.write(to: output, options: .atomic)
