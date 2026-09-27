// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import XStatsUI

@Suite struct FeedbackLinksTests {
    @Test func githubOpensTheBugReportTemplate() {
        let url = FeedbackLinks.githubBugReport
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
        #expect(url.path == "/ysicing/XStats/issues/new")
        #expect(components?.queryItems?.first(where: { $0.name == "template" })?.value == "bug_report.md")
    }

    @Test func emailPrefillsAppBuildAndSystemVersion() throws {
        let url = try #require(FeedbackLinks.email(version: "0.10.0", build: "119",
                                                  systemVersion: "Version 26.0 (Build 25A123)"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        #expect(components.path == "i@xiai.me")
        #expect(components.queryItems?.first(where: { $0.name == "subject" })?.value?.isEmpty == false)
        #expect(components.queryItems?.first(where: { $0.name == "body" })?.value
                == "XStats 0.10.0 (119)\nmacOS Version 26.0 (Build 25A123)\n\n")
    }
}
