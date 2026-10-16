// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import Testing
@testable import CaptureUI
@testable import XStatsUI

@MainActor struct CaptureIntegrationTests {
  @Test func discoveryPreservesChoiceAndSuccessfulSwitchPersistsAcrossRestart() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var launches = 0
    let integration = XStatsCapture(
      defaults: fixture.defaults,
      findApplications: { [fixture.app.appendingPathComponent("Removed.app"), fixture.app] },
      openApplication: { url in
        #expect(url == fixture.app)
        launches += 1
      })
    defer { integration.embedded.shortcuts.stop() }
    integration.useEmbedded()
    integration.refreshInstallation()
    #expect(integration.standaloneApplicationURL == fixture.app)
    #expect(integration.embedded.enabled && integration.embedded.shortcuts.enabled)
    #expect(!integration.prefersStandalone && launches == 0)

    await integration.openStandalone()
    #expect(launches == 1 && integration.prefersStandalone)
    #expect(!integration.embedded.enabled && !integration.embedded.shortcuts.enabled)
    #expect(!integration.embedded.hasActiveWorkspace && integration.issue == nil)
    let restored = XStatsCapture(defaults: fixture.defaults, findApplications: { [] })
    restored.embedded.startShortcuts()
    #expect(restored.prefersStandalone && !restored.embedded.shortcuts.enabled)
    await restored.openStandalone()
    #expect(restored.prefersStandalone && !restored.embedded.enabled)
    #expect(restored.issue == .missingApplication)
    restored.useEmbedded()
    defer { restored.embedded.shortcuts.stop() }
    #expect(restored.embedded.enabled && !restored.prefersStandalone)
    #expect(restored.issue == nil)
  }

  @Test func launchFailureRestoresEmbeddedChoiceAndShortcuts() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    let integration = XStatsCapture(
      defaults: fixture.defaults, findApplications: { [fixture.app] },
      openApplication: { _ in throw CocoaError(.fileReadNoSuchFile) })
    integration.useEmbedded()
    defer { integration.embedded.shortcuts.stop() }
    await integration.openStandalone()
    #expect(integration.issue == .launchFailed)
    #expect(integration.embedded.enabled && integration.embedded.shortcuts.enabled)
    #expect(!integration.prefersStandalone && !integration.isOpening)
    #expect(!fixture.defaults.bool(forKey: "capture.prefersStandalone"))
  }

  @Test func openWorkspaceBlocksSwitchWithoutDiscardingContent() async throws {
    _ = NSApplication.shared
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var launched = false
    let integration = XStatsCapture(
      defaults: fixture.defaults, findApplications: { [fixture.app] },
      openApplication: { _ in launched = true })
    integration.useEmbedded()
    integration.embedded.open()
    await integration.openStandalone()
    #expect(integration.issue == .workspaceOpen && !launched)
    #expect(integration.embedded.enabled && integration.embedded.hasActiveWorkspace)
    #expect(!integration.prefersStandalone)
    await integration.embedded.prepareForTermination()
    integration.embedded.cleanUp()
    integration.embedded.shortcuts.stop()
  }

  @Test(.timeLimit(.minutes(1))) func pendingLaunchRejectsDuplicateSwitchAndEmbeddedReactivation()
    async throws
  {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    var continuation: CheckedContinuation<Void, Never>?
    var launches = 0
    let (started, start) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let integration = XStatsCapture(
      defaults: fixture.defaults, findApplications: { [fixture.app] },
      openApplication: { _ in
        launches += 1
        start.yield(())
        start.finish()
        await withCheckedContinuation { continuation = $0 }
      })
    integration.useEmbedded()
    let opening = Task { await integration.openStandalone() }
    var events = started.makeAsyncIterator()
    await events.next()
    #expect(integration.isOpening && !integration.embedded.enabled)
    integration.useEmbedded()
    await integration.openStandalone()
    #expect(!integration.embedded.enabled && launches == 1)
    continuation?.resume()
    await opening.value
    #expect(integration.prefersStandalone && !integration.isOpening)
  }

  @Test func validatesBundleIdentityExecutableAndRemovedApplication() throws {
    let fixture = try Fixture()
    defer { fixture.cleanUp() }
    #expect(XStatsCapture.validatedStandaloneApplication(at: fixture.app) == fixture.app)
    #expect(
      XStatsCapture.validatedStandaloneApplication(
        at: URL(string: "https://example.com/Capture.app")!) == nil)
    let wrong = try Fixture(bundleID: "work.12306.other")
    defer { wrong.cleanUp() }
    #expect(XStatsCapture.validatedStandaloneApplication(at: wrong.app) == nil)
    try FileManager.default.removeItem(
      at: fixture.app.appendingPathComponent("Contents/MacOS/Capture"))
    #expect(XStatsCapture.validatedStandaloneApplication(at: fixture.app) == nil)
    try FileManager.default.removeItem(at: fixture.app)
    #expect(XStatsCapture.validatedStandaloneApplication(at: fixture.app) == nil)
  }

  @MainActor private struct Fixture {
    let suite = "XStats.CaptureIntegrationTests.\(UUID())"
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).app")
    let defaults: UserDefaults

    init(bundleID: String = XStatsCapture.standaloneBundleID) throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      try FileManager.default.createDirectory(
        at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
      let info = [
        "CFBundleIdentifier": bundleID, "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "Capture",
      ]
      try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
      let executable = app.appendingPathComponent("Contents/MacOS/Capture")
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    func cleanUp() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: app)
    }
  }
}
