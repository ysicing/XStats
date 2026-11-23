// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MachO

enum MachOCloneLoadCommand {
  static func isMachO(_ executable: URL) -> Bool {
    guard let file = try? FileHandle(forReadingFrom: executable) else { return false }
    defer { try? file.close() }
    guard let prefix = try? file.read(upToCount: 4), prefix.count == 4 else { return false }
    let magic = word(prefix, 0)
    return [MH_MAGIC_64, UInt32(MH_MAGIC), FAT_CIGAM, FAT_CIGAM_64].contains(magic)
  }

  static func attach(_ library: String, to executable: URL) throws -> Bool {
    let data = try Data(contentsOf: executable, options: .mappedIfSafe)
    guard let slice = arm64Slice(data), slice.count >= 32,
      word(data, slice.lowerBound) == MH_MAGIC_64,
      word(data, slice.lowerBound + 4) == UInt32(CPU_TYPE_ARM64)
    else { throw AppCloneStore.Failure.unsupportedExecutable }

    let header = slice.lowerBound
    let count = Int(word(data, header + 16))
    let size = Int(word(data, header + 20))
    let start = header + 32
    guard size <= slice.upperBound - start, count <= size / 8 else {
      throw AppCloneStore.Failure.unsupportedExecutable
    }
    let end = start + size
    var cursor = start
    var firstSection = slice.upperBound
    for _ in 0..<count {
      guard cursor <= end - 8 else { throw AppCloneStore.Failure.unsupportedExecutable }
      let length = Int(word(data, cursor + 4))
      guard length >= 8, length <= end - cursor else {
        throw AppCloneStore.Failure.unsupportedExecutable
      }
      if word(data, cursor) == LC_SEGMENT_64, length >= 72 {
        let sectionCount = Int(word(data, cursor + 64))
        guard sectionCount <= (length - 72) / 80 else {
          throw AppCloneStore.Failure.unsupportedExecutable
        }
        for index in 0..<sectionCount {
          let offset = Int(word(data, cursor + 72 + index * 80 + 48))
          if offset > 0 { firstSection = min(firstSection, header + offset) }
        }
      }
      cursor += length
    }
    guard cursor == end, firstSection >= end, firstSection < slice.upperBound else {
      throw AppCloneStore.Failure.unsupportedExecutable
    }
    var path = Data("@executable_path/../Frameworks/\(library)".utf8)
    path.append(0)
    let padding = (8 - path.count % 8) % 8
    let commandSize = 24 + path.count + padding
    // 只占用 load commands 与首个文件段之间的空白，不能移动原有段或覆盖指令。
    guard commandSize <= firstSection - end, data[end..<(end + commandSize)].allSatisfy({ $0 == 0 })
    else { return false }
    var command = Data()
    let fields: [UInt32] = [UInt32(LC_LOAD_DYLIB), UInt32(commandSize), 24, 0, 0, 0]
    for value in fields {
      append(value, to: &command)
    }
    command.append(path)
    command.append(Data(repeating: 0, count: padding))
    let file = try FileHandle(forWritingTo: executable)
    defer { try? file.close() }
    try file.seek(toOffset: UInt64(end))
    try file.write(contentsOf: command)
    var updatedHeader = Data()
    append(UInt32(count + 1), to: &updatedHeader)
    append(UInt32(size + commandSize), to: &updatedHeader)
    try file.seek(toOffset: UInt64(header + 16))
    try file.write(contentsOf: updatedHeader)
    return true
  }

  private static func arm64Slice(_ data: Data) -> Range<Int>? {
    guard data.count >= 8 else { return nil }
    let magic = word(data, 0)
    if magic == MH_MAGIC_64 { return 0..<data.count }
    guard magic == FAT_CIGAM || magic == FAT_CIGAM_64 else { return nil }
    let wide = magic == FAT_CIGAM_64
    let stride = wide ? 32 : 20
    let count = Int(word(data, 4).byteSwapped)
    guard count <= (data.count - 8) / stride else { return nil }
    for index in 0..<count {
      let entry = 8 + index * stride
      guard word(data, entry).byteSwapped == UInt32(CPU_TYPE_ARM64) else { continue }
      let offset: UInt64 =
        wide ? bigWord(data, entry + 8) : UInt64(word(data, entry + 8).byteSwapped)
      let size: UInt64 =
        wide ? bigWord(data, entry + 16) : UInt64(word(data, entry + 12).byteSwapped)
      guard offset <= data.count, size <= UInt64(data.count) - offset else { return nil }
      return Int(offset)..<Int(offset + size)
    }
    return nil
  }

  private static func word(_ data: Data, _ offset: Int) -> UInt32 {
    data.withUnsafeBytes {
      UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }

  private static func bigWord(_ data: Data, _ offset: Int) -> UInt64 {
    data.withUnsafeBytes {
      UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }
  }

  private static func append(_ value: UInt32, to data: inout Data) {
    withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
  }

}
