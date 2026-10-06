// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Localization
import Testing
@testable import NetworkObservation

struct NetworkComponentLocalizationTests {
    @Test func componentUsesMainSelectionBeforeSystemLanguage() {
        #expect(NetworkComponentLocalization.resolve(storedLanguage: "english", preferredLanguages: ["ja-JP"]) == .english)
        #expect(NetworkComponentLocalization.resolve(storedLanguage: "japanese", preferredLanguages: ["zh-Hans"]) == .japanese)
        #expect(NetworkComponentLocalization.resolve(storedLanguage: "system", preferredLanguages: ["ja-JP"]) == .japanese)
        #expect(NetworkComponentLocalization.resolve(storedLanguage: nil, preferredLanguages: ["en-US"]) == .english)
        #expect(NetworkComponentLocalization.resolve(storedLanguage: "invalid", preferredLanguages: ["ar"]) == .arabic)
    }
    @Test func canonicalTransportErrorsTranslateWithoutChangingGlobalLanguage() async {
        let source = "网络扩展响应超时，请重试。"
        let cases: [(AppLanguage, String)] = [
            (.chinese, source),
            (.english, "The network extension timed out. Try again."),
            (.japanese, "ネットワーク機能拡張がタイムアウトしました。再試行してください。")
        ]
        #expect(NetworkComponentLocalization.transportLanguage == .chinese)
        await withTaskGroup(of: Void.self) { group in
            for (language, expected) in cases {
                group.addTask {
                    for _ in 0..<20 { #expect(L10n.translate(source, language: language) == expected) }
                }
            }
        }
        #expect(L10n.translate("NSCocoaErrorDomain 4099", language: .japanese) == "NSCocoaErrorDomain 4099")
    }
}
