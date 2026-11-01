// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import IOKit

@MainActor
enum EgressNSFWPolicy {
  // 销售地区是静态硬件属性，只读一次；不能用系统地区或当前 IP 代替国行判断。
  static let deviceIsMainlandChina: Bool = {
    let platform = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard platform != 0 else { return false }
    defer { IOObjectRelease(platform) }
    let data =
      IORegistryEntryCreateCFProperty(
        platform, "region-info" as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? Data
    return isMainlandChinaDevice(regionInfo: data)
  }()

  static func isMainlandChinaDevice(regionInfo: Data?) -> Bool {
    guard let regionInfo, regionInfo.count <= 64 else { return false }
    return String(data: regionInfo.prefix(while: { $0 != 0 }), encoding: .utf8) == "CH/A"
  }

  static func isWorkHours(at date: Date, timeZone: TimeZone) -> Bool {
    let hour = CalendarEngine.gregorian(timeZone: timeZone).component(.hour, from: date)
    guard (8..<22).contains(hour) else { return false }
    // 安排未知时不能把周末当作休息日，避免漏掉尚未收录的调休上班。
    return CalendarEngine.isMainlandWorkday(at: date, timeZone: timeZone) ?? true
  }

  static func nextBoundary(after date: Date, timeZone: TimeZone) -> Date? {
    let calendar = CalendarEngine.gregorian(timeZone: timeZone)
    return [8, 22].compactMap { hour in
      calendar.nextDate(
        after: date, matching: DateComponents(hour: hour, minute: 0, second: 0),
        matchingPolicy: .nextTime)
    }.min()
  }
}
