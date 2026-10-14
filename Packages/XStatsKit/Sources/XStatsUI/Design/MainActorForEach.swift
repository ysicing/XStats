// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// macOS 15 的异步 DisplayLink 可在后台调用 ForEach.content。
/// 列表回调只传递元素值；模型读取、AppKit 缓存和界面构建留在行的 MainActor body 中。
struct MainActorForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View
where Data.Element: Sendable {
    let data: Data
    let id: KeyPath<Data.Element, ID>
    let content: @MainActor @Sendable (Data.Element) -> Content

    init(_ data: Data, id: KeyPath<Data.Element, ID>,
         @ViewBuilder content: @escaping @MainActor @Sendable (Data.Element) -> Content) {
        self.data = data
        self.id = id
        self.content = content
    }

    var body: some View {
        let callback: @Sendable (Data.Element) -> MainActorListRow<Data.Element, Content> = row
        return ForEach(data, id: id, content: callback)
    }

    // 显式非隔离的方法引用避免 Swift 6.4 把泛型 Content 元类型推断为隔离闭包捕获。
    @Sendable nonisolated private func row(_ element: Data.Element) -> MainActorListRow<Data.Element, Content> {
        MainActorListRow(element: element, content: content)
    }
}

extension MainActorForEach where Data.Element: Identifiable, ID == Data.Element.ID {
    init(_ data: Data, @ViewBuilder content: @escaping @MainActor @Sendable (Data.Element) -> Content) {
        self.init(data, id: \.id, content: content)
    }
}

extension MainActorForEach where Data == Range<Int>, ID == Int {
    init(_ data: Range<Int>, @ViewBuilder content: @escaping @MainActor @Sendable (Int) -> Content) {
        self.init(data, id: \.self, content: content)
    }
}

private struct MainActorListRow<Element: Sendable, Content: View>: View {
    let element: Element
    let content: @MainActor @Sendable (Element) -> Content

    nonisolated init(element: Element, content: @escaping @MainActor @Sendable (Element) -> Content) {
        self.element = element
        self.content = content
    }

    var body: some View { content(element) }
}
