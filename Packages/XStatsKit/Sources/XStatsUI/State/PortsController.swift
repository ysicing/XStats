// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Localization
import Metrics

/// 端口页的数据：只在功能开启且页面可见时每 3 秒读取一次 socket 与按进程速率，
/// 窗口隐藏、切到其他页、锁屏或休眠时停止；关闭功能后清空结果。
@MainActor
@Observable
final class PortsController {
  private(set) var sockets: [PortSocket] = []
  private(set) var rates: [Int32: NetworkProcessRate] = [:]
  private(set) var conflicts: Set<UInt64> = []
  private(set) var hasLoaded = false
  /// 系统拒绝列出进程时为 true，界面显示读取失败而不是空列表
  private(set) var failed = false

  @ObservationIgnored private var enabled = false
  @ObservationIgnored private var visible = false
  @ObservationIgnored private var paused = false
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var rateSampler = NetworkProcessSampler()

  static let interval: Duration = .seconds(3)

  func setDemand(enabled: Bool, visible: Bool) {
    guard enabled != self.enabled || visible != self.visible else { return }
    self.enabled = enabled
    self.visible = visible
    if !enabled {
      sockets = []
      rates = [:]
      conflicts = []
      hasLoaded = false
      failed = false
    }
    apply()
  }

  func setPaused(_ paused: Bool) {
    guard paused != self.paused else { return }
    self.paused = paused
    apply()
  }

  /// 立即重新读取：取消当前等待并重新开始循环；页面不可见时不做任何事。
  func refresh() {
    guard task != nil else { return }
    task?.cancel()
    task = nil
    apply()
  }

  private func apply() {
    let shouldRun = enabled && visible && !paused
    guard shouldRun != (task != nil) else { return }
    task?.cancel()
    task = nil
    // 停止后丢弃速率基线：隔了很久的两次读数只能得到失真的平均值
    guard shouldRun else {
      rateSampler = NetworkProcessSampler()
      rates = [:]
      return
    }
    task = Task { [weak self] in
      let clock = ContinuousClock()
      while !Task.isCancelled {
        guard let self else { return }
        let started = clock.now
        let sampler = self.rateSampler
        let sampling = Task.detached { [sampler] in
          var copy = sampler
          let rates = copy.sampleRates()
          return (PortSampler.sample(), rates, copy)
        }
        let (sockets, rates, next) = await withTaskCancellationHandler {
          await sampling.value
        } onCancel: {
          sampling.cancel()
        }
        guard !Task.isCancelled else { return }
        self.publish(sockets: sockets, rates: rates, sampler: next)
        do {
          try await Task.sleep(
            until: started + Self.interval, tolerance: .milliseconds(500), clock: clock)
        } catch {
          return
        }
      }
    }
  }

  /// 截图演示：直接写入匿名示例，不启动采样
  func showDemo(sockets: [PortSocket], rates: [Int32: NetworkProcessRate]) {
    self.sockets = sockets
    self.rates = rates
    conflicts = PortSampler.conflictingSocketIDs(sockets)
    hasLoaded = true
    failed = false
  }

  func publish(
    sockets: [PortSocket]?, rates: [Int32: NetworkProcessRate]?, sampler: NetworkProcessSampler
  ) {
    // 失败后重建速率基线，不把旧区间读数挂到新连接或复用的 PID 上。
    rateSampler = rates == nil ? NetworkProcessSampler() : sampler
    guard let sockets else {
      if !failed { Log.network.error("Cannot enumerate processes for port listing") }
      failed = true
      hasLoaded = true
      self.sockets = []
      self.rates = [:]
      conflicts = []
      return
    }
    if failed { Log.network.notice("Port listing recovered") }
    failed = false
    hasLoaded = true
    self.rates = rates ?? [:]
    guard sockets != self.sockets else { return }
    self.sockets = sockets
    conflicts = PortSampler.conflictingSocketIDs(sockets)
  }
}

// MARK: - 结束进程

enum PortActions {
  /// 不能从端口页结束的原因；与进程页使用相同的保护规则，nil 表示可以结束
  static func quitBlockedReason(_ socket: PortSocket) -> String? {
    if socket.uid == 0 || socket.uid != getuid() { return tr("系统或其他用户的进程，XStats 不提供结束") }
    if socket.pid == getpid() { return tr("请从菜单退出 XStats") }
    if ProcessActions.protectedNames.contains(socket.name) { return tr("结束它会注销当前用户，已禁止") }
    return nil
  }

  /// 只结束占用端口的这一个进程：应用主进程走应用退出，给它保存的机会；
  /// 辅助进程直接发信号，不连带退出整个应用。返回错误描述，nil 表示已发出结束请求。
  @MainActor
  static func terminate(_ socket: PortSocket, force: Bool) -> String? {
    if let reason = quitBlockedReason(socket) { return reason }
    // 确认框可能开了很久：目标退出后 PID 会被回收复用，不再持有原 socket 就不能按旧快照发信号
    guard PortSampler.holdsSocket(pid: socket.pid, socketID: socket.socketID) else {
      return tr("进程已退出或不再占用该端口，请刷新后重试")
    }
    if let app = NSRunningApplication(processIdentifier: socket.pid) {
      let sent = force ? app.forceTerminate() : app.terminate()
      Log.app.notice(
        "Requested app quit for port owner pid \(socket.pid, privacy: .public), force=\(force, privacy: .public), sent=\(sent, privacy: .public)"
      )
      return sent ? nil : tr("应用拒绝退出，可以试试强制退出")
    }
    guard kill(socket.pid, force ? SIGKILL : SIGTERM) == 0 else {
      let code = errno
      Log.app.error(
        "Cannot signal port owner pid \(socket.pid, privacy: .public), errno=\(code, privacy: .public)"
      )
      return tr("结束 \(socket.name) 失败：\(String(cString: strerror(code)))")
    }
    Log.app.notice(
      "Signaled port owner pid \(socket.pid, privacy: .public), force=\(force, privacy: .public)")
    return nil
  }
}
