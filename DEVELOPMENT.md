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
task snapshot                       # 使用当前 Release 构建渲染截图
task version                        # 查看版本与构建号
task clean                          # 删除 build/
```

截图默认使用 `build/DerivedData-arm64/Build/Products/Release/XStats.app`，不会悄悄使用 `/Applications` 中的旧版本。
先构建再生成网络演示截图：

```bash
task build BUMP=0 INSTALL=0
task snapshot SNAPSHOT_DIR=build/readme-1.0/zh-Hans -- --connections-only --language zh-Hans
task snapshot SNAPSHOT_DIR=build/readme-1.0/en -- --connections-only --language en
# 自选已有构建与输出目录；Debug 构建也可直接指定 CONFIG=Debug
task snapshot SNAPSHOT_APP=/path/to/XStats.app SNAPSHOT_DIR=build/screens -- --connections-only --language ja
```

`--connections-only` 使用隔离偏好与虚构连接，不采集本机连接、不安装或注册组件、不触发更新检查。
输出连接窗口、宽版连接页、暂停页、功能设置，以及组件未安装、已安装、待后台授权、可更新状态的明暗 PNG。
连接地址采用文档示例网段，地图分布为演示值；组件版本 `9.9.9 (9999)` 明确为虚构。
完整截图模式也会追加这些网络截图，但完整模式仍会读取本机指标、AI 用量及执行只读清理扫描；公开展示优先选定向模式。
截图目录或 PNG 写入失败时进程返回非零退出码。四语言 README 的网络图片来自各语言的
`connections-page-wide-light.png` / `connections-page-wide-dark.png`，分别保存为
`Assets/readme/connections-<zh-Hans|en|ja|ko>-<light|dark>.png`。

已有功能的 README 演示图库使用 `--features-only`：

```bash
task snapshot SNAPSHOT_DIR=build/feature-gallery/zh-Hans -- --features-only --language zh-Hans
```

该模式输出 AI 用量、历史趋势、显示器控制、番茄钟、音频混音和日历的明暗截图。
AI 由虚构 provider 提供；历史使用本次运行创建并清理的临时数据库；显示器、音频和番茄钟只注入展示状态，
不读取个人 AI 日志、不连接真实 DDC、不修改音量、不启动计时或写入 Widget 共享状态。
日历使用固定演示日期，中文展示农历与节假日，其他语言展示通用月历，不读取系统日程。README 每种语言选取六张代表图，存入 `Assets/readme/`。

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
| Widget App Group | `group.work.12306.xstats` |
| 观察 IPC App Group | `$(TeamIdentifierPrefix)work.12306.xstats.network-observation` |
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
点击“启用连接查看”时，主应用按需从 c-ip 下载并验证独立组件，安装到
`/Applications/XStats Network Monitor.app`。组件负责系统扩展激活和过滤器配置，
再按 macOS 提示批准系统扩展与网络过滤。主 `XStats.app` 不嵌入网络扩展，
不携带 System Extension 安装或 Network Extension 权限。首版统一放行，
只记录新连接的元数据与结束状态，不读取通信内容。
默认按应用查看，也可按进程、域名或国家切换连接数汇总；国家地图首次使用时从 c-ip 下载 DB-IP Lite 压缩国家表，校验后在本机离线查询，
同国家聚合显示数量，不表示精确设备位置。仅包含观察期间的新连接，不枚举观察开始前
已存在的连接；有界缓存满时不声称覆盖全部系统连接。
暂停保留画面并停止读取，恢复时以新租约观察；关闭页面或锁屏停止观察；关闭模块保存过滤器关闭状态。移除前使用页面内的
“更多 → 移除网络扩展”，系统若报告待重启则先重启，再删除应用包。

主应用、独立组件和扩展必须使用同一 Developer ID 团队；组件与扩展需要匹配权限的新 profiles：

- 主应用 `work.12306.xstats.app`：保留 Widget App Group、观察 IPC App Group 与日历权限；
  不需要 Network Extensions 或 System Extension 安装权限，仍通过 `XSTATS_APP_PROFILE` 选择。
- 独立组件 `work.12306.xstats.networkmonitor`：Network Extensions、System Extension 安装权限和
  观察 IPC App Group，通过 `XSTATS_COMPONENT_PROFILE` 选择；最低 macOS 15。
- 网络扩展 `work.12306.xstats.app.networkextension`：
  `content-filter-provider-systemextension` 与观察 IPC App Group，通过 `XSTATS_NETWORK_PROFILE` 选择。
- Widget 继续使用 `XSTATS_WIDGET_PROFILE` 和原 Widget App Group；组件不包含 Widget 或 helper。

```bash
task build-network-component SIGN_ID=- CONFIG=Debug  # ad-hoc 编译/分层签名，不安装、不推进版本
XSTATS_COMPONENT_PROFILE='xstats-network-monitor' \
XSTATS_NETWORK_PROFILE='xstats-ne-filter' task compile-network-component CONFIG=Release
```

独立 scheme 是 `XStatsNetworkMonitor`，产品位于
`build/DerivedData-network-arm64/Build/Products/<配置>/XStats Network Monitor.app`。
ad-hoc 构建仅用于 UI 与编译验证：去除组件根应用的受限网络权限，无法通过首次安装的
同团队／Gatekeeper 验证，也不能作为真实系统扩展授权与升级验收依据。
Profile 名称须与本机安装的描述文件一致；上例为当前团队的组件与扩展 profile 名称。
创建组件 App ID 时启用 Network Extensions 与 System Extension，并选择本机已有私钥的
Developer ID Application 证书生成 profile。现有扩展 ID 和 profile 可继续使用。
观察 IPC Group 使用 `<Team ID>.work.12306.xstats.network-observation` 的 macOS 专用格式，
无需在后台注册，也不要求 profile 列出该组；系统会验证签名团队前缀。
参见 [Apple 的 App Groups 说明](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups)。
正式运行仍须验证公证、系统授权、实际连接读取和停止后的资源释放，不能以编译成功代替。

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

独立组件与网络扩展共同使用 `NETWORK_EXTENSION_VERSION` 与 `NETWORK_EXTENSION_BUILD`。
组件、扩展、共享观察协议或影响扩展的依赖／编译器变化后，用 `scripts/version.sh network`
推进独立构建号。普通主应用 `build`／`release` 不改变组件版本，纯主 UI 改动复用现有组件。
主应用的首次安装器只写入缺失的组件；已有组件由自己的 Sparkle 更新，主应用不替换它。
首次安装 ZIP 固定为
`https://c.ysicing.net/oss/apps/macOS/XStats/network-monitor/XStats-Network-Monitor.zip`，
安装前校验根包名、Bundle ID、同团队签名、公证及 Gatekeeper，且不覆盖正在运行的组件。

主程序“设置 → 功能 → 网络监视器 → 管理组件”和监视页面“更多 → 管理组件”统一展示
安装、后台授权、组件/包内扩展版本、更新进度和完整卸载。未安装组件时，设置开关与监视页的启用操作
先弹出安装面板，安装成功后才继续启用；关闭面板或离开页面会取消待启用意图，安装失败保持原状态。
组件 Sparkle 固定读取
`network-monitor/appcast.xml`，主程序已有更新检查完成时复用同一调度检查组件；
也可从管理界面手动检查，不添加第二个检查计时器或自动下载/安装。共享 `Updates` 产品提供安装驱动；主应用和组件
各自持有自己的 updater、清单、构建号与更新选择。
组件控制使用 `SMAppService.agent` 注册的按需 LaunchAgent，其稳定 Mach 服务不经过扩展中转。
注册可能需要用户允许后台项目；界面仅按真实状态提示。服务不在登录时启动，也无 KeepAlive；
RPC/SDK结束后空闲退出。升级后由外部注册CLI按代码/agent plist指纹刷新注册，避免服务注销自己。
主程序普通退出会停用过滤配置；无人读取时扩展按租约串行应用全部放行规则，减少新流回调。
观察规则应用失败后，后续读取返回错误并按现有读取节奏重试；连续三次失败后界面报错停止，
无人读取时不重试。成功观察、新 provider 代次和旧回调的边界由代次及请求序号控制。
组件 GUI 沿用主程序语言偏好；服务和注册 CLI 的自定义错误传输中文源文案键，由接收界面翻译，
系统过滤配置名称使用显式语言翻译，不通过修改共享服务语言来迁就某一次调用。
协议使用明确的版本号，配置从磁盘读取而非 Bundle 缓存。完整卸载先注销后台项，再删除组件包。主应用更新不再按组件版本停用或替换扩展。
组件更新前比较已安装扩展和签名 XML 中的扩展版本：相同版本只停止组件读取；
版本变化时关闭过滤配置并有界确认实际停止。失败取消本次组件安装并恢复先前意图。
查询服务与扩展进程同寿命，配置已保存、XPC 断线或进程驻留不能单独证明停止。
Mach 服务后缀是扩展构建号，停用查询按系统报告的已安装构建定位服务。
重新启用后检查 `systemextensionsctl list` 的版本，必要时比较运行副本与组件包内扩展的 CDHash。
组件清单必须携带扩展版本，并与 ZIP 内的扩展 Info.plist 身份及版本一致；主应用清单无需该字段。

组件发行完全独立，不推进主版本、不走主 JSON 版本 API、不生成 Homebrew cask。
组件摘要维护在 `NetworkComponentReleaseNotes.json`：`version` 等于组件公开版本，`sourceNotes` 为简体中文单行条目，
`translations.en` 与中文条目一一对应；格式沿用 `ReleaseNotes.json`，与主程序摘要分别维护。

```bash
# 默认只构建、签名、公证、装订并生成 dist/network-monitor/ 的 ZIP、appcast.json、appcast.xml
NETWORK_RELEASE_NOTES=NetworkComponentReleaseNotes.json \
XSTATS_COMPONENT_PROFILE='组件 profile 名称' XSTATS_NETWORK_PROFILE='扩展 profile 名称' \
  task release-network-component

# 只有显式 --publish 才上传；使用同一套前置条件并重新构建制品
./scripts/release_network_component.sh --notes NetworkComponentReleaseNotes.json --publish
```

发布到 `c-ip/oss/apps/macOS/XStats/network-monitor`：先上传并 CDN 回读唯一版本 ZIP
`XStats-Network-Monitor-<version>-<build>-AppleSilicon.zip`，再用完全相同的已公证字节更新
首次安装别名 `XStats-Network-Monitor.zip`，最后更新已签名 `appcast.xml`。ZIP 或别名失败时
不更新 appcast；可变别名/XML 设置五分钟缓存，回读使用唯一查询避免旧缓存干扰。
`SKIP_NOTARIZE=1` 只允许本地打包，不能与 `--publish` 并用。

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
| `NetworkMonitorApp/`、`NetworkExtension/` | 独立网络伴随应用与其系统扩展 |
| `Packages/XStatsKit/Sources/` | 采集、AI 用量、清理、更新、同步与界面模块 |
| `Packages/XStatsKit/Tests/` | Swift 测试 |
| `server/api/` | 旧更新协议的兼容实现与测试 |
| `scripts/` | 版本、构建、发布与文档同步脚本 |
| `Taskfile.yml`、`project.yml` | 任务入口与 Xcode 工程配置 |
