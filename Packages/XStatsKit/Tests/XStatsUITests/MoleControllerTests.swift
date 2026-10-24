// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Cleaner
import Foundation
import SwiftUI
import Testing
@testable import XStatsUI

@MainActor
struct MoleControllerTests {
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

  @Test func switchingWorkflowInvalidatesPreviewAndPendingConfirmation() async throws {
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
    #expect(!controller.canExecute && !controller.isConfirming && controller.lastCommand == nil)
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
    #expect(!controller.canExecute && controller.exitStatus == nil && controller.output.isEmpty)
    #expect(controller.workflow == .clean)
  }

  @Test(arguments: [MoleController.Workflow.clean, .optimize])
  func executionRequiresSuccessfulPreviewAndExplicitConfirmation(
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
    controller.scan()
    await controller.waitForExit()
    #expect(controller.canExecute && controller.exitStatus == 0)
    controller.confirmExecution()
    #expect(await commands.values == [workflow.previewCommand])
    controller.requestExecution()
    #expect(controller.isConfirming)
    controller.confirmExecution()
    await controller.waitForExit()
    #expect(await commands.values == [workflow.previewCommand, workflow.executionCommand])
    #expect(!controller.canExecute)
  }

  @Test func cancellationKeepsBusyUntilRunnerReturnsAndRejectsLateSuccess() async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let gate = MoleRunGate()
    let controller = MoleController(
      settings: fixture.settings,
      detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, _, output in
        await gate.wait()
        await output(MoleOutput(text: "late", wasTruncated: false))
        return 0
      })
    await controller.refreshAvailability()
    controller.scan()
    controller.cancel()
    #expect(controller.isRunning && controller.isCancelling)
    await gate.release()
    await controller.waitForExit()
    #expect(!controller.isRunning && controller.wasCancelled)
    #expect(controller.exitStatus == nil && !controller.canExecute && controller.output.isEmpty)
  }

  @Test(arguments: [MoleController.Workflow.clean, .optimize])
  func missingExecutableFailureAndDisabledFeatureCannotExecute(
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
    #expect(controller.exitStatus == 7 && !controller.canExecute)
    fixture.settings.cleanerEnabled = false
    controller.scan()
    #expect(await commands.values == [workflow.previewCommand])
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

  @Test(arguments: [MoleController.Workflow.clean, .optimize])
  func consoleRendersLongOutputInBothDirectionsWithoutLaunchingCommands(
    workflow: MoleController.Workflow
  ) async throws {
    let fixture = try MoleControllerFixture()
    defer { fixture.remove() }
    let controller = MoleController(
      settings: fixture.settings, detect: { URL(fileURLWithPath: "/fixture/mo") },
      run: { _, _, output in
        await output(
          MoleOutput(
            text: String(repeating: "Mole · Bereinigung · تنظيف · 扫描\n", count: 500),
            wasTruncated: true))
        return 0
      })
    await controller.refreshAvailability()
    controller.selectWorkflow(workflow)
    controller.scan()
    await controller.waitForExit()
    for direction in [LayoutDirection.leftToRight, .rightToLeft] {
      let host = NSHostingView(
        rootView: MoleCommandView(controller: controller, nativeBusy: false)
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
        let name = "mole-\(workflow)-\(direction == .leftToRight ? "ltr" : "rtl").png"
        try #require(bitmap.representation(using: .png, properties: [:])).write(
          to: directory.appendingPathComponent(name))
      }
    }
    #expect(controller.exitStatus == 0 && !controller.isRunning)
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
