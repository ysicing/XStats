// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import OSLog

/// 网络组件的关键事件统一进入系统日志；错误描述默认私有，公开信息仅为阶段与错误码。
enum ComponentLog {
    static let subsystem = "work.12306.xstats.networkmonitor"
    static let service = Logger(subsystem: subsystem, category: "service")
    static let registration = Logger(subsystem: subsystem, category: "registration")
    static let filter = Logger(subsystem: subsystem, category: "filter")
    static let update = Logger(subsystem: subsystem, category: "update")

    static func failure(_ error: any Error, operation: String, logger: Logger = service) {
        if error is CancellationError {
            logger.info("Cancelled operation=\(operation, privacy: .public)")
            return
        }
        let failure = error as NSError
        logger.error("Failed operation=\(operation, privacy: .public) domain=\(failure.domain, privacy: .private) code=\(failure.code) detail=\(String(failure.localizedDescription.prefix(1024)), privacy: .private)")
    }
}
