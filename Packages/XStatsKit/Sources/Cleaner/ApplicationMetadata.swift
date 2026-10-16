// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 列表元数据与卸载身份分开：缺失的架构、Spotlight 日期不阻止浏览，也不参与删除判断。
public struct ApplicationMetadata: Sendable, Equatable {
  public enum Architecture: String, Sendable { case appleSilicon, intel, universal, iOS, unknown }
  public let architecture: Architecture
  public let lastOpened: Date?
  public let isAppStore: Bool
  public let appStoreID: String?

  public init(
    architecture: Architecture = .unknown, lastOpened: Date? = nil, isAppStore: Bool = false,
    appStoreID: String? = nil
  ) {
    self.architecture = architecture
    self.lastOpened = lastOpened
    self.isAppStore = isAppStore
    self.appStoreID = appStoreID
  }

  public static func read(_ app: InstalledApp) -> Self {
    let bundle = Bundle(url: app.url)
    let platforms = bundle?.infoDictionary?["CFBundleSupportedPlatforms"] as? [String] ?? []
    let architecture: Architecture
    if platforms.contains("iPhoneOS")
      || FileManager.default.fileExists(atPath: app.url.appendingPathComponent("Wrapper").path)
    {
      architecture = .iOS
    } else if let executable = bundle?.executableURL,
      let handle = try? FileHandle(forReadingFrom: executable)
    {
      defer { try? handle.close() }
      // Mach-O / fat 头有界读取，不为每个应用启动 lipo 或映射整个可执行文件。
      architecture = (try? handle.read(upToCount: 4096)).map(Self.architecture(in:)) ?? .unknown
    } else {
      architecture = .unknown
    }
    let item = NSMetadataItem(url: app.url)
    let lastOpened = item?.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
    let isAppStore = FileManager.default.fileExists(
      atPath: app.url.appendingPathComponent("Contents/_MASReceipt/receipt").path)
    let storeID =
      isAppStore
      ? (item?.value(forAttribute: "kMDItemAppStoreAdamID") as? NSNumber)?.stringValue : nil
    return Self(
      architecture: architecture, lastOpened: lastOpened,
      isAppStore: isAppStore, appStoreID: storeID)
  }

  static func architecture(in data: Data) -> Architecture {
    let bytes = [UInt8](data)
    guard bytes.count >= 8 else { return .unknown }
    let magic = word(bytes, offset: 0, littleEndian: false)
    let types: [UInt32]
    switch magic {
    case 0xfeed_face, 0xfeed_facf: types = [word(bytes, offset: 4, littleEndian: false)]
    case 0xcefa_edfe, 0xcffa_edfe: types = [word(bytes, offset: 4, littleEndian: true)]
    case 0xcafe_babe, 0xcafe_babf, 0xbeba_feca, 0xbfba_feca:
      let little = magic == 0xbeba_feca || magic == 0xbfba_feca
      let count = Int(word(bytes, offset: 4, littleEndian: little))
      let stride = magic == 0xcafe_babf || magic == 0xbfba_feca ? 32 : 20
      guard count > 0, count <= 64, 8 + count * stride <= bytes.count else { return .unknown }
      types = (0..<count).map { word(bytes, offset: 8 + $0 * stride, littleEndian: little) }
    default: return .unknown
    }
    let arm = types.contains(0x0100_000c)
    let intel = types.contains(0x0100_0007) || types.contains(7)
    if arm && intel { return .universal }
    if arm { return .appleSilicon }
    if intel { return .intel }
    return .unknown
  }

  private static func word(_ bytes: [UInt8], offset: Int, littleEndian: Bool) -> UInt32 {
    let slice = bytes[offset..<(offset + 4)]
    return (littleEndian ? Array(slice.reversed()) : Array(slice)).reduce(0) {
      ($0 << 8) | UInt32($1)
    }
  }
}
