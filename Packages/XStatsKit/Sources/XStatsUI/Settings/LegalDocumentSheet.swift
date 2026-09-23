// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import SwiftUI

struct LegalBlock: Equatable {
    enum Kind: Equatable { case metadata, section, paragraph, bullet }

    let kind: Kind
    let text: String
}

enum LegalDocument: String, Identifiable {
    case terms = "Terms"
    case privacy = "Privacy"

    var id: String { rawValue }
    var title: String { self == .terms ? tr("服务条款") : tr("隐私政策") }

    func blocks(for language: AppLanguage) -> [LegalBlock]? {
        let documentLanguage = language.isChinese ? "zh-Hans" : "en"
        guard let url = Bundle.module.url(forResource: "\(rawValue).\(documentLanguage)", withExtension: "md", subdirectory: "Legal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.parse(source)
    }

    /// SwiftUI 的单个 Text 会压平 Markdown 块级结构；按块拆开，交给布局控制章节和段落间距。
    static func parse(_ source: String) -> [LegalBlock] {
        var blocks: [LegalBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(LegalBlock(kind: blocks.isEmpty ? .metadata : .paragraph,
                                     text: paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        for line in source.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.isEmpty {
                flushParagraph()
            } else if line.hasPrefix("# ") {
                flushParagraph() // 标题由弹窗顶栏显示，不在正文重复。
            } else if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(LegalBlock(kind: .section, text: String(line.dropFirst(3))))
            } else if line.hasPrefix("- ") {
                flushParagraph()
                blocks.append(LegalBlock(kind: .bullet, text: String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }
}

struct LegalDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: LegalDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.s3) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: 28, height: 28)
                        .background(DS.Palette.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("关闭文档"))
                .keyboardShortcut(.cancelAction)
                Text(document.title)
                    .dsFont(.lg, weight: .semibold)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
            }
            .padding(DS.Space.s4)

            HairlineDivider()

            ScrollView {
                if let blocks = document.blocks(for: L10n.language) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            blockView(block)
                        }
                    }
                    .frame(maxWidth: 640, alignment: .leading)
                    .padding(DS.Space.s6)
                    .frame(maxWidth: .infinity)
                } else {
                    Text(tr("无法读取法律文件"))
                        .foregroundStyle(DS.Palette.textSecondary)
                        .padding(DS.Space.s4)
                }
            }
            .overlayScrollers()
        }
        .frame(width: 720, height: 600)
        .background(DS.Palette.background)
    }

    @ViewBuilder
    private func blockView(_ block: LegalBlock) -> some View {
        switch block.kind {
        case .metadata:
            Text(block.text)
                .dsFont(.xs)
                .foregroundStyle(DS.Palette.textSecondary)
                .padding(.bottom, DS.Space.s6)
        case .section:
            Text(block.text)
                .dsFont(.base, weight: .semibold)
                .foregroundStyle(DS.Palette.textPrimary)
                .padding(.top, DS.Space.s4)
                .padding(.bottom, DS.Space.s3)
        case .paragraph:
            richText(block.text)
                .dsFont(.sm)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, DS.Space.s4)
        case .bullet:
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Text("•").frame(width: DS.Space.s3, alignment: .leading)
                richText(block.text)
                    .dsFont(.sm)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, DS.Space.s2)
        }
    }

    private func richText(_ source: String) -> Text {
        Text((try? AttributedString(markdown: source)) ?? AttributedString(source))
    }
}
