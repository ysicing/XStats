// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum ClockTimeZone: String, CaseIterable, Identifiable, Sendable {
  case local
  case utc = "UTC"
  case pacific = "America/Los_Angeles"

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .local: "当地时间"
    case .utc: "UTC 时间"
    case .pacific: "美西时间"
    }
  }

  public var timeZone: TimeZone {
    self == .local ? .autoupdatingCurrent : TimeZone(identifier: rawValue)!
  }

  public func locationStyle(locale: Locale) -> Date.FormatStyle {
    Date.FormatStyle(
      date: .omitted, time: .omitted, locale: locale, timeZone: timeZone
    ).timeZone(.genericLocation)
  }

  public func timeStyle(locale: Locale, includesSeconds: Bool = true) -> Date.FormatStyle {
    let style = Date.FormatStyle(
      date: .omitted, time: .omitted, locale: locale, timeZone: timeZone
    ).hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)
    return includesSeconds ? style.second(.twoDigits) : style
  }

  public func dateStyle(locale: Locale) -> Date.FormatStyle {
    Date.FormatStyle(
      date: .omitted, time: .omitted, locale: locale, timeZone: timeZone
    ).year().month(.abbreviated).day()
  }
}
