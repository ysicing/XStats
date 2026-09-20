// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
//
// Upstream portions retain their MIT license.
// XStats modifications are licensed under AGPL-3.0-or-later.
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

import Foundation
import Localization
import Observation
import WebDAVSync

/// 手动 WebDAV 同步。一次仅执行一个操作，下载完整校验后只暂存，确认前不改设置。
@MainActor
@Observable
public final class SyncController {
    public enum Phase: Equatable {
        case idle, uploading, downloading
        case failed(String)
    }

    public private(set) var configuration: WebDAVConfiguration?
    public private(set) var phase: Phase = .idle
    public private(set) var pendingDownload: SettingsBackup?
    public private(set) var message: String?
    public private(set) var lastSyncedAt: Date?

    public var isBusy: Bool { phase == .uploading || phase == .downloading }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: WebDAVClient
    @ObservationIgnored private let passwords: any WebDAVPasswordStore

    init(settings: AppSettings, defaults: UserDefaults = .standard,
         client: WebDAVClient = WebDAVClient(),
         passwords: any WebDAVPasswordStore = KeychainWebDAVPasswordStore()) {
        self.settings = settings
        self.defaults = defaults
        self.client = client
        self.passwords = passwords
        if let saved = defaults.dictionary(forKey: "webdav.configuration"),
           let address = saved["address"] as? String, let username = saved["username"] as? String {
            configuration = try? WebDAVConfiguration(address: address, username: username)
        }
        lastSyncedAt = defaults.object(forKey: "webdav.lastSyncedAt") as? Date
    }

    /// 只在设置页打开或用户操作时读钥匙串；应用启动不登录、不访问网络。
    func savedPassword() -> String {
        guard let configuration else { return "" }
        do {
            return try passwords.read(account: configuration.credentialAccount) ?? ""
        } catch {
            phase = .failed(error.localizedDescription)
            return ""
        }
    }

    @discardableResult
    func save(address: String, username: String, password: String) -> Bool {
        guard !isBusy else { return false }
        do {
            let next = try WebDAVConfiguration(address: address, username: username)
            guard !password.isEmpty else { throw WebDAVError.missingPassword }
            // 先保存密码，失败时不提交连接信息，防止界面显示了实际不可用的新配置。
            try passwords.write(password, account: next.credentialAccount)
            if configuration != next {
                lastSyncedAt = nil
                defaults.removeObject(forKey: "webdav.lastSyncedAt")
            }
            defaults.set(["address": next.directoryURL.absoluteString, "username": next.username],
                         forKey: "webdav.configuration")
            configuration = next
            pendingDownload = nil
            phase = .idle
            message = tr("配置已保存，上传或下载时将验证连接")
            return true
        } catch {
            handle(error)
            return false
        }
    }

    func upload() async {
        guard !isBusy, pendingDownload == nil else { return }
        phase = .uploading
        message = nil
        do {
            let (configuration, password) = try credentials()
            let data = try SettingsBackup(document: settings.exportDocument()).encoded()
            try await client.upload(data, configuration: configuration, password: password)
            try Task.checkCancellation()
            markSynced()
            message = tr("本机设置已上传")
            phase = .idle
        } catch { handle(error) }
    }

    func download() async {
        guard !isBusy, pendingDownload == nil else { return }
        phase = .downloading
        message = nil
        do {
            let (configuration, password) = try credentials()
            let data = try await client.download(configuration: configuration, password: password)
            let backup = try SettingsBackup.decode(data)
            try Task.checkCancellation()
            pendingDownload = backup
            phase = .idle
        } catch { handle(error) }
    }

    func confirmDownload() {
        guard !isBusy, let backup = pendingDownload else { return }
        // 校验和下载已全部完成；此处在主线程同步应用，失败响应和取消操作不会进入这里。
        settings.apply(backup.document)
        pendingDownload = nil
        markSynced()
        message = tr("已应用远端设置")
        phase = .idle
    }

    func discardDownload() { pendingDownload = nil }

    private func credentials() throws -> (WebDAVConfiguration, String) {
        guard let configuration else { throw WebDAVError.notConfigured }
        guard let password = try passwords.read(account: configuration.credentialAccount),
              !password.isEmpty else { throw WebDAVError.missingPassword }
        return (configuration, password)
    }

    private func markSynced() {
        let now = Date()
        lastSyncedAt = now
        defaults.set(now, forKey: "webdav.lastSyncedAt")
    }

    private func handle(_ error: Error) {
        pendingDownload = nil
        phase = (error is CancellationError || Task.isCancelled) ? .idle : .failed(error.localizedDescription)
    }
}
