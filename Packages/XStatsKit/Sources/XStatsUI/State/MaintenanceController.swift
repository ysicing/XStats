import Cleaner
import Foundation
import HelperShared
import Localization
import Metrics
import Observation

/// 手动维护：缩略图由当前用户重置；DNS 与内存操作沿用辅助工具或系统管理员授权。
@MainActor
@Observable
public final class MaintenanceController {
  public struct Outcome: Equatable {
    let text: String
    let isError: Bool
  }

  public private(set) var running: MaintenanceCommand?
  public private(set) var outcomes: [MaintenanceCommand: Outcome] = [:]
  public private(set) var isApplyingDNS = false
  public private(set) var dnsOutcome: Outcome?
  public private(set) var isResettingThumbnails = false
  public private(set) var thumbnailOutcome: Outcome?

  @ObservationIgnored private let helper: HelperClient
  @ObservationIgnored private let resetThumbnailCache: @Sendable () async throws -> Void
  @ObservationIgnored var moleIsRunning: () -> Bool = { false }

  var isBusy: Bool { running != nil || isResettingThumbnails || isApplyingDNS }
  /// Mole 运行时执行入口会拒绝维护命令；视图据此禁用控件，避免点击后静默无响应。
  var isBlockedByMole: Bool { moleIsRunning() }

  init(
    helper: HelperClient,
    resetThumbnailCache: @escaping @Sendable () async throws -> Void = {
      try await ThumbnailCache.reset()
    }
  ) {
    self.helper = helper
    self.resetThumbnailCache = resetThumbnailCache
  }

  func run(_ command: MaintenanceCommand) async {
    guard !isBusy, !moleIsRunning(), !Task.isCancelled else { return }
    running = command
    defer { running = nil }

    let before = MemorySampler().sample()
    helper.refreshStatus()
    let prompt = command == .flushDNS ? tr("XStats 需要管理员权限来刷新 DNS 缓存。") : tr("XStats 需要管理员权限来释放内存。")
    let error =
      helper.isReady
      ? await helper.run(command)
      : await Self.runWithAdministratorPrompt(shell: command.shellCommand, prompt: prompt)

    if let error {
      Log.app.error(
        "\(command.rawValue, privacy: .public) 失败：\(String(error.prefix(500)), privacy: .private)")
      outcomes[command] = Outcome(text: error, isError: error != Self.cancelled)
      return
    }
    switch command {
    case .flushDNS:
      outcomes[command] = Outcome(text: tr("DNS 缓存已刷新"), isError: false)
    case .purgeMemory:
      let after = MemorySampler().sample()
      let freed: UInt64
      if let before, let after, before.cached > after.cached {
        freed = before.cached - after.cached
      } else {
        freed = 0
      }
      outcomes[command] = Outcome(
        text: freed > 0 ? tr("已释放 \(Format.bytes(freed)) 缓存内存") : tr("内存已整理"), isError: false)
    }
  }

  func resetThumbnails() async {
    guard !isBusy, !moleIsRunning(), !Task.isCancelled else { return }
    isResettingThumbnails = true
    thumbnailOutcome = nil
    defer { isResettingThumbnails = false }
    Log.app.info("Thumbnail cache reset started")
    do {
      try await resetThumbnailCache()
      try Task.checkCancellation()
      thumbnailOutcome = Outcome(text: tr("缩略图缓存已重置，缩略图将在浏览文件时重新生成。"), isError: false)
      Log.app.info("Thumbnail cache reset completed")
    } catch {
      guard !Task.isCancelled, !(error is CancellationError) else {
        Log.app.info("Thumbnail cache reset cancelled")
        return
      }
      thumbnailOutcome = Outcome(text: error.localizedDescription, isError: true)
      Log.app.error(
        "Thumbnail cache reset failed: \(String(error.localizedDescription.prefix(500)), privacy: .private)"
      )
    }
  }

  /// 为网络服务设置 DNS（空数组为恢复自动），完成后刷新 DNS 缓存
  func setDNSServers(_ servers: [String], service: String) async {
    guard !isBusy, !moleIsRunning(), !Task.isCancelled else { return }
    guard DNSConfiguration.isValidServiceName(service),
      servers.count <= DNSConfiguration.maxServers,
      servers.allSatisfy(DNSConfiguration.isValidAddress)
    else {
      dnsOutcome = Outcome(text: tr("DNS 地址格式不正确"), isError: true)
      return
    }
    isApplyingDNS = true
    dnsOutcome = nil
    defer { isApplyingDNS = false }

    let error: String?
    if let version = await helper.remoteProtocolVersion(), version >= 3 {
      error = await helper.setDNSServers(service: service, servers: servers)
    } else {
      // killall 在 mDNSResponder 恰好重启时可能返回非 0，不视为失败
      let shell =
        DNSConfiguration.shellCommand(service: service, servers: servers)
        + " && /usr/bin/dscacheutil -flushcache && (/usr/bin/killall -HUP mDNSResponder || true)"
      error = await Self.runWithAdministratorPrompt(
        shell: shell, prompt: tr("XStats 需要管理员权限来修改“\(service)”的 DNS。"))
    }
    if let error {
      Log.network.error("设置 DNS 失败：\(String(error.prefix(500)), privacy: .private)")
      dnsOutcome = Outcome(text: error, isError: error != Self.cancelled)
    } else {
      dnsOutcome = Outcome(
        text: servers.isEmpty
          ? tr("已恢复自动获取 DNS") : tr("DNS 已设置为 \(servers.joined(separator: tr("、")))"), isError: false
      )
    }
  }

  nonisolated static var cancelled: String { tr("已取消") }

  /// 未安装辅助工具时的回退：通过 AppleScript 请求一次性管理员授权执行命令。
  /// 命令只由固定路径与已校验的参数拼成，这里再做 AppleScript 字符串转义
  static func runWithAdministratorPrompt(shell: String, prompt: String) async -> String? {
    let escape = { (text: String) in
      text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
    let script =
      "do shell script \"\(escape(shell))\" with administrator privileges with prompt \"\(escape(prompt))\""
    return await Task.detached {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", script]
      let errorPipe = Pipe()
      process.standardError = errorPipe
      process.standardOutput = Pipe()
      do {
        try process.run()
      } catch {
        return error.localizedDescription
      }
      let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus != 0 else { return nil }
      let message = String(decoding: data, as: UTF8.self)
      // -128：用户在授权对话框中点了取消
      return message.contains("-128")
        ? cancelled : message.trimmingCharacters(in: .whitespacesAndNewlines)
    }.value
  }
}
