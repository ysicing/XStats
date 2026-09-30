// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Darwin
import Foundation
import Localization
import Security

public enum UpdateError: Error, LocalizedError, Equatable {
    case download(String)
    case invalidBundle(String)
    case install(String)

    public var errorDescription: String? {
        switch self {
        case .download(let reason): tr("下载失败：\(reason)")
        case .invalidBundle(let reason): tr("安装包内容不正确：\(reason)")
        case .install(let reason): tr("替换应用失败：\(reason)")
        }
    }
}

/// 本机安装能力与 Widget 升级协调；下载、验证、替换和重启由 Sparkle 负责。
public enum UpdateInstaller {
    /// 应用自身的签名团队；开发构建（未签名或临时签名）返回 nil
    public static func teamIdentifier(of app: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// 仅结束属于这份应用的旧小组件进程，避免替换后 WidgetKit 继续向旧进程索取组件清单。
    public static func stopWidgetExtension(in app: URL) throws {
        let executable = app.appendingPathComponent("Contents/PlugIns/XStatsWidget.appex/Contents/MacOS/XStatsWidget").path
        var resolved = [CChar](repeating: 0, count: 4096)
        guard realpath(executable, &resolved) != nil else { return }
        let expectedPath = String(decoding: resolved.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let capacity = max(1, Int(proc_listallpids(nil, 0)) + 128)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count >= 0 else { throw UpdateError.install(tr("应用正在运行，请先退出")) }

        for pid in pids.prefix(Int(count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) == expectedPath else {
                continue
            }
            if kill(pid, SIGTERM) != 0 && errno != ESRCH {
                throw UpdateError.install(tr("应用正在运行，请先退出") + " (XStatsWidget)")
            }
            for _ in 0..<50 {
                if kill(pid, 0) != 0 { break }
                usleep(100_000)
            }
            if kill(pid, 0) == 0 {
                throw UpdateError.install(tr("应用正在运行，请先退出") + " (XStatsWidget)")
            }
        }
    }
}
