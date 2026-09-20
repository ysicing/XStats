// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

/// 使用原生 popover 承载搜索和单选列表，保留外部点击与 Escape 关闭的系统行为。
struct LanguagePicker: View {
    @Binding var selection: AppLanguage
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: DS.Space.s2) {
                Text(selection.title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(DSButtonStyle(kind: .secondary))
        .accessibilityLabel(tr("选择语言"))
        .accessibilityValue(selection.title)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            LanguagePickerList(selection: selection) { language in
                isPresented = false
                selection = language
            }
        }
    }
}

/// 面板单独持有搜索和键盘高亮；每次打开重置，不影响持久化的实际选择。
struct LanguagePickerList: View {
    let selection: AppLanguage
    let choose: (AppLanguage) -> Void
    @State private var query = ""
    @State private var highlighted: AppLanguage?
    @FocusState private var searchFocused: Bool

    private var languages: [AppLanguage] {
        AppLanguage.allCases.filter { $0.matches(search: query) }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(tr("搜索语言"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel(tr("搜索语言"))
                    .onSubmit {
                        if let language = highlighted ?? languages.first { choose(language) }
                    }
                    .onKeyPress(.downArrow) { move(by: 1); return .handled }
                    .onKeyPress(.upArrow) { move(by: -1); return .handled }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)

            if languages.isEmpty {
                Text(tr("没有匹配的语言"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(languages) { language in
                                Button {
                                    choose(language)
                                } label: {
                                    HStack {
                                        Text(language.title)
                                            .lineLimit(1)
                                        Spacer(minLength: 12)
                                        if selection == language {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 11, weight: .semibold))
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                    .background(highlighted == language ? Color.primary.opacity(0.10) : .clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selection == language ? .isSelected : [])
                                .onHover { hovering in
                                    if hovering { highlighted = language }
                                }
                                .id(language)
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.bottom, 5)
                    }
                    .frame(height: min(CGFloat(languages.count) * 32 + 10, 330))
                    .onChange(of: highlighted) { _, next in
                        if let next { proxy.scrollTo(next, anchor: .center) }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .frame(width: 250)
        .padding(4)
        .onAppear {
            highlighted = selection
            searchFocused = true
        }
        .onChange(of: query) { _, _ in highlighted = languages.first }
    }

    private func move(by offset: Int) {
        guard !languages.isEmpty else { return }
        let current = highlighted.flatMap { languages.firstIndex(of: $0) } ?? (offset > 0 ? -1 : languages.count)
        highlighted = languages[min(max(current + offset, 0), languages.count - 1)]
    }
}
