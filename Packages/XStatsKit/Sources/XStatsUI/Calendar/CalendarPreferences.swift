// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization

/// 可跨设备同步的日历呈现偏好；本机日历列表标识另存，不进入设置备份。
public struct CalendarPreferences: Codable, Equatable, Sendable {
    public enum Display: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard, dateLunar, lunar, custom
        public var id: String { rawValue }

        /// 总开关只改变实际呈现，保留原模式，重新开启农历时即可恢复。
        func effective(showsLunar: Bool) -> Self {
            !showsLunar && (self == .lunar || self == .dateLunar) ? .standard : self
        }

        var title: String {
            switch self {
            case .standard: tr("日期与星期")
            case .dateLunar: tr("日期与农历")
            case .lunar: tr("农历")
            case .custom: tr("自定义")
            }
        }
    }

    public var display: Display = .standard
    public var dateFormat = "MM/dd"
    public var largeLunarText = false
    public var strongerLunarText = false
    public var openOnHover = false
    public var showHolidayOverview: Bool
    public var showEvents = false
    public var showReminders = false

    public init(locale: Locale = .current) {
        let isMainlandChina = locale.region?.identifier == "CN"
        showHolidayOverview = isMainlandChina
    }

    private enum CodingKeys: String, CodingKey {
        case display, dateFormat, largeLunarText, strongerLunarText, openOnHover
        case showHolidayOverview, showEvents, showReminders
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedDisplay = try values.decodeIfPresent(String.self, forKey: .display)
        // 旧的“仅日期”对应自定义月日；已移除的图标模式回到默认日期显示。
        display = savedDisplay == "compact" ? .custom : savedDisplay.flatMap(Display.init(rawValue:)) ?? .standard
        dateFormat = String((try values.decodeIfPresent(String.self, forKey: .dateFormat) ?? "MM/dd").prefix(64))
        largeLunarText = try values.decodeIfPresent(Bool.self, forKey: .largeLunarText) ?? false
        strongerLunarText = try values.decodeIfPresent(Bool.self, forKey: .strongerLunarText) ?? false
        openOnHover = try values.decodeIfPresent(Bool.self, forKey: .openOnHover) ?? false
        showHolidayOverview = try values.decodeIfPresent(Bool.self, forKey: .showHolidayOverview) ?? true
        showEvents = try values.decodeIfPresent(Bool.self, forKey: .showEvents) ?? false
        showReminders = try values.decodeIfPresent(Bool.self, forKey: .showReminders) ?? false
    }

    /// 只接受年月日字段和分隔文字；避免误用周历年 Y、年内日 D 或时间字段后显示错误日期。
    var isDateFormatValid: Bool {
        guard !dateFormat.isEmpty, dateFormat.count <= 64, !dateFormat.contains(where: \.isNewline) else { return false }
        var quoted = false
        var hasMonth = false
        var hasDay = false
        for character in dateFormat {
            if character == "'" { quoted.toggle(); continue }
            guard !quoted else { continue }
            if character == "M" { hasMonth = true }
            else if character == "d" { hasDay = true }
            else if character.isASCII && character.isLetter && character != "y" { return false }
        }
        return !quoted && hasMonth && hasDay
    }

    @MainActor
    func title(at date: Date, locale: Locale, timeZone: TimeZone = .autoupdatingCurrent,
               showsLunar: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        switch display.effective(showsLunar: showsLunar) {
        case .standard: formatter.setLocalizedDateFormatFromTemplate("MdEEE")
        case .custom:
            // 用户明确选择顺序，不能再用本地化模板把日月重新排回月日。
            formatter.dateFormat = isDateFormatValid ? dateFormat : "MM/dd"
        case .dateLunar, .lunar:
            formatter.setLocalizedDateFormatFromTemplate("Md")
            let solar = formatter.string(from: date)
            guard let lunar = CalendarEngine.lunarDateTitle(at: date, locale: locale, timeZone: timeZone) else { return solar }
            return display == .lunar ? lunar : [solar, lunar].joined(separator: " · ")
        }
        return formatter.string(from: date)
    }
}
