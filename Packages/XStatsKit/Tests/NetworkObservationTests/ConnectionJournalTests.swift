// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import NetworkObservation

struct ConnectionJournalTests {
    private func event(_ index: Int) -> ObservedConnection {
        ObservedConnection(id: UUID(), timestamp: Date(timeIntervalSince1970: Double(index)),
                           processID: 42, executablePath: "/Applications/Browser.app/Contents/MacOS/Browser",
                           address: "203.0.113.10", hostname: nil, port: 443,
                           transport: .tcp, direction: .outbound)
    }

    @Test func journalIsBoundedAndReportsEviction() {
        var journal = ConnectionJournal(capacity: 3)
        for index in 0..<5 { journal.append(event(index)) }
        let batch = journal.batch(after: 0, epoch: "")
        #expect(batch.events.map(\.sequence) == [3, 4, 5])
        #expect(batch.discarded == 2)
        #expect(batch.cursor == 5)
    }

    @Test func cursorAvoidsRedeliveryAndLimitsEachBatch() {
        var journal = ConnectionJournal(capacity: 200)
        for index in 0..<150 { journal.append(event(index)) }
        let first = journal.batch(after: 0, epoch: "")
        #expect(first.events.count == ObservationLimits.batchCount)
        var delivered = first.events
        var cursor = first.cursor
        while delivered.count < 150 {
            let batch = journal.batch(after: cursor, epoch: first.epoch)
            #expect(!batch.events.isEmpty && batch.events.count <= ObservationLimits.batchCount)
            delivered += batch.events
            cursor = batch.cursor
        }
        #expect(Set(delivered.map(\.sequence)).count == 150)
        #expect(journal.batch(after: cursor, epoch: first.epoch).events.isEmpty)
    }

    @Test func restartResetsEpochAndAcceptsAnOldCursor() {
        var journal = ConnectionJournal(capacity: 3)
        journal.append(event(0))
        let before = journal.batch(after: 0, epoch: "")
        journal.clear()
        journal.append(event(1))
        let after = journal.batch(after: before.cursor, epoch: before.epoch)
        #expect(after.epoch != before.epoch)
        #expect(after.events.count == 1)
        #expect(after.events.first?.sequence == 1)
    }

    @Test func invisibleObserverHasNoLeaseAndExpiredLeaseCannotRecord() {
        let buffer = ObservationBuffer()
        #expect(!buffer.isObserving(now: 1))
        _ = buffer.read(after: 0, epoch: "", now: 1)
        #expect(buffer.isObserving(now: 2))
        buffer.record(event(0), now: 2)
        #expect(!buffer.isObserving(now: 10))
        buffer.record(event(1), now: 10)
        let resumed = buffer.read(after: 0, epoch: "", now: 11)
        #expect(resumed.events.count == 1)
        buffer.stop()
        #expect(!buffer.isObserving(now: 11))
        #expect(buffer.read(after: 0, epoch: "", now: 12).events.isEmpty)
    }

    @Test func activeSnapshotKeepsNewestConnectionsWhenOlderLongLivedFlowsFillCapacity() {
        let buffer = ObservationBuffer()
        _ = buffer.read(after: 0, epoch: "", now: 1)
        let connections = (0..<(ObservationLimits.displayCount * 2)).map { event($0) }
        for connection in connections { buffer.record(connection, now: 2) }
        let latest = buffer.read(after: 0, epoch: "", now: 3)
        #expect(Set(latest.activeIDs ?? []) == Set(connections.suffix(ObservationLimits.displayCount).map(\.id)))
        buffer.close(connections[0].id)
        #expect(buffer.read(after: latest.cursor, epoch: latest.epoch, now: 4).activeIDs?.count == ObservationLimits.displayCount)
    }

    @Test func closedFlowLeavesActiveSnapshotWithoutDuplicatingIdentity() throws {
        let buffer = ObservationBuffer()
        _ = buffer.read(after: 0, epoch: "", now: 1)
        let connection = event(0)
        buffer.record(connection, now: 2)
        let opened = buffer.read(after: 0, epoch: "", now: 3)
        #expect(opened.activeIDs == [connection.id])
        buffer.close(connection.id, at: Date(timeIntervalSince1970: 4))
        let closed = buffer.read(after: opened.cursor, epoch: opened.epoch, now: 5)
        #expect(closed.activeIDs?.isEmpty == true)
        #expect(closed.events.first?.id == connection.id)
        #expect(closed.events.first?.closedAt != nil)
        #expect(try ObservationBatch.decode(JSONEncoder().encode(closed)) == closed)
    }

    @Test func pausedReaderKeepsActiveFlowsAndDeliversClosesAfterResume() {
        let buffer = ObservationBuffer()
        _ = buffer.read(after: 0, epoch: "", now: 1)
        let longLived = event(0), shortLived = event(1)
        buffer.record(longLived, now: 2)
        buffer.record(shortLived, now: 2)
        let before = buffer.read(after: 0, epoch: "", now: 3)
        // 切换标签、锁屏或断开读取端：停止记录新连接，但已观察的连接仍在进行。
        buffer.endLease()
        #expect(!buffer.isObserving(now: 3))
        buffer.record(event(2), now: 3)
        buffer.close(shortLived.id, at: Date(timeIntervalSince1970: 4))
        let resumed = buffer.read(after: before.cursor, epoch: before.epoch, now: 5)
        #expect(resumed.epoch == before.epoch, "暂停不应换代，否则读取端会把旧连接当作未知")
        #expect(resumed.activeIDs == [longLived.id], "暂停前建立且仍在进行的连接必须保留在活动快照中")
        #expect(resumed.events.map(\.id) == [shortLived.id], "暂停期间只投递已知连接的结束事件，不记录新连接")
        #expect(resumed.events.first?.closedAt != nil)
    }

    @Test func applicationNameOnlyStripsAppBundleSuffix() {
        let cases = [("/Applications/Safari.app/Contents/MacOS/Safari", "Safari"),
                     ("/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper", "Visual Studio Code"),
                     ("/opt/homebrew/bin/python3.12", "python3.12"),
                     ("/usr/local/bin/node-v18.2", "node-v18.2"),
                     ("", "PID 42")]
        for (path, expected) in cases {
            var record = event(0)
            record.executablePath = path
            #expect(record.applicationName == expected, "路径：\(path)")
        }
    }

    @Test func wirePayloadIsBoundedAndRejectsOversizedReplies() throws {
        var journal = ConnectionJournal(capacity: 256)
        for index in 0..<256 {
            var record = event(index)
            record.executablePath = String(repeating: "\u{0}\\\"文", count: 3000)
            record.hostname = String(repeating: "\\\"文", count: 1000)
            record.address = String(repeating: "\\\"", count: 1000)
            journal.append(record)
        }
        let batch = journal.batch(after: 0, epoch: "")
        let data = try JSONEncoder().encode(batch)
        #expect(data.count <= ObservationLimits.maximumPayloadBytes)
        #expect(try ObservationBatch.decode(data) == batch)
        #expect(throws: (any Error).self) {
            try ObservationBatch.decode(Data(repeating: 0, count: ObservationLimits.maximumPayloadBytes + 1))
        }
    }
}
