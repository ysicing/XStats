<!-- Copyright (C) 2026 ysicing
SPDX-License-Identifier: AGPL-3.0-or-later -->

# XStats 开发指南

本文面向 XStats 的二次开发、构建、测试和发布。普通用户请先阅读
[README.md](README.md)。

## 开发环境

需要 macOS 14+、**Xcode 26 或更高版本**（仅有 CommandLineTools 时缺少 SwiftUI 宏插件）、
[Go 1.25+](https://go.dev/)、[Go Task](https://taskfile.dev/)、以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
brew install go go-task xcodegen
```

## 构建与测试

```bash
task generate                         # 由 project.yml 生成 Xcode 工程
task build                           # Release 构建、安装并启动
task build BUMP=0 INSTALL=0          # 只构建，不更新版本或安装
task compile CONFIG=Debug            # 只编译 Debug，不安装
task test                             # 版本脚本、API 和 Swift 单元测试
task open                             # 生成工程并用 Xcode 打开
task clean                            # 删除 build/
```

更新与安装统计 API 位于 `server/api`，直接运行一个 Fiber/GORM 程序：

```bash
cd server/api
XSTATS_RELEASE_TOKEN='本地测试令牌' go run .
```

默认监听 `:8080`，数据库为当前目录的 `xstats-api.sqlite`；可通过 `XSTATS_LISTEN` 和
`XSTATS_DATABASE` 覆盖。`GET /stats` 是聚合统计大屏。正式发版前在环境中设置
`XSTATS_RELEASE_TOKEN`。发布脚本默认把 `dist/appcast.json` 同时提交到全球与国内服务的
`PUT /api/v1/releases/current`；可用逗号分隔的 `XSTATS_API_URLS` 覆盖完整列表，旧的
`XSTATS_API_URL` 仍可覆盖为单个接口。

服务镜像可从仓库根目录构建：

```bash
docker build -f server/api/Dockerfile -t xstats-server:local .
docker run --rm -p 8080:8080 -e XSTATS_RELEASE_TOKEN='本地测试令牌' \
  -v xstats-api-data:/data xstats-server:local
```

GitHub Actions 只在分支 push 且 `server/**` 发生变化时构建并发布 amd64/arm64 镜像；PR 不运行。
镜像发布到 `ghcr.io/<owner>/xstats-server`，标签格式为清洗后的 `<分支>-<完整提交哈希>`。

构建固定使用 `arm64`，仅支持 Apple Silicon Mac。
有 Developer ID Application 证书时，Taskfile 会自动使用钥匙串中的第一个证书；否则使用项目默认的 ad-hoc 签名。

菜单栏应用没有普通窗口，可以用已安装的应用渲染实时截图：

```bash
/Applications/XStats.app/Contents/MacOS/XStats --snapshot build/snapshots
```

修改 `CHANGELOG.md` 后运行以下命令，更新 README 顶部的最近更新和活跃度图：

```bash
python3 Scripts/sync_changelog.py
```

## 版本号

公开版本号使用 `年.月.日.当日索引` 格式，例如 `2026.09.21.01`：

- 当天首次构建使用 `.01`，同日后续构建递增。
- 日期变化后索引重置为 `.01`。
- `CURRENT_PROJECT_VERSION` 是独立的 Apple 内部构建号，每次构建持续递增且不重置。

```bash
task version                          # 显示当前版本
task version-next                     # 预览下一公开版本号
```

## 发布

正式分发需要 Apple Developer Program 的 **Developer ID Application** 证书、对应私钥，
以及 `notarytool` 公证凭据。发布脚本会构建 Apple Silicon 版本，检查签名团队、
安全时间戳、Hardened Runtime、公证票据和 Gatekeeper，然后生成 DMG、在线升级包和 Homebrew cask。

先将公证凭据保存到钥匙串：

```bash
xcrun notarytool store-credentials XStats \
  --apple-id you@example.com \
  --team-id YOUR_TEAM_ID
```

然后发布：

```bash
NOTARY_PROFILE=XStats task release
```

如果使用其他 profile，可以覆盖 `NOTARY_PROFILE`。`SKIP_NOTARIZE=1 task release` 只适合本机测试，
生成的包不应公开分发。

发布前需要先把对应版本写入 `CHANGELOG.md`，标题格式为：

标题示例：`## 2026.09.21.01 · 2026-09-21`。

## 项目结构

- `App/`：应用入口和资源。
- `Widget/`：WidgetKit 扩展。
- `Helper/`：特权辅助工具及 launchd 配置。
- `Packages/XStatsKit/Sources/SMC`：SMC 通信、温度传感器和风扇控制。
- `Packages/XStatsKit/Sources/Metrics`：CPU、内存、网络、GPU、磁盘、电池、进程和传感器采集。
- `Packages/XStatsKit/Sources/Cleaner`：清理规则、安全守卫、扫描和执行。
- `Packages/XStatsKit/Sources/Updates`：版本清单、下载校验和应用替换。
- `Packages/XStatsKit/Sources/HelperShared`：应用与辅助工具共用的 XPC 协议和维护命令。
- `Packages/XStatsKit/Sources/WebDAVSync`：WebDAV 同步和钥匙串密码存储。
- `Packages/XStatsKit/Sources/XStatsUI`：界面、设置、弹窗和菜单栏渲染。
- `Packages/XStatsKit/Tests`：Swift 单元测试。

更深入的模块边界、采样策略和安全约束见 [ARCHITECTURE.md](ARCHITECTURE.md)。
