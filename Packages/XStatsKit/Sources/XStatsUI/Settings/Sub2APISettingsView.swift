// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import AIUsage
import Localization
import SwiftUI

/// 会话内草稿由 AppModel 持有；弹窗关闭或切页时不丢弃未保存的凭据，且不写入磁盘。
@MainActor @Observable final class Sub2APIDraft {
    var loaded = false
    var expanded = false
    var address = ""
    var email = ""
    var password = ""
    var accountID = ""
    var configured = false
    var testing = false
    var result: String?
    var isError = false
}

struct Sub2APISettingsView: View {
    let provider: AIProviderID
    let directAvailable: Bool
    let needsFallback: Bool
    @Environment(AppModel.self) private var model
    private var providerName: String { provider == .codex ? "Codex" : "Claude" }
    private var hasStoredConfiguration: Bool {
        Sub2APISettingsStore(provider: provider).hasConfiguration()
    }
    private var draft: Sub2APIDraft { model.sub2apiDrafts[provider]! }

    var body: some View {
        @Bindable var form = draft
        Group {
            // 在用户正在填写时保持表单，避免后台自动查询恢复后突然移走输入框。
            if needsFallback || form.configured || hasStoredConfiguration || form.expanded {
                DisclosureGroup(isExpanded: $form.expanded) {
                    if directAvailable && form.configured {
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
                        if form.configured { Text(tr("已配置")).dsFont(.xs).foregroundStyle(DS.Palette.success) }
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    private var configurationForm: some View {
        @Bindable var form = draft
        return VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(tr("自动查询失败时才使用此 Sub2API 账号；后台不主动探测。"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(tr("Sub2API 地址（HTTPS）"), text: $form.address)
                .textFieldStyle(.roundedBorder)
            TextField(tr("管理员邮箱"), text: $form.email)
                .textFieldStyle(.roundedBorder)
            SecureField(tr("管理员密码"), text: $form.password)
                .textFieldStyle(.roundedBorder)
            TextField(tr("账号 ID"), text: $form.accountID)
                .textFieldStyle(.roundedBorder)
            Text(tr("管理员密码存于本机钥匙串；账号 ID 用于查询额度。"))
                .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DS.Space.s2) {
                Button(tr("保存并测试连接")) { Task { await saveAndTest() } }
                    .buttonStyle(DSButtonStyle(kind: .primary))
                    .disabled(form.testing)
                if form.configured {
                    Button(tr("移除配置")) { clear() }
                        .buttonStyle(DSButtonStyle(kind: .secondary))
                        .disabled(form.testing)
                }
            }
            if form.testing { ProgressView().controlSize(.small) }
            if let result = form.result {
                Text(result).dsFont(.xs)
                    .foregroundStyle(form.isError ? DS.Palette.error : DS.Palette.success)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, DS.Space.s2)
    }

    private func configuration() -> Sub2APIConfiguration? {
        do {
            return try Sub2APIConfiguration(address: draft.address, email: draft.email,
                                            password: draft.password, accountID: draft.accountID, provider: provider)
        } catch let error as Sub2APIConfigurationError {
            show(message(for: error), error: true)
        } catch {
            show(tr("Sub2API 配置无效"), error: true)
        }
        return nil
    }

    private func load() {
        guard !draft.loaded else { return }
        draft.loaded = true
        do {
            guard let saved = try Sub2APISettingsStore(provider: provider).load() else { return }
            draft.address = saved.baseURL.absoluteString
            draft.email = saved.email
            draft.password = saved.password
            draft.accountID = String(saved.accountID)
            draft.configured = true
        } catch {
            show(tr("Sub2API 配置无法读取，请检查设置"), error: true)
        }
    }

    private func saveAndTest() async {
        guard let configuration = configuration() else { return }
        draft.testing = true
        defer { draft.testing = false }
        do {
            let snapshot = try await Sub2APIQuotaClient.shared.fetch(configuration: configuration)
            try Sub2APISettingsStore(provider: provider).save(configuration)
            draft.configured = true
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
            draft.address = ""; draft.email = ""; draft.password = ""; draft.accountID = ""
            draft.configured = false
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
        draft.result = text
        draft.isError = error
    }
}
