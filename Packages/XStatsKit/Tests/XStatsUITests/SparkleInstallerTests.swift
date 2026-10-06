// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Localization
import Sparkle
import Testing
import Updates
@testable import XStatsUI

@MainActor
struct SparkleInstallerTests {
    @Test func cancelledCheckKeepsTheTargetOfALateCachedInstallation() async throws {
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(2, forKey: "SPUUserUpdateStateStage")
        archive.encode(false, forKey: "SPUUserUpdateStateUserInitiated")
        archive.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        defer { decoder.finishDecoding() }
        let state = try #require(SPUUserUpdateState(coder: decoder))
        let driver = SparkleInstaller(onPhase: { _ in }, onRelaunch: {})
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        driver.cancel()
        driver.showUpdateFound(with: try item(release()), state: state) { #expect($0 == .dismiss) }
        #expect(driver.installationExtension == release().networkExtension)
        var prepared = false
        driver.prepareForInstallation = { prepared = true }
        try await driver.waitForInstallationPreparation()
        #expect(prepared)
    }
    @Test func signedExtensionVersionIsRequiredAndIncludedInTheConfirmedRelease() throws {
        let original = release()
        let candidate = try SparkleInstaller.release(from: item(original))
        #expect(candidate.networkExtension == original.networkExtension)
        var fields = try item(original).propertiesDictionary
        fields.removeValue(forKey: "xstats:network-extension-build")
        #expect(throws: (any Error).self) { try SparkleInstaller.release(from: #require(SUAppcastItem(dictionary: fields))) }
        fields = try item(original).propertiesDictionary
        fields["xstats:network-extension-build"] = "137"
        let driver = SparkleInstaller(onPhase: { _ in }, onRelaunch: {})
        driver.check(userInitiated: true, action: .install(original))
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        #expect(throws: UpdateError.releaseChanged) {
            try driver.updater(updater, shouldProceedWithUpdate: #require(SUAppcastItem(dictionary: fields)), updateCheck: .updates)
        }
    }
    @Test func installationWaitsForNetworkShutdownBeforeAcceptingInstall() async throws {
        var choice: SPUUserUpdateChoice?
        var entered = false
        var gate: CheckedContinuation<Void, Never>?
        let driver = SparkleInstaller(onPhase: { _ in }, onRelaunch: {})
        driver.prepareForInstallation = {
            entered = true
            await withCheckedContinuation { gate = $0 }
        }
        defer { gate?.resume() }
        driver.showReady(toInstallAndRelaunch: { choice = $0 })
        while !entered && choice == nil { try Task.checkCancellation(); await Task.yield() }
        try #require(entered)
        #expect(choice == nil)
        gate?.resume(); gate = nil
        while choice == nil { try Task.checkCancellation(); await Task.yield() }
        #expect(choice == .install)
    }

    @Test func networkShutdownFailureCancelsInstallationAndRestoresOldSession() async throws {
        var choice: SPUUserUpdateChoice?
        var phases: [UpdateController.Phase] = []
        var restored = false
        let driver = SparkleInstaller(onPhase: { phases.append($0) }, onRelaunch: {})
        driver.prepareForInstallation = { throw NetworkMonitorError.timeout }
        driver.cancelInstallationPreparation = { restored = true }
        driver.showReady(toInstallAndRelaunch: { choice = $0 })
        while choice == nil { try Task.checkCancellation(); await Task.yield() }
        #expect(choice == .skip)
        #expect(restored)
        guard case .failed = phases.last else { Issue.record("停止失败必须显示安装错误"); return }
    }

    @Test func dismissalDuringPreparationCannotAcceptALateInstallReply() async throws {
        var choice: SPUUserUpdateChoice?
        var entered = false
        var gate: CheckedContinuation<Void, Never>?
        var restored = false
        let driver = SparkleInstaller(onPhase: { _ in }, onRelaunch: {})
        driver.prepareForInstallation = {
            entered = true
            await withCheckedContinuation { gate = $0 }
        }
        driver.cancelInstallationPreparation = { restored = true }
        defer { gate?.resume() }
        driver.showReady(toInstallAndRelaunch: { choice = $0 })
        while !entered { try Task.checkCancellation(); await Task.yield() }
        driver.dismissUpdateInstallation()
        gate?.resume(); gate = nil
        while choice == nil { try Task.checkCancellation(); await Task.yield() }
        #expect(choice == .skip && restored)
    }

    @Test func quittingDuringDownloadWaitsForPreparationEvenBeforeTheReadyCallback() async throws {
        var gate: CheckedContinuation<Void, Never>?
        var calls = 0
        let driver = SparkleInstaller(onPhase: { _ in }, onRelaunch: {})
        driver.prepareForInstallation = {
            calls += 1
            await withCheckedContinuation { gate = $0 }
        }
        defer { gate?.resume() }
        driver.check(userInitiated: true, action: .install(release()))
        #expect(driver.hasInstallationRequest)
        var finished = false
        let quitting = Task { try await driver.waitForInstallationPreparation(); finished = true }
        while gate == nil { try Task.checkCancellation(); await Task.yield() }
        #expect(!finished && calls == 1)
        var actualReadyChoice: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { actualReadyChoice = $0 })
        #expect(actualReadyChoice == nil)
        gate?.resume(); gate = nil
        try await quitting.value
        try await driver.waitForInstallationPreparation()
        #expect(finished && calls == 1 && actualReadyChoice == .install)
    }

    @Test func backgroundCachedInstallingStateKeepsConfirmationAndRequiresShutdownBeforeQuit() throws {
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(2, forKey: "SPUUserUpdateStateStage")
        archive.encode(false, forKey: "SPUUserUpdateStateUserInitiated")
        archive.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        defer { decoder.finishDecoding() }
        let state = try #require(SPUUserUpdateState(coder: decoder))
        #expect(state.stage == .installing)
        var choice: SPUUserUpdateChoice?
        let driver = SparkleInstaller(onPhase: { _ in }, onRelaunch: {})
        driver.showUpdateFound(with: try item(release()), state: state) { choice = $0 }
        #expect(choice == .dismiss && driver.hasInstallationRequest)
    }

    @Test func cachedFoundPreparationFailureDoesNotSilentlySkipTheVersion() async throws {
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(2, forKey: "SPUUserUpdateStateStage")
        archive.encode(false, forKey: "SPUUserUpdateStateUserInitiated")
        archive.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        defer { decoder.finishDecoding() }
        let state = try #require(SPUUserUpdateState(coder: decoder))
        var choice: SPUUserUpdateChoice?
        let driver = SparkleInstaller(onPhase: { _ in }, onRelaunch: {})
        driver.prepareForInstallation = { throw NetworkMonitorError.timeout }
        driver.check(userInitiated: true, action: .install(release()))
        driver.showUpdateFound(with: try item(release()), state: state) { choice = $0 }
        while choice == nil { try Task.checkCancellation(); await Task.yield() }
        #expect(choice == .dismiss)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        driver.updater(updater, didFinishUpdateCycleFor: .updates, error: nil)
        #expect(driver.hasInstallationRequest, "SDK 保留缓存时退出门禁也必须保留")
    }

    @Test func realReadyCancellationClearsTheCachedQuitRequirement() async throws {
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(2, forKey: "SPUUserUpdateStateStage")
        archive.encode(false, forKey: "SPUUserUpdateStateUserInitiated")
        archive.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        defer { decoder.finishDecoding() }
        let state = try #require(SPUUserUpdateState(coder: decoder))
        let driver = SparkleInstaller(onPhase: { _ in }, onRelaunch: {})
        driver.showUpdateFound(with: try item(release()), state: state) { #expect($0 == .dismiss) }
        driver.prepareForInstallation = { throw NetworkMonitorError.timeout }
        var choice: SPUUserUpdateChoice?
        driver.showReady(toInstallAndRelaunch: { choice = $0 })
        while choice == nil { try Task.checkCancellation(); await Task.yield() }
        #expect(choice == .skip && !driver.hasInstallationRequest)
    }
    private func release(build: String = "200") -> UpdateRelease {
        UpdateRelease(version: "1.0.0", build: build, date: "2026-09-30", minimumSystem: "14.0",
                      url: URL(string: "https://example.test/XStats-1.0.0-AppleSilicon.zip")!,
                      sha256: String(repeating: "a", count: 64), size: 1000, dmg: nil, notes: ["test"], changelog: nil, networkExtension: .init(version: "0.15.0", build: "136"))
    }

    @Test func cancelRejectsLateDownloadVerificationAndErrorCallbacks() {
        var phases: [UpdateController.Phase] = []
        var cancellations = 0
        let installer = SparkleInstaller(onPhase: { phases.append($0) }, onRelaunch: {})
        installer.showUserInitiatedUpdateCheck { cancellations += 1 }
        installer.cancel()
        installer.showDownloadInitiated { cancellations += 1 }
        installer.showDownloadDidReceiveExpectedContentLength(100)
        installer.showDownloadDidReceiveData(ofLength: 100)
        installer.showDownloadDidStartExtractingUpdate()
        var acknowledged = false
        installer.showUpdaterError(NSError(domain: "test", code: 1)) { acknowledged = true }
        #expect(phases == [.available])
        #expect(cancellations == 2 && acknowledged)
    }

    @Test func downloadProgressIsBoundedAndCancellationStopsAtExtraction() {
        var phases: [UpdateController.Phase] = []
        var cancellations = 0
        let installer = SparkleInstaller(onPhase: { phases.append($0) }, onRelaunch: {})
        installer.showDownloadInitiated { cancellations += 1 }
        installer.showDownloadDidReceiveExpectedContentLength(10_000)
        for _ in 0..<10_000 { installer.showDownloadDidReceiveData(ofLength: 1) }
        #expect(phases.last == .downloading(1))
        #expect(phases.count <= 202)
        installer.showDownloadDidReceiveData(ofLength: UInt64.max)
        #expect(phases.last == .downloading(1))
        installer.showDownloadDidStartExtractingUpdate()
        installer.cancel()
        #expect(phases.last == .verifying && cancellations == 0)
    }

    @Test(arguments: ["200", "201"])
    func mismatchedSignedFeedCannotInstallAnotherBuild(build: String) throws {
        let release = release()
        let installer = SparkleInstaller(onPhase: { _ in }, onRelaunch: {})
        installer.check(userInitiated: false, action: .install(release))
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: installer, delegate: installer)
        // 只构造清单字段；不使用该初始化器中依赖宿主版本和系统的属性。
        let item = try #require(SUAppcastItem(dictionary: [
            "sparkle:version": build, "sparkle:shortVersionString": release.version,
            "sparkle:minimumSystemVersion": release.minimumSystem,
            "xstats:network-extension-version": "0.15.0", "xstats:network-extension-build": "136",
            "enclosure": ["url": release.url.absoluteString, "length": "1000", "sparkle:installationType": "application"],
        ]))
        if build == release.build {
            try installer.updater(updater, shouldProceedWithUpdate: item, updateCheck: .updates)
        } else {
            #expect(throws: UpdateError.releaseChanged) {
                try installer.updater(updater, shouldProceedWithUpdate: item, updateCheck: .updates)
            }
        }
    }
    private func item(_ release: UpdateRelease) throws -> SUAppcastItem {
        try #require(SUAppcastItem(dictionary: [
            "sparkle:version": release.build, "sparkle:shortVersionString": release.version,
            "sparkle:minimumSystemVersion": release.minimumSystem,
            "xstats:network-extension-version": "0.15.0", "xstats:network-extension-build": "136",
            "xstats:date": release.date, "xstats:sha256": release.sha256,
            "xstats:dmg": "https://example.test/update.dmg",
            "sparkle:fullReleaseNotesLink": "https://example.test/changelog",
            "description": ["content": "test\nsecond line", "format": "plain-text"],
            "enclosure": ["url": release.url.absoluteString, "length": "1000", "sparkle:installationType": "application"],
        ]))
    }

    @Test func successfulCheckTimeMigratesOnceWithoutOverwritingSparkle() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let old = Date(timeIntervalSince1970: 1000)
        let sparkle = Date(timeIntervalSince1970: 2000)
        defaults.set(old, forKey: "updateLastChecked")
        _ = UpdateController(settings: AppSettings(defaults: defaults), defaults: defaults)
        #expect(defaults.object(forKey: "SULastCheckTime") as? Date == old)
        defaults.set(sparkle, forKey: "SULastCheckTime")
        _ = UpdateController(settings: AppSettings(defaults: defaults), defaults: defaults)
        #expect(defaults.object(forKey: "SULastCheckTime") as? Date == sparkle)
    }

    @Test func stableRegionalFeedURLsAndPublicDelegateSelectors() {
        #expect(UpdateFeed.sparkleURLs(prefersChina: true).map(\.absoluteString) == [
            "https://apps.china.12306.work/api/v1/apps/xstats/update/appcast.xml",
            "https://apps.12306.work/api/v1/apps/xstats/update/appcast.xml",
            "https://apps-api.xiai.me/api/v1/apps/xstats/update/appcast.xml",
        ])
        let driver = SparkleInstaller(onPhase: { _ in }, onRelaunch: {})
        for selector in ["feedParametersForUpdater:sendingSystemProfile:", "updater:mayPerformUpdateCheck:error:",
                         "updater:didFinishLoadingAppcast:", "updaterDidNotFindUpdate:error:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:"] {
            #expect(driver.responds(to: NSSelectorFromString(selector)))
        }
    }

    @Test func signedItemPreservesNotesDateAndManualLinks() throws {
        let candidate = try SparkleInstaller.release(from: item(release()))
        #expect(candidate.date == "2026-09-30")
        #expect(candidate.sha256 == release().sha256)
        #expect(candidate.dmg?.absoluteString == "https://example.test/update.dmg")
        #expect(candidate.changelog?.absoluteString == "https://example.test/changelog")
        #expect(candidate.notes == ["test", "second line"])
    }

    @Test func signedItemRetainsChineseAndEnglishIndependentOfSparklesChoice() throws {
        var fields = try item(release()).propertiesDictionary
        fields["xstats:notes-zh-Hans"] = "Chinese-first\nChinese-second"
        fields["xstats:notes-en"] = "English-first\nEnglish-second"
        // 即使 Sparkle 已按系统语言选了英文，中文界面仍须显示中文。
        fields["description"] = ["content": "system-selected English", "format": "plain-text"]
        let candidate = try SparkleInstaller.release(from: #require(SUAppcastItem(dictionary: fields)))
        #expect(candidate.notes == ["Chinese-first", "Chinese-second"])
        for language in AppLanguage.allCases where language != .system {
            let expected = language.languageCode.hasPrefix("zh-") ? candidate.notes : ["English-first", "English-second"]
            #expect(candidate.notes(for: language.languageCode) == expected)
        }
        #expect(candidate.notes(for: "unsupported") == ["English-first", "English-second"])
    }


    @Test func backgroundDismissesWithoutDownloadingAndMigratesLegacySkipThroughSparkle() throws {
        var found: [String] = []
        var phases: [UpdateController.Phase] = []
        var migrated = false
        let driver = SparkleInstaller(onPhase: { phases.append($0) }, onRelaunch: {})
        driver.onRelease = { release, manual in #expect(!manual); found.append(release.version) }
        // 使用公开 NSSecureCoding 接口构造状态，不调用 Sparkle 私有初始化器。
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(0, forKey: "SPUUserUpdateStateStage")
        archive.encode(false, forKey: "SPUUserUpdateStateUserInitiated")
        archive.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        defer { decoder.finishDecoding() }
        let state = try #require(SPUUserUpdateState(coder: decoder))
        var choice: SPUUserUpdateChoice?
        driver.showUpdateFound(with: try item(release()), state: state) { choice = $0 }
        #expect(choice == .dismiss && found == ["1.0.0"])
        driver.legacySkippedVersion = { "1.0.0" }
        driver.onLegacySkipMigrated = { migrated = true }
        driver.showUpdateFound(with: try item(release()), state: state) { choice = $0 }
        #expect(choice == .skip && migrated && found.count == 1)
        // 迁移只表示跳过新版，不能宣称当前安装已经是最新；周期结束后也应保持该状态。
        #expect(phases == [.available, .idle])
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        driver.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        #expect(phases.last == .idle)
    }

    @Test func skippedNewerBuildDoesNotClaimTheInstalledAppIsUpToDate() throws {
        var phases: [UpdateController.Phase] = []
        let driver = SparkleInstaller(onPhase: { phases.append($0) }, onRelaunch: {})
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        let error = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                            userInfo: [SPULatestAppcastItemFoundKey: try item(release(build: "99999999"))])
        driver.updaterDidNotFindUpdate(updater, error: error)
        #expect(phases == [.idle])
    }

    @Test(arguments: [true, false])
    func backgroundFailureKeepsPreviouslyFoundRelease(known: Bool) {
        var phases: [UpdateController.Phase] = []
        let driver = SparkleInstaller(endpoints: [URL(string: "https://example.test/appcast.xml")!],
                                      onPhase: { phases.append($0) }, onRelaunch: {})
        driver.hasKnownRelease = { known }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        driver.check(userInitiated: false)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        driver.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: offline)
        #expect(phases.last == (known ? .available : .idle))
    }

    @Test(arguments: [2, 3])
    func failedEndpointsRetryInOrderThenFinishOnce(endpointCount: Int) {
        let endpoints = ["primary", "fallback", "last"].prefix(endpointCount).map {
            URL(string: "https://\($0).example.test/appcast.xml")!
        }
        var phases: [UpdateController.Phase] = []
        var finished: [Bool] = []
        let driver = SparkleInstaller(endpoints: endpoints, onPhase: { phases.append($0) }, onRelaunch: {})
        driver.onCycleFinished = { finished.append($0) }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        driver.check(userInitiated: false)
        #expect(driver.feedURLString(for: updater) == endpoints.first?.absoluteString)
        // 每次失败只前进一个地址，重试途中不能结束本轮或复位到首选地址。
        for endpoint in endpoints.dropFirst() {
            driver.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: offline)
            #expect(finished.isEmpty)
            #expect(driver.feedURLString(for: updater) == endpoint.absoluteString)
            try? driver.updater(updater, mayPerform: .updatesInBackground)
            #expect(driver.feedURLString(for: updater) == endpoint.absoluteString)
        }
        // 最后一个地址失败后只结束一次；保留最后地址，避免 Sparkle 因换源立即检查。
        driver.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: offline)
        #expect(finished == [false])
        #expect(phases.last == .idle)
        #expect(driver.feedURLString(for: updater) == endpoints.last?.absoluteString)
        // 下一轮自动检查重新从首选地址开始。
        try? driver.updater(updater, mayPerform: .updatesInBackground)
        #expect(driver.feedURLString(for: updater) == endpoints.first?.absoluteString)
    }

    @Test func skippingWithdrawnReleaseDoesNotClaimAnUpdateIsAvailable() {
        var phases: [UpdateController.Phase] = []
        var known = true
        let driver = SparkleInstaller(endpoints: [URL(string: "https://example.test/appcast.xml")!],
                                      onPhase: { phases.append($0) }, onRelaunch: {})
        driver.hasKnownRelease = { known }
        driver.onNoUpdate = { known = false }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        driver.check(userInitiated: false, action: .skip(release()))
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
        driver.updaterDidNotFindUpdate(updater, error: noUpdate)
        driver.updater(updater, didFinishUpdateCycleFor: .updates, error: noUpdate)
        #expect(phases == [.upToDate], "版本已撤回：不能在清空版本信息后仍显示有更新")
    }

    @Test func calendarMonthLaunchOnlyAndFailureRetryIntervals() throws {
        let calendar = Calendar.current
        let jan = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12)))
        let feb = try #require(calendar.date(byAdding: .month, value: 1, to: jan))
        let launch = jan.addingTimeInterval(-1)
        #expect(UpdateCheckSchedule.monthly.sparkleInterval(lastChecked: jan, now: jan, launchedAt: launch) == feb.timeIntervalSince(jan))
        #expect(UpdateCheckSchedule.weekly.sparkleInterval(lastChecked: jan, now: jan, launchedAt: launch) == TimeInterval(7 * 86400))
        #expect(UpdateCheckSchedule.daily.sparkleInterval(lastChecked: jan, now: jan, launchedAt: launch, retry: true) == TimeInterval(3600))
        #expect(UpdateCheckSchedule.never.sparkleInterval(lastChecked: nil, now: jan, launchedAt: launch) == nil)
        #expect(UpdateCheckSchedule.atLaunch.sparkleInterval(lastChecked: jan, now: jan, launchedAt: launch) == nil)
        #expect(UpdateCheckSchedule.atLaunch.sparkleInterval(lastChecked: nil, now: jan, launchedAt: launch) == TimeInterval(3600))
    }

}
