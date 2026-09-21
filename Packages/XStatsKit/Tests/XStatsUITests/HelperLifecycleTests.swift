// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import ServiceManagement
import Testing
@testable import XStatsUI

@MainActor
private final class Registration: HelperRegistration {
    var status: SMAppService.Status = .enabled
    var operations: [String] = []
    var failUnregister = false
    func register() { operations.append("register"); status = .enabled }
    func unregister() async throws {
        operations.append("unregister")
        if failUnregister { throw NSError(domain: "test", code: 1) }
        status = .notRegistered
    }
}

@MainActor
struct HelperLifecycleTests {
    @Test func adHocDisablesRegistrationAndRemovesOldDaemonWithoutConnecting() async {
        let service = Registration()
        let helper = HelperClient(teamIdentifier: nil, service: service, versionProbe: {
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
        let helper = HelperClient(teamIdentifier: "ABCDE12345", service: service, versionProbe: { versions.removeFirst() })
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
