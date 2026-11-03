// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

enum DNSBenchmarkWire {
  static func query(domain: String, id: UInt16) throws -> Data {
    let domain = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
    let labels = domain.lowercased().split(separator: ".", omittingEmptySubsequences: false)
    guard domain.utf8.count <= 253, !labels.isEmpty else {
      throw DNSBenchmarkFailure.invalidResponse
    }
    var bytes: [UInt8] = [
      UInt8(id >> 8), UInt8(id & 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
    ]
    for label in labels {
      let text = Array(label.utf8)
      guard (1...63).contains(text.count), text.first != 45, text.last != 45,
        text.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 })
      else { throw DNSBenchmarkFailure.invalidResponse }
      bytes.append(UInt8(text.count))
      bytes.append(contentsOf: text)
    }
    bytes.append(contentsOf: [0, 0, 1, 0, 1])
    return Data(bytes)
  }

  static func addresses(in response: Data, query: Data) throws -> [String] {
    let bytes = Array(response)
    let question = Array(query)
    guard bytes.count >= 12, bytes.count <= 65_535, question.count > 16,
      bytes[0] == question[0], bytes[1] == question[1],
      bytes[2] & 0xfa == 0x80,
      word(bytes, 4) == 1
    else { throw DNSBenchmarkFailure.invalidResponse }
    var offset = 12
    let domain = try name(bytes, offset: &offset)
    var queryOffset = 12
    let expected = try name(question, offset: &queryOffset)
    guard domain == expected, offset + 4 <= bytes.count,
      bytes[offset..<(offset + 4)].elementsEqual(question[queryOffset..<(queryOffset + 4)])
    else { throw DNSBenchmarkFailure.invalidResponse }
    offset += 4
    let answers = word(bytes, 6)
    let count = answers + word(bytes, 8) + word(bytes, 10)
    guard count <= 4096 else { throw DNSBenchmarkFailure.invalidResponse }
    var aliases: [String: String] = [:]
    var records: [(String, String)] = []
    for index in 0..<count {
      let owner = try name(bytes, offset: &offset)
      guard offset + 10 <= bytes.count else { throw DNSBenchmarkFailure.invalidResponse }
      let type = word(bytes, offset)
      let recordClass = word(bytes, offset + 2)
      let length = word(bytes, offset + 8)
      offset += 10
      guard length <= bytes.count - offset else { throw DNSBenchmarkFailure.invalidResponse }
      if index < answers && recordClass == 1 {
        if type == 5 {
          var aliasOffset = offset
          let alias = try name(bytes, offset: &aliasOffset)
          guard aliasOffset == offset + length else { throw DNSBenchmarkFailure.invalidResponse }
          aliases[owner] = alias
        } else if type == 1 || type == 28 {
          guard length == (type == 1 ? 4 : 16) else { throw DNSBenchmarkFailure.invalidResponse }
          var storage = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
          let address = bytes.withUnsafeBytes { buffer in
            inet_ntop(
              type == 1 ? AF_INET : AF_INET6, buffer.baseAddress!.advanced(by: offset),
              &storage, socklen_t(storage.count))
          }
          guard address != nil else { throw DNSBenchmarkFailure.invalidResponse }
          records.append(
            (
              owner,
              String(
                decoding: storage.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            ))
        }
      }
      offset += length
    }
    guard offset == bytes.count else { throw DNSBenchmarkFailure.invalidResponse }
    var owners: Set<String> = [domain]
    var current = domain
    for _ in 0..<16 {
      guard let next = aliases[current], owners.insert(next).inserted else { break }
      current = next
    }
    let addresses = Array(Set(records.filter { owners.contains($0.0) }.map(\.1))).sorted()
    guard bytes[3] & 0x0f == 0, !addresses.isEmpty else { throw DNSBenchmarkFailure.noAnswer }
    return Array(addresses.prefix(16))
  }

  private static func word(_ bytes: [UInt8], _ offset: Int) -> Int {
    Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
  }

  private static func name(_ bytes: [UInt8], offset: inout Int) throws -> String {
    var cursor = offset
    var consumed: Int?
    var labels: [String] = []
    var length = 0
    // 压缩指针只能向前文跳转；跳数与展开长度同时有界，拒绝循环和超长名称。
    for _ in 0..<128 {
      guard cursor < bytes.count else { throw DNSBenchmarkFailure.invalidResponse }
      let size = Int(bytes[cursor])
      if size & 0xc0 == 0xc0 {
        guard cursor + 1 < bytes.count else { throw DNSBenchmarkFailure.invalidResponse }
        let pointer = (size & 0x3f) << 8 | Int(bytes[cursor + 1])
        guard pointer >= 12, pointer < cursor else { throw DNSBenchmarkFailure.invalidResponse }
        if consumed == nil { consumed = cursor + 2 }
        cursor = pointer
        continue
      }
      guard size <= 63, cursor + size + 1 <= bytes.count else {
        throw DNSBenchmarkFailure.invalidResponse
      }
      cursor += 1
      if size == 0 {
        offset = consumed ?? cursor
        return labels.joined(separator: ".")
      }
      let label = bytes[cursor..<(cursor + size)]
      guard label.allSatisfy({ $0 > 32 && $0 < 127 }) else {
        throw DNSBenchmarkFailure.invalidResponse
      }
      labels.append(String(decoding: label, as: UTF8.self).lowercased())
      length += size + 1
      guard length <= 254 else { throw DNSBenchmarkFailure.invalidResponse }
      cursor += size
    }
    throw DNSBenchmarkFailure.invalidResponse
  }
}
