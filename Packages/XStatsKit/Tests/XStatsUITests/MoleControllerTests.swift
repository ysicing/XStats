// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Foundation
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct MoleControllerTests {
  @Test func preinstallDetectionCannotOverwriteInstalledMole() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let detections = MoleCommands()
    let gate = MoleRunGate()
    let controller = MoleController(
      settings: fixture.settings,
      detect: {
        if await detections.values.isEmpty {
          await detections.append(.scan)
          await gate.wait()
          return nil
        }
        return URL(fileURLWithPath: "/fixture/mo")
      },
      findBrew: { URL(fileURLWithPath: "/fixture/brew") },
      run: { _, _, _ in 0 })
    let refresh = Task { await controller.refreshAvailability() }
    await gate.waitForStart()
    controller.install()
    await controller.waitForExit()
    #expect(controller.executable?.path == "/fixture/mo")
    await gate.release()
    await refresh.value
    #expect(controller.executable?.path == "/fixture/mo")
    #expect(!controller.canInstall && controller.canExecute)
  }

  @Test(arguments: [MoleController.Workflow.clean, .optimize])
  func homebrewWritesAndMoleCommandsAreMutuallyExclusive(workflow: MoleController.Workflow)
    async throws
  {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let operations = HomebrewOperationState()
    let commands = MoleCommands()
    let gate = MoleRunGate()
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      homebrewOperations: operations,
      run: { _, command, _ in
        await commands.append(command)
        if !command.isPreview { await gate.wait() }
        return 0
      })
    await controller.refreshAvailability()
    controller.selectWorkflow(workflow)
    #expect(operations.begin())
    #expect(!controller.canStart)
    controller.scan()
    #expect(!controller.isRunning)
    operations.finish()
    await controller.waitForExit()
    controller.scan()
    await controller.waitForExit()
    #expect(operations.begin())
    controller.requestExecution()
    #expect(!controller.isConfirming)
    operations.finish()
    controller.requestExecution()
    #expect(controller.isConfirming)
    #expect(operations.begin())
    controller.confirmExecution()
    #expect(!controller.isRunning)
    operations.finish()
    controller.confirmExecution()
    await gate.waitForStart()
    #expect(operations.isRunning)
    #expect(!operations.begin())
    controller.cancel()
    #expect(operations.isRunning)
    await gate.release()
    await controller.waitForExit()
    #expect(controller.wasCancelled && !operations.isRunning)
    #expect(await commands.values == [workflow.previewCommand, workflow.executionCommand])
  }

  @Test(arguments: [MoleController.Workflow.clean, .optimize], [false, true])
  func previewKeepsHomebrewLockUntilSuccessOrFailure(
    workflow: MoleController.Workflow, fails: Bool
  ) async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let operations = HomebrewOperationState()
    let gate = MoleRunGate()
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      homebrewOperations: operations,
      run: { _, _, _ in
        await gate.wait()
        if fails { throw CocoaError(.fileReadUnknown) }
        return 0
      })
    await controller.refreshAvailability()
    controller.selectWorkflow(workflow)
    controller.scan()
    await gate.waitForStart()
    #expect(operations.isRunning && !controller.canStart)
    #expect(!operations.begin())
    await gate.release()
    await controller.waitForExit()
    #expect(!operations.isRunning && controller.canStart)
    #expect(controller.canExecute)
    #expect((controller.failure != nil) == fails)
  }

  @Test func installationStreamsLogsAndDetectsMoleOnlyAfterCompletion() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let commands = MoleCommands()
    let gate = MoleRunGate()
    let operations = HomebrewOperationState()
    let controller = MoleController(
      settings: fixture.settings,
      detect: {
        await commands.values.contains(.install) ? URL(fileURLWithPath: "/fixture/mo") : nil
      },
      findBrew: { URL(fileURLWithPath: "/fixture/brew") },
      homebrewOperations: operations,
      run: { url, command, output in
        #expect(url.path == "/fixture/brew" && command == .install)
        await commands.append(command)
        await output(MoleOutput(text: "Installing\n", wasTruncated: false))
        await gate.wait()
        return 0
      })
    controller.install()
    await gate.waitForStart()
    #expect(controller.isRunning && operations.isRunning)
    #expect(controller.output == "Installing\n" && controller.executable == nil)
    #expect(!operations.begin())
    controller.install()
    controller.scan()
    controller.selectWorkflow(.optimize)
    controller.cancelPreview()
    #expect(!controller.isCancelling)
    await gate.release()
    await controller.waitForExit()
    #expect(await commands.values == [.install])
    #expect(controller.executable?.path == "/fixture/mo")
    #expect(controller.exitStatus == 0 && controller.canExecute && !operations.isRunning)
    controller.install()
    #expect(!controller.isRunning)
    #expect(await commands.values == [.install])
  }

  @Test func cancellingPostInstallDetectionRejectsLateResult() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let gate = MoleRunGate()
    let operations = HomebrewOperationState()
    let controller = MoleController(
      settings: fixture.settings,
      detect: {
        await gate.wait()
        return URL(fileURLWithPath: "/fixture/mo")
      },
      findBrew: { URL(fileURLWithPath: "/fixture/brew") },
      homebrewOperations: operations, run: { _, _, _ in 0 })
    controller.install()
    await gate.waitForStart()
    controller.cancel()
    #expect(controller.isRunning && operations.isRunning)
    await gate.release()
    await controller.waitForExit()
    #expect(controller.wasCancelled && controller.executable == nil && controller.exitStatus == nil)
    #expect(!controller.canExecute && !operations.isRunning)
  }

  @Test func installationLaunchFailureReleasesHomebrewLock() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let operations = HomebrewOperationState()
    let controller = MoleController(
      settings: fixture.settings, detect: { nil },
      findBrew: { URL(fileURLWithPath: "/fixture/brew") },
      homebrewOperations: operations,
      run: { _, _, _ in throw CocoaError(.fileNoSuchFile) })
    controller.install()
    await controller.waitForExit()
    #expect(controller.failure != nil && controller.exitStatus == nil && !controller.canExecute)
    #expect(!controller.isRunning && !operations.isRunning && controller.canInstall)
  }

  @Test func installationCancellationKeepsLockUntilExitAndRejectsLateSuccess() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let gate = MoleRunGate()
    let operations = HomebrewOperationState()
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      findBrew: { URL(fileURLWithPath: "/fixture/brew") },
      homebrewOperations: operations,
      run: { _, _, output in
        await gate.wait()
        await output(MoleOutput(text: "late", wasTruncated: false))
        return 0
      })
    controller.install()
    await gate.waitForStart()
    controller.cancel()
    #expect(controller.isRunning && controller.isCancelling && operations.isRunning)
    await gate.release()
    await controller.waitForExit()
    #expect(controller.wasCancelled && controller.executable == nil && controller.output.isEmpty)
    #expect(controller.exitStatus == nil && !operations.isRunning)
  }

  @Test func installationRequiresHomebrewEnabledFeatureAndIdleOperations() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let commands = MoleCommands()
    let operations = HomebrewOperationState()
    var available = false
    let controller = MoleController(
      settings: fixture.settings, detect: { nil },
      findBrew: { available ? URL(fileURLWithPath: "/fixture/brew") : nil },
      homebrewOperations: operations,
      run: { _, command, _ in
        await commands.append(command)
        return 0
      })
    controller.install()
    #expect(!controller.isRunning)
    available = true
    #expect(operations.begin())
    controller.install()
    #expect(!controller.isRunning)
    operations.finish()
    fixture.settings.cleanerEnabled = false
    controller.install()
    #expect(!controller.isRunning)
    fixture.settings.cleanerEnabled = true
    controller.nativeIsBusy = { true }
    controller.install()
    #expect(!controller.isRunning)
    #expect(await commands.values.isEmpty)
  }

  @Test(arguments: [Int32(0), 7])
  func unsuccessfulInstallationDoesNotEnableMole(status: Int32) async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let operations = HomebrewOperationState()
    let controller = MoleController(
      settings: fixture.settings, detect: { nil },
      findBrew: { URL(fileURLWithPath: "/fixture/brew") },
      homebrewOperations: operations, run: { _, _, _ in status })
    controller.install()
    await controller.waitForExit()
    #expect(controller.executable == nil && !controller.canExecute && !operations.isRunning)
    #expect(controller.exitStatus == status)
    if status == 0 { #expect(controller.failure != nil) }
  }

  @Test(arguments: [MoleController.Workflow.clean, .optimize])
  func nativeMaintenanceBlocksPreviewAndRechecksExecutionConfirmation(
    workflow: MoleController.Workflow
  ) async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let gate = MoleRunGate()
    let maintenance = MaintenanceController(
      helper: HelperClient(teamIdentifier: nil, service: SystemHelperRegistration()),
      resetThumbnailCache: { await gate.wait() })
    let commands = MoleCommands()
    let mole = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, command, _ in
        await commands.append(command)
        return 0
      })
    mole.nativeIsBusy = { maintenance.isBusy }
    await mole.refreshAvailability()
    mole.selectWorkflow(workflow)
    mole.scan()
    await mole.waitForExit()
    mole.requestExecution()
    #expect(mole.isConfirming)

    let reset = Task { await maintenance.resetThumbnails() }
    await gate.waitForStart()
    mole.confirmExecution()
    mole.scan()
    #expect(!mole.isRunning)
    #expect(await commands.values == [workflow.previewCommand])
    mole.cancelConfirmation()
    mole.requestExecution()
    #expect(!mole.isConfirming)

    await gate.release()
    await reset.value
    mole.requestExecution()
    mole.confirmExecution()
    await mole.waitForExit()
    #expect(await commands.values == [workflow.previewCommand, workflow.executionCommand])
  }

  @Test func moleBlocksMaintenanceUntilCancellationActuallyFinishes() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let gate = MoleRunGate()
    let mole = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, _, _ in
        await gate.wait()
        return 0
      })
    let maintenance = MaintenanceController(
      helper: HelperClient(teamIdentifier: nil, service: SystemHelperRegistration()),
      resetThumbnailCache: {})
    maintenance.moleIsRunning = { mole.isRunning }
    await mole.refreshAvailability()
    mole.scan()
    await gate.waitForStart()
    await maintenance.resetThumbnails()
    #expect(maintenance.thumbnailOutcome == nil)
    mole.cancel()
    await maintenance.resetThumbnails()
    await maintenance.run(.purgeMemory)
    await maintenance.run(.flushDNS)
    // 无效地址不会触发真实系统操作，但互斥应先于参数处理直接返回。
    await maintenance.setDNSServers(["invalid"], service: "")
    #expect(maintenance.thumbnailOutcome == nil && maintenance.dnsOutcome == nil)
    #expect(maintenance.outcomes.isEmpty && maintenance.running == nil)
    #expect(mole.isRunning && mole.isCancelling)
    await gate.release()
    await mole.waitForExit()
    await maintenance.resetThumbnails()
    #expect(maintenance.thumbnailOutcome?.isError == false)
  }

  @Test func switchingWorkflowClearsLogAndPendingConfirmation() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let commands = MoleCommands()
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, command, _ in
        await commands.append(command)
        return 0
      })
    await controller.refreshAvailability()
    controller.scan()
    await controller.waitForExit()
    controller.requestExecution()
    controller.selectWorkflow(.optimize)
    #expect(controller.canExecute && !controller.isConfirming && controller.lastCommand == nil)
    controller.confirmExecution()
    #expect(await commands.values == [.scan])
    controller.scan()
    await controller.waitForExit()
    #expect(controller.canExecute)
    controller.confirmExecution()
    #expect(await commands.values == [.scan, .optimizePreview])
    controller.requestExecution()
    controller.confirmExecution()
    await controller.waitForExit()
    #expect(await commands.values == [.scan, .optimizePreview, .optimize])
  }

  @Test func switchingWorkflowCancelsRunningCommandAndRejectsLateOutput() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let gate = MoleRunGate()
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, _, output in
        await gate.wait()
        await output(MoleOutput(text: "late", wasTruncated: false))
        return 0
      })
    await controller.refreshAvailability()
    controller.selectWorkflow(.optimize)
    controller.scan()
    controller.selectWorkflow(.clean)
    controller.scan()
    #expect(controller.isRunning && controller.isCancelling)
    await gate.release()
    await controller.waitForExit()
    #expect(controller.canExecute && controller.exitStatus == nil && controller.output.isEmpty)
    #expect(controller.workflow == .clean)
  }

  @Test(arguments: [MoleController.Workflow.clean, .optimize])
  func leavingStopsPreviewButLetsExecutionFinish(workflow: MoleController.Workflow) async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let execution = MoleRunGate()
    let preview = MoleRunGate()
    let previews = MoleCommands()
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, command, _ in
        if command.isPreview {
          // 首次预览直接成功，第二次预览阻塞以验证离开时被停止。
          await previews.append(command)
          if await previews.values.count > 1 { await preview.wait() }
        } else {
          await execution.wait()
        }
        return 0
      })
    await controller.refreshAvailability()
    controller.selectWorkflow(workflow)
    controller.scan()
    await controller.waitForExit()
    controller.requestExecution()
    controller.cancelPreview()
    #expect(!controller.isConfirming)

    controller.requestExecution()
    controller.confirmExecution()
    await execution.waitForStart()
    controller.cancelPreview()
    #expect(controller.isRunning && !controller.isCancelling)
    await execution.release()
    await controller.waitForExit()
    #expect(!controller.wasCancelled && controller.exitStatus == 0)

    controller.scan()
    await preview.waitForStart()
    controller.cancelPreview()
    #expect(controller.isRunning && controller.isCancelling)
    await preview.release()
    await controller.waitForExit()
    #expect(controller.wasCancelled && controller.canExecute)
  }

  @Test func moleExecutionInvalidatesNativeScanButPreviewDoesNot() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let mole = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, _, _ in 0 })
    let cleaner = CleanerController(settings: fixture.settings, mole: mole)
    await mole.refreshAvailability()
    cleaner.showPreview([])
    mole.scan()
    await mole.waitForExit()
    #expect(cleaner.lastScan != nil && cleaner.phase == .ready)
    mole.requestExecution()
    mole.confirmExecution()
    await mole.waitForExit()
    // 旧候选不能在切回原生引擎后被当作当前状态；nil 使 scan(ifNeeded:) 重新扫描。
    #expect(cleaner.lastScan == nil && cleaner.phase == .idle && cleaner.scans.isEmpty)
  }

  @Test(arguments: [MoleController.Workflow.clean, .optimize])
  func executionWithoutPreviewRequiresExplicitConfirmation(
    workflow: MoleController.Workflow
  ) async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let commands = MoleCommands()
    let controller = MoleController(
      settings: fixture.settings,
      detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, command, _ in
        await commands.append(command)
        return 0
      })
    await controller.refreshAvailability()
    controller.selectWorkflow(workflow)
    controller.confirmExecution()
    #expect(await commands.values.isEmpty)
    controller.requestExecution()
    #expect(controller.isConfirming)
    #expect(await commands.values.isEmpty)
    controller.confirmExecution()
    await controller.waitForExit()
    #expect(await commands.values == [workflow.executionCommand])
    #expect(controller.canExecute && !controller.isConfirming)
    controller.confirmExecution()
    await controller.waitForExit()
    #expect(await commands.values == [workflow.executionCommand])
  }

  @Test(arguments: [MoleCommand.scan, .optimizePreview, .clean, .optimize])
  func cancellationKeepsBusyUntilRunnerReturnsAndRejectsLateSuccess(command: MoleCommand)
    async throws
  {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let gate = MoleRunGate()
    let commands = MoleCommands()
    let operations = HomebrewOperationState()
    let controller = MoleController(
      settings: fixture.settings,
      detect: { URL(fileURLWithPath: "/fixture/mo") },
      homebrewOperations: operations,
      run: { _, command, output in
        await commands.append(command)
        await gate.wait()
        await output(MoleOutput(text: "late", wasTruncated: false))
        return 0
      })
    await controller.refreshAvailability()
    controller.selectWorkflow(command == .scan || command == .clean ? .clean : .optimize)
    if command.isPreview {
      controller.scan()
    } else {
      controller.requestExecution()
      controller.confirmExecution()
    }
    await gate.waitForStart()
    #expect(controller.lastCommand == command && operations.isRunning)
    controller.cancel()
    #expect(controller.isRunning && controller.isCancelling && !controller.canExecute)
    // 直接执行同样须等 runner 收尾，期间不能通过任一入口启动第二条命令。
    controller.scan()
    controller.requestExecution()
    controller.confirmExecution()
    #expect(!controller.isConfirming && operations.isRunning)
    #expect(await commands.values == [command])
    await gate.release()
    await controller.waitForExit()
    #expect(!controller.isRunning && controller.wasCancelled && !operations.isRunning)
    #expect(controller.exitStatus == nil && controller.canExecute && controller.output.isEmpty)
  }

  @Test(arguments: [MoleController.Workflow.clean, .optimize])
  func missingExecutableAndDisabledFeatureBlockCommands(
    workflow: MoleController.Workflow
  ) async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let commands = MoleCommands()
    let missing = MoleController(settings: fixture.settings, detect: { nil })
    await missing.refreshAvailability()
    missing.selectWorkflow(workflow)
    missing.scan()
    #expect(missing.executable == nil && !missing.isRunning)
    missing.requestExecution()
    missing.confirmExecution()
    #expect(!missing.isConfirming && !missing.isRunning)
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, command, _ in
        await commands.append(command)
        return 7
      })
    await controller.refreshAvailability()
    controller.selectWorkflow(workflow)
    controller.scan()
    await controller.waitForExit()
    #expect(controller.exitStatus == 7 && controller.canExecute)
    controller.requestExecution()
    controller.confirmExecution()
    await controller.waitForExit()
    #expect(await commands.values == [workflow.previewCommand, workflow.executionCommand])
    fixture.settings.cleanerEnabled = false
    controller.scan()
    controller.requestExecution()
    controller.confirmExecution()
    #expect(!controller.isConfirming && !controller.isRunning)
    #expect(await commands.values == [workflow.previewCommand, workflow.executionCommand])
  }

  @Test func replacingExecutableRequiresNewConfirmation() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let detections = MoleCommands()
    let commands = MoleCommands()
    let controller = MoleController(
      settings: fixture.settings,
      detect: {
        let path = await detections.values.isEmpty ? "/fixture/mo" : "/replacement/mo"
        await detections.append(.scan)
        return URL(fileURLWithPath: path)
      },
      run: { _, command, _ in
        await commands.append(command)
        return 0
      })
    await controller.refreshAvailability()
    controller.requestExecution()
    #expect(controller.isConfirming)
    await controller.refreshAvailability()
    #expect(!controller.isConfirming && controller.canExecute)
    controller.confirmExecution()
    await controller.waitForExit()
    #expect(await commands.values.isEmpty)
    controller.requestExecution()
    controller.confirmExecution()
    await controller.waitForExit()
    #expect(await commands.values == [.clean])
  }

  @Test(arguments: [MoleController.Workflow.clean, .optimize])
  func idleCommandsUseCompactHeightWithoutStartingWork(workflow: MoleController.Workflow)
    async throws
  {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, _, _ in
        Issue.record("Rendering must not launch a command")
        return 0
      })
    await controller.refreshAvailability()
    controller.selectWorkflow(workflow)
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let view = MoleCommandView(controller: controller, nativeBusy: false)
        .environment(\.layoutDirection, direction)
        .environment(\.isSnapshot, true)
        .preferredColorScheme(.light)
      let compact = NSHostingView(rootView: view.frame(width: 860))
      #expect(compact.fittingSize.height > 40 && compact.fittingSize.height < 160)
      #expect(controller.lastCommand == nil && !controller.isRunning && controller.canExecute)
      if let path = ProcessInfo.processInfo.environment["XSTATS_CLEANER_PREVIEW_DIR"] {
        let host = NSHostingView(
          rootView: view.frame(width: 860, height: 600, alignment: .topLeading)
            .background(DS.Palette.background))
        #expect(host.fittingSize == NSSize(width: 860, height: 600))
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "mole-idle-\(workflow)-\(direction == .leftToRight ? "ltr" : "rtl").png"
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: directory.appendingPathComponent(name))
      }
    }
  }

  @Test func engineRequiresInstalledMoleAndDoesNotStartNativeScan() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let mole = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, _, _ in 0 })
    let cleaner = CleanerController(settings: fixture.settings, mole: mole)
    cleaner.selectEngine(.mole)
    #expect(cleaner.engine == .native)
    await mole.refreshAvailability()
    cleaner.selectEngine(.mole)
    #expect(cleaner.engine == .mole)
    cleaner.scan()
    #expect(cleaner.phase == .idle)
    cleaner.selectEngine(.native)
    #expect(cleaner.engine == .native)
  }

  @Test(arguments: [MoleCommand.scan, .optimizePreview, .install])
  func consoleRendersLongOutputInBothDirectionsWithoutLaunchingCommands(
    command: MoleCommand
  ) async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      findBrew: { URL(fileURLWithPath: "/fixture/brew") },
      run: { _, _, output in
        await output(
          MoleOutput(
            text: String(repeating: "Mole · Bereinigung · تنظيف · 扫描\n", count: 500),
            wasTruncated: true))
        return 0
      })
    if command == .install {
      controller.install()
    } else {
      await controller.refreshAvailability()
      controller.selectWorkflow(command == .scan ? .clean : .optimize)
      controller.scan()
    }
    await controller.waitForExit()
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let host = NSHostingView(
        rootView: MoleCommandView(
          controller: controller, nativeBusy: false, installation: command == .install
        )
        .environment(\.layoutDirection, direction)
        .environment(\.isSnapshot, true)
        .preferredColorScheme(.light)
        .frame(width: 860, height: 600)
        .background(DS.Palette.background))
      #expect(host.fittingSize == NSSize(width: 860, height: 600))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
        styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.appearance = NSAppearance(named: .aqua)
      window.contentView = host
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      if let path = ProcessInfo.processInfo.environment["XSTATS_CLEANER_PREVIEW_DIR"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "mole-\(command)-\(direction == .leftToRight ? "ltr" : "rtl").png"
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: directory.appendingPathComponent(name))
      }
    }
    #expect(controller.exitStatus == 0 && !controller.isRunning)
  }

  @Test(arguments: [LayoutDirection.leftToRight, .rightToLeft])
  func completedLogInitiallyFollowsOutput(direction: LayoutDirection) async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, _, output in
        await output(
          MoleOutput(
            text: (1...500).map { "line \($0)" }.joined(separator: "\n"),
            wasTruncated: false))
        return 0
      })
    await controller.refreshAvailability()
    controller.scan()
    await controller.waitForExit()
    let host = NSHostingView(
      rootView: MoleCommandView(controller: controller, nativeBusy: false)
        .environment(\.layoutDirection, direction)
        .environment(\.isSnapshot, true)
        .frame(width: 860, height: 600))
    #expect(host.fittingSize == NSSize(width: 860, height: 600))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    var pending: [NSView] = [host]
    var scroll: NSScrollView?
    while let view = pending.popLast() {
      if let candidate = view as? NSScrollView {
        scroll = candidate
        break
      }
      pending.append(contentsOf: view.subviews)
    }
    let log = try #require(scroll)
    let document = try #require(log.documentView)
    // scrollTo 的锚点在末行之后，文档底部还保留 s3 内边距。
    let endOfOutput = document.bounds.maxY - DS.Space.s3
    let deadline = ContinuousClock.now + .seconds(2)
    while log.documentVisibleRect.maxY < endOfOutput - 2,
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
      host.layoutSubtreeIfNeeded()
    }
    #expect(document.bounds.height > log.documentVisibleRect.height)
    #expect(log.documentVisibleRect.maxY >= endOfOutput - 2)
  }
}

private actor MoleCommands {
  var values: [MoleCommand] = []
  func append(_ command: MoleCommand) { values.append(command) }
}

private actor MoleRunGate {
  var continuation: CheckedContinuation<Void, Never>?
  var started: CheckedContinuation<Void, Never>?
  var didStart = false
  var released = false
  func wait() async {
    didStart = true
    started?.resume()
    started = nil
    guard !released else { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func waitForStart() async {
    guard !didStart else { return }
    await withCheckedContinuation { started = $0 }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

@MainActor
private struct MoleControllerFixture {
  let suite = "MoleControllerTests.\(UUID())"
  let defaults: UserDefaults
  let settings: AppSettings
  init() throws {
    defaults = try #require(UserDefaults(suiteName: suite))
    settings = AppSettings(defaults: defaults)
    settings.cleanerEnabled = true
  }
  func remove() { defaults.removePersistentDomain(forName: suite) }
}
