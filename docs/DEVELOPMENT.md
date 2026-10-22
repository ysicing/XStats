<!-- Copyright (C) 2026 ysicing
SPDX-License-Identifier: AGPL-3.0-or-later -->

# XStats 开发指南

本文用于本地开发、构建、测试和发布。应用使用说明见 [README.md](../README.md)，
模块边界与实现约束见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 本地性能报告

运行 `task perf`：先构建 Release 测试程序，再串行执行 `MonitoringResourceTests` 的三组
真实硬件测试（监控开关、电池页面、关闭监控后的基础信息页面）。不安装应用、不推进版本，
也不需要管理员权限。需使用能提供功耗与 App 能耗采样的 Apple Silicon Mac；硬件或权限
不满足现有测试断言时会失败，不将未测项目记为通过。运行期间保持机器唤醒，避免同时构建或执行其他重负载任务。

全部测试通过且三份数据完整后，更新固定的 [性能报告](PERFORMANCE.md)。该 Markdown 摘要
随代码提交，使用 `git diff -- docs/PERFORMANCE.md` 或 Git 历史查看变化；命令本身不提交 Git。
每次原始 JSON、环境信息与构建／测试日志保存在 `build/performance/<时间>-<随机后缀>/`，不入库。
失败返回非零并保留上一份成功摘要，排障查看终端输出的本次日志目录。

报告记录测试进程 CPU 时间、快照和样本数，以及已有测试提供的阶段耗时；不包含子进程 CPU、
应用内存峰值、唤醒或整机耗电量。三组各运行一次，不设耗时回归阈值；小幅变化不等于性能退化。
比较时核对硬件、系统、工具链和负载。报告中的 HEAD 是运行起点，未提交代码会如实标记，
不是生成报告后才创建的提交。

## 应用窗口与菜单

从 Finder、启动台或 `open /Applications/XStats.app` 手动启动时显示主窗口。登录项或系统服务启动通过打开应用事件的 `keyAEPropData` 识别，保持后台运行；`--background` 可用于本地验证，已有定向调试参数与深链不额外打开主窗口。

主窗口、账号配置、测速、出口与分流、项目产物及更新窗口仍打开时，使用普通应用模式，显示程序坞图标与原生应用菜单。最小化或隐藏窗口只降低页面采集需求，不移除程序坞入口；最后一个窗口关闭后回到菜单栏模式。通用设置中的“关窗后保留程序坞图标”复用原 `showDockIcon` 偏好键，开启时关窗后仍保留普通应用模式。计时 HUD 和菜单栏弹窗不单独触发程序坞显示。

应用菜单的关于、设置与检查更新分别打开现有关于页、通用设置和 Sparkle 更新流程；窗口菜单通过 `⌘0` 恢复主窗口，帮助菜单链接项目使用说明与问题反馈。切换应用语言时重建菜单，普通编辑、隐藏、最小化与关闭操作继续使用系统响应链。

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
`network`、`thermal`、`battery`、`processes`、`ports`、`audio`、`keep-awake`、`rest`、`cleaner`、
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
- GitHub Actions 使用 `macos-15` 镜像中已安装的最新稳定版 Xcode（`latest-stable`），并输出实际工具链版本。
- Python 3、Go 1.25+、Go Task 和 XcodeGen；Go 用于 API 兼容性测试。

```bash
brew install go go-task xcodegen
```

## 常用命令

在仓库根目录执行：

```bash
task format                         # 提交前使用 swift format 格式化源码
task format-check                   # 严格检查格式，不修改文件
task generate                       # 从 project.yml 生成 Xcode 工程
task build                          # 构建、安装并启动；构建号递增
task build BUMP=0 INSTALL=0          # 只构建，不改构建号或安装
task compile CONFIG=Debug           # 只编译 Debug，不安装
task compile-capture                # 独立 Capture 验证构建，不安装、不推进版本
task run-capture                    # 构建并启动 Capture
task release-capture -- --publish   # 独立 Capture 签名、公证与发布，见 CAPTURE.md
task test                           # 脚本、Go API 和 Swift 测试
task open                           # 生成工程并用 Xcode 打开
task snapshot                       # 使用当前 Release 构建渲染截图
task version                        # 查看版本与构建号
task clean                          # 删除 build/
```

每次提交前先执行 `task format`，再执行 `task format-check`。两者使用 Swift 工具链自带的
`swift format` 和根目录 `.swift-format`，处理 Git 已跟踪及未忽略的新 Swift 文件，
跳过构建产物、依赖缓存和本地索引。检查格式化差异后，仅暂存本次提交范围内的文件。
GitHub Actions 在测试和构建前执行同一条 `task format-check`，检查失败则停止后续步骤；
在本地执行 `task format` 修正后再提交。
保留现有导入顺序，避免格式器的导入排序合并脚本 shebang 与紧随其后的版权注释。

`task test` 按 Swift 测试模块隔离运行，其中 `XStatsUITests` 显式使用 `--no-parallel`。
UI 用例共享主 actor，同步布局、日历计算和阻塞夹具并发时会拖延取消与超时处理；串行执行保留全部断言与原有时限。
单独运行整个 UI 模块时同样加上 `--no-parallel`，其他模块保留默认调度。
串行不能代替全局状态隔离：UI 用例不得修改进程全局的 `L10n` 语言，需要切换语言的翻译测试放在并行运行的 `LocalizationTests` 并使用显式语言的翻译表。

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

硬件详情走查：`XStats --snapshot <目录> --hardware-details-only --language zh-Hans` 使用隔离偏好，只读采集 GPU、电池和磁盘约五秒，停止采样后输出 320 点弹窗与 600 点详情的明暗截图。使用 `de`、`ar` 检查长译文及 RTL；这些截图采用真实本机数据，无内置电池或不支持的属性沿用缺失状态。单元测试中的演示读数与实机截图应分别标注。

指标摘要走查：`XStats --snapshot <目录> --metric-summary-only --language zh-Hans` 使用隔离偏好，采集 CPU、内存与网络约三秒后停止循环，再以匿名演示进程、2 GB 交换区及严重热压力生成明暗截图。用 `de`、`ar` 检查长译文和 RTL。CPU 应用汇总与总览共用「整机／单核」口径，默认整机；设置参与保存、导入导出与同步，切换不改变采样、排行及告警。内存顶部始终显示交换区用量；温度区域的系统热压力随现有温度采样读取，不依赖 CPU 使用率采样。

GPU 采样生命周期的实机检查：设置 `XSTATS_GPU_RESOURCE_REPORT=<输出路径>`，单独筛选 `HardwareDetailsPresentationTests/gpuDetailsSamplingStopsAndRestartsWithFreshBaselines`；记录关闭、重开、暂停、恢复及功能关闭阶段的样本数与 CPU 时间。磁盘组成的单次只读检查：设置 `XSTATS_DISK_DETAILS_REPORT=<输出路径>`，筛选 `HardwareDetailsTests/realDiskCompositionIsReadableAndBounded`。未提供环境变量时不运行这些延时硬件检查。

菜单栏布局走查可对当前构建运行 `XStats --snapshot <目录> --menubar-only --language zh-Hans`；
仅采集相关指标，输出三种布局、总览和详情的明暗截图，不扫描清理目录或 AI 日志。
README 的菜单栏图库使用独立的演示模式：

```bash
SIGN_ID=- task build BUMP=0 INSTALL=0 CONFIG=Release
task snapshot SNAPSHOT_DIR=build/readme-gallery/zh-Hans -- --readme-only --language zh-Hans
```

`--readme-only` 使用隔离偏好，输出三种菜单栏布局、聚合状态总览、Magpie AI 用量、
三合一设置、弹窗区块排序与 Wi-Fi 详情的明暗截图。仅短暂只读采样取得指标结构，
展示数值随后由演示值覆盖；不启动持续监控、不连接真实 Magpie、不读取个人 AI 日志，也不修改硬件设置。
网络名称、接入点地址、音频设备和账户均为虚构数据。
`menubar-layouts-dark.png`、`combined-overview-<light|dark>.png`、
`ai-usage-light.png`、`trio-settings-light.png`、`popover-order-light.png` 和
`wifi-details-light.png` 分别保存为 `Assets/readme/<名称>-zh-Hans-<light|dark>.png`；
菜单栏布局图使用 `menubar-layouts-zh-Hans-dark.png`。
更新后逐张检查内容与裁切，同步四语言 README 的图片引用、替代文本和演示数据说明。
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

“设置 → 功能”使用“基础功能”和“可选功能”两个页签；较大的原生分段选择器放在内容顶部，与功能卡片按阅读方向对齐。两类页签均不放顶部通用说明，分类下方直接衔接功能卡片；基础功能列表底部保留菜单栏与小组件行为提示。指针切换列表使用 180 毫秒淡入淡出，键盘与减少动态效果即时切换。切换后从列表顶部显示，不改变开关或新增采样需求。基础功能各行在标题下直接显示“在菜单栏显示”复选框，右侧开关只负责功能启用；不再用文字重复描述启用与展示状态，也不为这些开关添加额外动画。能耗下分别选择电池、温度的菜单栏展示；风扇独立管理；可选功能中的 AI 用量和音频也提供相同的展示复选框。完整样式仍在菜单栏设置页调整。显示器参数控制放在可选功能中。基础监控的启用开关控制采集，菜单栏开关控制展示：
加入菜单栏时自动启用模块，移出菜单栏不关闭模块，关闭模块则移除菜单栏入口并停止监控、
相关告警和新增历史值。已有历史、样式与告警选择保留；基础监控开关也包含在设置备份中。

能耗页集中显示电池信息、功耗、App 能耗和温度，无内置电池也可查看可用读数。阻止睡眠与蓝牙设备在详情页并排显示，窄窗口转为单列。睡眠阻止信息仅在能耗启用且页面可见时每 10 秒读取一次，切页、关闭、最小化、锁屏与休眠时停止并丢弃旧结果；不读取历史、不持久化。能耗关闭后保留电池基础信息和电池菜单栏入口，温度入口移除；加入电池入口不隐式开启额外采集，加入温度入口则启用能耗。风扇仅在确认硬件存在后展示；其调速、交还系统及过热保护不依赖能耗开关。沿用 `battery`／`thermal` 偏好标识，不重置用户设置；升级时一次性迁移：旧版仅开散热的开启能耗，仅开电池的保持 CPU 温度告警关闭。能耗关闭时能耗页顶部提供启用入口，不按实时页每秒采样。

可选功能按用途拆为独立卡片：网络监视器、进程、应用与清理一组；AI 用量、音频与显示器参数控制一组；计时、菜单栏日历各自单独一组。每组首项不画线，其余条目使用相同细分隔线，组间留白，不新增动画。

“设置 → 菜单栏 → AI 用量”仅在 Magpie 模式下提供额度服务多选，只列出 Magpie 实际返回的服务，同一服务的多个账户合并成一个选项；默认选择仍为 OpenAI（Codex）、Claude、Grok、Gemini。菜单栏显示所有已勾选且有当前有效额度的服务，不限制为前三个；没有可用额度时暂时隐藏读数，但保留选择项。刷新失败沿用上次成功返回的列表，服务暂时消失也不清空已保存的选择。未使用 Magpie 时隐藏这组选项，Codex、Claude 按已有来源设置展示，不受 Magpie 选择影响。此偏好仅控制菜单栏展示，不改变数据查询、详情页或 Widget。选择使用原生复选框，即时响应，不添加过渡动画。

侧栏统一使用“应用服务”，内部分为应用、Homebrew、启动项与服务。应用与 Homebrew 管理放在可选功能中，默认开启，保留 `uninstallerEnabled` 与 `uninstaller` 路由；关闭后停止应用扫描并释放运行应用监听，保留启动项和服务，当前应用分类回到启动项。分类选择仅保存在本机；旧 `startupItems` 偏好与 `startup-items` 深链映射到统一入口的启动项分类。待确认操作会取消，已经开始的废纸篓操作正常收尾，移除期间禁用功能开关。偏好支持导出与恢复。

全新安装的菜单栏默认使用聚合模式，并保存首次布局。已有安装保留已选布局；旧版未保存布局时沿用每项独立模式。

聚合排序定向验证：`swift test --package-path Packages/XStatsKit --filter 'MenuBarOrderTests|MenuBarLayoutTests|MenuBarResourceTests|WebDAVSettingsTests|MonitoringResourceTests'`。覆盖顺序保存、关闭再开启、硬件不可用项目、功能启用过滤、设置同步与重绘观察。使用现有 `--menubar-only` 截图入口检查中文、英文和 RTL；独立图标仍由系统拖动排序。

合并菜单栏的“项目间距”可选 4、6、8、12 点，默认 8 点，包含在备份与设置同步中。该设置只用于聚合布局的项目分隔。AI 用量内部各服务之间固定 6 点，图标风格中图标与百分比间隔 3 点；百分比至少预留两位数字的宽度，100% 与 >99% 按实际文字宽度扩展，避免普通额度变化时跳动并减少留白。弹窗顶栏和菜单栏右键菜单提供防休眠快捷入口，保留原有时长并补充 4、8、12 小时；已保存合盖运行请求时先打开防休眠页。风扇快捷模式仍走辅助工具与安全检查，缺少风扇参数或辅助工具时打开散热页，不增加后台采样。CPU、内存、概览进程与网络应用排行保留仍在前 N 名的项目位置，数值继续更新，新成员替换离开的成员。磁盘应用读写数字与条形使用相同平滑速率；网络详情在探测开启时展示最近一次延迟及现有最多 60 次探测的丢包比例，不增加探测请求。

本批定向验证：`swift test --package-path Packages/XStatsKit --filter 'MenuBarEnhancementsTests|FanSafetyLifecycleTests|LocalizationTests'`。设置 `XSTATS_MENU_RESOURCE_REPORT=<输出路径>` 运行 `MenuBarResourceTests`，检查打开、关闭、暂停和恢复的实际采样行为；长译文与 RTL 仍使用上述原生截图入口。

应用服务页使用原生分段控件切换四个分类，搜索词、选中项和排序在页面内按分类保留；更新与卸载仍是各分类中的操作。启动项只列出当前用户与所有用户的 LaunchAgents，服务只列出 LaunchDaemons，不扩展系统扫描目录或权限。只有当前用户的代理可启停，其余只读；用户域和系统域的状态分开读取，不使用用户域进程状态推断系统服务运行情况。启动项与服务仅在打开时或手动刷新时读取，页面不可见、锁屏或休眠时取消读取并拒绝旧结果，不新增定时器。

应用页使用原生表格浏览 App 与 Homebrew 清单，可搜索、按列排序、查看运行状态、版本、大小、架构、上次打开与来源。App 清单复用固定应用目录扫描，保护 XStats 自身和 Apple 应用；普通应用卸载打开原有残留预览与确认。Homebrew 来源按 Cask 的真实 app 产物路径匹配，卸载走 Cask 命令而不是直接回收本体。Spotlight 没有上次打开记录或无法识别架构时显示空值，不以文件修改时间代替使用记录。

应用管理没有检查定时器。App 列表按需从 `~/Library/Caches/XStats/AppInventory-v2.json` 恢复展示快照（最多 8 MiB、10,000 项，保留 7 天），重启后先显示缓存，再异步核对本地清单与元数据。自动刷新保留表格与刷新按钮，只重新计量新增、身份或应用本体／Info.plist 修改时间变化、或计量超过 24 小时的应用；手动重新扫描则重做全部计量。App 清单在 30 秒内复用内存结果，超过期限后于下次访问时后台核对；已知安装／卸载变化和手动刷新立即核对。元数据在应用身份或指纹变化时失效，“上次打开”不依赖文件指纹，按 60 秒期限在访问时重新查询。体积遍历每批最多 20 项，并在单项完成后检查 100 毫秒预算，合并发布结果；关闭时丢弃未提交批次，不标记为已计量。应用图标最多缓存 128 个小位图，逐项淘汰最久未使用项；Homebrew 清单沿用 5 分钟的按需刷新间隔。缓存不保存卸载计划与授权，卸载仍读取真实应用身份并经过预览确认；Homebrew 清单和操作保护保持实时读取。窗口不可见、锁屏、休眠、离开页面时取消只读遍历，拒绝旧任务结果，关闭功能释放结果。运行状态通过 NSWorkspace 事件更新。Homebrew 自动更新、分析、自动清理与依赖自动移除均关闭；只有点击“检查更新”才执行 `brew update`。Formula / Cask 更新、卸载逐项确认，保留原生依赖保护，不使用 force / zap；运行中的 Cask、XStats 本身和固定版本更新有保护。已经确认的 brew 写操作不因切页或关闭窗口中断，操作中退出应用会提示等待；结束后两个列表失效，失败时提示终端检查。

App 标签中的“检查更新”查询 App Store 来源的 Mac 应用。通过 Spotlight 的 App Store ID 查询 Mac 专用目录，未命中时使用 bundle ID 查询公开目录；地区沿用系统地区，与 Apple Account 商店地区不同时可能查不到结果。每批最多 20 项、顺序执行，每次响应最多 2 MiB、请求超时 10 秒／总超时 20 秒。页面可见时异步按需检查，成功目录结果在内存保留 1 小时，未命中或失败退避 10 分钟；手动检查绕过期限，不重复启动正在运行的查询。离开 App 页面、关闭或最小化窗口、锁屏／休眠、关闭功能时取消并拒绝旧结果，不新增定时器。仅确认新版兼容本机 macOS 时在版本旁显示“更新”，点击交给 App Store；返回应用页后核对本地清单与版本。查询失败或未命中保持当前版本，不添加标记；必要失败只记录统一日志，不把未知状态描述为“已是最新”。不读取 Apple Account 凭据，不安装 mas，不自行下载或替换商店应用。

定向验证：`swift test --package-path Packages/XStatsKit --filter 'AppStoreUpdatesTests|ApplicationManagementTests|AppManagementControllerTests'`。可选实机只读检查：设置 `XSTATS_APP_MANAGEMENT_RESOURCE_REPORT=<输出路径>`，筛选 `AppManagementControllerTests/nativeInventoryStopsWhenClosed`，验证关闭后的遍历退出与 5 秒内无新增读取；不执行软件包更新或卸载。原生布局截图：`XStats --snapshot <目录> --app-management-only --language zh-Hans`，可切换 `en` 与 `ar`，只使用演示数据，不读取真实应用或执行 brew 写操作。

卸载增强的定向验证：`swift test --package-path Packages/XStatsKit --filter 'AppUninstall|Uninstaller|ScanCancellationTests'`。测试只使用临时应用、目录和模拟回收器，覆盖容器元数据、签名应用组、共享候选默认保留、路径重定向、取消与残留重试；不会卸载真实应用。`XStats --snapshot <目录> --uninstaller-only --language zh-Hans` 使用独立偏好与演示候选生成卸载/重试及确认弹窗的明暗截图；可用 `en` 和 `ar` 验证长译文与 RTL，不扫描本机应用或调用废纸篓。

显示器是单独的参数控制开关：关闭后仍显示型号、分辨率、刷新率与菜单栏信息入口，停止 DDC 参数读写；加入显示器菜单栏不会自动开启参数控制。显示器信息由系统事件更新，不添加轮询。

启用但无展示、历史记录或提醒需求时不采集；全部需求为空时停止采样循环。历史记录默认开启，
只为仍启用的 CPU、内存、网络维持后台采样，其余指标仍按界面需求记录。
手动风扇关闭前交还系统控制，失败恢复功能入口；合盖运行继续保留电量保护。

风扇切换档位、自定义转速提交或唤醒重新下发成功后，只在风扇读数可见时立即读取实际转速，并按约 500 毫秒的间隔短暂跟踪；最多 10 秒、20 次读取，接近目标后提前结束；风扇模式键读不到时不视为已达成，继续读取直至上限。读取复用 MetricsHub 的 SMC 连接，只更新风扇，不提高其他指标的采样频率或写入历史。菜单栏风扇读数、包含风扇摘要的合并面板、风扇弹窗以及概览／风扇页可作为读取方；最后一个读取方关闭、功能关闭、锁屏、休眠和退出时取消，迟到结果丢弃。读取失败时保留实际转速并结束跟踪；控制失败不启动跟踪，仍沿用原有错误和安全复位流程。指令目标不会作为实际转速展示。
手动风扇模式写入后读回确认；首次直接写入未确认时，仅在存在 `Ftst` 且未开启时启用该键，无 `Ftst` 的机型也会继续重试模式写入。不按芯片代际假定该键存在，不固定等待 3 秒，而是在控制权交出后立即继续；模式重试最多约 15 秒，启用 `Ftst` 的写入重试另有最多约 5 秒的等待。失败保留最后一次真实写入错误，或明确区分读回不匹配与读回失败。新接管失败时尝试撤回该风扇；只有确认全部风扇自动控制时才复位全局解锁，避免干扰另一个手动风扇。交还系统控制时风扇数量读取失败视为复位失败而非无风扇，helper 保留接管记录以便重试，只有读到 0 才表示确认无风扇。

指标弹窗默认收起核心分工、排队程度、压缩详情、SSD 健康和功耗等次要分区，已保存的分区选择与备份恢复优先；主窗口保留完整详情。内存顶部展示已有用量历史并按当前内存压力着色；网络顶部展示当前物理接口与可复制的本地地址。磁盘弹窗显示其他已装载卷的可用／总容量，复用主窗口的卷读取；仅在磁盘内容可见时按打开及装卸事件读取，隐藏、锁屏或休眠时取消，不新增定时轮询。

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

## macOS 15 启动与 SwiftUI 隔离验收

macOS 15 的异步 DisplayLink 可能在后台调用 `ForEach.content`。只传递不可变快照的行使用
`@Sendable` 回调和仅赋值的 `nonisolated init`；读取模型、图标缓存或绑定的监控列表使用
`MainActorForEach`，将实际构建延迟到行的 `MainActor body`。不要把模型或 AppKit 缓存改为非隔离，
也不要在后台闭包里直接调用 builder。几何与时间线闭包需单独核实，不能仅凭存在执行器检查就批量改写。

在有桌面会话的 macOS 15 测试机运行：

```bash
XSTATS_STARTUP_REPORT_DIR="$PWD/build/startup-verification" \
  swift test --package-path Packages/XStatsKit --no-parallel \
  --filter 'StartupRenderingTests|MainActorForEachIsolationTests|BluetoothListIsolationTests|BatteryEnergyPresentationTests|CPUPresentationTests'
```

窗口验收覆盖 10 个保存页面与能耗开/关，共 20 种组合；通过真实 `MainWindowController` 反复挂载、
刷新、关闭，并进入关于/升级页。测试使用隔离偏好与演示指标，不启动主程序采样调度或更新安装；
报告包含实际 OS，`macOS15` 必须为 `true` 才算该系统的窗口验收。后台列表测试另行覆盖蓝牙多部件、
行构建与模型读取的隔离、数据 ID 与设置更新；蓝牙演示数据在已挂载窗口中依次切换加载、空列表、
单电量、多部件与断开状态，并检查左右书写布局。Picker 的直接标签保持原结构，仅在主线程预先生成文案快照。

这些测试不等于完整进程启动验收。发布候选仍需在 macOS 15 上手动验证冷启动恢复能耗/本机信息/仪表盘、
蓝牙设备列表、打开电池弹窗、关闭能耗后重启以及从恢复页进入升级页。缺少 macOS 15 机器时报告待验证，
不能用其他系统测试通过或 macOS 部署目标版本代替。

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

清理审阅的定向验证：`swift test --package-path Packages/XStatsKit --filter 'ApplicationCacheTests|DeveloperCleanupCatalogTests|CleanupReviewTests|CleanupReviewRegressionTests|ToolCachePlanTests|CleanerReviewFlowTests|CleanerTests|CleanerSelectionTests|ScanCancellationTests|AppUninstall|LanguageSupportTests'`。
使用临时目录与模拟 CLI 验证自定义缓存路径查询、路径锁定、版本子目录、保留项保护及不完整卸载扫描；不执行真实工具清理。验证工具缓存不重复覆盖、运行应用状态刷新、排除路径的父子与别名保护、逐项选择、错误语义及本机偏好不进入备份。
开发者清单及原生工具的执行边界见 [CLEANUP.md](CLEANUP.md)。
修改工具查询或路径校验后，另跑 `swift test --package-path Packages/XStatsKit -c release --filter 'ToolCachePlanTests|DeveloperCleanupCatalogTests|AppUninstallIdentityTests|AppUninstallerMoleTests'`。当前 Swift 6.4 工具链中，直接传入 `CharacterSet.controlCharacters.contains` 的实例方法引用曾在 Release 下误拒正常路径；应用标识的字符集成员检查也曾在 Release 下误拒正常标识；两处均保持显式闭包，并用正常路径、控制字符、目录边界和有效/无效应用标识验证优化构建。
`XStats --snapshot <目录> --cleaner-review-only --language zh-Hans` 使用隔离偏好与演示候选渲染扫描不完整、完整列表与保留目录的明暗截图；`en`、`ar` 可检查长文案与 RTL。项目产物截图使用临时演示项目，追加 `--native-preview` 可打开 120 秒的隔离交互窗口，验证分组、三态勾选与筛选后的选择保留；不会扫描个人目录。定向运行 `ProjectPurgeReviewTests|CleanerReviewFlowTests` 验证选择边界和原生复选框无障碍语义。

## 网络连接试验模块

主程序、特权辅助工具、独立网络组件及网络扩展均使用 Apple 统一日志（`Logger`）。
网络组件子系统为 `work.12306.xstats.networkmonitor`，类别为 `service`、`registration`、
`filter`、`update`；扩展为 `work.12306.xstats.app.networkextension`。
只记录关键动作、授权、过滤器切换、更新与错误，不逐次记录状态查询、下载进度或连接。
错误描述最多 1024 字符并标记为 private；不写入目标地址、域名、凭据或原始 IPC 参数。
注册 CLI 的标准输出仍为协议 JSON，日志不混入其输出。

```bash
# 实时查看主程序与所有服务；默认遮蔽私有字段。
/usr/bin/log stream --style compact --level info \
  --predicate 'subsystem IN {"work.12306.xstats.app", "work.12306.xstats.helper", "work.12306.xstats.networkmonitor", "work.12306.xstats.app.networkextension"}'
```

“导出诊断信息”收集以上四个子系统最近三天可用的日志，并沿用地址和用户路径脱敏；
系统日志保留策略决定实际可获取的时间范围。日志采集最多 15 秒、8 MiB，超限保留已取得的
内容并注明截断；不会为导出一直扫描系统日志。定向验证用
`swift test --package-path Packages/XStatsKit --filter 'DiagnosticsTests|DiagnosticsArchiveTests|NetworkMonitorTests|NetworkComponent'`。
日志改动可编译组件验证，无需安装或重新激活过滤器。

清理操作日志 `~/Library/Logs/XStats/cleanup.log` 最多保留 1 MiB，达到上限时仅保留
末尾约 512 KiB 的完整记录；单条文本字段限制为 4096 个 Unicode scalar。诊断导出
仅读取末尾 256 KiB 并取最后 500 行，兼容旧版本遗留的大日志，不增加后台轮转任务。

Helper 的网络、磁盘维护在独立串行队列执行，不占用风扇控制与客户端断连恢复的状态队列。
每条维护命令最多 30 秒，本地快照删除最多 120 秒，`pmset` 最多 5 秒；输出保留上限为
64 KiB。超时包含主进程退出后等待输出管道 EOF 的时间，必要时终止本次启动的进程。
禁用睡眠前先持久化接管意图，命令超时或失败时保留恢复记录，避免实际已生效却漏掉恢复。
定向回归可运行 `swift test --package-path Packages/XStatsKit --filter HelperToolRunnerTests`。

主程序与独立组件的共享 Sparkle 驱动在各自子系统的 `update` 类别记录实际检查开始、
发现版本、没有可提醒的更新、区域入口重试、取消和最终结果。正常周期使用 notice，
清单加载使用 info，入口重试使用 warning，启动或最终失败使用 error。
“没有更新”是正常结果；有较新构建但不提醒时会记录 `newerBuildExists` 和 Sparkle 的原因码，
不直接认定为已是最新版本。仅输出入口序号和版本，不记录安装标识、完整请求 URL 或清单正文；
错误详情最多 1024 字符且标记为 private。不逐次记录下载进度，也不添加日志采集任务或计时器。

Sparkle 的调度回调记录实际安排的 `delaySeconds` 或未安排后续检查，不能仅凭检查成功判断
下一轮定时器已经启动。主程序还记录更新通知被静默策略、开关、跳过版本或去重拦截的原因，
以及系统通知授权、横幅和通知中心设置。`authorization` 值 0/1/2/3/4 分别为未询问、拒绝、
允许、临时授权和短期授权；`alert` / `center` 值 0/1/2 分别为不支持、关闭和开启；
`style` 值 0/1/2 分别为无横幅、横幅和提醒。首次授权请求后的 `granted` 记录最终授权结果。
“已提交”只表示系统接受了通知请求并记录同版本去重，不代表已展示横幅；
系统专注模式等投递限制不在此回执中。拒绝或提交失败不会写入去重记录，后续检查可重试。

```bash
# 查看主程序及独立组件最近一小时的更新检查日志。
/usr/bin/log show --last 1h --style compact --info \
  --predicate 'category == "update" AND subsystem IN {"work.12306.xstats.app", "work.12306.xstats.networkmonitor"}'
```

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

发布流程在应用制品上传前自动执行 `scripts/sync_network_geography.py --publish --max-age-days 7`：
按线上 `current.json` 的 `generatedAt`（UTC）判断数据年龄，不依赖本地构建目录；未超过
7 天且两个压缩文件回读哈希校验通过时复用，不重新下载官方源、转换、压缩或上传。
超过 7 天、线上数据缺失或清单／时间记录无效时，从 DB-IP 官方本月 gzip CSV 下载、
严格校验并转换，使用系统 LZFSE 压缩；上传至
`c-ip/oss/apps/macOS/XStats/network-geography`。文件名包含压缩内容 SHA-256，先上传
并回读校验两个不可变文件，最后更新 `current.json`（CDN max-age=300）。同步失败会中止
后续应用制品和版本清单发布。客户端入口固定为
`https://c.ysicing.net/oss/apps/macOS/XStats/network-geography/current.json`。

```bash
python3 scripts/sync_network_geography.py            # 只准备到 dist/network-geography
python3 scripts/sync_network_geography.py --publish  # 强制从官方重新获取并同步 c-ip
python3 scripts/sync_network_geography.py --publish --max-age-days 7  # 按线上数据年龄复用
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
恢复从原 ZIP 解包校验签名、公证票据与更新清单，不依赖 DerivedData、Developer ID 私钥或构建 profile；
仍需 Sparkle 验签工具及原密钥账户、对象存储与更新 API 的发布凭据。主程序发布保留独立产品的制品目录。
源站已有同名 ZIP 时必须与本地原制品哈希相同，否则停止；组件更新与主程序一样走区域 API，API 原样返回不可变 XML，发布后逐入口回读核验。

可对构建执行 `XStats --snapshot <目录> --connections-only --language en` 走查界面。
此命令只使用虚构连接数据，不能替代签名安装、系统授权、真实连接观察和停止验证。

## 发布

主应用、Widget 与 Helper 的 Release 构建在 Xcode 签名前裁剪调试符号和非外部符号，
保留外部符号、Swift 运行时元数据以及独立的 `dwarf-with-dsym` 调试信息；Debug 不裁剪。
正式打包通过 `task build CONFIG=Release INSTALL=0 BUMP=0 CLEAN=1` 执行 Xcode `clean build`，
清理全部目标的旧产物与中间文件，避免已裁剪的 Widget 被增量复用后生成空 dSYM；
保留 SourcePackages 下载缓存。本地预览默认仍为增量构建。
`task release` 在公证与打包前核对三者以及 Sparkle 各二进制的 arm64 UUID 与 dSYM，
缺失或不匹配即停止。符号独立保存为
`release-symbols/XStats-<版本>-<构建号>-AppleSilicon.dSYMs.zip`，
包括 dSYM 和记录版本、UUID、二进制 SHA-256 的 `manifest.json`；不进入 DMG、升级 ZIP 或公开上传列表。
`DEBUG_SYMBOLS_DIR` 可指定其他保存目录。默认目录不受 `task clean` 或下次发布清理 `dist/` 影响，
同版本与构建号的不同二进制禁止覆盖已有本地归档。
每次 `task release` 自动将符号 ZIP 和独立清单备份到内网对象存储
`home/oss/apps/macOS/XStats/dSYMs/<版本>-<构建号>/<归档 SHA-256>/`，
上传前后确认目标禁止匿名访问，分别回读 ZIP 和清单比对 SHA-256。
对象通过条件写入禁止覆盖；两台机器生成不同归档时按哈希分开保存，相同内容可安全重跑。
备份失败会在公证与打包前停止，本地归档保留；修复连接或权限后执行
`python3 scripts/backup_debug_symbols.py <符号归档 ZIP>` 重试，不需要重新构建。
两台打包机均需配置 `mc` 的 `home` 别名和目标读写／私有权限查询权限；
`DEBUG_SYMBOLS_TARGET` 可覆盖私有备份根目录，与公开安装包的 `MC_TARGET` 独立。
正式发布仍须串行，切换机器前拉取最新代码；跨机器续发使用原始制品和对应符号，不能以重新构建代替。
不可在签名或公证后再次裁剪二进制。

崩溃排查时用报告中的 Binary Images UUID 匹配归档；解压后将 dSYM 导入 Xcode，
或执行 `xcrun atos -arch arm64 -o <dSYM>/Contents/Resources/DWARF/<二进制名> -l <加载地址> <崩溃地址>`。
`python3 scripts/archive_debug_symbols_test.py` 使用真实 Mach-O 与 dSYM 验证匹配、缺失、
错误 UUID、归档覆盖保护，以及裁剪后的运行与文件行号符号化。

正式分发需要 Developer ID 证书及私钥、公证凭据、`mc`（对象存储别名 `c-ip` 和私有备份别名 `home`）、
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

Homebrew tap 的 XStats 与 Capture Cask 分别由 `scripts/release.sh` 和
`scripts/release_capture.py` 生成。两者的 livecheck 使用 GitHub Releases，分别匹配
`vX.Y.Z` 与 `capture-vX.Y.Z` 正式标签，排除草稿与预发布；修改 tap 时同步修改生成器。
普通卸载请求对应应用正常退出并移除应用本体，保留配置与历史；显式 `--zap` 才清理各自列出的私有数据。
两种宿主共用的 `~/Library/Caches/XStatsCapture` 素材缓存始终保留，独立网络组件与辅助工具安全恢复状态不由 Cask 删除。
安装 Homebrew 后，`python3 scripts/homebrew_cask_test.py` 使用真实 Cask DSL 和离线 Releases 夹具验证生成结果，
不执行安装或卸载；无 Homebrew 时此项测试明确跳过。tap 修改后另运行：

```bash
brew livecheck --cask ysicing/tap/xstats ysicing/tap/xstats-capture
brew style --cask ysicing/tap/xstats ysicing/tap/xstats-capture
brew audit --strict --online --cask ysicing/tap/xstats ysicing/tap/xstats-capture
```

显式 Sparkle／应用重签名与 DMG 签名遇到 Apple 的
`The timestamp service is not available.` 时最多尝试 3 次，间隔为 2 秒、5 秒；
每次使用相同证书、时间戳、runtime 和 entitlement 参数。其他签名错误立即停止，
不会降级为无时间戳或临时签名。Xcode 内部签名、公证等步骤仍按自身结果停止。

中断后先按日志确认阶段：构建、符号备份或公证失败时保留日志、版本与构建号、
`dist/release-provenance.json` 及已有符号归档，不直接重跑完整发布；
在同一源码和构建号下按 [runbook](../.agents/skills/xstats-release/references/runbook.md) 恢复。
若 release commit 已创建但推送失败，先确认远端后重试 `git push origin main`；
若 commit 已推送、外部发布失败，仅用 `task publish` 续发既有制品。

发布构建保存在 `build/DerivedData-arm64/Build/Products/Release/XStats.app`，不安装到本机。
脚本校验架构、同团队签名、公证、Gatekeeper、构建来源和公开制品哈希。
Sparkle 私钥使用已有钥匙串账户，构建后的源码或摘要译文变化需要重新构建。

GitHub Actions 作为异步验证，等待、运行或失败均不阻塞正在进行的发布。
发布后读取一次状态并如实报告，失败记录供后续单独排查；不因 CI 失败自动修改源码、
重新构建公证或推进构建号，也不因此将已完成独立校验的发布标为部分完成。
本地测试、构建来源、签名、公证、Gatekeeper、公开制品哈希和更新入口仍是发布门禁。

更新与发布使用 `/api/v1/apps/xstats/...`，入口为：

- 国内：`https://apps.china.12306.work`。
- 海外主入口：`https://apps.12306.work`。
- 海外备用入口：`https://apps-api.xiai.me`。

默认发布和校验覆盖三个入口，固定路径及环境变量覆盖方式见 [发布脚本](../scripts/publish_api.py)；覆盖的入口必须是 https，仅 `localhost`、`127.0.0.1`、`::1` 允许 http，避免 Bearer token 明文外发。
详细签名配置、制品核验、分步发布与失败恢复见 [发布 runbook](../.agents/skills/xstats-release/references/runbook.md)。

## 项目目录

| 路径 | 用途 |
|---|---|
| `Apps/XStats/App/`、`Apps/XStats/Widget/`、`Apps/XStats/Helper/` | 主应用、桌面小组件、特权辅助工具 |
| `Apps/Capture/App/` | 独立截图与录屏应用 |
| `Apps/NetworkMonitor/App/`、`Apps/NetworkMonitor/Extension/` | 独立网络伴随应用与其系统扩展 |
| `Packages/XStatsKit/Sources/` | 采集、AI 用量、清理、更新、同步与界面模块 |
| `Packages/XStatsKit/Tests/` | Swift 测试 |
| `server/api/` | 旧更新协议的兼容实现与测试 |
| `docs/` | 开发指南、架构说明与文档导航 |
| `scripts/` | 版本、构建、发布与文档同步脚本 |
| `Taskfile.yml`、`project.yml` | 任务入口与 Xcode 工程配置 |

## 计时与护眼验证

计时页包含倒计时、番茄钟和秒表。菜单栏左键打开三模式快捷弹窗：顶部为模式和主操作，准备状态使用横向时长刻度，运行后显示读数与次要操作；倒计时可点击读数精确编辑时分秒，番茄钟刻度沿用已有专注时长选项，护眼提醒位于底部。右键提供计时页面与迷你 HUD 入口；运行优先于暂停，全部暂停时保留所选或仍有进度的计时读数。弹窗内确认计时冲突，关闭弹窗取消未确认的切换并释放弹窗刷新需求，计时继续。切换页签不停止计时；启动冲突的倒计时或番茄钟需确认，确认后暂停另一项并保留进度。秒表独立运行，最多记录 200 个分段。关闭功能结束当前计时，但保留设置及专注历史。关闭窗口后继续计时；退出应用结束当前会话，重新启动保留设置，不自动继续会话。番茄钟默认每 4 轮长休息、不限制目标轮数；设置目标后，在最后一轮的休息结束时停止自动循环。

`--show-timer` 在计时功能已启用时展开真实菜单栏快捷弹窗，供本地交互验证。`--snapshot <目录> --timer-only --language zh-Hans` 使用隔离偏好输出三种模式、快捷弹窗（含暂停）、HUD 与设置的明暗演示截图；可用 `en`、`de`、`ar` 验证长译文及 RTL。追加 `--verify-runtime` 输出隔离进程的空闲、可见、隐藏、休眠与关闭状态资源测量 `timer-runtime.json`。定向测试为 `swift test --package-path Packages/XStatsKit --no-parallel --filter 'TimerSessionTests|TimerControllerTests|RestSessionTests|WellnessControllerTests|WellnessLocalizationTests'`。覆盖截止点、暂停恢复、休眠追赶、计时互斥、分段上限、后台刷新释放及旧设置/备份。

倒计时到期复用现有系统通知代理，遵守通知权限与勿扰；在休眠中到期时于恢复后结算一次。秒表按包含休眠的单调时钟计时，UI 以秒刷新、分段记录到百分之一秒。菜单栏优先显示护眼休息、倒计时、番茄钟、秒表；仅有显示需求时刷新读数，锁屏或休眠时释放刷新定时器。

`--snapshot <目录> --wellness-only --language zh-Hans` 输出专注页、护眼卡片、提醒设置、七日统计和护眼幕布的明暗截图。可替换为 `en`、`ar` 检查长译文与 RTL。数据均为演示，使用独立偏好和内存活动库，不请求通知权限、不采集指标、不访问本机健康记录。

定向测试：`swift test --package-path Packages/XStatsKit --filter 'Wellness|RestSettings'`。覆盖提醒合并、锁屏暂停、番茄与护眼融合、午夜拆分、SQLite 去重/清空/保留边界和旧设置读取。局部迭代只运行相关测试，完整 `task test` 留给正式发布或明确需要全局回归的改动。手动验收时分别检查通知允许/拒绝与系统专注模式、多屏幕布、退出后无残留计时；护眼休息与轮间休息不重复统计。

在该定向模式后加 `--verify-runtime` 会短暂显示独立护眼预览窗口，测量空闲、可见护眼休息和关闭三个阶段，将 CPU 时间、峰值驻留内存与计时器状态写入 `runtime.json`。不创建通知管理器、不请求权限，也不改已安装应用。该结果为短时独立进程测量，不能代替多屏、系统专注模式或长期能耗验收。

专注页统一为开始专注、暂停/继续、结束；休息后默认等待“开始下一轮”，设置中的“休息后自动开始下一轮”只影响后续衔接，不暂停当前计时。现有 `restMode` 偏好与备份继续读取；新增 `timerPreferences` 保存模式、倒计时时长、长休息间隔与目标轮数，缺少该字段的旧设置沿用原有番茄钟行为。`RestSettingsTests` 覆盖默认值、旧配置映射、切换开关保留截止点、三种已保存配置下的统一结束操作，以及完成轮数保留。

休息环境音定向验证：`swift test --package-path Packages/XStatsKit --filter 'RestAmbientSoundTests|RestSoundPreviewTests'`。覆盖采样幅度/DC/起始渐入、44.1/48 kHz 生成、旧 `rain` 标识与设置备份、AVAudioEngine 离线渲染及连续切换后的引擎释放。可用 `XSTATS_SOUND_ARTIFACTS="$PWD/build/relaxing-sounds-validation"` 运行测试，生成轻雨、溪流、风声各八秒的 WAV；测试采用离线引擎，不向扬声器播放。试听文件结尾单独淡出，便于对比；实时播放器保持原有停止方式。交付前运行完整 `task test`。

自定义休息音频使用本地文件选择器，导入副本最大 50 MiB，不下载或上传。`RestCustomAudioTests` 验证原文件移走后副本可用、替换仅保留当前副本、无效/超限/取消导入不影响原文件、播放器释放，以及本机元数据不进入设置备份。该功能使用独立临时文件夹验证，不读取用户音频；本地 UI 验收应使用测试音频，不能自动选择用户私人文件。

迷你 HUD 的定向截图：`XStats --snapshot <目录> --rest-hud-only --language zh-Hans`，使用独立偏好与演示时钟输出数字、圆环、进度条三种样式的专注/暂停/轮间休息/护眼休息明暗 PNG，不启动计时、播放音频或写入用户记录。可使用 `en`、`ar` 验证长文案与 RTL。离屏截图使用实色回退，不能作为 Liquid Glass 或桌面透视的验证依据；追加 `--native-preview` 可打开限时原生预览窗口，检查真实材质。秒表 HUD 固定使用数字并隐藏样式入口；倒计时、番茄钟及护眼休息提供带选中标记的样式菜单，沿用保存的 HUD 偏好。实际面板需检查关闭/样式/底部操作不会触发拖动，旧窗口位置恢复后新尺寸仍在屏幕内。

## 内置与独立截图录屏

XStats 默认使用内置 Capture，与独立 XStats Capture 共用 CaptureCore/CaptureUI。独立版保留独立 target、Bundle ID、版本和偏好设置，两种 App 分别授权屏幕录制与麦克风。构建、宿主生命周期、URL 协议、媒体管线及运行验收见 [CAPTURE.md](CAPTURE.md)。Capture 的本地构建不安装、不更新 XStats 或网络组件，也不推进任何版本。

### 主动休息与计时快捷键

计时菜单栏弹窗顶部并排显示倒计时、番茄钟、秒表与休息；休息页选择短休或长休、调整对应时长及“休息时关闭显示器”，底部以轻量状态栏显示护眼提醒及明确的下次提醒时间、未开启、已暂停、等待休息或休息中；“休息设置…”位于右上角更多菜单，打开设置时屏蔽计时快捷键，关闭后恢复。切换到休息页不改写已保存的计时模式、不启停其他计时；空格开始所选休息，⌘L 不操作后台秒表。计时页面与菜单栏右键菜单继续提供护眼、短休、长休和关闭显示器入口。短休和长休复用已有番茄钟时长配置，但作为独立休息记录；开始时暂停当前专注并保留进度、轮次，结束后由用户继续，倒计时和秒表不受影响。番茄钟卡片只显示番茄参数，休息区域集中管理护眼提醒、声音和默认关闭的“休息时关闭显示器”。旧配置缺少该字段时解码为关闭。

休息幕布的“收起提醒”和 Esc 只隐藏当前提醒，休息计时与记录继续；“跳过休息并开始专注”和“结束休息”才改变计时状态。收起后可从计时快捷弹窗或菜单栏右键菜单“恢复全屏提醒”，恢复前同步截止时间，已结束或系统暂停的休息不重建幕布。同一轮休息在暂停、继续和显示器变化后保留收起选择，下一轮重新提醒。关闭迷你 HUD 会释放 SwiftUI 内容与对应刷新需求，应用退出时清理休息窗口及显示器观察者。

息屏使用系统 `pmset displaysleepnow`，不改电源设置、不安排强制唤醒。主动休息在息屏期间保留单次截止唤醒并停止显示刷新；系统睡眠期间不唤醒电脑，恢复后按原截止点结算，最多计入实际设置的休息时长。结束休息不会主动点亮显示器。

全局快捷键集中在“设置 → 通用”，新增入口默认不绑定；关闭计时会释放对应注册但保留配置。录制期间临时释放全局绑定，与内置 Capture 录制互相避让；同组重复组合键全部报冲突。计时页面和菜单栏弹窗中，空格控制当前选中模式的开始、暂停或继续，⌘L 为秒表计次；文本输入、原生控件、确认弹层、按键重复和快捷键录制期间不拦截按键。结束和重置没有快捷键。
