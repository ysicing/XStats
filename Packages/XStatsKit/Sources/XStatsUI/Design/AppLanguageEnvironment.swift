// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Localization
import SwiftUI

/// 每个独立窗口/弹窗都读取当前选择，立即更新日期语言、文字方向与已计算的文案。
private struct AppLanguageEnvironment: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let language = model.settings.language.resolved
        content
            .environment(\.locale, L10n.locale(for: language))
            .environment(\.layoutDirection, language.isRightToLeft ? .rightToLeft : .leftToRight)
            .id(model.settings.language)
    }
}

extension View {
    func appLanguageEnvironment() -> some View { modifier(AppLanguageEnvironment()) }
}
