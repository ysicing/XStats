<!-- Copyright (C) 2026 ysicing
SPDX-License-Identifier: AGPL-3.0-or-later -->

# XStats 开发指南

本文用于本地开发、构建、测试和发布。应用使用说明见 [README.md](README.md)，
模块边界与实现约束见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## xstats 深链

安装 App 后，启动器或 `open 'xstats://open/audio'` 可通过系统 URL 事件调用现有入口。

| 路径 | 行为 |
| --- | --- |
| `xstats://open` | 显示主窗口，保留当前页面 |
| `xstats://open/<page>` | 打开页面 |
| `xstats://panel/<item>` | 显示菜单栏详情；没有该入口时转到主窗口对应页面 |
| `xstats://panel/overview` | 显示合并总览；分开显示模式转到主窗口总览 |
| `xstats://open/calendar` | 日历；未开启时转到功能设置 |
| `xstats://open/speed-test`、`xstats://open/egress` | 测速、出口与分流窗口，不自动运行探测 |
| `xstats://rest/<action>` | 番茄钟：`start`、`pause`、`toggle`、`reset`、`skip`、`hud` |
| `xstats://keep-awake/<action>` | 普通防休眠：`start`、`stop`、`toggle` |

`page`：`overview`、`system`、`history`、`ai-usage`、`cpu`、`gpu`、`memory`、`disk`、
`network`、`thermal`、`battery`、`processes`、`audio`、`keep-awake`、`rest`、`cleaner`、
`uninstaller`、`startup-items`，以及 `settings/general`、`settings/features`、`settings/menu-bar`、
`settings/notifications`、`settings/helper`、`settings/about`；`settings` 等同于 `settings/general`。

`item`：`cpu`、`gpu`、`memory`、`network`、`disk`、`temperature`、`fan`、`battery`、
`ai-usage`、`display`、`audio`。模块关闭时转到功能设置，不更改开关。

链接不接受查询参数、片段、账户、端口或转义路径。普通防休眠链接遇到已请求的合盖模式时
只打开防休眠页，由用户操作；链接不直接下发特权设置或执行清理、卸载。
冷启动命令会在控制器初始化后顺序执行；单条链接最多 2048 字节，等待队列最多 16 条。
显式 `start`、`pause`、`stop` 保持幂等，`toggle` 每次都会切换。

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

## 网络连接试验模块

“功能 → 网络监视器”仅在 macOS 15 及以上开放，默认关闭。macOS 14 不显示入口，
保留原有功能；即使旧偏好或备份包含开启状态，也不会激活扩展。进入页面后
点击“启用连接查看”，再按 macOS 提示批准
系统扩展与网络过滤。首版统一放行，只记录新连接的元数据与结束状态，不读取通信内容。
默认按应用查看，也可按进程、域名或国家切换连接数汇总；国家地图首次使用时从 c-ip 下载 DB-IP Lite 压缩国家表，校验后在本机离线查询，
同国家聚合显示数量，不表示精确设备位置。仅包含观察期间的新连接，不枚举观察开始前
已存在的连接；有界缓存满时不声称覆盖全部系统连接。
暂停保留画面并停止读取，恢复时以新租约观察；关闭页面或锁屏停止观察；关闭模块保存过滤器关闭状态。移除前使用页面内的
“更多 → 移除网络扩展”，系统若报告待重启则先重启，再删除应用包。

签名配置需要与 Developer ID 团队匹配的新 profiles，现有仅带 App Group 的 profiles
不能用于这个构建：

- 主应用 `work.12306.xstats.app`：Network Extensions 与 System Extension 安装权限，
  保留已有 App Group、日历权限；通过 `XSTATS_APP_PROFILE` 选择。
- 网络扩展 `work.12306.xstats.app.networkextension`：
  `content-filter-provider-systemextension`；通过 `XSTATS_NETWORK_PROFILE` 选择。
- Widget 继续使用 `XSTATS_WIDGET_PROFILE`。

```bash
XSTATS_APP_PROFILE='主应用 profile 名称' \
XSTATS_NETWORK_PROFILE='网络扩展 profile 名称' \
XSTATS_WIDGET_PROFILE='Widget profile 名称' task build BUMP=0 INSTALL=0
```

地图轮廓仍内置；两个 IP 库不再打入应用包。只有监视页面可见且采集正在运行时才下载或
检查更新；暂停、关闭页面、锁屏和休眠取消尚未完成的下载。成功数据保存在
`~/Library/Application Support/XStats/NetworkGeography`，不进入设置备份；30天内复用，
没有后台更新计时器。“更多 → 更新地图数据库”可手动刷新。下载失败不影响连接列表，
已有库保持可用；IPv4／IPv6 一起校验并原子切换本机索引。

发布流程在应用制品上传前自动执行 `scripts/sync_network_geography.py --publish`：
从 DB-IP 官方本月 gzip CSV 下载、严格校验并转换，使用系统 LZFSE 压缩；上传至
`c-ip/oss/apps/macOS/XStats/network-geography`。文件名包含压缩内容 SHA-256，先上传
并回读校验两个不可变文件，最后更新 `current.json`（CDN max-age=300）。同步失败会中止
后续应用制品和版本清单发布。客户端入口固定为
`https://c.ysicing.net/oss/apps/macOS/XStats/network-geography/current.json`。

```bash
python3 scripts/sync_network_geography.py            # 只准备到 dist/network-geography
python3 scripts/sync_network_geography.py --publish  # 从官方重新获取并同步 c-ip
```

网络扩展代码或观察协议变更后，本地试装必须用 `scripts/version.sh build` 推进一次
内部构建号，再执行 `task build BUMP=0`；或直接使用默认 `task build`。
macOS 可能把相同版本／构建号的激活请求视为已安装，继续运行旧扩展。
安装主应用不能单独证明扩展已升级：重新启用后检查 `systemextensionsctl list` 的版本，
必要时对比系统运行副本与主应用内扩展的 CDHash。普通 UI 改动仍可保持 `BUMP=0`。

可对构建执行 `XStats --snapshot <目录> --connections-only --language en` 走查界面。
此命令只使用虚构连接数据，不能替代签名安装、系统授权、真实连接观察和停止验证。

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
