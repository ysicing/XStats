// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import Localization

struct AIAssistantSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var config = model.aiAssistant
        SettingsGroup {
            GroupRow {
                SettingRow(title: tr("AI 助手"), subtitle: tr("用于解释进程，不自动执行系统操作")) {
                    DSToggle(isOn: $config.enabled, label: tr("AI 助手"))
                }
            }
            GroupRow {
                SettingRow(title: tr("默认服务"), subtitle: nil) {
                    Picker(tr("默认服务"), selection: $config.provider) {
                        ForEach(AssistantProvider.allCases) { provider in
                            Text(tr(provider.title)).tag(provider)
                        }
                    }.labelsHidden()
                }
            }
            if config.provider == .apple {
                GroupRow {
                    Text(ProcessExplainer.appleAvailability).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupRow {
                    SettingRow(title: tr("Apple 智能不可用时"), subtitle: tr("仅在设备、系统或模型不可用时使用备用服务")) {
                        Picker(tr("备用服务"), selection: $config.fallbackChoice) {
                            Text(tr("遇到时询问")).tag(AssistantFallbackChoice.ask)
                            Text(tr("不使用备用")).tag(AssistantFallbackChoice.none)
                            Text("Codex CLI").tag(AssistantFallbackChoice.codex)
                            Text("Claude Code").tag(AssistantFallbackChoice.claude)
                        }.labelsHidden()
                    }
                }
            }
        }
        SettingsGroup(caption: tr("CLI 服务")) {
            GroupRow {
                Text(tr("选择 Codex 或 Claude 作为默认或备用服务后，点击解释才会通过 CLI 联网发送脱敏进程摘要，并可能消耗额度。不发送完整路径、命令行参数或环境变量。"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupRow {
                cliFields(title: "Codex CLI", provider: .codex, path: $config.codexPath, selectedModel: $config.codexModel)
            }
            GroupRow {
                cliFields(title: "Claude Code", provider: .claude, path: $config.claudePath, selectedModel: $config.claudeModel)
            }
            GroupRow {
                Text(tr("CLI 使用独立临时目录，不加载项目规则或扩展工具。Codex 忽略用户配置；模型留空使用 CLI 内置默认。登录由 CLI 自行管理。"))
                    .dsFont(.xs).foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        SettingsGroup {
            GroupRow {
                Button(tr("测试进程解释")) {
                    model.explainProcess(.init(pid: getpid(), name: "XStats", displayName: "XStats",
                        executablePath: Bundle.main.executablePath, appBundlePath: Bundle.main.bundlePath,
                        cpu: nil, memory: nil, networkRate: nil))
                }.buttonStyle(DSButtonStyle(kind: .secondary))
                    .disabled(!config.enabled)
            }
        }
    }

    private func cliFields(title: String, provider: AssistantProvider, path: Binding<String>,
                           selectedModel: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(title).dsFont(.sm, weight: .semibold)
            TextField(tr("可执行文件路径（留空自动发现）"), text: path)
                .textFieldStyle(.roundedBorder)
            if let resolved = AssistantCLI.resolve(provider, override: path.wrappedValue) {
                Text(resolved.path).dsFont(.xs).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled)
            } else {
                Text(tr("未找到 CLI，请先安装或指定路径。")).dsFont(.xs).foregroundStyle(DS.Palette.warning)
            }
            TextField(tr("模型（留空使用默认）"), text: selectedModel).textFieldStyle(.roundedBorder)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
