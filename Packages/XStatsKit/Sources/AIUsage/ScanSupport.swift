// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Dispatch
import Foundation

/// ISO8601DateFormatter 的创建开销远高于一次解析，按解析状态复用一份，不要逐行新建。
struct ISO8601Parser {
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let whole = ISO8601DateFormatter()

    func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
    }
}

/// 冷启动要读完整个日志目录，是几十秒的同步 IO。放在专用串行队列上执行，
/// 不占用 Swift 并发的协作线程池，否则首次扫描期间每秒采样的系统指标会被一起卡住。
/// 两个 Provider 共用一条线程：扫描瓶颈在磁盘，并行读并不会更快。
final class ScanExecutor: SerialExecutor {
    static let shared = ScanExecutor()

    private let queue = DispatchQueue(label: "com.xstats.ai-usage-scan", qos: .utility)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
