// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@Suite struct UsageNumberTests {
    @Test func chineseUsesReadableTokenUnits() {
        let locale = Locale(identifier: "zh_Hans_CN")
        #expect(UsageNumber.short(1_374_863_940, locale: locale) == "13.75亿")
        #expect(UsageNumber.short(1_234_567, locale: locale) == "123.5万")
        #expect(UsageNumber.short(12_345, locale: locale) == "1.2万")
        #expect(UsageNumber.short(0, locale: locale) == "0")
        #expect(UsageNumber.short(999, locale: locale) == "999")
    }
    @Test func englishAndTraditionalChineseKeepTheirUnits() {
        #expect(UsageNumber.short(1_374_863_940, locale: Locale(identifier: "en_US")) == "1.37B")
        #expect(UsageNumber.short(1_374_863_940, locale: Locale(identifier: "zh_Hant_TW")) == "13.75億")
    }
}
