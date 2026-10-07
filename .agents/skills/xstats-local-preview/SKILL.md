---
name: xstats-local-preview
description: Build, sign, install, and inspect the current XStats macOS app locally so the user can preview working-tree changes. Use for 本地构建、测试安装、预览效果; not for public releases.
---

<!-- Copyright (C) 2026 ysicing -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# XStats 本地构建预览

把当前工作区的 macOS App 编译并安装到 `/Applications/XStats.app`，让用户查看实际界面。使用仓库现有的 `Taskfile.yml` 和 `scripts/install_local.sh`；正式签名、公证和对外发布走 `xstats-release`。

## 开始前

- 确认位于 XStats 仓库，读当前 `AGENTS.md`、`Taskfile.yml` 和 `scripts/install_local.sh`。查看 `git status --short --branch`、`./scripts/version.sh`，辨别本次要预览的改动，保留已有未提交文件。
- 按变更范围运行有意义的定向测试，例如清理规则对应 `CleanerTests`，用户可见文案对应 `LocalizationTests`。共享或高风险逻辑按仓库门禁扩大验证；不要为了低风险预览重复跑无关测试。
- 本地预览通常用 `BUMP=0`，避免仅因试装修改 `project.yml`。若**新增或移除了 Widget kind**，同一构建号可能使系统小组件目录沿用旧结果；这时明确推进一次内部构建号并在结果中报告 `project.yml` 的变化。不要仅因普通 UI 编辑而加号。

## 构建与安装

1. 使用 `security find-identity -v -p codesigning` 核对本机 Developer ID 身份；主 App 与 Widget 的 provisioning profile 名称按本机实际安装情况及 `docs/DEVELOPMENT.md` 配置为 `XSTATS_APP_PROFILE`、`XSTATS_WIDGET_PROFILE`。有多张证书时用 `SIGN_ID` 选择与两个 profile 匹配的一张。不要硬编码身份、索要私钥或修改 Apple 账户。缺少可用签名时明确报告；ad-hoc 构建无法预览特权辅助工具功能。
2. 先编译，不安装：`task build BUMP=0 INSTALL=0 CONFIG=Release`。若上一步确认需要刷新 Widget 目录，仅这次改为 `BUMP=1`。命令继承已经核实的签名环境变量。
3. 确认构建成功，并对 `build/DerivedData-arm64/Build/Products/Release/XStats.app` 运行 `codesign --verify --deep --strict`、`lipo -archs`。用 `plutil -extract CFBundleShortVersionString raw -o - <App>/Contents/Info.plist` 和对应的 `CFBundleVersion` 读取版本；相对路径不要交给 `defaults read` 当域名解析。
4. 运行 `./scripts/install_local.sh build/DerivedData-arm64/Build/Products/Release/XStats.app`。它会退出旧 App 和扩展、替换 `/Applications/XStats.app` 并启动新版，保留用户偏好与历史。若仅因 `XStatsWidget 尚未退出` 而失败，可先结束 **XStatsWidget** 进程、等待退出后重试一次；不要终止 Notification Center 或清理用户数据。

## 验收与边界

- 回读 `/Applications/XStats.app/Contents/Info.plist` 的公开版本与构建号，再验证安装包签名和 XStats 进程。可用 UI 工具时打开本次相关页面，观察实际状态；若看不到 UI，只报告已验证的构建、安装和进程事实。
- 若新增 Widget，让用户在“编辑小组件”中确认新入口可见。`pluginkit` 登记或二进制包含新 kind，只证明扩展已安装，不能单独证明小组件目录已经刷新。
- 最后检查 `git status`，说明是否产生了预期的构建号改动。除非用户另有明确要求，不提交、不推送，也不运行 `task release`、`task release-all` 或任何发布脚本。
