// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Metrics

struct LocalIPQueryTests {
  @Test func keepsGeographyWithItsActualAddress() throws {
    let body = Data(
      #"{"ok":true,"ip":"203.0.113.24","geo":{"country_code":"JP","city":"Tokyo"},"network":{"asn":64500,"isp":"Example"}}"#
        .utf8)
    let result = try #require(LocalIPQuery.parse(body, source: .ipv4))
    #expect(result.ipv4 == "203.0.113.24")
    #expect(result.ipv6 == nil)
    #expect(result.countryCode == "JP")
    #expect(result.asn == "AS64500")
    #expect(result.organization == "Example")
    #expect(LocalIPQuery.parse(body, source: .ipv6) == nil)
  }

  @Test func acceptsIPv6OnlyForCorrectFamily() throws {
    let body = Data(#"{"ip":"2001:db8::1"}"#.utf8)
    let result = try #require(LocalIPQuery.parse(body, source: .ipv6))
    #expect(result.ipv6 == "2001:db8::1")
    #expect(result.ipv4 == nil)
    #expect(LocalIPQuery.parse(body, source: .ipv4) == nil)
  }

  @Test func domesticEchoDoesNotInventLocation() throws {
    let body = Data(#"{"ip":" 198.51.100.2 ","extra":123}"#.utf8)
    let result = try #require(LocalIPQuery.parse(body, source: .domestic))
    #expect(result.ipv4 == "198.51.100.2")
    #expect(result.countryCode == nil && result.asn == nil)
  }

  @Test func cloudflareUsesReturnedFamilyAndCountry() throws {
    let body = Data("ip=2001:db8::2\nloc=us\n".utf8)
    let result = try #require(LocalIPQuery.parse(body, source: .cloudflare))
    #expect(result.ipv6 == "2001:db8::2" && result.ipv4 == nil)
    #expect(result.countryCode == "US")
  }

  @Test(arguments: LocalIPQuery.Source.allCases)
  func rejectsInvalidOrInterceptedResponses(source: LocalIPQuery.Source) {
    for body in ["<html>blocked</html>", "{}", #"{"ip":"bad"}"#, "ip=bad\nloc=CN"] {
      #expect(LocalIPQuery.parse(Data(body.utf8), source: source) == nil)
    }
  }
}
