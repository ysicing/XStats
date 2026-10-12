// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import IOKit.pwr_mgt

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
                      assertions: [[String: Any]]) -> SleepBlockingProcess? {
        var system = false
        var display = false
        var reasons: [String] = []
        for assertion in assertions {
            guard (assertion["AssertLevel"] as? NSNumber)?.intValue == kIOPMAssertionLevelOn,
                  let type = assertion["AssertType"] as? String else { continue }
            switch type {
            case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "NetworkClientActive": system = true
            case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion", "InternalPreventDisplaySleep": display = true
            default: continue
            }
            let reason = assertion["HumanReadableReason"] as? String
                ?? assertion["AssertName"] as? String ?? ""
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
}
