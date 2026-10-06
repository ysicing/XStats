// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

enum NetworkMonitorSupport {
    static let isAvailable = supports(on: ProcessInfo.processInfo.operatingSystemVersion)

    static func supports(on version: OperatingSystemVersion) -> Bool { version.majorVersion >= 15 }
}
