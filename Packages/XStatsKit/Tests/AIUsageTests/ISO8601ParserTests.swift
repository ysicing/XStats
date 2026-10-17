// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import AIUsage

@Suite struct ISO8601ParserTests {
  @Test func mixedTimestampFormatsReuseParserWithoutChangingAbsoluteTime() throws {
    let parser = ISO8601Parser()
    let base = try #require(parser.date("2026-10-17T00:00:00Z"))
    // 先后切换有无小数和时区，覆盖两份格式化器按需创建后的重复复用。
    for _ in 0..<3 {
      let fractional = try #require(parser.date("2026-10-17T08:00:00.125+08:00"))
      #expect(abs(fractional.timeIntervalSince(base) - 0.125) < 0.001)
      #expect(parser.date("2026-10-16T20:00:00-04:00") == base)
      #expect(parser.date("2026-10-17T00:00:00.000Z") == base)
      #expect(parser.date("2026-10-17T00:00:00Z") == base)
    }
  }

  @Test func absentOrInvalidTimestampsDoNotAffectLaterParsing() {
    let parser = ISO8601Parser()
    #expect(parser.date(nil) == nil)
    #expect(parser.date(123) == nil)
    #expect(parser.date("") == nil)
    #expect(parser.date("not-a-date") == nil)
    #expect(parser.date("1970-01-01T00:00:00Z") == Date(timeIntervalSince1970: 0))
  }
}
