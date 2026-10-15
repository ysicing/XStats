// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NetworkExtension

autoreleasepool {
    _ = ConnectionFilterProvider.host
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
