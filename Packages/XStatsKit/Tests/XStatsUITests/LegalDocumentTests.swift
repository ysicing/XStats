// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import Testing
@testable import XStatsUI

@Suite struct LegalDocumentTests {
    @Test(arguments: [LegalDocument.terms, .privacy], [AppLanguage.chinese, .english])
    func bundledDocumentsCanBeRead(document: LegalDocument, language: AppLanguage) throws {
        let blocks = try #require(document.blocks(for: language))
        #expect(blocks.contains { $0.kind == .section })
        #expect(blocks.contains { $0.kind == .paragraph && $0.text.contains("i@xiai.me") })
        #expect(blocks.allSatisfy { !$0.text.hasPrefix("#") })
        if document == .privacy {
            #expect(blocks.filter { $0.kind == .bullet }.count >= 3)
        }
    }

    @Test func markdownBlockBoundariesArePreserved() {
        let source = "# Title\n\nDate\n\nIntro\n\n## Section\n\nFirst paragraph\ncontinued line\n\n- One\n- Two\n"
        let blocks = LegalDocument.parse(source)
        #expect(blocks.map(\.kind) == [.metadata, .paragraph, .section, .paragraph, .bullet, .bullet])
        #expect(blocks[3].text == "First paragraph continued line")
    }
}
