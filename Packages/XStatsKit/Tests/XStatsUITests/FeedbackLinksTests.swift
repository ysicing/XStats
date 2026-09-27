// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
@testable import Localization
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
        // 测试进程使用默认的简体中文；其余语言由目录完整性测试保证有译文
        #expect(components.queryItems?.first(where: { $0.name == "subject" })?.value == "XStats 反馈 · 0.10.0")
        #expect(components.queryItems?.first(where: { $0.name == "body" })?.value
                == "应用版本：0.10.0 (119)\n系统版本：macOS Version 26.0 (Build 25A123)\n\n请描述遇到的问题：\n\n")
    }

    @Test func feedbackEmailStringsAreTranslatedForEveryLanguage() throws {
        for language in AppLanguage.allCases where language != .system && language != .chinese {
            let catalog = try #require(Translations.catalog(for: language))
            for key in ["XStats 反馈 · {}", "应用版本：{}", "系统版本：{}", "请描述遇到的问题："] {
                let value = try #require(catalog.translate(key), "\(language) is missing \(key)")
                #expect(!value.isEmpty && value != key, "\(language): \(key)")
                #expect(value.contains("{}") == key.contains("{}"), "\(language) placeholder: \(value)")
            }
        }
    }
}
