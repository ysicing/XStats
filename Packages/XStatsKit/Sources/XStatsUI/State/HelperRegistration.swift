// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import HelperShared
import ServiceManagement

/// 把注册生命周期与 XPC 调用分开，使升级流程可在不启动 root 服务的情况下验证。
@MainActor
protocol HelperRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

@MainActor
struct SystemHelperRegistration: HelperRegistration {
    private let service = SMAppService.daemon(plistName: HelperConstants.launchdPlistName)
    var status: SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.unregister { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
