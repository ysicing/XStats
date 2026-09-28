// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
@testable import Updates

@Suite struct InstallationIdentityTests {
    @Test func existingRandomSeedKeepsItsHash() throws {
        let store = MemoryInstallationIDStore()
        store.value = Data(0..<32)
        var generations = 0
        let identity = InstallationIdentity(store: store, serialNumber: { "C02TESTSERIAL123" }) {
            generations += 1
            return Data(0..<32)
        }

        let first = try identity.hashedID()
        let second = try identity.hashedID()

        #expect(first == "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd")
        #expect(second == first)
        #expect(generations == 0)
        #expect(store.value == Data(0..<32))
    }

    @Test func freshInstallsOnSameMacUseOneSerialHash() throws {
        let firstStore = MemoryInstallationIDStore()
        let secondStore = MemoryInstallationIDStore()
        let first = try InstallationIdentity(store: firstStore, serialNumber: { "C02TESTSERIAL123" }) {
            Issue.record("读取到序列号时不应生成随机值")
            return Data()
        }.hashedID()
        let second = try InstallationIdentity(store: secondStore, serialNumber: { "C02TESTSERIAL123" }) {
            Issue.record("读取到序列号时不应生成随机值")
            return Data()
        }.hashedID()

        #expect(first == "0313491002c5f3c4bca8abd15969fef6ddc54cf04164c7be1635acdce2bc1152")
        #expect(second == first)
        #expect(firstStore.value == nil)
        #expect(secondStore.value == nil)
    }

    @Test func missingSerialFallsBackToPersistentRandomSeed() throws {
        let suite = "InstallationIdentityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var generations = 0
        let randomBytes = {
            generations += 1
            return Data(0..<32)
        }

        let first = try InstallationIdentity(defaults: defaults, serialNumber: { nil }, randomBytes: randomBytes).hashedID()
        let second = try InstallationIdentity(defaults: defaults, serialNumber: { nil }, randomBytes: randomBytes).hashedID()

        #expect(first == second)
        #expect(generations == 1)
        #expect(defaults.data(forKey: UserDefaultsInstallationIDStore.key) == Data(0..<32))
    }
}

private final class MemoryInstallationIDStore: InstallationIDStore, @unchecked Sendable {
    var value: Data?

    func read() throws -> Data? { value }
    func write(_ value: Data) throws { self.value = value }
}
