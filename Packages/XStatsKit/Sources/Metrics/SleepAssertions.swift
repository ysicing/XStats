// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import IOKit.pwr_mgt
import Localization

/// 当前有效的睡眠阻止请求，按所属进程汇总；不读取历史或通信内容。
public struct SleepBlockingProcess: Identifiable, Equatable, Sendable {
    public let id: Int32
    public let name: String
    public let bundlePath: String?
    public let reason: String
    public let preventsDisplaySleep: Bool
    public let preventsSystemSleep: Bool
    public let isSystemService: Bool
}

public enum SleepAssertionReader {
    public struct ReadError: Error, Sendable {
        public let code: Int32
    }

    /// 使用公开 IOKit 接口；调用方负责在后台执行，并按页面需求限频。
    public static func read() throws -> [SleepBlockingProcess] {
        var result: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&result)
        guard status == kIOReturnSuccess, let result else { throw ReadError(code: status) }
        let dictionary = result.takeRetainedValue() as NSDictionary
        var processes: [SleepBlockingProcess] = []
        for (key, value) in dictionary {
            guard let pid = key as? NSNumber, let assertions = value as? [[String: Any]] else { continue }
            // 大多数进程只持有用户活动等无关断言，先按类型筛选，避免逐个查询进程路径。
            guard assertions.contains(where: { blockingKind($0) != nil }) else { continue }
            let meta = ProcessSampler.meta(for: pid.int32Value)
            if let process = parse(pid: pid.int32Value, name: meta.name, path: meta.path,
                                   bundlePath: meta.bundle, assertions: assertions) {
                processes.append(process)
            }
        }
        return processes.sorted { $0.id < $1.id }
    }

    /// 只计入有效的屏幕／系统睡眠阻止请求，用户活动等断言并不等于应用阻止睡眠。
    static func parse(pid: Int32, name: String, path: String?, bundlePath: String?,
                      assertions: [[String: Any]],
                      localize: (_ key: String, _ bundlePath: String) -> String? = SleepAssertionReader.localizedReason) -> SleepBlockingProcess? {
        var system = false
        var display = false
        var reasons: [String] = []
        for assertion in assertions {
            guard let kind = blockingKind(assertion) else { continue }
            switch kind {
            case .system: system = true
            case .display: display = true
            }
            let reason = Self.reason(of: assertion, localize: localize)
            let bounded = String(reason.prefix(256)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !bounded.isEmpty, !reasons.contains(bounded), reasons.count < 3 { reasons.append(bounded) }
        }
        guard system || display else { return nil }
        // /usr/bin 的 caffeinate 等用户启动命令保留在主列表，系统守护进程折叠展示。
        let service = bundlePath == nil && path.map { path in
            ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"].contains { path.hasPrefix($0) }
        } == true
        return SleepBlockingProcess(id: pid, name: name, bundlePath: bundlePath,
                                    reason: reasons.joined(separator: " · "), preventsDisplaySleep: display,
                                    preventsSystemSleep: system, isSystemService: service)
    }

    enum BlockingKind { case system, display }

    /// 只认有效的屏幕／系统睡眠阻止类型；用户活动等断言返回 nil。
    static func blockingKind(_ assertion: [String: Any]) -> BlockingKind? {
        guard (assertion["AssertLevel"] as? NSNumber)?.intValue == kIOPMAssertionLevelOn,
              let type = assertion["AssertType"] as? String else { return nil }
        switch type {
        case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "NetworkClientActive": return .system
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion", "InternalPreventDisplaySleep": return .display
        default: return nil
        }
    }

    /// 带 BundlePath 时 HumanReadableReason 是该 bundle 的本地化键（如 caffeinate 的全大写键），
    /// 不能直接展示；解析不到译文时退回断言名称。未带 BundlePath 的原因按原文展示。
    static func reason(of assertion: [String: Any], localize: (_ key: String, _ bundlePath: String) -> String?) -> String {
        let name = assertion["AssertName"] as? String
        guard let key = assertion["HumanReadableReason"] as? String else { return name ?? "" }
        guard let bundlePath = assertion["BundlePath"] as? String else { return key }
        return localize(key, bundlePath) ?? name ?? key
    }

    /// 按应用当前语言选择 bundle 中最接近的本地化；返回值等于键本身视为没有译文。
    /// macOS 15.4 以下没有指定语言的接口，沿用进程首选语言（应用切换语言时同步写入 AppleLanguages）。
    static func localizedReason(key: String, bundlePath: String) -> String? {
        guard let bundle = Bundle(path: bundlePath) else { return nil }
        let text: String
        if #available(macOS 15.4, *) {
            let preferred = Bundle.preferredLocalizations(from: bundle.localizations,
                                                          forPreferences: [L10n.language.languageCode])
            text = bundle.localizedString(forKey: key, value: nil, table: nil,
                                          localizations: preferred.map { Locale.Language(identifier: $0) })
        } else {
            text = bundle.localizedString(forKey: key, value: nil, table: nil)
        }
        return text.isEmpty || text == key ? nil : text
    }
}
