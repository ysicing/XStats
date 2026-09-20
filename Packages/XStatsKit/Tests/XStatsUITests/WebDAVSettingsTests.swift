// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import Testing
import WebDAVSync
@testable import XStatsUI

private struct MockWebDAV: WebDAVTransport {
    let handler: @Sendable (URLRequest) async throws -> WebDAVResponse
    func send(_ request: URLRequest) async throws -> WebDAVResponse { try await handler(request) }
}

@MainActor
private final class Passwords: WebDAVPasswordStore {
    var values: [String: String] = [:]
    var failWrites = false
    func read(account: String) -> String? { values[account] }
    func write(_ password: String, account: String) throws {
        if failWrites { throw WebDAVError.forbidden }
        values[account] = password
    }
}

/// 明确等待请求进入/释放，不用 sleep 猜测网络任务何时挂起。
private actor SuspendedRequest: WebDAVTransport {
    var continuation: CheckedContinuation<WebDAVResponse, Never>?
    var observer: CheckedContinuation<Void, Never>?
    var calls = 0
    func send(_ request: URLRequest) async throws -> WebDAVResponse {
        calls += 1
        return await withCheckedContinuation {
            continuation = $0
            observer?.resume()
            observer = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func finish(data: Data) {
        continuation?.resume(returning: WebDAVResponse(data: data, status: 200))
        continuation = nil
    }
}

@MainActor
struct WebDAVSettingsTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "WebDAVSettingsTests.\(UUID().uuidString)")!
    }
    private func configured(_ settings: AppSettings, defaults: UserDefaults,
                            passwords: Passwords = Passwords(), transport: any WebDAVTransport) -> SyncController {
        let sync = SyncController(settings: settings, defaults: defaults,
                                  client: WebDAVClient(transport: transport), passwords: passwords)
        #expect(sync.save(address: "https://dav.example.com/settings/", username: "alice", password: "secret"))
        return sync
    }

    @Test func downloadRequiresConfirmationAndCancelKeepsLocalSettings() async throws {
        let defaults = defaults()
        let settings = AppSettings(defaults: defaults)
        let local = settings.exportDocument()
        var remote = local
        remote.refreshSeconds = 5
        let data = try SettingsBackup(document: remote).encoded()
        let sync = configured(settings, defaults: defaults, transport: MockWebDAV { _ in
            WebDAVResponse(data: data, status: 200)
        })
        await sync.download()
        #expect(sync.pendingDownload != nil)
        #expect(settings.exportDocument() == local)
        #expect(sync.lastSyncedAt == nil)
        sync.discardDownload()
        #expect(settings.exportDocument() == local)
        await sync.download()
        sync.confirmDownload()
        #expect(settings.refreshSeconds == 5)
        #expect(sync.pendingDownload == nil)
        #expect(sync.lastSyncedAt != nil)
    }

    @Test(arguments: [
        "<html>login</html>", "{}", "{\"format\":\"other\"}",
        "{\"format\":\"work.12306.xstats.settings\",\"version\":99,\"savedAt\":\"2026-09-20T00:00:00Z\",\"document\":{\"schema\":1}}",
        "{\"format\":\"work.12306.xstats.settings\",\"version\":1,\"savedAt\":\"2026-09-20T00:00:00Z\",\"document\":{\"schema\":9}}",
        "{\"format\":\"work.12306.xstats.settings\",\"version\":1,\"savedAt\":\"2026-09-20T00:00:00Z\",\"document\":{\"schema\":1,\"refreshSeconds\":\"bad\"}}",
    ])
    func badDownloadNeverMutatesLocalState(_ text: String) async {
        let defaults = defaults()
        let settings = AppSettings(defaults: defaults)
        let before = settings.exportDocument()
        let sync = configured(settings, defaults: defaults, transport: MockWebDAV { _ in
            WebDAVResponse(data: Data(text.utf8), status: 200)
        })
        await sync.download()
        if case .failed = sync.phase {} else { Issue.record("Expected failure") }
        #expect(sync.pendingDownload == nil)
        sync.confirmDownload()
        #expect(settings.exportDocument() == before)
        #expect(sync.lastSyncedAt == nil)
    }

    @Test func uploadContainsOnlySettingsAndDoesNotMutateLocalState() async throws {
        let defaults = defaults()
        let settings = AppSettings(defaults: defaults)
        let before = settings.exportDocument()
        let sync = configured(settings, defaults: defaults, transport: MockWebDAV { request in
            let data = try #require(request.httpBody)
            let backup = try SettingsBackup.decode(data)
            #expect(backup.document == before)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("secret") == false)
            #expect(text.contains("dav.example.com") == false)
            #expect(text.contains("alice") == false)
            return WebDAVResponse(data: Data(), status: 201)
        })
        await sync.upload()
        #expect(sync.phase == .idle)
        #expect(sync.lastSyncedAt != nil)
        #expect(settings.exportDocument() == before)
        let persisted = defaults.dictionary(forKey: "webdav.configuration")
        #expect(persisted?["password"] == nil)
    }

    @Test func failedPasswordSaveDoesNotCommitNewConfiguration() {
        let defaults = defaults()
        let passwords = Passwords()
        let sync = configured(AppSettings(defaults: defaults), defaults: defaults, passwords: passwords,
                              transport: MockWebDAV { _ in throw WebDAVError.transport })
        let before = sync.configuration
        passwords.failWrites = true
        #expect(sync.save(address: "https://other.example.com/", username: "bob", password: "new-secret") == false)
        #expect(sync.configuration == before)
        #expect(defaults.dictionary(forKey: "webdav.configuration")?["username"] as? String == "alice")
    }

    @Test func cancelDuringDownloadAndDuplicateRequestsAreSafe() async throws {
        let defaults = defaults()
        let settings = AppSettings(defaults: defaults)
        let before = settings.exportDocument()
        let gate = SuspendedRequest()
        let sync = configured(settings, defaults: defaults, transport: gate)
        let first = Task { await sync.download() }
        await gate.waitUntilStarted()
        #expect(sync.isBusy)
        await sync.download()
        #expect(await gate.calls == 1)
        #expect(sync.save(address: "https://other.example.com/", username: "bob", password: "secret") == false)
        first.cancel()
        await gate.finish(data: try SettingsBackup(document: before).encoded())
        await first.value
        #expect(sync.phase == .idle)
        #expect(sync.pendingDownload == nil)
        #expect(settings.exportDocument() == before)
    }

    @Test func backupRoundTripsAndRetainsValidationOnApply() throws {
        let settings = AppSettings(defaults: defaults())
        var document = settings.exportDocument()
        document.refreshSeconds = 7
        let backup = try SettingsBackup.decode(SettingsBackup(document: document).encoded())
        settings.apply(backup.document)
        #expect(settings.refreshSeconds == 2)
        #expect(backup.document == document)
    }
}
