// Portions adapted from gentpan/OpenStats, Copyright (c) 2026 GiantAccel, LLC.
// Original portions: MIT, see LICENSES/OpenStats-MIT.txt.
// XStats modifications: Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation

/// APFS 容器组成。其他系统数据含辅助卷、快照及未归类空间，并非单指启动与恢复。
public struct DiskBreakdown: Sendable, Equatable {
  public var system: UInt64
  public var data: UInt64
  public var virtualMemory: UInt64
  public var other: UInt64
  public var purgeable: UInt64
  public var free: UInt64

  public static func compose(
    total: UInt64, free: UInt64, purgeable: UInt64,
    systemUsed: UInt64, dataUsed: UInt64, vmUsed: UInt64
  ) -> DiskBreakdown? {
    guard free <= total, purgeable <= dataUsed else { return nil }
    let (volumes, overflow) = systemUsed.addingReportingOverflow(dataUsed)
    let (known, vmOverflow) = volumes.addingReportingOverflow(vmUsed)
    let used = total - free
    // 读取期间 APFS 可能变化；不通过截断卷用量来制造不可信的细分。
    guard !overflow, !vmOverflow, known <= used else { return nil }
    return DiskBreakdown(
      system: systemUsed, data: dataUsed - purgeable, virtualMemory: vmUsed,
      other: used - known, purgeable: purgeable, free: free)
  }

  static func read(_ usage: DiskUsage) -> DiskBreakdown? {
    var info = statfs()
    guard statfs("/", &info) == 0 else { return nil }
    let type = withUnsafeBytes(of: info.f_fstypename) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    guard type == "apfs", let system = volumeUsed("/"),
      let data = volumeUsed("/System/Volumes/Data"),
      let vm = volumeUsed("/System/Volumes/VM")
    else { return nil }
    return compose(
      total: usage.total, free: usage.free, purgeable: usage.purgeable,
      systemUsed: system, dataUsed: data, vmUsed: vm)
  }

  /// statfs 的已用量是整个共享容器；ATTR_VOL_SPACEUSED 才是各卷自身的占用。
  private static func volumeUsed(_ path: String) -> UInt64? {
    var attributes = attrlist(
      bitmapcount: UInt16(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: 0,
      volattr: attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED),
      dirattr: 0, fileattr: 0, forkattr: 0)
    var buffer = [UInt8](repeating: 0, count: 32)
    guard getattrlist(path, &attributes, &buffer, buffer.count, 0) == 0 else { return nil }
    return buffer.withUnsafeBytes { bytes in
      guard bytes.loadUnaligned(as: UInt32.self) >= 12 else { return nil }
      let value = bytes.loadUnaligned(fromByteOffset: 4, as: Int64.self)
      return value >= 0 ? UInt64(value) : nil
    }
  }
}
