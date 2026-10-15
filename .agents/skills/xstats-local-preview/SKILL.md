---
name: xstats-local-preview
description: Build, install, and inspect the current XStats macOS app locally, using ad-hoc signing by default and certificate signing when verifying privileged features or existing macOS privacy permissions. Use for 本地构建、测试安装、预览效果; not for public releases.
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

1. 按本次验收范围选择签名：
   - **默认使用本地临时签名（ad-hoc）**，适用于界面、文案和普通功能预览。显式设置 `SIGN_ID=-`，不查询证书或配置 provisioning profile；仓库脚本会完成临时签名，无需 Apple 时间戳服务或公证。不要省略 `SIGN_ID`，否则 `Taskfile.yml` 会自动选择钥匙串中的 Developer ID 证书。
   - **需要验证特权辅助工具、Widget／App Group，或沿用屏幕录制、麦克风、日历等 macOS 隐私授权时，使用证书签名**。临时签名的应用身份绑定代码哈希，替换原证书签名版本后，即使系统设置中的权限开关仍打开，TCC 也可能因签名要求不匹配而拒绝访问；重新构建后也可能需要重新授权。截图与录屏的实际捕获验收应沿用原 Developer ID 团队身份，不反复要求用户切换权限开关。使用 `security find-identity -v -p codesigning` 核对本机 Developer ID 身份；主 App 与 Widget 的 provisioning profile 名称按本机实际安装情况及 `docs/DEVELOPMENT.md` 配置为 `XSTATS_APP_PROFILE`、`XSTATS_WIDGET_PROFILE`，并用 `SIGN_ID` 选择与两个 profile 匹配的证书。不要硬编码身份、索要私钥或修改 Apple 账户。缺少可用签名时报告相应功能无法验证，不把临时签名的 UI 预览当作特权或隐私授权功能验收。
2. 先编译，不安装。默认命令为 `SIGN_ID=- task build BUMP=0 INSTALL=0 CONFIG=Release`；需要证书签名时，使用上一步核实的签名环境变量运行 `task build BUMP=0 INSTALL=0 CONFIG=Release`。若确认需要刷新 Widget 目录，仅这次改为 `BUMP=1`。
3. 确认构建成功，并对 `build/DerivedData-arm64/Build/Products/Release/XStats.app` 运行 `codesign --verify --deep --strict`、`lipo -archs`；用 `codesign -dv --verbose=4` 确认默认构建为 `Signature=adhoc`，证书构建的团队与所选身份一致。用 `plutil -extract CFBundleShortVersionString raw -o - <App>/Contents/Info.plist` 和对应的 `CFBundleVersion` 读取版本；相对路径不要交给 `defaults read` 当域名解析。
4. 运行 `./scripts/install_local.sh build/DerivedData-arm64/Build/Products/Release/XStats.app`。它会退出旧 App 和扩展、替换 `/Applications/XStats.app` 并启动新版，保留用户偏好与历史。若仅因 `XStatsWidget 尚未退出` 而失败，可先结束 **XStatsWidget** 进程、等待退出后重试一次；不要终止 Notification Center 或清理用户数据。

## 验收与边界

- 回读 `/Applications/XStats.app/Contents/Info.plist` 的公开版本与构建号，再验证安装包签名和 XStats 进程。报告实际使用的签名方式；临时签名不代表特权辅助工具、团队身份或受限权限已经验证。权限开关已开但访问仍被拒绝时，先核对 `codesign -dr -` 和 `tccd` 的签名要求不匹配日志，不自动重置 TCC 或修改授权数据库。可用 UI 工具时打开本次相关页面，观察实际状态；若看不到 UI，只报告已验证的构建、安装和进程事实。
- 若新增 Widget，让用户在“编辑小组件”中确认新入口可见。`pluginkit` 登记或二进制包含新 kind，只证明扩展已安装，不能单独证明小组件目录已经刷新。
- 最后检查 `git status`，说明是否产生了预期的构建号改动。除非用户另有明确要求，不提交、不推送，也不运行 `task release`、`task release-all` 或任何发布脚本。
