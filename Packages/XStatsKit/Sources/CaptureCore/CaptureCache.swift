// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import OSLog

/// 两种宿主共享的临时素材约定；用户保存的截图、视频不属于缓存。
public enum CaptureCache {
  public static let logger = Logger(subsystem: CaptureRequest.bundleIdentifier, category: "media")

  public static var directory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("XStatsCapture", isDirectory: true)
  }
  public static var recordingsDirectory: URL {
    directory.appendingPathComponent("Recordings", isDirectory: true)
  }

  public struct Usage: Sendable, Equatable {
    public var totalBytes: Int64 = 0
    public var reclaimableBytes: Int64 = 0
    public var reclaimableSessions: Int = 0
  }
  public struct Report: Sendable {
    public var usage = Usage()
    public var removedSessions = 0
    public var removedBytes: Int64 = 0
  }

  /// 按需统计，不启动定时器；占用仅反映此次扫描时的素材大小。
  public static func usage() async throws -> Usage {
    try await manage(root: recordingsDirectory, policy: .inspect).usage
  }
  /// 手动清理仍保留活动会话和最近一小时的恢复素材。
  public static func cleanUnusedRecordings() async throws -> Report {
    try await manage(root: recordingsDirectory, policy: .unused)
  }

  enum Policy: Sendable {
    case inspect
    case unused
    case retention(age: TimeInterval, bytes: Int64, sessions: Int)
  }
  private struct Session {
    let url: URL
    let date: Date
    let bytes: Int64
  }

  /// 自动与手动清理共用资格检查，删除前重新获取跨进程租约，绝不整目录清空。
  static func manage(root: URL, now: Date = Date(), policy: Policy) async throws -> Report {
    let worker = Task.detached(priority: .utility) {
      let manager = FileManager.default
      var report = Report()
      guard manager.fileExists(atPath: root.path) else { return report }
      // 拒绝缓存根目录被换成符号链接；会话内的链接同样不参与计量。
      for directory in [root.deletingLastPathComponent(), root] {
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
          throw CocoaError(.fileReadInvalidFileName)
        }
      }
      let directories = try manager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
        ])
      var candidates: [Session] = []
      var count = 0
      var candidateBytes: Int64 = 0
      for directory in directories {
        try Task.checkCancellation()
        guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
        do {
          let values = try directory.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey,
          ])
          guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
          let date = values.contentModificationDate ?? now
          let files = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
          var size: Int64 = 0
          for file in files {
            try Task.checkCancellation()
            let properties = try file.resourceValues(forKeys: [
              .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if properties.isRegularFile == true, properties.isSymbolicLink != true {
              size += Int64(properties.fileSize ?? 0)
            }
          }
          report.usage.totalBytes += size
          // 保护 mkdir 到建立租约的间隙，也给近期崩溃留出恢复时间。
          guard now.timeIntervalSince(date) >= 3600 else {
            count += 1
            continue
          }
          guard let lease = try? RecordingSessionLease(directory: directory) else { continue }
          // 兼容尚无锁文件的历史会话；探测不能延长其保留期。
          try withExtendedLifetime(lease) {
            try manager.setAttributes([.modificationDate: date], ofItemAtPath: directory.path)
            candidates.append(Session(url: directory, date: date, bytes: size))
          }
          report.usage.reclaimableBytes += size
          report.usage.reclaimableSessions += 1
          candidateBytes += size
          count += 1
        } catch let error as CocoaError
          where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
        {
          // 另一个宿主可能刚完成导出并移除了会话。
          continue
        }
      }
      for candidate in candidates.sorted(by: { $0.date < $1.date }) {
        try Task.checkCancellation()
        switch policy {
        case .inspect: continue
        case .unused: break
        case .retention(let age, let bytes, let sessions):
          guard
            now.timeIntervalSince(candidate.date) > age || candidateBytes > bytes
              || count > sessions
          else { continue }
        }
        guard let lease = try? RecordingSessionLease(directory: candidate.url) else { continue }
        try withExtendedLifetime(lease) {
          try manager.removeItem(at: candidate.url)
        }
        count -= 1
        candidateBytes -= candidate.bytes
        report.removedSessions += 1
        report.removedBytes += candidate.bytes
        report.usage.totalBytes -= candidate.bytes
        report.usage.reclaimableBytes -= candidate.bytes
        report.usage.reclaimableSessions -= 1
      }
      if report.removedSessions > 0 {
        logger.notice(
          "Removed \(report.removedSessions) unused recording sessions, \(report.removedBytes) bytes"
        )
      }
      return report
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
}
