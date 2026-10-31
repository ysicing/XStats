// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum ObservationLimits {
  public static let journalCount = 32_768
  /// 采集预算独立于列表窗口；达到预算时显式报告拒收，不淘汰仍活动的连接。
  public static let captureCount = 8192
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

/// 系统报告的累计字节数；只传计数与时间，不读取通信内容。
public struct ConnectionTrafficSnapshot: Codable, Sendable, Equatable {
  // 512 个活动快照与64条最坏情况元数据需共同满足原有256 KiB传输上限。
  private enum CodingKeys: String, CodingKey {
    case id
    case timestamp = "at"
    case receivedBytes = "rx"
    case sentBytes = "tx"
    case observationID = "ob"
  }

  public var id: UUID
  public var timestamp: Date
  public var receivedBytes: UInt64
  public var sentBytes: UInt64
  /// 由采集租约生成；客户端重试/重连不能改变已观察区间的归属。
  public var observationID: UUID? = nil

  public init(id: UUID, timestamp: Date, receivedBytes: UInt64, sentBytes: UInt64) {
    self.id = id
    self.timestamp = timestamp
    self.receivedBytes = receivedBytes
    self.sentBytes = sentBytes
  }
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
  public var traffic: ConnectionTrafficSnapshot? = nil

  public init(
    id: UUID, timestamp: Date, processID: Int32, executablePath: String,
    address: String?, hostname: String?, port: UInt16?,
    transport: ConnectionTransport, direction: ConnectionDirection
  ) {
    self.id = id
    self.timestamp = timestamp
    self.processID = processID
    self.executablePath = executablePath
    self.address = address
    self.hostname = hostname
    self.port = port
    self.transport = transport
    self.direction = direction
  }

  public var applicationPath: String? {
    guard let range = executablePath.range(of: ".app/") else { return nil }
    return String(executablePath[..<range.upperBound].dropLast())
  }

  /// 只去掉 .app 后缀；裸可执行文件名中的点属于名称本身（python3.12、node-v18.2）。
  public var applicationName: String {
    if let applicationPath {
      return URL(fileURLWithPath: applicationPath).deletingPathExtension().lastPathComponent
    }
    guard !executablePath.isEmpty else { return "PID \(processID)" }
    return URL(fileURLWithPath: executablePath).lastPathComponent
  }
}

public struct ObservationBatch: Codable, Sendable, Equatable {
  public let epoch: String
  public let cursor: Int64
  public let discarded: Int64
  public let events: [ObservedConnection]
  public var activeIDs: [UUID]? = nil
  public var protocolVersion: Int = NetworkObservationProtocol.version
  /// 增量能力版本：旧组件省略此字段，旧主程序忽略新增字段，连接协议继续兼容。
  public var trafficVersion: Int? = nil
  public var traffic: [ConnectionTrafficSnapshot]? = nil
  public var captureDropped: Int64? = nil

  public static func decode(_ data: Data) throws -> Self {
    guard data.count <= ObservationLimits.maximumPayloadBytes else {
      throw CocoaError(.coderReadCorrupt)
    }
    let batch = try JSONDecoder().decode(Self.self, from: data)
    guard NetworkObservationProtocol.supports(batch.protocolVersion),
      UUID(uuidString: batch.epoch) != nil, batch.cursor >= 0, batch.discarded >= 0,
      batch.events.count <= ObservationLimits.batchCount,
      (batch.traffic?.count ?? 0) <= ObservationLimits.displayCount,
      batch.traffic == nil || batch.trafficVersion == 1,
      (batch.captureDropped ?? 0) >= 0,
      batch.traffic?.allSatisfy({ $0.timestamp.timeIntervalSince1970.isFinite }) ?? true,
      (batch.activeIDs?.count ?? 0) <= ObservationLimits.displayCount,
      batch.events.allSatisfy({
        $0.sequence > 0 && $0.sequence <= batch.cursor
          && $0.executablePath.utf8.count <= 1024 && ($0.hostname?.utf8.count ?? 0) <= 255
          && ($0.address?.utf8.count ?? 0) <= 128
      })
    else { throw CocoaError(.coderReadCorrupt) }
    return batch
  }
}

/// 只读增量接口；协议没有规则、放行或阻断入口。断开连接会终止观察租约。
@objc public protocol NetworkObservationService {
  func readEvents(after cursor: Int64, epoch: String, reply: @escaping (Data) -> Void)
  /// v3 停止接收新事件并排空已观察的尾批；不续租，不请求额外通信内容。
  func finishEvents(after cursor: Int64, epoch: String, reply: @escaping (Data) -> Void)
  /// 只读生命周期查询；未运行或 stopFilter 已完成收尾时返回 true，停止过程中保持 false。
  func isFilterStopped(reply: @escaping @Sendable (Bool) -> Void)
  /// 显式、有界的真机诊断窗口；零秒读取上次结果，不续观察租约。
  func flowDiagnostics(windowSeconds: Double, reply: @escaping @Sendable (Data) -> Void)

}

/// 伴随应用仅管理过滤器生命周期，所有网络流量继续由扩展放行。
@objc public protocol NetworkComponentService {
  func perform(_ command: String, reply: @escaping @Sendable (Data) -> Void)
}
