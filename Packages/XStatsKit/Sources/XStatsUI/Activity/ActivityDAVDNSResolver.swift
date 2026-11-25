// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import WebDAVSync
import dnssd
import os

enum ActivityDAVDNSResolver {
  static let maximumAddresses = 32

  static func resolve(_ host: String) async throws -> [String] {
    let query = ActivityDAVDNSQuery(host: host)
    return try await withThrowingTaskGroup(of: [String].self) { group in
      group.addTask { try await query.run() }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw WebDAVError.transport
      }
      defer { group.cancelAll() }
      guard let answers = try await group.next() else { throw WebDAVError.transport }
      try Task.checkCancellation()
      return answers
    }
  }
}

/// 每个实例只执行一次。串行队列拥有原生引用，锁只保护任务等待状态。
private final class ActivityDAVDNSQuery: @unchecked Sendable {
  private enum Waiter: Sendable {
    case idle
    case waiting(CheckedContinuation<[String], any Error>)
    case finished
  }

  private let host: String
  private let queue = DispatchQueue(label: "XStats.ActivityDAVDNS", qos: .utility)
  private let waiter = OSAllocatedUnfairLock(initialState: Waiter.idle)
  private var services: [DNSServiceRef] = []
  private var pending: Set<DNSServiceRef> = []
  private var seen: Set<String> = []
  private var answers: [String] = []

  init(host: String) {
    // 保留单标签名称，让系统应用当前网络的搜索域（包括 MagicDNS）。
    self.host = host
  }

  func run() async throws -> [String] {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let registered = waiter.withLock { state in
          guard case .idle = state else { return false }
          state = .waiting(continuation)
          return true
        }
        guard registered else {
          continuation.resume(throwing: CancellationError())
          return
        }
        queue.async { self.start() }
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
    }
  }

  private var isWaiting: Bool {
    waiter.withLock { state in
      if case .waiting = state { return true }
      return false
    }
  }

  private func start() {
    let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)
    // 分别查询两族，才能区分另一族尚未响应与明确无记录。
    for family in [kDNSServiceProtocol_IPv4, kDNSServiceProtocol_IPv6] {
      guard isWaiting else { return }
      var reference: DNSServiceRef?
      let result = DNSServiceGetAddrInfo(
        &reference, flags, 0, DNSServiceProtocol(family), host,
        { service, flags, _, error, _, address, _, context in
          guard let service, let context else { return }
          let query = Unmanaged<ActivityDAVDNSQuery>.fromOpaque(context).takeUnretainedValue()
          query.receive(service: service, flags: flags, error: error, address: address)
        }, Unmanaged.passUnretained(self).toOpaque())
      guard result == kDNSServiceErr_NoError, let reference else {
        finish(.failure(WebDAVError.transport))
        return
      }
      services.append(reference)
      pending.insert(reference)
      guard DNSServiceSetDispatchQueue(reference, queue) == kDNSServiceErr_NoError else {
        finish(.failure(WebDAVError.transport))
        return
      }
    }
  }

  private func receive(
    service: DNSServiceRef, flags: DNSServiceFlags, error: DNSServiceErrorType,
    address: UnsafePointer<sockaddr>?
  ) {
    guard isWaiting else { return }
    switch Int(error) {
    case kDNSServiceErr_NoError:
      guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
        let address, let text = Self.numericAddress(address)
      else {
        finish(.failure(WebDAVError.transport))
        return
      }
      if seen.insert(text).inserted {
        guard answers.count < ActivityDAVDNSResolver.maximumAddresses else {
          finish(.failure(ActivitySyncFailure.limit))
          return
        }
        answers.append(text)
      }
    case kDNSServiceErr_NoSuchRecord:
      break
    default:
      finish(.failure(WebDAVError.transport))
      return
    }

    if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0 {
      pending.insert(service)
    } else {
      pending.remove(service)
    }
    if pending.isEmpty { finish(.success(answers)) }
  }

  private static func numericAddress(_ address: UnsafePointer<sockaddr>) -> String? {
    let family = Int32(address.pointee.sa_family)
    guard family == AF_INET || family == AF_INET6 else { return nil }
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let capacity = socklen_t(host.count)
    guard
      getnameinfo(
        address, socklen_t(address.pointee.sa_len), &host, capacity, nil, 0, NI_NUMERICHOST
      ) == 0
    else { return nil }
    let bytes = host.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:))
    return String(decoding: bytes, as: UTF8.self)
  }

  private func finish(_ result: Result<[String], any Error>) {
    let continuation = waiter.withLock { state -> CheckedContinuation<[String], any Error>? in
      defer { state = .finished }
      if case .waiting(let continuation) = state { return continuation }
      return nil
    }
    guard let continuation else { return }
    // 即使本机 DNS 守护进程卡在创建查询，调用方也可退出。原生引用仍在原队列释放。
    queue.async { [self] in
      for service in services { DNSServiceRefDeallocate(service) }
      services.removeAll()
    }
    continuation.resume(with: result)
  }
}
