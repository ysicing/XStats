// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Metrics

struct SleepAssertionTests {
    @Test(arguments: ["NetworkClientActive", "InternalPreventDisplaySleep"])
    func includesNetworkAndInternalDisplayRequests(type: String) throws {
        let reading = try #require(SleepAssertionReader.parse(pid: 1, name: "service", path: "/usr/libexec/powerd",
                                                            bundlePath: nil, assertions: [
            ["AssertType": type, "AssertLevel": kIOPMAssertionLevelOn, "AssertName": "request"]
        ]))
        #expect(reading.isSystemService)
        #expect(reading.preventsSystemSleep == (type == "NetworkClientActive"))
        #expect(reading.preventsDisplaySleep == (type == "InternalPreventDisplaySleep"))
    }

    @Test func ignoresInactiveAndUserActivityButCombinesSleepTypes() throws {
        let assertions: [[String: Any]] = [
            ["AssertType": "UserIsActive", "AssertLevel": kIOPMAssertionLevelOn, "AssertName": "touch"],
            ["AssertType": "PreventSystemSleep", "AssertLevel": kIOPMAssertionLevelOff, "AssertName": "inactive"],
            ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": kIOPMAssertionLevelOn, "AssertName": "audio"],
            ["AssertType": "PreventUserIdleDisplaySleep", "AssertLevel": kIOPMAssertionLevelOn, "AssertName": "display", "HumanReadableReason": "Watching video"],
            ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": kIOPMAssertionLevelOn, "AssertName": "audio"]
        ]
        let reading = try #require(SleepAssertionReader.parse(pid: 12, name: "Player", path: "/Applications/Player.app/Contents/MacOS/Player",
                                                            bundlePath: "/Applications/Player.app", assertions: assertions))
        #expect(reading.preventsDisplaySleep && reading.preventsSystemSleep)
        #expect(!reading.isSystemService && reading.reason == "audio · Watching video")
        #expect(SleepAssertionReader.parse(pid: 1, name: "inactive", path: nil, bundlePath: nil,
                                          assertions: Array(assertions.prefix(2))) == nil)
    }

    @Test func foldsOnlySystemDaemonsAndBoundsReasons() throws {
        let assertions: [[String: Any]] = [["AssertType": "PreventSystemSleep", "AssertLevel": kIOPMAssertionLevelOn,
                                           "AssertName": String(repeating: "x", count: 1_000)]]
        for (path, bundle, service) in [("/usr/libexec/powerd", nil, true), ("/usr/bin/caffeinate", nil, false),
                                       ("/System/Applications/Music.app/Contents/MacOS/Music", "/System/Applications/Music.app", false)] {
            let reading = try #require(SleepAssertionReader.parse(pid: 1, name: "test", path: path,
                                                                bundlePath: bundle, assertions: assertions))
            #expect(reading.isSystemService == service && reading.reason.count == 256)
        }
    }

    @Test func bundleReasonUsesLocalizationAndFallsBackToAssertionName() throws {
        let caffeinate: [String: Any] = ["AssertType": "PreventUserIdleSystemSleep", "AssertLevel": kIOPMAssertionLevelOn,
                                         "AssertName": "caffeinate command-line tool",
                                         "HumanReadableReason": "THE CAFFEINATE TOOL IS PREVENTING SLEEP.",
                                         "BundlePath": "/System/Library/CoreServices/powerd.bundle"]
        var lookups: [String] = []
        let translated = try #require(SleepAssertionReader.parse(pid: 1, name: "caffeinate", path: "/usr/bin/caffeinate",
                                                               bundlePath: nil, assertions: [caffeinate]) { key, bundle in
            lookups.append(bundle)
            return key == "THE CAFFEINATE TOOL IS PREVENTING SLEEP." ? "caffeinate is preventing sleep" : nil
        })
        #expect(translated.reason == "caffeinate is preventing sleep")
        #expect(lookups == ["/System/Library/CoreServices/powerd.bundle"])
        // 没有译文时不能展示全大写的本地化键。
        let fallback = try #require(SleepAssertionReader.parse(pid: 1, name: "caffeinate", path: "/usr/bin/caffeinate",
                                                             bundlePath: nil, assertions: [caffeinate]) { _, _ in nil })
        #expect(fallback.reason == "caffeinate command-line tool")
        // 不带 BundlePath 的原因是应用自行提供的原文，不做查找。
        var plain = caffeinate
        plain["BundlePath"] = nil
        plain["HumanReadableReason"] = "Playing audio"
        let original = try #require(SleepAssertionReader.parse(pid: 1, name: "Player", path: nil, bundlePath: nil,
                                                             assertions: [plain]) { _, _ in Issue.record("不应查找"); return nil })
        #expect(original.reason == "Playing audio")
    }

    @Test func defaultLocalizerTreatsUntranslatedKeysAsMissing() {
        #expect(SleepAssertionReader.localizedReason(key: "XSTATS UNTRANSLATED KEY", bundlePath: "/System/Library/CoreServices/powerd.bundle") == nil)
        #expect(SleepAssertionReader.localizedReason(key: "OK", bundlePath: "/nonexistent/XStats.bundle") == nil)
    }

    @Test func nativeReaderReturnsUniqueProcesses() throws {
        var assertion: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                "XStats sleep assertion test" as CFString, &assertion)
        #expect(status == kIOReturnSuccess)
        defer { IOPMAssertionRelease(assertion) }
        let processes = try SleepAssertionReader.read()
        #expect(processes.contains { $0.id == ProcessInfo.processInfo.processIdentifier
            && $0.preventsSystemSleep && $0.reason.contains("XStats sleep assertion test") })
        #expect(Set(processes.map(\.id)).count == processes.count)
        #expect(processes.allSatisfy { $0.preventsDisplaySleep || $0.preventsSystemSleep })
    }
}
