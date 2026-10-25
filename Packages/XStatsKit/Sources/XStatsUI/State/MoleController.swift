// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
import Localization
import Observation

@MainActor
@Observable
final class MoleController {
  enum Workflow {
    case clean, optimize

    var previewCommand: MoleCommand { self == .clean ? .scan : .optimizePreview }
    var executionCommand: MoleCommand { self == .clean ? .clean : .optimize }
  }

  typealias Runner =
    @Sendable (URL, MoleCommand, @Sendable (MoleOutput) async -> Void) async throws -> Int32

  private(set) var executable: URL?
  private(set) var operation: MoleCommand?
  private(set) var lastCommand: MoleCommand?
  private(set) var output = ""
  private(set) var outputWasTruncated = false
  private(set) var exitStatus: Int32?
  private(set) var failure: String?
  private(set) var wasCancelled = false
  private(set) var isCancelling = false
  private(set) var workflow: Workflow = .clean
  var isConfirming = false

  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let detect: @Sendable () async -> URL?
  @ObservationIgnored private let findBrew: () -> URL?
  private let homebrewOperations: HomebrewOperationState
  @ObservationIgnored private let run: Runner
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var pendingExecutable: URL?
  @ObservationIgnored private var availabilityGeneration = UUID()
  @ObservationIgnored var nativeIsBusy: () -> Bool = { false }
  /// 真实执行（含取消或失败，可能已部分生效）结束后通知，原生扫描结果据此失效。
  @ObservationIgnored var onExecutionFinished: () -> Void = {}

  init(
    settings: AppSettings,
    detect: @escaping @Sendable () async -> URL? = { await MoleRunner.detect() },
    findBrew: @escaping () -> URL? = { MoleRunner.homebrewExecutable },
    homebrewOperations: HomebrewOperationState = HomebrewOperationState(),
    run: @escaping Runner = { url, command, output in
      try await MoleRunner.run(executable: url, command: command, output: output)
    }
  ) {
    self.settings = settings
    self.detect = detect
    self.findBrew = findBrew
    self.homebrewOperations = homebrewOperations
    self.run = run
  }

  var isRunning: Bool { operation != nil }
  var canStart: Bool {
    settings.cleanerEnabled && !isRunning && !nativeIsBusy() && !homebrewOperations.isRunning
  }
  var canExecute: Bool { canStart && executable != nil }
  var brewAvailable: Bool { findBrew() != nil }
  var canInstall: Bool {
    canStart && executable == nil && brewAvailable
  }

  func refreshAvailability() async {
    guard !isRunning else { return }
    let generation = UUID()
    availabilityGeneration = generation
    let found = await detect()
    guard !Task.isCancelled, !isRunning, availabilityGeneration == generation else { return }
    if found != executable {
      cancelConfirmation()
    }
    executable = found
  }

  func selectWorkflow(_ workflow: Workflow) {
    guard operation != .install, self.workflow != workflow else { return }
    cancel()
    self.workflow = workflow
    // Tab 变化须撤销待执行确认，也不能显示另一种操作的延迟输出。
    output = ""
    outputWasTruncated = false
    if !isRunning {
      lastCommand = nil
      exitStatus = nil
      failure = nil
      wasCancelled = false
    }
  }

  func scan() { start(workflow.previewCommand) }
  func install() { start(.install) }

  func requestExecution() {
    guard canExecute, let executable else {
      return
    }
    pendingExecutable = executable
    isConfirming = true
  }

  func cancelConfirmation() {
    pendingExecutable = nil
    isConfirming = false
  }

  func confirmExecution() {
    guard canExecute,
      let pendingExecutable, pendingExecutable == executable
    else { return }
    start(workflow.executionCommand)
  }

  func cancel() {
    cancelConfirmation()
    guard isRunning else { return }
    isCancelling = true
    task?.cancel()
  }

  /// 离开页面、隐藏窗口或暂停时调用：只读预览随之停止；真实执行与原生清理一致继续运行，
  /// 中途终止会留下已部分生效的修改。关闭功能和退出应用仍使用 `cancel()`。
  func cancelPreview() {
    cancelConfirmation()
    guard operation?.isPreview == true else { return }
    cancel()
  }

  func waitForExit() async { await task?.value }

  private func start(_ command: MoleCommand) {
    guard canStart else { return }
    let executable: URL
    if command == .install {
      guard canInstall, let brew = findBrew() else { return }
      executable = brew
    } else {
      guard let mole = self.executable else { return }
      executable = mole
    }
    // Mole 清理内部也会调用 brew；预览与包管理操作共用状态，直至进程退出才释放。
    guard homebrewOperations.begin() else { return }
    availabilityGeneration = UUID()
    cancelConfirmation()
    operation = command
    lastCommand = command
    output = ""
    outputWasTruncated = false
    exitStatus = nil
    failure = nil
    wasCancelled = false
    isCancelling = false
    Log.app.info("Mole \(command.displayCommand, privacy: .public) started")
    task = Task {
      defer {
        homebrewOperations.finish()
        operation = nil
        isCancelling = false
        task = nil
        if !command.isPreview { onExecutionFinished() }
      }
      do {
        let status = try await run(executable, command) { [weak self] value in
          guard !Task.isCancelled else { return }
          await self?.receive(value)
        }
        try Task.checkCancellation()
        if command == .install, status == 0 {
          let found = await detect()
          try Task.checkCancellation()
          self.executable = found
          if found == nil {
            failure = tr("安装已结束，但未检测到 Mole。请查看日志后重新检测。")
          }
        }
        exitStatus = status
        Log.app.info("Mole exited with status \(status, privacy: .public)")
      } catch {
        if Task.isCancelled || error is CancellationError {
          wasCancelled = true
          Log.app.info("Mole operation stopped")
        } else {
          failure = error.localizedDescription
          Log.app.error(
            "Mole failed: \(String(error.localizedDescription.prefix(500)), privacy: .private)")
        }
      }
    }
  }

  private func receive(_ value: MoleOutput) {
    guard !isCancelling else { return }
    output = value.text
    outputWasTruncated = value.wasTruncated
  }
}
