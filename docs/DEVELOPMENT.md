<!-- Copyright (C) 2026 ysicing
SPDX-License-Identifier: AGPL-3.0-or-later -->

# XStats 开发指南

本文用于本地开发、构建、测试和发布。应用使用说明见 [README.md](../README.md)，
模块边界与实现约束见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## xstats 深链

安装 App 后，启动器或 `open 'xstats://open/audio'` 可通过系统 URL 事件调用现有入口。

| 路径 | 行为 |
| --- | --- |
| `xstats://open` | 显示主窗口，保留当前页面 |
| `xstats://open/<page>` | 打开页面 |
| `xstats://panel/<item>` | 显示菜单栏详情；没有该入口时转到主窗口对应页面 |
| `xstats://panel/overview` | 显示聚合模式的状态总览；分开显示模式转到主窗口总览 |
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
# 自选已有构建与输出目录；Debug 构建也可直接指定 CONFIG=Debug
task snapshot SNAPSHOT_APP=/path/to/XStats.app SNAPSHOT_DIR=build/screens -- --connections-only --language ja
```

`--connections-only` 使用隔离偏好与虚构连接，不采集本机连接、不安装或注册组件、不触发更新检查。
输出连接窗口、宽版连接页、暂停页、功能设置，以及组件未安装、已安装、待后台授权、可更新状态的明暗 PNG。
连接地址采用文档示例网段，地图分布为演示值；组件版本 `9.9.9 (9999)` 明确为虚构。
完整截图模式也会追加这些网络截图，但完整模式仍会读取本机指标、AI 用量及执行只读清理扫描；公开展示优先选定向模式。
截图目录或 PNG 写入失败时进程返回非零退出码。四语言 README 共用一套中文界面截图，说明文字与图片替代文本分别翻译；不必为每种文档语言重新生成截图。网络图片来自
`connections-page-wide-light.png` / `connections-page-wide-dark.png`，分别保存为
`Assets/readme/connections-zh-Hans-<light|dark>.png`。

已有功能的 README 演示图库使用 `--features-only`：

```bash
task snapshot SNAPSHOT_DIR=build/feature-gallery/zh-Hans -- --features-only --language zh-Hans
```

该模式输出 AI 用量、历史趋势、显示器控制、番茄钟、音频混音和日历的明暗截图。
AI 由虚构 provider 提供；历史使用本次运行创建并清理的临时数据库；显示器、音频和番茄钟只注入展示状态，
不读取个人 AI 日志、不连接真实 DDC、不修改音量、不启动计时或写入 Widget 共享状态。
日历使用固定演示日期，中文展示农历与节假日，其他语言展示通用月历，不读取系统日程。
README 共用图库选取 AI、历史、显示器、番茄钟、音频与日历六张中文代表图，并加入
`monitoring-features-zh-Hans-light.png` 和 `optional-features-zh-Hans-light.png`。
网络定向模式另选连接总览明暗两张，以及 `component-install-light.png`、`component-installed-light.png`，
分别保存为 `component-install-zh-Hans-light.png` 和 `component-management-zh-Hans-light.png`。
截图统一使用当前发布构建；核心监控和工具页可来自完整模式的只读采样，公开使用前检查用户路径、设备标识和真实地址。
保留演示数据说明，不把模拟组件版本当成实际发布版本。

菜单栏布局走查可对当前构建运行 `XStats --snapshot <目录> --menubar-only --language zh-Hans`；
仅采集相关指标，输出三种布局、总览和详情的明暗截图，不扫描清理目录或 AI 日志。
README 的聚合状态总览使用该模式的 `overview-light.png` / `overview-dark.png`，
保存为 `Assets/readme/combined-overview-zh-Hans-<light|dark>.png`，与主窗口仪表盘截图区分。
显示器控制页面可改用 `--display-only`，只读本机信息和 DDC 能力，不修改硬件设置。

系统信息中的 Apple 智能详情可单独走查：

```bash
task snapshot SNAPSHOT_DIR=build/apple-intelligence -- --apple-intelligence-only --language zh-Hans
# 使用 --demo 只验证界面，不读取本机 Apple 智能偏好或模型占用
task snapshot SNAPSHOT_DIR=build/apple-intelligence-demo -- --apple-intelligence-only --demo --language en
```

实际模式输出只读 `report.json`，以及详情浮层、入口行的明暗 PNG；详细功能与模型占用检测仅在 macOS 27+
执行，其他版本保留已有本机模型可用性摘要，明细标注无法检测。读取资产服务失败不视为零占用，
功能配置状态与 `removemacai status` 的判定顺序一致：受管理关闭、明确关闭、仅模型型功能按占用判断，
其他情况默认开启（包括未保存显式值）。没有独立开关的照片清理与 Xcode 补全按模型占用判断开启或关闭；
模型清单读取失败后改查单个模型集合，仍失败时保持未知。顶部本机模型可用性单独使用 Foundation Models
API 检测；配置开启不代表模型可用。此模式不生成回答、修改设置、下载或删除模型。

`project.yml` 是 Xcode 工程配置来源，调整 target、entitlement 或签名设置后重新生成工程。
修改 `CHANGELOG.md` 后运行 `python3 scripts/sync_changelog.py`，同步 README 版本摘要与活跃度图。

## 监控功能与采样验证

“设置 → 功能”使用“基础功能”和“可选功能”两个页签；选择器与页面标题共用固定顶栏，两页说明与列表起点一致；指针切换使用 180 毫秒淡入淡出，键盘与减少动态效果即时切换。切换后从列表顶部显示，不改变开关或新增采样需求。基础功能各行在标题下直接显示“在菜单栏显示”复选框，右侧开关只负责功能启用；不再用文字重复描述启用与展示状态，也不为这些开关添加额外动画。温度与风扇分别选择；可选功能中的 AI 用量和音频也提供相同的展示复选框。完整样式仍在菜单栏设置页调整。显示器参数控制放在可选功能中。基础监控的启用开关控制采集，菜单栏开关控制展示：
加入菜单栏时自动启用模块，移出菜单栏不关闭模块，关闭模块则移除菜单栏入口并停止监控、
相关告警和新增历史值。已有历史、样式与告警选择保留；基础监控开关也包含在设置备份中。

可选功能按用途拆为独立卡片：网络监视器、进程、卸载应用与清理一组；AI 用量、音频与显示器参数控制一组；专注与护眼、菜单栏日历各自单独一组。每组首项不画线，其余条目使用相同细分隔线，组间留白，不新增动画。

卸载应用也放在可选功能中，默认关闭。启用后显示侧栏入口，关闭后停止扫描并释放运行应用监听；深链转到功能设置。待确认操作会取消，已经开始的废纸篓操作正常收尾，移除期间禁用功能开关。偏好支持导出与恢复。

显示器是单独的参数控制开关：关闭后仍显示型号、分辨率、刷新率与菜单栏信息入口，停止 DDC 参数读写；加入显示器菜单栏不会自动开启参数控制。显示器信息由系统事件更新，不添加轮询。

启用但无展示、历史记录或提醒需求时不采集；全部需求为空时停止采样循环。历史记录默认开启，
只为仍启用的 CPU、内存、网络维持后台采样，其余指标仍按界面需求记录。
手动风扇关闭前交还系统控制，失败恢复功能入口；合盖运行继续保留电量保护。
这些开关控制主程序，系统小组件继续独立刷新。

定向截图 `--features-only` 额外输出 `monitoring-features-*`、`optional-features-*` 与 `monitoring-disabled-*`，可用
`--language en` / `ar` 走查长译文与从右到左布局。真实采样停止与重复启用验收生成阶段报告：

```bash
mkdir -p build/monitoring-verification
XSTATS_MONITORING_RESOURCE_REPORT="$PWD/build/monitoring-verification/resources.json" \
  swift test --package-path Packages/XStatsKit --filter MonitoringResourceTests
```

此项约运行 15 秒，使用隔离偏好，不操作风扇、音量、显示器或系统扩展；报告记录各阶段快照数、
CPU 采样数与测试进程 CPU 时间。它验证采样循环的需求与释放，不代表整机能耗或长期稳定性结论。

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
`https://c.ysicing.net/oss/apps/macOS/XStats/network-monitor/XStats-Network-Monitor-<version>-AppleSilicon.zip`，
安装前校验根包名、Bundle ID、同团队签名、公证、Gatekeeper 及协议版本与控制服务，且不覆盖正在运行的组件。
系统扩展要求组件位于 `/Applications`，标准账户无写权限时提示需要管理员账户，不通过辅助工具提权写入。

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

推进 `NetworkObservationProtocol.version` 前必须先补齐兼容路径，否则任一侧先升级都会让组件无法使用或卸载：
组件签名清单需携带协议版本，组件自更新在调用 Sparkle 安装前拒绝与当前主程序不兼容的版本；
主程序遇到已安装组件 `protocolMismatch` 时需提供卸载后重新安装的入口，而不是只校验不替换。

组件发行完全独立，不推进主版本、不走主 JSON 版本 API、不生成 Homebrew cask。
组件摘要维护在 `docs/NetworkComponentReleaseNotes.json`：`version` 等于组件公开版本，`sourceNotes` 为简体中文单行条目，
`translations.en` 与中文条目一一对应；格式沿用 `docs/ReleaseNotes.json`，与主程序摘要分别维护。

```bash
# 默认只构建、签名、公证、装订并生成 dist/network-monitor/ 的 ZIP、appcast.json、appcast.xml
NETWORK_RELEASE_NOTES=docs/NetworkComponentReleaseNotes.json \
XSTATS_COMPONENT_PROFILE='组件 profile 名称' XSTATS_NETWORK_PROFILE='扩展 profile 名称' \
  task release-network-component

# 只有显式 --publish 才上传；使用同一套前置条件并重新构建制品
./scripts/release_network_component.sh --notes docs/NetworkComponentReleaseNotes.json --publish
```

发布到 `c-ip/oss/apps/macOS/XStats/network-monitor`：每个公开版本只有
`XStats-Network-Monitor-<version>-AppleSilicon.zip`，构建号只保存在包内与 XML 中。
首次安装按主程序 Info.plist 的 `NetworkComponentVersion` 下载指定兼容版本；已有组件仍由 Sparkle 独立更新。
先上传并 CDN 回读版本 ZIP 和同名版本 XML，再通过 `/api/v1/apps/xstats-network-monitor/releases/current`
发布到三个区域 API，使用现有公钥登记组件应用；不再写跨版本 ZIP 别名或可变对象存储 XML。
已存在的公开版本禁止重新构建覆盖；中断后以原始公证 ZIP/XML 执行
`./scripts/release_network_component.sh --notes docs/NetworkComponentReleaseNotes.json --publish-only`。
源站已有同名 ZIP 时必须与本地原制品哈希相同，否则停止；组件更新与主程序一样走区域 API，API 原样返回不可变 XML，发布后逐入口回读核验。

可对构建执行 `XStats --snapshot <目录> --connections-only --language en` 走查界面。
此命令只使用虚构连接数据，不能替代签名安装、系统授权、真实连接观察和停止验证。

## 发布

正式分发需要 Developer ID 证书及私钥、公证凭据、`mc`（对象存储别名 `c-ip`）、
已登录的 `gh`，以及环境变量 `XSTATS_RELEASE_TOKEN`。公证凭据首次保存：

```bash
xcrun notarytool store-credentials XStats --apple-id you@example.com --team-id YOUR_TEAM_ID
```

发版前将 `CHANGELOG.md` 顶部的 `## 未发布` 替换为 `## X.Y.Z · YYYY-MM-DD`，
同步 `docs/ReleaseNotes.json` 的中英文摘要，并把四个 README 中“开发中”“即将随 X.Y 发布”等预发布说明改为已发布状态。
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

默认发布和校验覆盖三个入口，固定路径及环境变量覆盖方式见 [发布脚本](../scripts/publish_api.py)。
详细签名配置、制品核验、分步发布与失败恢复见 [发布 runbook](../.agents/skills/xstats-release/references/runbook.md)。

## 项目目录

| 路径 | 用途 |
|---|---|
| `App/`、`Widget/`、`Helper/` | 主应用、桌面小组件、特权辅助工具 |
| `NetworkMonitorApp/`、`NetworkExtension/` | 独立网络伴随应用与其系统扩展 |
| `Packages/XStatsKit/Sources/` | 采集、AI 用量、清理、更新、同步与界面模块 |
| `Packages/XStatsKit/Tests/` | Swift 测试 |
| `server/api/` | 旧更新协议的兼容实现与测试 |
| `docs/` | 开发指南、架构说明与文档导航 |
| `scripts/` | 版本、构建、发布与文档同步脚本 |
| `Taskfile.yml`、`project.yml` | 任务入口与 Xcode 工程配置 |

## 专注与护眼验证

`--snapshot <目录> --wellness-only --language zh-Hans` 输出专注页、护眼卡片、提醒设置、七日统计和护眼幕布的明暗截图。可替换为 `en`、`ar` 检查长译文与 RTL。数据均为演示，使用独立偏好和内存活动库，不请求通知权限、不采集指标、不访问本机健康记录。

定向测试：`swift test --package-path Packages/XStatsKit --filter 'Wellness|RestSettings'`。覆盖提醒合并、锁屏暂停、番茄与护眼融合、午夜拆分、SQLite 去重/清空/保留边界和旧设置读取。局部迭代只运行相关测试，完整 `task test` 留给正式发布或明确需要全局回归的改动。手动验收时分别检查通知允许/拒绝与系统专注模式、多屏幕布、退出后无残留计时；护眼休息与轮间休息不重复统计。

在该定向模式后加 `--verify-runtime` 会短暂显示独立护眼预览窗口，测量空闲、可见护眼休息和关闭三个阶段，将 CPU 时间、峰值驻留内存与计时器状态写入 `runtime.json`。不创建通知管理器、不请求权限，也不改已安装应用。该结果为短时独立进程测量，不能代替多屏、系统专注模式或长期能耗验收。

专注页统一为开始专注、暂停/继续、结束；休息后默认等待“开始下一轮”，设置中的“休息后自动开始下一轮”只影响后续衔接，不暂停当前计时。现有 `restMode` 偏好与备份继续读取，不新增持久化字段。`RestSettingsTests` 覆盖默认值、旧配置映射、切换开关保留截止点、三种已保存配置下的统一结束操作，以及完成轮数保留。

休息环境音定向验证：`swift test --package-path Packages/XStatsKit --filter 'RestAmbientSoundTests|RestSoundPreviewTests'`。覆盖采样幅度/DC/起始渐入、44.1/48 kHz 生成、旧 `rain` 标识与设置备份、AVAudioEngine 离线渲染及连续切换后的引擎释放。可用 `XSTATS_SOUND_ARTIFACTS="$PWD/build/relaxing-sounds-validation"` 运行测试，生成轻雨、溪流、风声各八秒的 WAV；测试采用离线引擎，不向扬声器播放。试听文件结尾单独淡出，便于对比；实时播放器保持原有停止方式。交付前运行完整 `task test`。

自定义休息音频使用本地文件选择器，导入副本最大 50 MiB，不下载或上传。`RestCustomAudioTests` 验证原文件移走后副本可用、替换仅保留当前副本、无效/超限/取消导入不影响原文件、播放器释放，以及本机元数据不进入设置备份。该功能使用独立临时文件夹验证，不读取用户音频；本地 UI 验收应使用测试音频，不能自动选择用户私人文件。
