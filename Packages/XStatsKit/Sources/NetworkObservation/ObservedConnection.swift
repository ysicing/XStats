// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum ObservationLimits {
    public static let journalCount = 256
    public static let displayCount = 512
    public static let batchCount = 64
    public static let maximumPayloadBytes = 256 * 1024
    public static let leaseSeconds: TimeInterval = 6
}

public enum ConnectionTransport: String, Codable, Sendable {
    case tcp, udp, other
}

public enum ConnectionDirection: String, Codable, Sendable {
    case inbound, outbound
}

/// 连接元数据与结束事件；活动状态以同一批次的 activeIDs 为准。
public struct ObservedConnection: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sequence: Int64 = 0
    public var closedAt: Date? = nil
    public var timestamp: Date
    public var processID: Int32
    public var executablePath: String
    public var address: String?
    public var hostname: String?
    public var port: UInt16?
    public var transport: ConnectionTransport
    public var direction: ConnectionDirection

    public init(id: UUID, timestamp: Date, processID: Int32, executablePath: String,
                address: String?, hostname: String?, port: UInt16?,
                transport: ConnectionTransport, direction: ConnectionDirection) {
        self.id = id; self.timestamp = timestamp; self.processID = processID
        self.executablePath = executablePath; self.address = address; self.hostname = hostname
        self.port = port; self.transport = transport; self.direction = direction
    }

    public var applicationPath: String? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        return String(executablePath[..<range.upperBound].dropLast())
    }

    public var applicationName: String {
        let path = applicationPath ?? executablePath
        guard !path.isEmpty else { return "PID \(processID)" }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

public struct ObservationBatch: Codable, Sendable, Equatable {
    public let epoch: String
    public let cursor: Int64
    public let discarded: Int64
    public let events: [ObservedConnection]
    public var activeIDs: [UUID]? = nil

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= ObservationLimits.maximumPayloadBytes else { throw CocoaError(.coderReadCorrupt) }
        let batch = try JSONDecoder().decode(Self.self, from: data)
        guard UUID(uuidString: batch.epoch) != nil, batch.cursor >= 0, batch.discarded >= 0,
              batch.events.count <= ObservationLimits.batchCount,
              (batch.activeIDs?.count ?? 0) <= ObservationLimits.displayCount,
              batch.events.allSatisfy({ $0.sequence > 0 && $0.sequence <= batch.cursor
                  && $0.executablePath.utf8.count <= 1024 && ($0.hostname?.utf8.count ?? 0) <= 255
                  && ($0.address?.utf8.count ?? 0) <= 128 }) else { throw CocoaError(.coderReadCorrupt) }
        return batch
    }
}

/// 只读增量接口；协议没有规则、放行或阻断入口。断开连接会终止观察租约。
@objc public protocol NetworkObservationService {
    func readEvents(after cursor: Int64, epoch: String, reply: @escaping (Data) -> Void)
}
