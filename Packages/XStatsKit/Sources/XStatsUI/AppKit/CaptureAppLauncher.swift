// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureCore
import Localization
import Security
import os

enum CaptureAppLauncher {
    enum Trust: Sendable {
        case team(String), adHocDevelopment, unavailable
    }

    private static let logger = Logger(subsystem: "work.12306.xstats", category: "CaptureLauncher")

    /// 签名信息不可读取时拒绝启动；只有明确的临时签名才允许开发构建降级。
    nonisolated static func currentTrust() -> Trust {
        var ownCode: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return .unavailable }
        if let flags = info[kSecCodeInfoFlags as String] as? UInt32, flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return .adHocDevelopment
        }
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return .unavailable }
        return .team(team)
    }

    /// 直接读取 plist，避免替换应用后 Bundle 仍使用旧身份；签名同时绑定标识和团队。
    nonisolated static func isCaptureApplication(_ url: URL, trust: Trust) -> Bool {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let size = try? plist.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: plist, options: .mappedIfSafe),
              data.count <= 1_048_576,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        guard info["CFBundleIdentifier"] as? String == CaptureRequest.bundleIdentifier else { return false }
        let expression: String
        switch trust {
        case .team(let team):
            guard team.count == 10, team.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { return false }
            expression = "anchor apple generic and identifier \"\(CaptureRequest.bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        case .adHocDevelopment:
            expression = "identifier \"\(CaptureRequest.bundleIdentifier)\""
        case .unavailable: return false
        }
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
    @MainActor static func open(_ action: CaptureRequest.Action) async throws {
        let workspace = NSWorkspace.shared
        let trust = currentTrust()
        let remembered = UserDefaults.standard.string(forKey: "capture.applicationPath").map { URL(fileURLWithPath: $0) }
        let registered = workspace.urlForApplication(withBundleIdentifier: CaptureRequest.bundleIdentifier)
        // 递归签名验证可能读取整包资源，仅在点击入口时于后台执行。
        var application = await Task.detached(priority: .userInitiated) {
            for candidate in [registered, remembered].compactMap({ $0 }) {
                if Task.isCancelled { return nil as URL? }
                if isCaptureApplication(candidate, trust: trust) { return candidate }
                logger.notice("Rejected untrusted Capture application")
            }
            return nil as URL?
        }.value
        try Task.checkCancellation()
        if application == nil {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
            panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
            panel.message = tr("请选择已安装的 XStats Capture.app。")
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            let accepted = await Task.detached(priority: .userInitiated) { isCaptureApplication(selected, trust: trust) }.value
            try Task.checkCancellation()
            guard accepted else {
                logger.notice("Rejected selected Capture application")
                throw CaptureError.invalidRequest
            }
            UserDefaults.standard.set(selected.path, forKey: "capture.applicationPath")
            application = selected
        }
        guard let application else { throw CaptureError.invalidRequest }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        _ = try await workspace.open([CaptureRequest(action: action).url], withApplicationAt: application, configuration: configuration)
        logger.info("Opened verified Capture application")
    }
}
