<!-- Copyright (C) 2026 ysicing
SPDX-License-Identifier: AGPL-3.0-or-later -->

# XStats 开发指南

本文用于本地开发、构建、测试和发布。应用使用说明见 [README.md](README.md)，
模块边界与实现约束见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 开发环境

- macOS 14+，Apple Silicon Mac；构建固定使用 `arm64`。
- Xcode 26+；仅安装 CommandLineTools 无法提供所需的 SwiftUI 宏插件。
- Python 3、Go 1.25+、Go Task 和 XcodeGen；Go 用于 API 兼容性测试。

```bash
brew install go go-task xcodegen
```

## 常用命令

在仓库根目录执行：

```bash
task generate                       # 从 project.yml 生成 Xcode 工程
task build                          # 构建、安装并启动；构建号递增
task build BUMP=0 INSTALL=0          # 只构建，不改构建号或安装
task compile CONFIG=Debug           # 只编译 Debug，不安装
task test                           # 脚本、Go API 和 Swift 测试
task open                           # 生成工程并用 Xcode 打开
task snapshot                       # 使用已安装的 App 渲染实时截图
task version                        # 查看版本与构建号
task clean                          # 删除 build/
```

菜单栏布局走查可对当前构建运行 `XStats --snapshot <目录> --menubar-only --language en`；
仅采集相关指标，输出三种布局、总览和详情的明暗截图，不扫描清理目录或 AI 日志。
显示器控制页面可改用 `--display-only`，只读本机信息和 DDC 能力，不修改硬件设置。

`project.yml` 是 Xcode 工程配置来源，调整 target、entitlement 或签名设置后重新生成工程。
修改 `CHANGELOG.md` 后运行 `python3 scripts/sync_changelog.py`，同步 README 版本摘要与活跃度图。

## 本地签名与权限

有 Developer ID Application 证书时默认选择钥匙串中的第一个身份；多张证书时用
`SIGN_ID` 指定证书指纹。无可用身份时使用 ad-hoc 签名，不能在线安装更新或使用特权辅助工具。

主应用与 Widget 的签名需要启用相同的 App Group，并分别安装匹配的 provisioning profile：

| 项目 | 标识或配置 |
|---|---|
| 主应用 Bundle ID | `work.12306.xstats.app` |
| Widget Bundle ID | `work.12306.xstats.app.widget` |
| App Group | `group.work.12306.xstats` |
| 主应用 profile 名称 | 环境变量 `XSTATS_APP_PROFILE` |
| Widget profile 名称 | 环境变量 `XSTATS_WIDGET_PROFILE` |

```bash
export XSTATS_APP_PROFILE='主应用 profile 名称'
export XSTATS_WIDGET_PROFILE='Widget profile 名称'
task compile CONFIG=Debug
```

日程权限还需要最终 App 签名包含 `com.apple.security.personal-information.calendars`；
仅有 Info.plist 说明不足以触发授权。授权由用户在应用中主动请求。

## 发布

正式分发需要 Developer ID 证书及私钥、公证凭据、`mc`（对象存储别名 `c-ip`）、
已登录的 `gh`，以及环境变量 `XSTATS_RELEASE_TOKEN`。公证凭据首次保存：

```bash
xcrun notarytool store-credentials XStats --apple-id you@example.com --team-id YOUR_TEAM_ID
```

发版前将 `CHANGELOG.md` 顶部的 `## 未发布` 替换为 `## X.Y.Z · YYYY-MM-DD`，
同步 `ReleaseNotes.json` 的中英文摘要和四个 README 的版本徽章。
公开版本取自 CHANGELOG，构建号由脚本递增；`project.yml` 的版本字段由脚本更新。

源码改动先提交并推送；构建前只保留允许的版本元数据改动。完整发布命令：

```bash
NOTARY_PROFILE=XStats task release-all
```

此命令执行测试、签名、公证、打包、提交推送版本元数据，并发布制品、API 清单和 Homebrew cask。
`task release` 只构建制品；已推送 release commit 后若外部发布失败，用 `task publish` 续跑。
重新执行 `task release-all` 会再次推进构建号。

发布构建保存在 `build/DerivedData-arm64/Build/Products/Release/XStats.app`，不安装到本机。
脚本校验架构、同团队签名、公证、Gatekeeper、构建来源和公开制品哈希。
Sparkle 私钥使用已有钥匙串账户，构建后的源码或摘要译文变化需要重新构建。

更新与发布使用 `/api/v1/apps/xstats/...`，入口为：

- 国内：`https://apps.china.12306.work`。
- 海外主入口：`https://apps.12306.work`。
- 海外备用入口：`https://apps-api.xiai.me`。

默认发布和校验覆盖三个入口，固定路径及环境变量覆盖方式见 [发布脚本](scripts/publish_api.py)。
详细签名配置、制品核验、分步发布与失败恢复见 [发布 runbook](.agents/skills/xstats-release/references/runbook.md)。

## 项目目录

| 路径 | 用途 |
|---|---|
| `App/`、`Widget/`、`Helper/` | 主应用、桌面小组件、特权辅助工具 |
| `Packages/XStatsKit/Sources/` | 采集、AI 用量、清理、更新、同步与界面模块 |
| `Packages/XStatsKit/Tests/` | Swift 测试 |
| `server/api/` | 旧更新协议的兼容实现与测试 |
| `scripts/` | 版本、构建、发布与文档同步脚本 |
| `Taskfile.yml`、`project.yml` | 任务入口与 Xcode 工程配置 |
