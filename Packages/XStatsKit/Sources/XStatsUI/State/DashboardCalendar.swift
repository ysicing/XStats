// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

enum DashboardCalendar {
  static let path = "/dashboard/calendar/"

  @MainActor
  static func summary(for dateKey: String, language: AppLanguage) -> String? {
    let parts = dateKey.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, dateKey.utf8.count == 10, let year = Int(parts[0]),
      let month = Int(parts[1]), let dayOfMonth = Int(parts[2]), (1...31).contains(dayOfMonth),
      let day = CalendarEngine.day(year: year, month: month, day: dayOfMonth, timeZone: .gmt),
      day.id == dateKey
    else { return nil }

    let locale = L10n.locale(for: language)
    let text = { (key: String) in L10n.translate(key, language: language) }
    var summary: [String] = []
    if let lunar = CalendarEngine.lunarDateTitle(at: day.date, locale: locale, timeZone: .gmt) {
      summary.append(language.isChinese ? text("农历") + lunar : text("农历：\(lunar)"))
    }
    let names = day.festivals + [day.solarTerm, day.holiday?.name].compactMap { $0 }
    for name in names.map(text) where !summary.contains(name) {
      summary.append(name)
    }

    if let holiday = day.holiday {
      summary.append(text(holiday.isWork ? "补班" : "放假"))
    } else if day.isWeekend && CalendarEngine.hasHolidayData(year: day.year) {
      summary.append(text("周末"))
    } else {
      let formatter = DateFormatter()
      formatter.locale = locale
      formatter.timeZone = .gmt
      formatter.setLocalizedDateFormatFromTemplate("EEE")
      summary.append(formatter.string(from: day.date))
    }
    return summary.joined(separator: " · ")
  }
}
