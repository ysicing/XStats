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
有 Developer ID Application 证书时，Taskfile 会自动使用钥匙串中第一个证书的唯一指纹；否则使用项目默认的 ad-hoc 签名。
桌面小组件与主应用通过 `group.work.12306.xstats` App Group 共享只读展示摘要。
菜单栏日历提供“日期与星期”“日期与农历”“农历”“自定义”四种显示方式，自定义可自由组合 y/M/d 字段与分隔符，年份可省略，输入时显示预览并提示无效格式，独立于月历的星期开关；支持农历字号与对比度、可选悬停展开，按分钟刷新，休眠或关闭功能后停止。日程和到期提醒默认关闭，通过明确的授权按钮请求 EventKit 权限，只在日历面板可见时查询当前 42 格日期范围；只读展示，不修改日程，也不向 Widget、设置备份或服务端传递内容。列表 ID 仅保存在本机，显示偏好参与设置备份。节假日覆盖年份来自内置 Tyme 数据并随应用更新；假期倒计时与最多 3 天的请假建议只基于已公布的中国调休与双休安排，跨到未知年份时停止推算。
月历使用固定六行布局，日期 ID 在生成日期时计算一次。面板打开时测量初始高度，后续翻月、详情与日程内容变化在内部滚动，不从内容几何回调反向调整窗口，避免窗口高度与懒布局估算形成反馈循环。
月历计算仅缓存最近一个月份（包含周起始日和时区），供实际面板、高度测量和重复打开共用；翻月替换缓存，避免浏览历史导致内存累积。日程日期标记在工作 actor 内随查询结果生成，界面不再逐格扫描日程列表；连续 EventKit 通知按 300 毫秒窗口合并，关闭面板时取消待执行刷新。
用于正式签名的 Apple Developer 团队须为主应用和 Widget 扩展启用同一个 App Group；
EventKit 授权还依赖主 App 的 `com.apple.security.personal-information.calendars` entitlement，配置来源为 `project.yml`。即使已有 Info.plist 权限说明，Hardened Runtime 缺少此 entitlement 仍会直接拒绝授权且不弹窗。本地预览和发布时应检查最终 App 签名中的 entitlement；系统授权必须由用户点击允许访问后决定。

小组件不读取 AI 登录凭据，也不自行请求额度或 IP 服务。日历节假日与黄历由主应用预计算，Widget 只读共享摘要；主应用未生成数据时，小组件显示空状态。
网络测速在检测到 VPN 或代理时提供“直连 / 经代理”选择，默认直连并绑定物理网卡；经代理的延迟使用目标 HTTP 往返而非本机代理提前应答的 TCP 握手。国内三网节点只支持 TCP 建连计时，因此始终尝试直连；无法取得直连路径时显示原因而不提供虚假的延迟。测速线路随设置备份保存，切换线路会清除上一路线的结果。
番茄钟与护眼休息为默认关闭的本机功能：通用设置只显示模块开关，时长、目标与声音由独立设置弹层中的系统下拉菜单调整；启用后手动开始，可暂停、重置当前阶段或跳过；切换阶段时保留各自剩余时间；有未完成进度时用“继续”恢复，点“开始”从完整时长启动，点“重置”恢复完整时长但保持暂停；跳过或自动进入下一阶段也从完整时长开始；单次模式在一轮专注与休息后暂停，循环模式连续运行，每完成四轮专注进入长休。“工作番茄”需手动点“开始工作”，随后自动交替专注与休息，每四轮进入长休；暂停或切换运行方式不结束工作时段；切换运行方式会暂停当前阶段并保留剩余时间，修改时长会暂停并回到完整专注阶段，但保留已完成轮数；点“结束工作”才结束并回到待开始状态。每日完成数只保存在本机偏好中，不加入设置备份。`RestSession` 用 `mach_continuous_time` 的绝对截止点计算阶段，唤醒后重算而非累加定时器 tick；多屏幕布、独立菜单栏计时入口与 Mini HUD 由主应用创建；HUD 可拖动并保存位置，支持数字、圆环和沙漏样式，Esc 或长按可以跳过，休息时可再专注五分钟。白噪音、粉红噪音和雨声由 `AVAudioSourceNode` 实时合成，仅在休息阶段播放。休息 Widget 从 App Group 读取阶段和预计截止时间，实际刷新受 WidgetKit 管理，不能作为秒级提醒来源。
主应用与扩展的 Bundle ID 分别是 `work.12306.xstats.app` 和 `work.12306.xstats.app.widget`；
带 App Group 能力的 Developer ID provisioning profile 要分别安装，并通过
`XSTATS_APP_PROFILE`、`XSTATS_WIDGET_PROFILE` 指定 profile 名称后再签名构建。
若钥匙串里有多张同名证书，应确保所选证书包含在两个 profile 中；可用 `SIGN_ID` 指定对应证书的 SHA-1 指纹。

Homebrew 清理使用原生命令：扫描执行 `brew cleanup --prune=30 --dry-run`，确认后执行 `brew cleanup --prune=30`。候选路径和估算空间来自命令预览，释放空间来自执行输出；日志仅记录命令执行汇总，不把预览候选记为已删除。命令中途失败或取消时释放量显示为未确认。不会根据预览路径手动删除文件，也不会回退到扫描固定缓存目录。运行时禁用自动更新、自动移除依赖和分析上报。预览设置 60 秒超时和 2 MB 输出上限；实际清理持续读取输出并只保留有限的末尾诊断文本，不因输出量中断命令。两者都支持取消。Homebrew 缓存与日志排除在通用清理规则之外。

清理页顶栏的“项目产物”入口打开独立窗口；项目扫描独立于普通缓存规则，只在用户点击后运行。默认扫描目录来自 Mole 的默认项目位置、Agent 工作树及自动发现的项目目录；“扫描位置”显示当前完整列表，可新增、移除默认或自定义目录，并恢复默认。第一次修改后保存完整列表，被移除的默认目录不会在下次扫描时自动加入；恢复默认会重新发现默认目录。目录配置只保存在本机偏好中，不加入跨设备备份。每个根目录最多向下查找 6 层；最近 7 天有活动的条目会标记提醒。应用包及其内部目录不会被当作项目扫描。Git 跟踪内容、嵌套仓库、部署密钥、符号链接及未完成安全检查的条目不会作为可清理候选；用户逐项选择并确认后，每项移到废纸篓前重新检查 Git 跟踪状态与路径身份。云盘候选会提示同步删除风险。实现不依赖 Mole 命令，也不会在后台常驻扫描。

菜单栏应用没有普通窗口，可以用已安装的应用渲染实时截图：

```bash
/Applications/XStats.app/Contents/MacOS/XStats --snapshot build/snapshots
```

修改 `CHANGELOG.md` 后运行以下命令，更新 README 中的版本摘要和活跃度图：

```bash
python3 scripts/sync_changelog.py
```

## 发布

### 版本号

公开版本号是标准 semver，真源是 `CHANGELOG.md` 顶部的第一个二级标题，格式
`## X.Y.Z · YYYY-MM-DD`；数字段不接受前导零，日期必须真实存在，不支持 `-rc` 等后缀。
内部构建号是单调递增的整数，与日期无关。

- `./scripts/version.sh` 显示当前版本和构建号。
- `./scripts/version.sh build` 只推进构建号，`task build` 会自动调用。
- `./scripts/version.sh release` 按 CHANGELOG 顶部标题写入公开版本号并推进构建号，
  由 `scripts/release.sh` 调用，不需要手动执行。

CI 不参与发版：它只在 push 到 `main` 和 PR 时跑测试与构建校验，不再由 tag 触发，
也不写版本、不建 Release。Actions 摘要仍会显示版本、构建号、Git 引用和提交号，
截图产物名也包含版本。服务器镜像工作流仍使用原有分支规则。发版全部在本地手动执行。

### 签名与公证

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

`task release` 只构建并校验制品，`task release-all` 会继续对外发布；两者都不会退出、替换或启动当前机器
`/Applications/XStats.app`。发布版 App 留在 `build/DerivedData-arm64/Build/Products/Release/XStats.app`
供签名、公证和架构核验；只有明确需要本地试用时才单独执行安装。

如果使用其他 profile，可以覆盖 `NOTARY_PROFILE`。`SKIP_NOTARIZE=1 task release` 只适合本机测试，
生成的包不应公开分发。

`release.sh` 开始时只允许版本元数据存在未提交改动，任何源码、脚本或新增文件都会中止构建；
随后在 `dist/release-provenance.json` 记录构建前提交、版本、构建号及版本文件哈希。
`publish_release.sh` 会验证最终提交只改了允许的版本元数据，且工作区、版本文件与构建记录一致，
避免安装包与 Git tag 对应源码不一致。

准备好 CHANGELOG 正式标题和四个 README 的版本徽章后，可用一个命令执行完整流程：

```bash
# 需要提前通过安全环境提供 XSTATS_RELEASE_TOKEN；该命令会 commit、push 并写入所有发布目标
task release-all
```

它会依次运行测试、签名公证构建、精确暂存版本元数据、创建并推送 release commit，
再上传对象存储、创建 GitHub Release、发布双区域清单并更新 Homebrew tap。
如果 release commit 已推送后外部发布失败，修复外部问题后运行 `task publish` 续跑，
不要再次运行 `task release-all`，否则会重复推进构建号。

需要逐阶段审阅或手工恢复时，按下面的分步流程执行。

打包完成后按顺序执行：

```bash
# 1. 检查 dist/ 产物：dmg、zip、appcast.json、xstats.rb
ls dist/

# 2. 提交并推送版本改动——publish_release.sh 会校验 HEAD 与 origin/main 一致，
#    它不会替你 commit 或 push
git add project.yml CHANGELOG.md README*.md Assets/readme
git commit -m "chore(release): 1.0.0"
git push

# 3. 上传安装包到对象存储、建 GitHub Release、提交版本清单、更新 Homebrew tap
./scripts/publish_release.sh
```

发布需要本地装有 `mc`（MinIO 客户端，别名 `c-ip` 指向对象存储源站）和 `gh`（GitHub CLI）。
安装包放在 `https://c.ysicing.net/oss/apps/macOS/XStats/`；GitHub Release 只挂 dmg，
作为应用内「手动下载」和 README 的下载入口。版本徽章需在四个 README 的第 9 行手动更新，
`scripts/sync_changelog.py` 不处理徽章。

发布前需要先把对应版本写入 `CHANGELOG.md`：把顶部的 `## 未发布` **整体替换**成正式标题，
不要在它上面再留一个 `## 未发布`。标题示例：`## 1.0.0 · 2026-09-21`。
发布完成后的下一次开发提交再插入新的空 `## 未发布`。

## 项目结构

- `App/`：应用入口和资源。
- `Widget/`：WidgetKit 扩展。
- `Helper/`：特权辅助工具及 launchd 配置。
- `Packages/XStatsKit/Sources/SMC`：SMC 通信、温度传感器和风扇控制。
- `Packages/XStatsKit/Sources/Metrics`：CPU、内存、网络、GPU、磁盘、电池、进程和传感器采集。
- `Packages/XStatsKit/Sources/AIUsage`：本机 Codex / Claude Code 会话日志的只读扫描、Token 统计与增量检查点；订阅额度在 AI 模块启用后自动查询，“显示本地用量”只控制日志扫描与本地 Token 展示。
- `Packages/XStatsKit/Sources/Cleaner`：清理规则、安全守卫、扫描和执行。
- `Packages/XStatsKit/Sources/Updates`：版本清单、下载校验和应用替换。
- `Packages/XStatsKit/Sources/HelperShared`：应用与辅助工具共用的 XPC 协议和维护命令。
- `Packages/XStatsKit/Sources/WebDAVSync`：WebDAV 同步和钥匙串密码存储。
- `Packages/XStatsKit/Sources/WidgetData`：主应用与桌面小组件共享的无凭据展示摘要；AI 额度沿用模块总开关，本地用量开关单独传给 Widget，旧摘要缺少新字段时沿用原有总开关。
- `Packages/XStatsKit/Sources/XStatsUI`：界面、设置、弹窗和菜单栏渲染。

- `Packages/XStatsKit/Sources/XStatsUI/Rest`：本机休息计时、幕布、Mini HUD 与合成声音。
- `Packages/XStatsKit/Tests`：Swift 单元测试。

硬件能力：风扇相关入口仅在成功读取到大于 0 的风扇数量后显示；尚未采样、数量未知或明确为 0 时隐藏。未知不等同于无风扇，仍沿既有需求采样重试；已确认的数量保留至本次运行结束，短暂读取失败与转速为 0 不导致入口消失。能力过滤不改写用户保存的展示偏好。

性能约束：本机 AI 用量扫描只在文件集合、文件元数据、统计日期或时区变化时重新聚合；进程内仅缓存上一轮元数据与汇总，解析检查点仍保存在 SQLite。扫描失败不复用该轮结果。清理扫描及工具清理后的大小核验必须在目录枚举中响应取消，不能发布部分计量结果。指标弹窗在同一布局轮次合并当前标题栏和滚动内容的绝对高度，下一轮更新窗口；不能同步累加内容与视口差值，也不能用新建视图的默认交互状态覆盖实际高度。定向回归见 `LocalUsageScanCacheTests`、`ScanCancellationTests` 和 `StatusPanelLayoutTests`。

更深入的模块边界、采样策略和安全约束见 [ARCHITECTURE.md](ARCHITECTURE.md)。
