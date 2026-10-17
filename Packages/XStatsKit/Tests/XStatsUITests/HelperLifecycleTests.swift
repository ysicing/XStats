// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import ServiceManagement
import Testing
import os
@testable import XStatsUI

@MainActor
private final class Registration: HelperRegistration {
  var status: SMAppService.Status = .enabled
  var operations: [String] = []
  var failUnregister = false
  func register() {
    operations.append("register")
    status = .enabled
  }
  func unregister() async throws {
    operations.append("unregister")
    if failUnregister { throw NSError(domain: "test", code: 1) }
    status = .notRegistered
  }
}

@MainActor
struct HelperLifecycleTests {
  @Test func startupReadsSigningIdentityOffMainThreadBeforeVerifyingHelper() async {
    let service = Registration()
    let helper = HelperClient(
      service: service,
      readTeamIdentifier: {
        #expect(!Thread.isMainThread)
        return "ABCDE12345"
      }, versionProbe: { 5 })
    await helper.verifyVersion()
    #expect(helper.canInstall)
    #expect(helper.isReady)
    #expect(service.operations.isEmpty)
  }

  @Test(arguments: [true, false])
  func pendingIdentityIsNotTreatedAsUnsignedAndConcurrentChecksShareOneRead(signed: Bool) async {
    let service = Registration()
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let helper = HelperClient(
      service: service,
      readTeamIdentifier: {
        #expect(!Thread.isMainThread)
        reads.withLock { $0 += 1 }
        return signed ? "ABCDE12345" : nil
      },
      versionProbe: {
        #expect(signed, "没有签名时不能连接旧 Helper")
        return 5
      })
    #expect(helper.isResolvingIdentity)
    #expect(!helper.canInstall && !helper.isReady)
    helper.install()
    #expect(service.operations.isEmpty)
    #expect(helper.lastError == nil)

    async let first: Void = helper.verifyVersion()
    async let second: Void = helper.verifyVersion()
    _ = await (first, second)
    #expect(!helper.isResolvingIdentity)
    #expect(helper.canInstall == signed)
    #expect(helper.isReady == signed)
    #expect(service.operations == (signed ? [] : ["unregister"]))
    await helper.verifyVersion()
    #expect(reads.withLock { $0 } == 1)
  }

  @Test func adHocDisablesRegistrationAndRemovesOldDaemonWithoutConnecting() async {
    let service = Registration()
    let helper = HelperClient(
      teamIdentifier: nil, service: service,
      versionProbe: {
        Issue.record("ad-hoc must not connect to the old daemon")
        return 4
      })
    helper.refreshStatus()
    #expect(helper.isReady == false)
    helper.install()
    #expect(service.operations.isEmpty)
    await helper.verifyVersion()
    #expect(service.operations == ["unregister"])
    #expect(helper.canInstall == false)
    #expect(helper.isReady == false)
    if case .unavailable = helper.status {} else { Issue.record("Must show signing limitation") }
  }

  @Test func runningVersionFourIsUnregisteredAndReplacedBeforeReady() async {
    let service = Registration()
    var versions = [4, 5]
    let helper = HelperClient(
      teamIdentifier: "ABCDE12345", service: service, versionProbe: { versions.removeFirst() })
    helper.refreshStatus()
    #expect(helper.isReady == false)
    await helper.verifyVersion()
    #expect(service.operations == ["unregister", "register"])
    #expect(versions.isEmpty)
    #expect(helper.isReady)
    #expect(helper.isOutdated == false)
  }

  @Test func unregisterFailureDoesNotReinstallOrTrustOldHelper() async {
    let service = Registration()
    service.failUnregister = true
    let helper = HelperClient(teamIdentifier: "ABCDE12345", service: service, versionProbe: { 4 })
    await helper.verifyVersion()
    #expect(service.operations == ["unregister"])
    #expect(helper.isReady == false)
    #expect(helper.isOutdated)
    #expect(helper.lastError != nil)
  }

  @Test func failedVersionHandshakeNeverReportsReady() async {
    let service = Registration()
    let helper = HelperClient(teamIdentifier: "ABCDE12345", service: service, versionProbe: { nil })
    await helper.verifyVersion()
    #expect(helper.isReady == false)
    #expect(service.operations.isEmpty)
  }
}
