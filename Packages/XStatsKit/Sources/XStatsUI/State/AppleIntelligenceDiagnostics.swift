// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Darwin
import Dispatch
import ObjectiveC
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple 智能只读诊断。偏好键和模型集合的研究来源见 ThirdPartyNotices.md。
/// 私有资产接口只在短寿命子进程中读取，不发送重置、删除或下载请求。
enum AppleIntelligenceDiagnostics {
    static let argument = "--apple-intelligence-report"

    enum FeatureState: String, Codable, Sendable {
        case on, off, lockedOff, unknown
    }

    struct FeatureStatus: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let state: FeatureState
    }

    struct ModelStatus: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let bytes: Int64?
    }

    struct Report: Codable, Equatable, Sendable {
        let reason: String
        let features: [FeatureStatus]
        let models: [ModelStatus]
        let inventoryIssue: String?

        static var example: Self {
            Self(reason: "Apple 智能本机模型当前不可用。",
                 features: catalog.map { .init(id: $0.id, title: $0.title, state: $0.model == nil ? .on : .off) },
                 models: modelCatalog.map { .init(id: $0.id, title: $0.title, bytes: 0) }, inventoryIssue: nil)
        }

        static var unreadable: Self {
            Self(reason: "Apple 智能暂时不可用。",
                 features: catalog.map { .init(id: $0.id, title: $0.title, state: .unknown) },
                 models: modelCatalog.map { .init(id: $0.id, title: $0.title, bytes: nil) },
                 inventoryIssue: "无法读取诊断信息，请稍后刷新。")
        }
    }

    private struct Preference: Sendable {
        let domain: String
        let key: String
        let disabledValue: Bool
    }

    private struct Feature: Sendable {
        let id: String
        let title: String
        var restrictions: [String] = []
        var preferences: [Preference] = []
        var model: String? = nil
    }

    private struct Model: Sendable {
        let id: String
        let title: String
        let assetType: String
    }

    private static let modelCatalog: [Model] = [
        .init(id: "com.apple.modelcatalog", title: "Apple 智能基础模型", assetType: "com.apple.MobileAsset.UAF.FM.GenerativeModels"),
        .init(id: "com.apple.MobileAsset.UAF.FM.Visual", title: "图像与 Genmoji 模型", assetType: "com.apple.MobileAsset.UAF.FM.Visual"),
        .init(id: "com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive", title: "空间照片模型", assetType: "com.apple.MobileAsset.UAF.Photos.SpatialPhotosRelive"),
        .init(id: "com.apple.MobileAsset.UAF.Photos.MagicCleanup", title: "照片清理模型", assetType: "com.apple.MobileAsset.UAF.Photos.MagicCleanup"),
        .init(id: "com.apple.MobileAsset.UAF.FM.CodeLM", title: "Xcode 代码补全模型", assetType: "com.apple.MobileAsset.UAF.FM.CodeLM")
    ]

    private static let catalog: [Feature] = [
        .init(id: "siri", title: "Siri 与 Siri AI", restrictions: ["allowAssistant"], preferences: [
            .init(domain: "com.apple.assistant.support", key: "Assistant Enabled", disabledValue: false),
            .init(domain: "com.apple.Siri", key: "StatusMenuVisible", disabledValue: false),
            .init(domain: "com.apple.Siri", key: "VoiceTriggerUserEnabled", disabledValue: false)]),
        .init(id: "chatgpt", title: "ChatGPT 与其他 AI 扩展", restrictions: ["allowExternalIntelligenceIntegrations", "allowExternalIntelligenceIntegrationsSignIn"]),
        .init(id: "writing-tools", title: "写作工具", restrictions: ["allowWritingTools"]),
        .init(id: "genmoji", title: "Genmoji", restrictions: ["allowGenmoji"]),
        .init(id: "image-playground", title: "Image Playground", restrictions: ["allowImagePlayground"]),
        .init(id: "mail", title: "邮件摘要与智能回复", restrictions: ["allowMailSummary", "allowMailSmartReplies"], preferences: [
            .init(domain: "group.com.apple.mail", key: "DisableAutomaticMessageSummarization", disabledValue: true),
            .init(domain: "group.com.apple.mail", key: "PersonalizedSmartReplies", disabledValue: false)]),
        .init(id: "notification-summaries", title: "通知摘要", preferences: [
            .init(domain: "group.com.apple.usernoted", key: "summarize_previews", disabledValue: false)]),
        .init(id: "messages-summaries", title: "信息摘要", preferences: [
            .init(domain: "com.apple.MobileSMS", key: "messageSummarizationEnabled", disabledValue: false)]),
        .init(id: "safari-summaries", title: "Safari 摘要", restrictions: ["allowSafariSummary"]),
        .init(id: "notes-summaries", title: "备忘录转录摘要", restrictions: ["allowNotesTranscriptionSummary"]),
        .init(id: "inline-predictions", title: "行内文本预测", preferences: [
            .init(domain: ".GlobalPreferences", key: "NSAutomaticInlinePredictionEnabled", disabledValue: false)]),
        .init(id: "spatial-photos", title: "空间照片", preferences: [
            .init(domain: "com.apple.spatialphotosrelive", key: "LocallyDisabled", disabledValue: true)]),
        .init(id: "photos-clean-up", title: "照片清理", model: "com.apple.MobileAsset.UAF.Photos.MagicCleanup"),
        .init(id: "xcode-completion", title: "Xcode 预测代码补全", model: "com.apple.MobileAsset.UAF.FM.CodeLM")
    ]

    struct SettingValue: Sendable {
        let value: Bool?
        var isForced = false
    }

    /// 与 RemoveMacAI status 一致：未发现明确关闭条件时视为配置开启，而非模型就绪。
    /// preferences 的 true 表示读值等于该项关闭值；nil 仍走上游默认开启规则。
    static func featureState(restrictions: [SettingValue], preferences: [SettingValue],
                             modelBytes: [Int64?]? = nil, profileLocksModel: Bool = false) -> FeatureState {
        let hasSettings = !restrictions.isEmpty || !preferences.isEmpty
        let forcedOff = restrictions.allSatisfy { $0.isForced && $0.value == false }
            && preferences.allSatisfy { $0.isForced && $0.value == true }
        if hasSettings && forcedOff || !hasSettings && profileLocksModel { return .lockedOff }
        if !preferences.isEmpty && preferences.allSatisfy({ $0.value == true }) { return .off }
        guard !hasSettings else { return .on }
        guard let modelBytes else { return .unknown }
        if modelBytes.contains(where: { ($0 ?? 0) > 0 }) { return .on }
        return modelBytes.allSatisfy { $0 == 0 } ? .off : .unknown
    }

    /// 与上游相同，完整清单优先；失败时才查询单个集合。不把查询失败或负数当成零。
    static func modelBytes(assetType: String, inventory: [String: Int64]?, fallback: () -> Int64?) -> Int64? {
        if let inventory { return inventory[assetType] ?? 0 }
        guard let bytes = fallback(), bytes >= 0 else { return nil }
        return bytes
    }

    static func total(_ sizes: [Int64?]) -> Int64? {
        var sum: Int64 = 0
        for size in sizes {
            guard let size, size >= 0 else { return nil }
            let next = sum.addingReportingOverflow(size)
            guard !next.overflow else { return nil }
            sum = next.partialValue
        }
        return sum
    }

    /// 只有结构完整的资产清单才能把“没有此模型记录”解释为零。
    static func parseInventory(_ object: [String: Any]) -> [String: Int64]? {
        guard let assets = object["SystemAssets"] as? [[String: Any]], assets.count <= 4096 else { return nil }
        var result: [String: Int64] = [:]
        for asset in assets {
            guard let present = asset["isPresentOnDevice"] as? Bool else { return nil }
            if !present { continue }
            guard let metadata = asset["metadata"] as? [String: Any],
                  let type = metadata["AssetType"] as? String,
                  let size = metadata["com.apple.UnifiedAssetFramework.UnarchivedSize"] ?? metadata["_UnarchivedSize"],
                  let bytes = Int64(String(describing: size)), bytes >= 0 else { return nil }
            let sum = (result[type] ?? 0).addingReportingOverflow(bytes)
            guard !sum.overflow else { return nil }
            result[type] = sum.partialValue
        }
        return result
    }

    /// 每次打开仅启动一次当前构建的只读入口；取消或超时只终止本次子进程。
    static func load(executableURL: URL? = Bundle.main.executableURL, timeout: Duration = .seconds(5)) async throws -> Report {
        try Task.checkCancellation()
        guard let executable = executableURL else { return .unreadable }
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        // Process 启动和回收会同步等待；沿用额度读取器的 GCD 桥接，不能占住协作线程池。
        let report: Report = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(with: Result {
                        try readReport(executableURL: executable, timeout: timeout,
                                       isCancelled: { cancelled.withLock { $0 } })
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return report
    }

    /// 只在 GCD 线程运行，取消标记由调用方持锁读写；结果与清理都必须有界。
    private static func readReport(executableURL: URL, timeout: Duration, isCancelled: () -> Bool) throws -> Report {
        if isCancelled() { throw CancellationError() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("report.json")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { return .unreadable }
        let writer = try FileHandle(forWritingTo: output)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [argument]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = writer
        process.standardError = FileHandle.nullDevice
        defer {
            if process.isRunning, process.processIdentifier > 0 {
                kill(process.processIdentifier, SIGKILL)
                // 非 RunLoop 线程可能错过 waitUntilExit() 的退出通知；最多等待两秒。
                // ESRCH 表示内核已回收，即使 Foundation 的 isRunning 尚未更新也应结束。
                let reapDeadline = clock.now.advanced(by: .seconds(2))
                while process.isRunning && clock.now < reapDeadline {
                    if kill(process.processIdentifier, 0) == -1 && errno == ESRCH { break }
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            try? writer.close()
        }
        if isCancelled() { throw CancellationError() }
        guard clock.now < deadline else { return .unreadable }
        try process.run()
        while process.isRunning {
            if isCancelled() { throw CancellationError() }
            guard clock.now < deadline else { return .unreadable }
            let remaining = (deadline - clock.now).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            Thread.sleep(forTimeInterval: max(0, min(0.25, seconds)))
        }
        // 退出可能发生在调用方等待期间；先检查取消和截止时间，不能用空输出覆盖超时结果。
        if isCancelled() { throw CancellationError() }
        guard clock.now < deadline, process.terminationStatus == 0 else { return .unreadable }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { return .unreadable }
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else { return .unreadable }
        guard report.features.map(\.id) == catalog.map(\.id), report.models.map(\.id) == modelCatalog.map(\.id),
              report.models.allSatisfy({ $0.bytes.map { $0 >= 0 } ?? true }) else { return .unreadable }
        return report
    }

    /// 在应用创建窗口、采样器及修改偏好之前执行，报告字段使用源文案键。
    static func writeReport() {
        guard let data = try? JSONEncoder().encode(readReport()) else { exit(1) }
        FileHandle.standardOutput.write(data)
    }

    private static func readReport() -> Report {
        var reason = "无法检测"
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: reason = "本机模型已就绪"
            case .unavailable(let why):
                switch why {
                case .appleIntelligenceNotEnabled: reason = "请先在“系统设置 → Apple 智能与 Siri”中开启 Apple 智能。"
                case .modelNotReady: reason = "Apple 智能模型还在下载或准备中，请稍后再试。"
                case .deviceNotEligible: reason = "Apple 智能本机模型当前不可用。"
                @unknown default: reason = "Apple 智能暂时不可用。"
                }
            @unknown default: reason = "Apple 智能暂时不可用。"
            }
        }
        #endif
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else {
            return Report(reason: reason, features: Report.unreadable.features, models: Report.unreadable.models,
                          inventoryIssue: "详细功能与模型占用检测需要 macOS 27 或更新版本。")
        }
        let models = readModelSizes()
        let sizes = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0.bytes) })
        let profileLocks = profileLockedModels()
        let features = catalog.map { feature -> FeatureStatus in
            let restrictions = feature.restrictions.map { readSetting("com.apple.applicationaccess", $0) }
            let preferences = feature.preferences.map { preference in
                let read = readSetting(preference.domain, preference.key)
                return SettingValue(value: read.value.map { $0 == preference.disabledValue }, isForced: read.isForced)
            }
            let state = featureState(restrictions: restrictions, preferences: preferences,
                                     modelBytes: feature.model.map { [sizes[$0] ?? nil] },
                                     profileLocksModel: profileLocks.contains(feature.id))
            return .init(id: feature.id, title: feature.title, state: state)
        }
        return Report(reason: reason, features: features, models: models,
                      inventoryIssue: models.contains { $0.bytes == nil } ? "部分模型占用无法检测，无法确认总计。" : nil)
    }

    private static func readSetting(_ domain: String, _ key: String) -> SettingValue {
        let application = domain as CFString
        CFPreferencesAppSynchronize(application)
        return SettingValue(value: CFPreferencesCopyAppValue(key as CFString, application) as? Bool,
                            isForced: CFPreferencesAppValueIsForced(key as CFString, application))
    }

    /// 只读取上游配置的强制标记，不修改或移除其描述文件；兼容缺少 ai 标记的旧描述文件。
    private static func profileLockedModels() -> Set<String> {
        let domain = "io.github.omlahore.removemacai" as CFString
        CFPreferencesAppSynchronize(domain)
        guard CFPreferencesAppValueIsForced("installed" as CFString, domain),
              CFPreferencesCopyAppValue("ai" as CFString, domain) as? Bool ?? true else { return [] }
        let kept = CFPreferencesCopyAppValue("kept" as CFString, domain) as? String ?? ""
        let keptIDs = Set(kept.split(separator: ",").map(String.init))
        return Set(catalog.filter { $0.model != nil }.map(\.id)).subtracting(keptIDs)
    }

    private static func readModelSizes() -> [ModelStatus] {
        guard dlopen("/System/Library/PrivateFrameworks/UnifiedAssetFramework.framework/UnifiedAssetFramework", RTLD_LAZY) != nil else {
            return modelCatalog.map { .init(id: $0.id, title: $0.title, bytes: nil) }
        }
        var inventory: [String: Int64]?
        if let inventoryClass = NSClassFromString("UAFAssetSetManager") as? NSObject.Type,
           inventoryClass.responds(to: NSSelectorFromString("generateInformationWithError:")),
           let result = inventoryClass.perform(NSSelectorFromString("generateInformationWithError:"), with: nil)?.takeUnretainedValue() {
            if let dictionary = result as? [String: Any] { inventory = parseInventory(dictionary) }
            else if let text = result as? String, let data = text.data(using: .utf8), data.count <= 2_000_000,
                    let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                inventory = parseInventory(dictionary)
            }
        }
        let statusClass = NSClassFromString("UAFAutoAssetManager") as? NSObject.Type
        let statusSelector = NSSelectorFromString("latestStatusForClients:error:")
        return modelCatalog.map { model in
            let bytes = modelBytes(assetType: model.assetType, inventory: inventory) {
                guard let statusClass, statusClass.responds(to: statusSelector),
                      let status = statusClass.perform(statusSelector, with: model.id, with: nil)?.takeUnretainedValue() as? NSObject,
                      status.responds(to: NSSelectorFromString("downloadedFilesystemBytes")),
                      let number = status.value(forKey: "downloadedFilesystemBytes") as? NSNumber else { return nil }
                return number.int64Value
            }
            return .init(id: model.id, title: model.title, bytes: bytes)
        }
    }
}
