// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Localization
import SwiftUI

struct Sub2APISettingsView: View {
    let provider: AIProviderID
    let directAvailable: Bool
    let needsFallback: Bool
    @Environment(AppModel.self) private var model
    private var providerName: String { provider == .codex ? "Codex" : "Claude" }
    private var hasStoredConfiguration: Bool {
        Sub2APISettingsStore(provider: provider).hasConfiguration()
    }
    @State private var expanded = false
    @State private var address = ""
    @State private var email = ""
    @State private var password = ""
    @State private var accountID = ""
    @State private var configured = false
    @State private var testing = false
    @State private var result: String?
    @State private var isError = false

    var body: some View {
        Group {
            // 在用户正在填写时保持表单，避免后台自动查询恢复后突然移走输入框。
            if needsFallback || configured || hasStoredConfiguration || expanded {
                DisclosureGroup(isExpanded: $expanded) {
                    if directAvailable && configured {
                        VStack(alignment: .leading, spacing: DS.Space.s2) {
                            Text(tr("本机账号可用，当前使用自动额度。"))
                                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                            Button(tr("移除配置")) { clear() }
                                .buttonStyle(DSButtonStyle(kind: .secondary))
                        }
                        .padding(.top, DS.Space.s2)
                    } else {
                        configurationForm
                    }
                } label: {
                    HStack {
                        Text(providerName + " · " + tr("Sub2API 备用额度"))
                        Spacer()
                        if configured { Text(tr("已配置")).dsFont(.xs).foregroundStyle(DS.Palette.success) }
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private var configurationForm: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(tr("自动查询失败时才使用此 Sub2API 账号；后台不主动探测。"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(tr("Sub2API 地址（HTTPS）"), text: $address)
                .textFieldStyle(.roundedBorder)
            TextField(tr("管理员邮箱"), text: $email)
                .textFieldStyle(.roundedBorder)
            SecureField(tr("管理员密码"), text: $password)
                .textFieldStyle(.roundedBorder)
            TextField(tr("账号 ID"), text: $accountID)
                .textFieldStyle(.roundedBorder)
            Text(tr("管理员密码存于本机钥匙串；账号 ID 用于查询额度。"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s2) {
                Button(tr("保存并测试连接")) { Task { await saveAndTest() } }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(testing)
                if configured {
                    Button(tr("移除配置")) { clear() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(testing)
                }
            }
            if testing { ProgressView().controlSize(.small) }
            if let result {
                Text(result).dsFont(.xs)
                    .foregroundStyle(isError ? DS.Palette.error : DS.Palette.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, DS.Space.s2)
    }

    private func configuration() -> Sub2APIConfiguration? {
        do {
            return try Sub2APIConfiguration(address: address, email: email,
                                            password: password, accountID: accountID, provider: provider)
        } catch let error as Sub2APIConfigurationError {
            show(message(for: error), error: true)
        } catch {
            show(tr("Sub2API 配置无效"), error: true)
        }
        return nil
    }

    private func load() {
        do {
            guard let saved = try Sub2APISettingsStore(provider: provider).load() else { return }
            address = saved.baseURL.absoluteString
            email = saved.email
            password = saved.password
            accountID = String(saved.accountID)
            configured = true
        } catch {
            show(tr("Sub2API 配置无法读取，请检查设置"), error: true)
        }
    }

    private func saveAndTest() async {
        guard let configuration = configuration() else { return }
        testing = true
        defer { testing = false }
        do {
            let snapshot = try await Sub2APIQuotaClient.shared.fetch(configuration: configuration)
            try Sub2APISettingsStore(provider: provider).save(configuration)
            configured = true
            show(tr("Sub2API 配置已保存") + " · "
                 + tr("连接成功，读取到 \(snapshot.windows.count) 个额度窗口"), error: false)
            await model.aiUsage.refresh()
        } catch let error as Sub2APIConfigurationError {
            show(message(for: error), error: true)
        } catch AIQuotaFailure.sub2apiUnauthorized {
            show(tr("Sub2API 登录失败，请检查管理员邮箱和密码"), error: true)
        } catch AIQuotaFailure.sub2apiAccountMismatch {
            show(tr("Sub2API 账号平台与所选来源不匹配"), error: true)
        } catch {
            show(tr("Sub2API 连接失败，请检查地址、账号 ID 与服务状态"), error: true)
        }
    }

    private func clear() {
        do {
            try Sub2APISettingsStore(provider: provider).clear()
            address = ""; email = ""; password = ""; accountID = ""
            configured = false
            show(tr("Sub2API 配置已移除"), error: false)
            Task {
                await Sub2APIQuotaClient.shared.clearSession()
                await model.aiUsage.refresh()
            }
        } catch {
            show(tr("Sub2API 配置移除失败，请检查钥匙串权限"), error: true)
        }
    }

    private func message(for error: Sub2APIConfigurationError) -> String {
        switch error {
        case .invalidAddress: tr("请输入有效的 Sub2API HTTPS 地址")
        case .invalidAccountID: tr("请输入有效的账号 ID")
        case .missingCredentials: tr("请填写管理员邮箱和密码")
        case .providerMismatch: tr("Sub2API 账号平台与所选来源不匹配")
        case .keychain: tr("钥匙串读写失败，请检查权限")
        }
    }

    private func show(_ text: String, error: Bool) {
        result = text
        isError = error
    }
}
