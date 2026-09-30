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
    private func release(build: String = "200") -> UpdateRelease {
        UpdateRelease(version: "1.0.0", build: build, date: "2026-09-30", minimumSystem: "14.0",
                      url: URL(string: "https://example.test/XStats-1.0.0-AppleSilicon.zip")!,
                      sha256: String(repeating: "a", count: 64), size: 1000, dmg: nil, notes: ["test"], changelog: nil)
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
            "https://x-stats.china.12306.work/api/v1/update/appcast.xml",
            "https://xstats-apps.12306.work/api/v1/update/appcast.xml",
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

    @Test func failedPrimaryRegionRetriesFallbackOnceThenReportsFailure() {
        let primary = URL(string: "https://primary.example.test/appcast.xml")!
        let fallback = URL(string: "https://fallback.example.test/appcast.xml")!
        var phases: [UpdateController.Phase] = []
        var finished: [Bool] = []
        let driver = SparkleInstaller(endpoints: [primary, fallback], onPhase: { phases.append($0) }, onRelaunch: {})
        driver.onCycleFinished = { finished.append($0) }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        driver.check(userInitiated: false)
        #expect(driver.feedURLString(for: updater) == primary.absoluteString)
        // 主区域失败：切到备用区域重试，本轮尚未结束，不能触发失败重排。
        driver.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: offline)
        #expect(finished.isEmpty)
        #expect(driver.feedURLString(for: updater) == fallback.absoluteString)
        try? driver.updater(updater, mayPerform: .updatesInBackground)
        #expect(driver.feedURLString(for: updater) == fallback.absoluteString, "区域重试不能复位到主区域")
        // 备用区域也失败：只结束一次并报告未取得 feed，由控制器按 1 小时重试间隔重排。
        driver.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: offline)
        #expect(finished == [false])
        #expect(phases.last == .idle)
        #expect(driver.feedURLString(for: updater) == fallback.absoluteString, "结束后保留最后地址，避免 Sparkle 视为换源")
        // 下一轮自动检查重新从主区域开始。
        try? driver.updater(updater, mayPerform: .updatesInBackground)
        #expect(driver.feedURLString(for: updater) == primary.absoluteString)
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
