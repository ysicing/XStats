// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MachO
import Testing

@testable import XStatsUI

struct MachOCloneLoadCommandTests {
  @Test
  func distinguishesTelegramDistributions() {
    #expect(CloneApplication.telegram.sourceIdentifiers == ["ru.keepcoder.Telegram"])
    #expect(
      CloneApplication.telegramDesktop.sourceIdentifiers
        == ["org.telegram.desktop", "com.tdesktop.Telegram"])
  }

  @Test
  func appendsCommandWithoutMovingExecutableBytes() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = executable(firstSection: 384)
    try original.write(to: url)

    #expect(try MachOCloneLoadCommand.attach("Clone.dylib", to: url))
    let patched = try Data(contentsOf: url)
    #expect(patched.count == original.count)
    #expect(patched[16] == 2)
    #expect(patched[184] == UInt8(LC_LOAD_DYLIB))
    #expect(patched[384...] == original[384...])
  }

  @Test
  func fallsBackWithoutOverwritingFirstSection() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let original = executable(firstSection: 200)
    try original.write(to: url)

    #expect(try !MachOCloneLoadCommand.attach("Clone.dylib", to: url))
    #expect(try Data(contentsOf: url) == original)
  }

  private func executable(firstSection: UInt32) -> Data {
    var data = Data(repeating: 0, count: 512)
    let fields: [(Int, UInt32)] = [
      (0, MH_MAGIC_64), (4, UInt32(CPU_TYPE_ARM64)), (16, 1), (20, 152),
      (32, UInt32(LC_SEGMENT_64)), (36, 152), (96, 1), (152, firstSection),
    ]
    for (offset, value) in fields {
      withUnsafeBytes(of: value.littleEndian) {
        data.replaceSubrange(offset..<(offset + 4), with: $0)
      }
    }
    data[Int(firstSection)] = 0xFE
    return data
  }
}
