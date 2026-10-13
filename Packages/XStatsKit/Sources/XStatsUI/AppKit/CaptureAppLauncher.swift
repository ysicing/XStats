// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
import AppKit
import CaptureCore
import Localization

enum CaptureAppLauncher {
    /// Read the plist directly to avoid Bundle's cached identity after app replacement.
    nonisolated static func isCaptureApplication(_ url: URL) -> Bool {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              let size = try? plist.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576,
              let data = try? Data(contentsOf: plist, options: .mappedIfSafe),
              data.count <= 1_048_576,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return info["CFBundleIdentifier"] as? String == CaptureRequest.bundleIdentifier
    }
    @MainActor static func open(_ action: CaptureRequest.Action) async throws {
        let workspace = NSWorkspace.shared
        let remembered = UserDefaults.standard.string(forKey: "capture.applicationPath").map { URL(fileURLWithPath: $0) }
        var application = workspace.urlForApplication(withBundleIdentifier: CaptureRequest.bundleIdentifier)
        if application.map(isCaptureApplication) != true { application = remembered.flatMap { isCaptureApplication($0) ? $0 : nil } }
        if application == nil {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
            panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
            panel.message = tr("请选择已安装的 XStats Capture.app。")
            guard panel.runModal() == .OK, let selected = panel.url else { return }
            guard isCaptureApplication(selected) else { throw CaptureError.invalidRequest }
            UserDefaults.standard.set(selected.path, forKey: "capture.applicationPath")
            application = selected
        }
        guard let application else { throw CaptureError.invalidRequest }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
        _ = try await workspace.open([CaptureRequest(action: action).url], withApplicationAt: application, configuration: configuration)
    }
}
