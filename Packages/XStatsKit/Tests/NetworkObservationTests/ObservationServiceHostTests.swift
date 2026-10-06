// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Security
import Testing
@testable import NetworkObservation

@Suite(.timeLimit(.minutes(1)))
struct ObservationServiceHostTests {
    private func requirement() throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        #expect(SecCodeCopySelf([], &code) == errSecSuccess)
        let own = try #require(code)
        #expect(SecCodeCopyStaticCode(own, [], &staticCode) == errSecSuccess)
        #expect(SecCodeCopyDesignatedRequirement(try #require(staticCode), [], &requirement) == errSecSuccess)
        #expect(SecRequirementCopyString(try #require(requirement), [], &text) == errSecSuccess)
        return try #require(text) as String
    }

    private func stopped(_ peer: NSXPCConnection) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let proxy = peer.remoteObjectProxyWithErrorHandler { @Sendable error in continuation.resume(throwing: error) } as! NetworkObservationService
            proxy.isFilterStopped { @Sendable value in continuation.resume(returning: value) }
        }
    }

    @Test func lifecycleRepliesStayAvailableAfterStopAndClientReplacementCannotConfirmStop() async throws {
        let listener = NSXPCListener.anonymous()
        let host = ObservationServiceHost(listener: listener, requiredClientCode: try requirement())
        defer { listener.invalidate() }
        let generation = host.startFilter()
        let first = NSXPCConnection(listenerEndpoint: listener.endpoint)
        first.remoteObjectInterface = NSXPCInterface(with: NetworkObservationService.self)
        first.resume()
        defer { first.invalidate() }
        #expect(try await stopped(first) == false)
        let second = NSXPCConnection(listenerEndpoint: listener.endpoint)
        second.remoteObjectInterface = NSXPCInterface(with: NetworkObservationService.self)
        second.resume()
        defer { second.invalidate() }
        #expect(try await stopped(second) == false)
        #expect(host.isFilterStopped == false)
        host.beginStoppingFilter(generation: generation)
        #expect(try await stopped(second) == false, "完成 stopFilter 前不能确认停止")
        host.finishStoppingFilter(generation: generation)
        #expect(try await stopped(second) == true)
    }

    @Test func lateStopCompletionCannotConfirmANewerFilterGeneration() throws {
        let listener = NSXPCListener.anonymous()
        let host = ObservationServiceHost(listener: listener, requiredClientCode: try requirement())
        defer { listener.invalidate() }
        let old = host.startFilter()
        host.beginStoppingFilter(generation: old)
        let current = host.startFilter()
        host.finishStoppingFilter(generation: old)
        #expect(host.isFilterStopped == false)
        host.beginStoppingFilter(generation: current)
        host.finishStoppingFilter(generation: current)
        #expect(host.isFilterStopped == true)
    }
}
