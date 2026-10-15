// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import CaptureUI

/// No controller, capture producer or observers exist until the first action.
/// The XStats host owns app menus, language, Dock presentation and termination.
@MainActor enum XStatsCapture {
    static let workspace = CaptureWorkspace(host: .embedded)
}
