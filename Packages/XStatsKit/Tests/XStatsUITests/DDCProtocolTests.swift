// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Testing
@testable import XStatsUI

struct DDCProtocolTests {
    private func reply(control: DisplayControl = .brightness, status: UInt8 = 0,
                       current: UInt16 = 50, maximum: UInt16 = 100) -> [UInt8] {
        let data: [UInt8] = [0x6e, 0x88, 0x02, status, control.rawValue, 0,
                            UInt8(maximum >> 8), UInt8(maximum & 0xff), UInt8(current >> 8), UInt8(current & 0xff)]
        return data + [data.reduce(UInt8(0x50), ^)]
    }

    @Test func validatesTheWholeReplyAndKeepsUnsupportedDistinct() {
        let good = reply()
        #expect(DDCProtocol.parse(good, control: .brightness) == .value(DDCValue(current: 50, maximum: 100)))
        #expect(DDCProtocol.parse(reply(status: 1), control: .brightness) == .unsupported)
        #expect(DDCProtocol.parse(reply(status: 2), control: .brightness) == .unavailable)
        #expect(DDCProtocol.parse(good, control: .volume) == .unavailable)
        for index in good.indices {
            var bad = good; bad[index] ^= 1
            #expect(DDCProtocol.parse(bad, control: .brightness) == .unavailable)
        }
        #expect(DDCProtocol.parse(Array(good.dropLast()), control: .brightness) == .unavailable)
        #expect(DDCProtocol.parse(good + [0], control: .brightness) == .unavailable)
        #expect(DDCProtocol.parse(reply(current: 101), control: .brightness) == .unavailable)
        #expect(DDCProtocol.parse(reply(current: 0, maximum: 0), control: .brightness) == .unavailable)
    }

    @Test func readsEDIDSignatureInCoreGraphicsByteOrder() throws {
        // 本机 DELL U2422H 的真实值：CGDisplayVendorNumber 4268、ModelNumber 41400、SerialNumber 810567746
        var edid = [UInt8](repeating: 0, count: 128)
        edid.replaceSubrange(0..<16, with: [0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00,
                                            0x10, 0xac, 0xb8, 0xa1, 0x42, 0x48, 0x50, 0x30])
        let signature = try #require(EDIDSignature(edid))
        #expect(signature == EDIDSignature(vendor: 4268, product: 41400, serial: 810_567_746))
        var badHeader = edid; badHeader[0] = 1
        #expect(EDIDSignature(badHeader) == nil)
        #expect(EDIDSignature(Array(edid.prefix(127))) == nil)
    }

    @Test func edidMatchRejectsOtherDisplaysAndToleratesMissingSerial() {
        let target = EDIDSignature(vendor: 4268, product: 41400, serial: 810_567_746)
        #expect(target.matches(target))
        #expect(!target.matches(EDIDSignature(vendor: 4268, product: 41400, serial: 1)))
        #expect(!target.matches(EDIDSignature(vendor: 4268, product: 41401, serial: 810_567_746)))
        #expect(!target.matches(EDIDSignature(vendor: 1552, product: 41400, serial: 810_567_746)))
        #expect(target.matches(EDIDSignature(vendor: 4268, product: 41400, serial: 0)))
    }

    @Test func unverifiableProxyIsOnlyAcceptedWithASingleExternalDisplay() {
        let target = EDIDSignature(vendor: 4268, product: 41400, serial: 810_567_746)
        let other = EDIDSignature(vendor: 4268, product: 41400, serial: 1)
        #expect(EDIDSignature.verifies(nil, expected: target, externalDisplays: 1))
        #expect(!EDIDSignature.verifies(nil, expected: target, externalDisplays: 2))
        #expect(!EDIDSignature.verifies(nil, expected: target, externalDisplays: 0))
        #expect(EDIDSignature.verifies(target, expected: target, externalDisplays: 3))
        #expect(!EDIDSignature.verifies(other, expected: target, externalDisplays: 1))
    }

    @Test func preservesFullRangeAndRejectsInvalidUserValues() {
        let value = DDCValue(current: 32768, maximum: 65535)
        #expect(DDCProtocol.parse(reply(current: 32768, maximum: 65535), control: .brightness) == .value(value))
        #expect(value.rawValue(for: 0) == 0)
        #expect(value.rawValue(for: 100) == 65535)
        #expect(value.rawValue(for: -1) == nil)
        #expect(value.rawValue(for: 101) == nil)
        #expect(value.rawValue(for: .nan) == nil)
        #expect(value.rawValue(for: .infinity) == nil)
        #expect(DDCProtocol.get(.brightness) == [0x82, 0x01, 0x10, 0xac])
        #expect(DDCProtocol.set(.contrast, value: 50) == [0x84, 0x03, 0x12, 0x00, 0x32, 0x98])
    }
}

struct DDCWriteTransactionTests {
    @Test func unsupportedUnavailableAndStaleConnectionsNeverWrite() {
        for result: DDCResult in [.unsupported, .unavailable, .timedOut] {
            var writes = 0
            let actual = DDCWriteTransaction.apply(percent: 50, cancellation: DDCCancellation(), isCurrent: { true },
                read: { result }, send: { _ in writes += 1; return true })
            #expect(actual == result)
            #expect(writes == 0)
        }
        var writes = 0
        let stale = DDCWriteTransaction.apply(percent: 50, cancellation: DDCCancellation(), isCurrent: { false },
            read: { .value(DDCValue(current: 75, maximum: 100)) }, send: { _ in writes += 1; return true })
        #expect(stale == .cancelled && writes == 0)
    }

    @Test func cancellationBetweenProbeAndSetPreventsTheSet() {
        let ticket = DDCCancellation()
        var writes = 0
        let result = DDCWriteTransaction.apply(percent: 50, cancellation: ticket, isCurrent: { true }, read: {
            ticket.cancel()
            return .value(DDCValue(current: 75, maximum: 100))
        }, send: { _ in writes += 1; return true })
        #expect(result == .cancelled && writes == 0)
    }

    @Test func successfulSendNeedsMatchingReadbackAndRange() {
        for after: DDCResult in [.value(DDCValue(current: 50, maximum: 100)),
                                .value(DDCValue(current: 75, maximum: 100)),
                                .value(DDCValue(current: 50, maximum: 80)), .unavailable] {
            var reads = 0
            var sent: UInt16?
            let result = DDCWriteTransaction.apply(percent: 50, cancellation: DDCCancellation(), isCurrent: { true }, read: {
                reads += 1
                return reads == 1 ? .value(DDCValue(current: 75, maximum: 100)) : after
            }, send: { sent = $0; return true })
            #expect(sent == 50)
            if after == .value(DDCValue(current: 50, maximum: 100)) { #expect(result == after) }
            else if case .unconfirmed = result {} else { Issue.record("An unverified write must not be shown as applied") }
        }
    }
}
