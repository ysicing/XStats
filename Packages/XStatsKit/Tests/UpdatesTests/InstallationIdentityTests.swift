// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Updates

@Suite struct InstallationIdentityTests {
    @Test func persistsRandomValueAndReturnsOnlyItsHash() throws {
        let store = MemoryInstallationIDStore()
        var generations = 0
        let identity = InstallationIdentity(store: store) {
            generations += 1
            return Data(0..<32)
        }

        let first = try identity.hashedID()
        let second = try identity.hashedID()

        #expect(first == "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd")
        #expect(second == first)
        #expect(generations == 1)
        #expect(store.value == Data(0..<32))
    }
}

private final class MemoryInstallationIDStore: InstallationIDStore, @unchecked Sendable {
    var value: Data?

    func read() throws -> Data? { value }
    func write(_ value: Data) throws { self.value = value }
}
