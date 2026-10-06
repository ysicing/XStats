// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// 固定容量环形缓冲；连接回调中追加不移动已有记录，界面用游标读取增量。
public struct ConnectionJournal: Sendable {
    private var slots: [ObservedConnection?]
    private var head = 0
    private var count = 0
    private var sequence: Int64 = 0
    private var epoch = UUID().uuidString
    private var discarded: Int64 = 0

    public init(capacity: Int = ObservationLimits.journalCount) {
        precondition(capacity > 0)
        slots = Array(repeating: nil, count: capacity)
    }

    public mutating func append(_ event: ObservedConnection) {
        if sequence == .max { clear() }
        var record = event
        // 对 UTF-8 字节限长，包含长路径及多字节名称时仍保持传输与内存上界。
        record.executablePath = boundedMetadata(record.executablePath, bytes: 768)
        record.hostname = record.hostname.map { boundedMetadata($0, bytes: 252) }
        record.address = record.address.map { boundedMetadata($0, bytes: 125) }
        sequence += 1
        record.sequence = sequence
        if count == slots.count {
            slots[head] = record
            head = (head + 1) % slots.count
            discarded += 1
        } else {
            slots[(head + count) % slots.count] = record
            count += 1
        }
    }

    public func batch(after cursor: Int64, epoch requestedEpoch: String) -> ObservationBatch {
        let previous = requestedEpoch == epoch ? max(0, cursor) : 0
        var events: [ObservedConnection] = []
        for index in 0..<count {
            guard let record = slots[(head + index) % slots.count], record.sequence > previous else { continue }
            events.append(record)
            if events.count == ObservationLimits.batchCount { break }
        }
        return ObservationBatch(epoch: epoch, cursor: events.last?.sequence ?? sequence,
                                discarded: discarded, events: events)
    }

    public mutating func clear() {
        slots = Array(repeating: nil, count: slots.count)
        head = 0; count = 0; sequence = 0; discarded = 0
        epoch = UUID().uuidString
    }
}

/// 去掉控制字符并限制 UTF-8 大小；64 条记录即使 JSON 转义后也低于传输上限。
private func boundedMetadata(_ text: String, bytes: Int) -> String {
    let prefix = String(decoding: text.utf8.prefix(bytes - 3), as: UTF8.self)
    return String(prefix.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
}
