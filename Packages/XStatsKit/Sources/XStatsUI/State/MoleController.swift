// SPDX-License-Identifier: AGPL-3.0-or-later

import Cleaner
import Foundation
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
  private(set) var canExecute = false
  private(set) var workflow: Workflow = .clean
  var isConfirming = false

  @ObservationIgnored private let settings: AppSettings
  @ObservationIgnored private let detect: @Sendable () async -> URL?
  @ObservationIgnored private let run: Runner
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var pendingExecutable: URL?
  @ObservationIgnored var nativeIsBusy: () -> Bool = { false }

  init(
    settings: AppSettings,
    detect: @escaping @Sendable () async -> URL? = { await MoleRunner.detect() },
    run: @escaping Runner = { url, command, output in
      try await MoleRunner.run(executable: url, command: command, output: output)
    }
  ) {
    self.settings = settings
    self.detect = detect
    self.run = run
  }

  var isRunning: Bool { operation != nil }

  func refreshAvailability() async {
    guard !isRunning else { return }
    let found = await detect()
    guard !Task.isCancelled, !isRunning else { return }
    if found != executable {
      canExecute = false
      cancelConfirmation()
    }
    executable = found
  }

  func selectWorkflow(_ workflow: Workflow) {
    guard self.workflow != workflow else { return }
    cancel()
    canExecute = false
    self.workflow = workflow
    // tab 变化不能复用另一种操作的预览，也不能显示其延迟输出。
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

  func requestExecution() {
    guard settings.cleanerEnabled, !isRunning, !nativeIsBusy(), canExecute, let executable else {
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
    guard settings.cleanerEnabled, !isRunning, !nativeIsBusy(), canExecute,
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

  func waitForExit() async { await task?.value }

  private func start(_ command: MoleCommand) {
    guard settings.cleanerEnabled, !isRunning, !nativeIsBusy(), let executable else { return }
    cancelConfirmation()
    operation = command
    lastCommand = command
    canExecute = false
    output = ""
    outputWasTruncated = false
    exitStatus = nil
    failure = nil
    wasCancelled = false
    isCancelling = false
    Log.app.info("Mole \(command.displayCommand, privacy: .public) started")
    task = Task {
      defer {
        operation = nil
        isCancelling = false
        task = nil
      }
      do {
        let status = try await run(executable, command) { [weak self] value in
          guard !Task.isCancelled else { return }
          await self?.receive(value)
        }
        try Task.checkCancellation()
        exitStatus = status
        canExecute = command == workflow.previewCommand && status == 0
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
