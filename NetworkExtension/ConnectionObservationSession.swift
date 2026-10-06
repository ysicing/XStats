// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import NetworkObservation

/// 每条 XPC 连接独立的导出对象。已被替换的会话无法通过晚到的读取重新夺取租约。
final class ConnectionObservationSession: NSObject, NetworkObservationService {
    private let lock = NSLock()
    private var hasRead = false
    // XPC 在任意队列分发；成员关系校验与续租必须由 provider 在同一临界区内完成。
    private let readBatch: (NSXPCConnection, Bool, Int64, String) -> ObservationBatch?

    init(readBatch: @escaping (NSXPCConnection, Bool, Int64, String) -> ObservationBatch?) {
        self.readBatch = readBatch
    }

    func readEvents(after cursor: Int64, epoch: String, reply: @escaping (Data) -> Void) {
        guard epoch.utf8.count <= 36, cursor >= 0 else { reply(Data()); return }
        guard let peer = NSXPCConnection.current() else { reply(Data()); return }
        lock.lock()
        let firstRead = !hasRead
        hasRead = true
        lock.unlock()
        guard let batch = readBatch(peer, firstRead, cursor, epoch) else { reply(Data()); return }
        reply((try? JSONEncoder().encode(batch)) ?? Data())
    }
}
