// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 只保留上一轮的文件元数据和汇总，不常驻逐消息解析状态。
/// 文件集、内容、日期或时区变化时仍走原有增量检查点和跨文件去重流程。
struct LocalUsageScanCache {
    struct Revision: Equatable {
        struct File: Equatable {
            let path: String
            let size: UInt64
            let modified: Date
            let inode: UInt64
        }
        let files: [File]
        let day: Date
        let timeZone: String

        init(files: [URL], now: Date, calendar: Calendar) throws {
            self.files = try files.map { url in
                try Task.checkCancellation()
                let path = url.resolvingSymlinksInPath().path
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                return File(path: path, size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                            modified: attributes[.modificationDate] as? Date ?? .distantPast,
                            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
            }
            day = calendar.startOfDay(for: now)
            timeZone = calendar.timeZone.identifier
        }
    }

    let revision: Revision
    let report: LocalUsageReport
}
