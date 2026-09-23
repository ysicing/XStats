// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.

// 英文译文：每行“中文原文<Tab>English”，由 Scripts/l10n_wrap.py 收集原文。
// 带插值的原文用 {} 表示插入的内容；译文可以用 {1}、{2} 调整顺序。

extension Translations {
    static var tables: [String] {
        [english, webDAVEnglish, languagePickerEnglish, calendarEnglish]
    }

    static let english = #"""
Apple 智能	Apple Intelligence
设备不支持	Device not supported
需要 macOS 15.1 或更新版本	Requires macOS 15.1 or later
支持	Supported
无法检测	Can't determine
仅显示本机模型当前是否可用；设备兼容不代表当前可用。	Shows whether the on-device model is available now; a compatible device may still be unable to use it.
Token 活动	Token activity
每日	Daily
每周	Weekly
{} 当周：{} Tokens	Week of {}: {} Tokens
截至 {} 当周累计：{} Tokens	Through the week of {}: {} Tokens cumulative
缓存创建 Token	Cache creation tokens
AI 用量与额度	AI Usage & Quotas
Codex / Claude Code 本机 Token 用量与订阅额度	Local Codex / Claude Code tokens and subscription quotas
今天	Today
模型	Model
全部模型	All models
输入 Token	Input tokens
输出 Token	Output tokens
缓存 Token	Cached tokens
缓存命中率	Cache hit rate
用量记录	Usage records
模型排行	Model ranking
启用使用统计	Enable usage statistics
启用后读取本机会话日志，并使用本机登录凭据向 Codex / Claude 查询订阅额度。	When enabled, reads local session logs and uses local login credentials to query Codex / Claude subscription usage.
统计本机会话 Token，并使用本机登录凭据自动查询 Codex / Claude 订阅额度。	Counts local session tokens and automatically queries Codex / Claude subscription usage with local login credentials.
订阅额度	Subscription usage
服务端用量 · 与本机 Token 统计不同	Server usage · separate from local token statistics
重置：	Resets:
查询失败，显示上次额度	Query failed; showing previous quota
暂无额度数据	No quota data yet
未检测到登录凭据，请先登录对应 CLI	No login credentials found; sign in with the corresponding CLI
登录已失效，请在对应 CLI 重新登录	Login expired; sign in again with the corresponding CLI
服务暂时限流，稍后会自动重试	Rate limited; will retry later
暂时无法连接额度服务	Cannot connect to the quota service right now
额度接口返回了无法识别的数据	The quota service returned unrecognized data
启用后自动读取本机 CLI 登录凭据，直接向 Codex / Claude 查询额度；凭据不保存到 XStats。	When enabled, reads local CLI login credentials and queries Codex / Claude directly; XStats does not save the credentials.
本机 Token 统计不代表订阅账单或其他设备的用量	Local token statistics are not a subscription bill or usage from other devices
Sub2API 备用额度	Sub2API backup quota
已配置	Configured
自动查询失败时才使用此 Sub2API 账号；后台不主动探测。	Use this Sub2API account only when automatic lookup fails; background checks do not trigger active probes.
本机账号可用，当前使用自动额度。	The local account is available; automatic quota data is in use.
Sub2API 地址（HTTPS）	Sub2API address (HTTPS)
管理员邮箱	Admin email
管理员密码	Admin password
账号 ID	Account ID
管理员密码存于本机钥匙串；账号 ID 用于查询额度。	The admin password stays in this Mac's Keychain; the account ID selects the quota to view.
保存并测试连接	Save and test connection
移除配置	Remove configuration
Sub2API 配置无效	Invalid Sub2API configuration
Sub2API 配置无法读取，请检查设置	Cannot read Sub2API configuration; check the settings
Sub2API 配置已保存	Sub2API configuration saved
Sub2API 配置已移除	Sub2API configuration removed
Sub2API 配置移除失败，请检查钥匙串权限	Could not remove Sub2API configuration; check Keychain access
连接成功，读取到 {} 个额度窗口	Connection successful; read {} quota windows
Sub2API 登录失败，请检查管理员邮箱和密码	Sub2API sign-in failed; check the admin email and password
Sub2API 连接失败，请检查地址、账号 ID 与服务状态	Could not connect to Sub2API; check the address, account ID, and server
Sub2API 返回了无法识别的额度数据	Sub2API returned unrecognized quota data
Sub2API 账号平台与所选来源不匹配	The Sub2API account platform does not match the selected source
暂时无法连接 Sub2API	Cannot connect to Sub2API right now
请输入有效的 Sub2API HTTPS 地址	Enter a valid Sub2API HTTPS address
请输入有效的账号 ID	Enter a valid account ID
请填写管理员邮箱和密码	Enter the admin email and password
钥匙串读写失败，请检查权限	Could not access Keychain; check permissions
缓存 Token 已包含在输入中，推理 Token 已包含在输出中。	Cached tokens are included in input; reasoning tokens are included in output.
所选时间范围没有用量记录	No usage in this time range
部分会话日志无法读取，统计可能不完整	Some session logs could not be read; statistics may be incomplete
读取失败，显示上次统计结果	Read failed; showing previous statistics
正在读取会话日志…	Reading session logs…
暂无本机用量数据	No local usage data
 {} 英寸	 {}-inch
 · {} 项使用中	 · {} in use
 · 移到废纸篓	 · Moves to Trash
# XStats 诊断信息	# XStats Diagnostics
1 个传感器	1 sensor
1 个应用，系统自带的不列出	1 app; built-in apps are not listed
1 个进程	1 process
1 分钟	1 min
1 小时	1 hour
1 项	1 item
10 根柱子是最近 10 次采样（约 20 秒）的变化	10 bars show the last 10 samples (about 20 seconds)
15 分钟	15 min
2 小时	2 hours
24 小时	24 hours
5 分钟	5 min
5 小时	5 hours
60 秒峰值	Peak
7 天	7 days
Apple 智能暂时不可用。	Apple Intelligence is temporarily unavailable.
Apple 智能模型还在下载或准备中，请稍后再试。	The Apple Intelligence model is still downloading or preparing. Try again later.
Apple 智能没有给出回答：{}	Apple Intelligence didn't answer: {}
Apple 智能解释	Apple Intelligence
Apple（系统自带）	Apple (built in)
Application Support 中只允许清理缓存目录	Only cache folders inside Application Support can be cleaned
CPU 占用 {}，已持续超过 1 分钟。可以打开 CPU 详情，在“按应用汇总”里看看是哪个应用在占用。	CPU usage has been {} for over a minute. Open the CPU details and check By App to see which app is busy.
CPU 总占用持续 1 分钟高于设定值，通常是某个应用卡住或在后台狂跑	Total CPU usage stays above the set level for 1 minute, usually an app that is stuck or running wild in the background
CPU 持续高负载	CPU Under Sustained Load
CPU 时间	CPU Time
CPU 时间 {}	CPU time {}
CPU 最高	CPU max
CPU 核心最高温度	Hottest CPU core
CPU 温度	CPU Temperature
CPU 温度 {}	CPU temperature {}
CPU 温度 {}，已持续超过 1 分钟。可以检查高占用进程，或在“温度与风扇”里提高风扇转速。	CPU temperature has been {} for over a minute. Check busy processes, or raise the fan speed in Temperature & Fans.
CPU 温度偏高	CPU is warm
CPU 温度持续 1 分钟高于设定值	CPU stays above the set temperature for 1 minute
CPU 温度达到 {}，已恢复系统自动控制	CPU reached {}; fans returned to system control
CPU 温度过高	CPU is too hot
CPU 负载偏高	CPU load is high
CPU 负载很高	CPU load is very high
CPU 过热	CPU Overheating
CPU：{}（以单核满载为 100%）	CPU: {} (100% = one full core)
Cloudflare 接入节点（机场代码）	Cloudflare edge location (airport code)
Cloudflare（1.1.1.1）	Cloudflare (1.1.1.1)
CoreSimulator 的动态库与运行时缓存	CoreSimulator dyld and runtime caches
DNS 地址格式不正确	Invalid DNS address
DNS 已设置为 {}	DNS set to {}
DNS 缓存已刷新	DNS cache flushed
DerivedData，下次编译时自动重建	DerivedData; rebuilt on the next build
GPU 占用	GPU Usage
Globalping 返回了错误（HTTP {}）	Globalping returned an error (HTTP {})
Google（8.8.8.8）	Google (8.8.8.8)
IP 地址	IP Addresses
IP 类型	IP type
IP 纯净度	IP cleanliness
IPv6 没有经过代理：只走 IPv6 的连接会直接暴露本机地址 {}。	IPv6 isn't going through the proxy: IPv6-only connections expose your address {}.
IPv6 连接也经过代理。	IPv6 connections also go through the proxy.
XStats {} 已发布	XStats {} is available
XStats 控制	Controlled by XStats
XStats 控制中	Controlled by XStats
XStats 的通知被关闭了，打开的提醒不会显示。	Notifications for XStats are turned off, so alerts won't appear.
XStats 辅助工具	XStats Helper
XStats 通知测试	XStats Test Notification
XStats 防休眠	XStats Keep Awake
XStats 需要授权以安装新版本。	XStats needs permission to install the new version.
XStats 需要管理员权限来修改“{}”的 DNS。	XStats needs administrator permission to change DNS for “{}”.
XStats 需要管理员权限来删除 Time Machine 本地快照。	XStats needs administrator privileges to delete Time Machine local snapshots.
XStats 需要管理员权限来刷新 DNS 缓存。	XStats needs administrator permission to flush the DNS cache.
XStats 需要管理员权限来释放内存。	XStats needs administrator permission to free memory.
XStats-诊断-{}	XStats-Diagnostics-{}
XStats-诊断-{}.zip	XStats-Diagnostics-{}.zip
SMC [{}] 不支持的数据类型 {}	SMC [{}] unsupported data type {}
SMC [{}] 被固件拒绝 (0x{})	SMC [{}] rejected by firmware (0x{})
SMC [{}] 调用失败 ({})	SMC [{}] call failed ({})
SMC 通信与 Apple Silicon 风扇解锁流程移植自该项目 · MIT License	SMC access and the Apple Silicon fan unlock sequence are ported from this project · MIT License
XStats 基于 OpenStats 开发，感谢原项目的开源贡献 · MIT License	XStats is based on OpenStats. Thanks to the original project for its open-source contributions · MIT License
SSD 健康	SSD Health
Time Machine 在备份之间会先在本机留下快照，它们占的空间计入“可清除”，系统缺空间时会自动删。手动删除不影响已完成的备份。	Between backups Time Machine keeps snapshots on this Mac. Their space counts as purgeable and macOS removes them when it runs low. Deleting them by hand does not affect completed backups.
VPN / 代理	VPN / Proxy
VPN / 隧道	VPN / Tunnel
VPN 不允许绕开它连接	The VPN doesn't allow bypassing it
VPN 不允许绕开它连接，读不到本机网络原本的出口。下方按出口列出各网站。	The VPN doesn't allow connections that bypass it, so your network's original exit can't be read. Sites are listed by exit below.
VPN 隧道	VPN Tunnel
Xcode 归档	Xcode Archives
Xcode 编译缓存	Xcode Build Cache
cleanip.io 对这次评分的把握：各数据源结论越一致越高	How sure cleanip.io is about this score: the more its sources agree, the higher
macOS 系统目录（系统组件）	macOS system folder (system component)
npm 缓存	npm Cache
Go 缓存	Go Cache
Rust 缓存	Rust Cache
uv 缓存	uv Cache
Yarn 缓存	Yarn Cache
pnpm 缓存	pnpm Cache
Bun 缓存	Bun Cache
npm 下载缓存，由 npm 自行清理	npm download cache; cleaned by npm
Yarn 全局与离线镜像缓存，由 Yarn 自行清理	Yarn global and offline mirror caches; cleaned by Yarn
pnpm 内容寻址存储，仅清理未被引用的包	pnpm content-addressable store; only unreferenced packages are removed
Bun 下载的包缓存，由 Bun 自行清理	Bun package download cache; cleaned by Bun
Go 编译与完整模块缓存，由 go clean 清理	Go build and complete module caches; cleaned by go clean
Cargo 注册表与 Git 依赖缓存，需要 cargo-cache	Cargo registry and Git dependency caches; requires cargo-cache
uv 下载的 Python 包与构建缓存，由 uv 自行清理	Python package and build caches downloaded by uv; cleaned by uv
未找到 {}，无法安全清理	{} was not found, so it cannot be cleaned safely
{} 清理失败（退出码 {}）	{} cleanup failed (exit code {})
{} 清理失败（退出码 {}）：{}	{} cleanup failed (exit code {}): {}
{}：未找到 {}，无法安全清理	{}: {} was not found, so it cannot be cleaned safely
支持的内容先移到废纸篓；工具缓存由对应命令直接清理。	Supported items are moved to Trash first; tool caches are cleaned directly by their commands.
支持的缓存可以恢复；工具缓存始终由对应命令直接清理	Supported caches can be restored; tool caches are always cleaned directly by their commands
{} {} 英寸	{} {}-inch
{} · {} 个	{} · {}
{} · {} 核	{} · {} cores
{} · 约 {}	{} · about {}
{} · 负载 {}/{}	{} · load {}/{}
{} 个	{}
{} 个传感器	{} sensors
{} 个应用，系统自带的不列出	{} apps; built-in apps are not listed
{} 个网站	{} sites
{} 个进程	{} processes
{} 中位延迟	{} median
{} 分钟	{} min
{} 可用 {} · 共 {}	{} {} free · {} total
{} 天	{} d
{} 天 {} 小时	{} d {} h
{} 小时	{} h
{} 小时 {} 分钟	{} h {} min
{} 核	{} cores
{} 核图形处理器	{}-core GPU
{} 正在运行	{} is running
{} 正在运行，卸载前需要先退出。	{} is running. Quit it before uninstalling.
{} 测	at {}
{} 秒	{}s
{} 秒 / {} MB	{}s / {} MB
{} 秒·{} MB	{}s · {} MB
{} 组	{} groups
{} 缓存	{} Cache
{} 英寸	{}-inch
{} 项	{} items
{} 项 · 可直接停用	{} items · can be turned off here
{} 项 · 需要管理员权限，只读	{} items · needs admin, read-only
{} 项失败	{} failed
{}%（阈值 {}%）	{}% (threshold {}%)
{}/{} 个节点连得上	{}/{} nodes reachable
{}{}只剩 {}%，记得充电。	{}{} is down to {}%. Time to charge.
{}{}（{}）	{}{} ({})
{}。系统会自动分配任务，不用你操心	{}. macOS assigns work between them automatically.
{}中	{}
{}前	{} ago
{}前检测	Checked {} ago
{}后充满	Full in {}
{}电量低	{} battery low
{}（{}）	{} ({})
{}（代理接管）	{} (handled by proxy)
{}，{}，健康 {}	{}, {}, health {}
{}，后台{}	{}, background {}
{}：{}	{}: {}
{}：{}/{} 个节点连得上	{}: {}/{} nodes reachable
~/.npm/_cacache，安装依赖时自动重新下载	~/.npm/_cacache; downloaded again when installing dependencies
~/Library/Caches 中各应用的缓存，删除后会按需重建	App caches in ~/Library/Caches; rebuilt as needed
~/Library/Logs 中的日志和诊断报告	Logs and diagnostic reports in ~/Library/Logs
· 结果反映 XStats 自己发出的请求，按应用分流的规则下其他应用可能走不同出口	· Results reflect requests sent by XStats; with per-app rules, other apps may use different exits
“{}”只剩 {} 可用。可以用 XStats 的清理功能释放缓存。	“{}” has only {} free. Use XStats Cleanup to clear caches.
“{}”（{}）会移到废纸篓，可以从废纸篓放回。	“{1}” ({2}) will be moved to the Trash; you can put it back from there.
、	, 
一般	Fair
一键安装	Install Now
上传	Upload
上传 {} · 下载 {}	Up {} · Down {}
上传与下载速度、IP 地址、DNS	Upload and download speed, IP addresses, DNS
上传本机设置	Upload this Mac's settings
上次同步：{}	Last synced: {}
上次更新：{}	Last updated: {}
上次检查 {}，最新 {}	Last checked {}, latest {}
上次检查发现问题	Last check found problems
上次检查正常	Last check was fine
上次检查：{}	Last checked: {}
上行	Upload
下行	Download
下载	Download
下载失败：{}	Download failed: {}
下载目录中的 .dmg / .pkg / .xip / .iso，移到废纸篓	.dmg / .pkg / .xip / .iso files in Downloads; moved to Trash
不可用	Unavailable
不在允许清理的目录内	Not inside an allowed cleanup folder
不在可卸载的位置：{}	Not in a location that can be uninstalled: {}
不提供电量	No battery info
不支持 IPv6	IPv6 not supported
不是团队 {} 签名的完整应用（{}）	Not a complete app signed by team {} ({})
不是应用程序	Not an application
不是绝对路径	Not an absolute path
不经过代理	Without proxy
不能删除清理目录本身	Can't delete the cleanup folder itself
不限	No limit
不限时	Indefinitely
与 30 秒前持平	Same as 30s ago
丢包 {}%	{}% loss
严重	Critical
中位延迟	Median
中等负载	Moderate load
中等风险	Medium risk
中继	Relay
主显示器	Main display
主窗口与弹窗的配色；菜单栏始终跟随系统	Colors for the window and popovers; the menu bar always follows the system
云端只保存邮箱、姓名与设置文档	The cloud only keeps your email, name and the settings document
云端已有 {} 在 {} 保存的设置，和这台 Mac 上的不一样。要用哪一份？	{1} saved settings to the cloud {2}, and they differ from this Mac's. Which one should be used?
交换区	Swap
仅系统不休眠	Keep system awake
介质错误	Media errors
从左侧选择应用，或把应用拖到这里	Choose an app on the left, or drop one here
从未	Never
从这个节点下载测速，上限 {}	Download from this node, up to {}
代理	Proxy
代理出口	proxy exit
代理出口不支持 IPv6，IPv6 连接也不会绕过代理泄露地址。	The proxy exit doesn't support IPv6, and IPv6 connections don't leak your address around the proxy.
代理出口（{}）	proxy exit ({})
代理方式	Proxy Setup
代理没有生效	Proxy Not Working
代理软件	Proxy Apps
以单核满载为 100%	100% = one full core
以后再说	Later
以系统权限运行的后台服务，只接受本应用的请求	A background service with system privileges that only accepts requests from this app
仪表盘	Dashboard
企业	Business
企业 IP	Business IP
企业网络	Business network
会一并找出它留在资源库里的缓存、偏好设置、容器与登录启动项，全部移到废纸篓，可以放回	Also finds its caches, preferences, containers and launch agents in your Library and moves them all to the Trash, where you can restore them
会结束这个应用的 {} 个进程，未保存的内容可能会丢失。强制退出会立即结束，不给应用保存的机会。	This ends {} processes of the app and unsaved work may be lost. Force Quit ends them immediately without letting the app save.
传输速率	Link rate
位置	Location
位置：{}	Location: {}
低负载	Light load
低风险	Low risk
住宅 IP	Residential IP
住宅代理	Residential proxy
住宅宽带	Residential
住宅概率	Residential probability
余量 {}	Headroom {}
使用 {} 登录	Sign in with {}
使用云端设置	Use cloud settings
使用历史	Usage History
使用电池	On battery
使用电池且电量低于该值时，自动关闭合盖运行	Turn off lid-closed mode when on battery below this level
例如 1.1.1.1, 8.8.8.8	e.g. 1.1.1.1, 8.8.8.8
保持唤醒	Keep Awake
保持运行	Keep alive
信号强度	Signal
修改 DNS 需要管理员权限：已安装辅助工具时直接修改，否则每次弹出系统授权框。	Changing DNS needs administrator permission: it's applied directly when the helper is installed, otherwise the system asks each time.
修改地址	Edit addresses
偏好设置	Preferences
偏高	Elevated
停止	Stop
停用	Turn Off
停用失败：{}	Failed to turn off: {}
健康 {}	Health {}
健康度	Health
健康度是现在充满时的容量与出厂容量之比，低于 80% 时苹果建议更换电池	Health is today's full charge capacity versus the design capacity; Apple recommends a replacement below 80%
充电上限可在系统设置中设为 80%–100%，长期接电源时有助于延缓电池老化	Set a charge limit of 80%–100% in System Settings to slow battery aging when you stay plugged in
充电中	Charging
充电盒	Case
全局代理	Global Proxy
全局快捷键（在任何应用中都能使用，需要包含 ⌘、⌥ 或 ⌃）	Global shortcuts (work in any app; must include ⌘, ⌥ or ⌃)
全球探针看目标	Global Probes
全球节点	Global Nodes
全选	Select All
全部	All
全部删除	Delete all
全部经代理	All Traffic Proxied
公网 IP	Public IP
公网 IP 查询	Public IP Lookup
公网 IPv4	Public IPv4
公网 IPv6	Public IPv6
共 {}	{} total
共 {} 条记录	{} records
共 {}，{} 个条目 · {}	{1} in {2} items · {3}
关	Off
关于	About
关于 XStats	About XStats
关闭	Off
其他	Other
其他位置	Other locations
其他磁盘	Other disks
其他程序手动控制	Controlled by another app
其他程序控制	Another app
内存	Memory
内存 {}	Memory {}
内存与图形	Memory & Graphics
内存压力严重	Critical Memory Pressure
内存压力严重的时段：{} 个（图上红色标记）	Critical memory pressure periods: {} (marked red)
内存压力偏高	Memory pressure is elevated
内存压力持续 30 秒处于严重，系统开始大量换页	Memory pressure stays critical for 30 seconds and the system starts heavy paging
内存已整理	Memory cleaned up
内存水位	Memory Levels
内存类型	Memory type
内存：{}	Memory: {}
写入	Write
出口	Exit
出口与分流	Egress & Routing
出口与分流：检查 VPN 与代理是否生效、各网站从哪个出口出去	Egress & Routing: check whether your VPN and proxy work and which exit each site uses
出口依据	Basis
出口未知	Exit unknown
出现介质错误，建议备份	Media errors found; back up your data
分别经物理网卡、系统代理与 VPN 隧道访问检测目标，约需 10 秒。	Reaching test targets through the network interface, the system proxy, and the VPN tunnel. This takes about 10 seconds.
分流正常	Split Routing Works
切换到浅色	Switch to Light
切换到深色	Switch to Dark
刚刚	Just now
刚刚检测	Checked just now
刚刚被使用	Recently used
删除	Delete
删除…	Delete…
删除中…	Deleting…
删除云端数据	Delete cloud data
删除云端数据？	Delete cloud data?
删除全部本地快照？	Delete all local snapshots?
删除账号、所有登录方式与云端保存的设置；这台 Mac 上的设置保留	Deletes the account, every sign-in method and the settings stored in the cloud; settings on this Mac stay
到时后自动恢复系统默认的睡眠行为。	Normal sleep behavior resumes when time runs out.
刷新	Refresh
刷新 DNS 缓存	Flush DNS Cache
刷新 DNS 缓存、释放内存、为网络服务设置 DNS 服务器	Flush the DNS cache, free memory, set DNS servers for network services
刷新状态	Refresh Status
刷新间隔	Refresh Interval
刷新频率	Refresh Rate
剩余	Remaining
距重置	Until reset
剩余 {}	{} left
剩余寿命	Life left
剩余寿命 {}% · 已写入 {}	{}% life left · {} written
剪切	Cut
功耗	Power
包名是 {}	Bundle ID is {}
包含城市数据	Include City Data
协议版本	Protocol version
单个节点一次测速最多花的时间与流量，先到哪个停哪个	Time and data cap for one node's speed test, whichever comes first
单行	Inline
单行文字	Inline Text
占整机 CPU 的比例：{} 个核心全部跑满为 100%	Share of total CPU: all {} cores fully busy is 100%
占用	Usage
占用超过 85% 时数值与图形显示为红色	Show values and graphs in red above 85%
占用超过 85%（电池电量低于 20%）时数值与图形显示为红色	Values and graphics turn red above 85% usage (below 20% battery)
占用高于	Usage above
卷	Volume
卸载	Uninstall
卸载“{}”？	Uninstall “{}”?
卸载失败：{}	Uninstall failed: {}
卸载应用	Uninstaller
卸载辅助工具	Uninstall Helper
历史	History
历史记录	History
历史记录已关闭，下面是关闭前记录的数据。	History recording is off. Below is data recorded before it was turned off.
压力 {}	Pressure {}
压力{}	{}
压力走势	Pressure Trend
压缩	Compressed
压缩与交换	Compression & Swap
压缩为你省下	Saved by compression
压缩包里应当只有一个 .app	The archive should contain exactly one .app
压缩比	Compression ratio
原因	Reason
原生 / 广播	Native / broadcast
原生 IP	Native IP
去批准	Approve
去授权	Grant Access
双行圆点	Dots
双行文字	Stacked Text
双行箭头	Arrows
反向解析	Reverse DNS
反馈问题	Report a Problem
发现新版本 {}	Version {} available
发现问题	Problems found
发现问题：{}	Problem found: {}
发生这些状况时发送系统通知，点通知打开对应页面	Send a notification when these happen; click it to open the related page
发送	Send
发送测试通知	Send Test Notification
取消	Cancel
受保护	Protected
受保护的项目：{}	Protected item: {}
另一台 Mac	Another Mac
另有 {} 个出口，见网站分流	{} more exits, see Site Routing
另有 {} 移到废纸篓	Plus {} moved to Trash
另有 {} 项	{} more
只含当前用户的进程	Your processes only
只在打开温度与风扇页面时记录	Recorded only while Temperature & Fans is open
只在菜单栏显示 GPU 或打开 GPU 相关页面时记录	Recorded only when GPU is in the menu bar or a GPU page is open
只在菜单栏显示温度、开启过热通知或打开温度页面时记录	Recorded only when temperature is in the menu bar, overheating alerts are on, or a temperature page is open
只在菜单栏显示电池或打开电池页面时记录	Recorded only while Battery is in the menu bar or the Battery page is open
只显示菜单栏时的采样间隔；打开弹窗或主窗口时为 1 秒（进程页 2 秒）	Sampling interval when only the menu bar is shown; 1 second with a popover or window open (2 seconds on Processes)
只查找以该应用包名命名的文件，以及 Application Support、Logs 下与应用同名的目录；钥匙串与其他应用共享的数据不会动。程序坞里的图标会一并移除	Only files named after the app's bundle ID, plus folders with the app's name in Application Support and Logs, are included. Keychains and data shared with other apps are never touched. The Dock icon is removed as well
只设置了系统代理：浏览器等应用走代理，命令行工具、游戏等不读代理设置的程序仍在直连。要接管全部流量，可以开启增强模式或 TUN 模式。	Only a system proxy is set: browsers and most apps use it, but command-line tools, games, and other programs that ignore proxy settings still connect directly. To route all traffic, turn on enhanced mode or TUN mode.
可以恢复，但清空废纸篓前不会释放空间	Recoverable, but space isn't freed until the Trash is emptied
可执行文件：{}	Executable: {}
可清理 · 已选 {} 项	Cleanable · {} selected
可清除	Purgeable
可清除是系统随时可以腾出的缓存；访达显示的“可用”把它算在内	Purgeable is cache the system can free at any time; Finder's “available” figure includes it.
可用	Available
可用 {}	{} available
可用 {} / 共 {}	{1} free of {2}
可用内存只剩 {}，系统正在压缩和交换内存。关闭不用的应用可以缓解。	Only {} of memory is available and the system is compressing and swapping. Quitting unused apps will help.
可用空间包含系统可以随时清除的缓存，与访达显示一致	Available space includes purgeable caches, matching Finder
可访问	Reachable
右侧风扇	Right Fan
右耳	Right
各核心占用	Per-Core Load
各核心负载	Core Load
各项指标正常	Everything looks good
合上屏幕时 Mac 不进入睡眠，下载、渲染、远程连接不中断。	Your Mac stays awake with the lid closed, so downloads, renders and remote sessions continue.
合并为一个	Combined
合盖后继续运行	Keep Running with Lid Closed
合盖电量下限	Lid Mode Battery Floor
合盖睡眠	Lid sleep
合盖运行	Lid Closed
合盖运行时散热变差，请勿放入包中。使用电池且电量低于 {}% 时会自动关闭。	Cooling is worse with the lid closed, so don't put your Mac in a bag. Turns off automatically on battery below {}%.
合盖运行设置	Lid Mode
合盖运行需要修改系统睡眠设置，需安装辅助工具（管理员授权一次）。	Lid mode changes system sleep settings and needs the helper (one-time admin approval).
同步	Sync
同步失败	Sync failed
同步的内容：菜单栏项目与风格、刷新频率、外观与语言、详情弹窗的区块、连接探测、通知、快捷键、风扇安全温度、合盖电量下限。当前页面、辅助工具与历史记录留在本机。	What syncs: menu bar items and styles, refresh rate, appearance and language, popover sections, connection probe, notifications, hotkeys, fan safety temperature and lid-mode battery floor. The current page, the helper and history stay on this Mac.
后台低频探测	Background Probing
启动于	Booted
启动时和之后每天检查一次，发现新版本时显示更新摘要	Checks at launch and daily, and shows what's new when an update is found
启动磁盘	Startup Disk
启动磁盘可用空间低于 10% 或 10 GB，每 10 分钟检查一次	Startup disk has less than 10% or 10 GB free; checked every 10 minutes
启动磁盘已用占比	Startup disk used
启动项	Startup Items
启用	Turn On
启用 {}	Enable {}
启用失败：{}	Failed to turn on: {}
哔哩哔哩	Bilibili
唤醒	Wakeups
团队 {}	team {}
国内	China
国内分省三网延迟	Latency Across China
国内网站也绕到了{}，访问会变慢，也可能触发风控。	Chinese sites also detour through the {}, which is slower and may trigger security checks.
国内网站直连，国际网站经 {} 的{}。	Chinese sites connect directly; international sites go through {}'s {}.
国内网站走了代理，访问会绕路变慢。	Chinese sites are going through the proxy, which takes a longer route and is slower.
国内网络建议选阿里云或腾讯；选路由器只检测本地连接	In mainland China, Alibaba Cloud or Tencent work best; Router only checks the local link
图形	Graphics
图形处理器	GPU
图形核心	GPU cores
图标	Icon
圆环	Ring
圆环表示当前占用比例	A ring shows current usage
在 cleanip.io 查看这个 IP 的完整报告	Open this IP's full report on cleanip.io
在主窗口打开“{}”	Open “{}” in the main window
在程序坞显示图标	Show Icon in Dock
在线升级	Online Updates
在线升级：发现新版本时显示更新摘要，一键安装并自动重启	Online updates: see what's new, install in one click and relaunch automatically
在菜单栏显示	Show in Menu Bar
在菜单栏显示{}	Show {} in menu bar
在访达中显示	Show in Finder
型号	Model
域名，例如 example.com	Domain, for example example.com
处理器	Processor
处理器核心	CPU cores
备用空间	Available spare
备用空间低于阈值，建议备份	Spare capacity below threshold; back up your data
外置硬盘、U 盘、镜像与网络共享	External drives, USB sticks, disk images and network shares
外观	Appearance
存储	Storage
它只做这几件事	It only does these things
安全温度	Safety Temperature
安装	Install
安装包	Installers
安装包不支持这台 Mac 的芯片	This update doesn't support this Mac's chip
安装包内容不正确：{}	The update package is invalid: {}
安装包校验值与版本清单不一致，已放弃安装	The update's checksum doesn't match the manifest; installation stopped
安装失败：{}	Install failed: {}
安装辅助工具	Install Helper
安静	Quiet
定时 ping 一个地址，记录网络是否通畅	Pings an address regularly to record whether the network is reachable
定时探测网络	Connectivity Probe
实测	Measured
家目录	Home folder
容量	Capacity
导出…	Export…
导出失败：{}	Export failed: {}
导出时间	Exported at
导出诊断信息	Export Diagnostics
寿命偏低，注意备份	Low remaining life; keep backups
寿命按厂商估算的已用比例计算；写入量越大消耗越快，日常使用通常可用很多年	Life is based on the vendor's wear estimate. Heavy writes wear it faster; typical use lasts many years.
将清理 {} 个项目，共 {}。{}	{} items, {} total, will be cleaned. {}
将移到废纸篓	Will move to Trash
小标签在上、数值在下，最紧凑	Small label above the value; most compact
尚未检查	Not checked yet
屏幕保持常亮	Keep display on
屏幕可按设置关闭，下载、编译等后台任务继续运行	The display can turn off as usual while downloads and builds keep running
屏幕和系统都不会因闲置而关闭或休眠	Neither the display nor the system sleeps when idle
展开{}	Expand {}
峰值	Peak
峰值 {}	Peak {}
工具	Tools
左侧风扇	Left Fan
左耳	Left
已{}“{}”	{} “{}”
已使用 Developer ID 签名	Signed with Developer ID
已停用	Off
已充满	Charged
已删除 {} 个快照，腾出的空间稍后会反映在“可清除”里	Deleted {} snapshots; the freed space will show up under purgeable shortly
已到设定时间，防休眠已关闭	Time's up; Keep Awake is off
已加载	Loaded
已取消	Cancelled
已取消登录	Sign-in cancelled
已启用	Enabled
已导出 {}	Exported {}
已将 {} 与 {} 项残留移到废纸篓，约 {}{}{}。需要时可以在废纸篓里放回。	Moved {} and {} leftovers to the Trash, about {}{}{}. You can put them back from the Trash.
已开启同步	Sync is on
已恢复自动获取 DNS	DNS is automatic again
已扫描 {} 个条目 · {}	Scanned {} items · {}
已把“{}”移到废纸篓	Moved “{}” to the Trash
已拷贝	Copied
已推出“{}”	Ejected “{}”
已是最新版本	Up to date
已用	Used
已用 {} · {}	{} used · {}
已用内存占比	Memory used
已记录的数据会从本机删除，无法恢复。	Recorded data will be deleted from this Mac and can't be recovered.
已运行	Uptime
已运行 	Up 
已连接	Connected
已连接的键盘、鼠标、耳机等电量低于 15%，每 10 分钟检查一次	A connected keyboard, mouse, headphones or similar drops below 15%; checked every 10 minutes
已选 {} 项 · {}	{} selected · {}
已释放	Freed
已释放 {} 缓存内存	Freed {} of cached memory
布局	Layout
干净	Clean
平均	Average
平均 {} · 峰值 {}{}	Avg {} · Peak {}{}
平均 {} · 最高 {}	Avg {} · Max {}
平均温度	Average temperature
平均负载除以核心数：小于 1 表示任务不用排队，大于 1 表示有任务在等 CPU	Load average per core: below 1 means no waiting; above 1 means tasks are waiting for the CPU
广播 IP	Broadcast IP
序列号	Serial Number
应用	Apps
应用 {} / 辅助工具 {}	App {} / Helper {}
应用与勾选的 {} 项残留会移到废纸篓，约 {}。清空废纸篓前都可以放回。	The app and {} selected leftovers will move to the Trash, about {}. You can restore them until you empty the Trash.
应用包内未找到辅助工具，请使用完整构建的 XStats.app	Helper not found in the app bundle. Use a complete XStats.app build.
应用拒绝退出，可以试试强制退出	The app refused to quit. Try Force Quit.
应用数据	App Data
应用日志与崩溃报告	App Logs & Crash Reports
应用本体	Application
应用正在运行，请先退出	The app is running. Quit it first.
应用程序文件夹	Applications folder
应用缓存	App Caches
应用退出或断开连接时，自动恢复风扇与睡眠设置	Restores fan and sleep settings when the app quits or disconnects
废纸篓	Trash
延迟	Latency
开	On
开关防休眠	Toggle Keep Awake
开发	Developer
开发构建不支持在线升级	Development builds can't update online
开发构建不支持在线升级，请下载安装包	Development builds can't update online; download the installer instead
开发版	Development
开发者	Developer
开启	On
开启 / 关闭“合盖不睡眠”（等同 pmset disablesleep）	Turn lid-closed sleep prevention on or off (same as pmset disablesleep)
开启后图标出现在菜单栏；按住 ⌘ 键拖动图标可以调整位置	Adds the icon to the menu bar; hold ⌘ and drag the icon to move it
开始分析	Analyze
开始探测	Run
开机以来	Since boot
开机后上传	Uploaded since boot
开机后下载	Downloaded since boot
开机后自动在菜单栏显示 XStats	Show XStats in the menu bar after you log in
异常断电	Unsafe shutdowns
弹窗显示	Popover Sections
强冷	Max
强制刷新：忽略缓存，立即重新查询公网 IP 与归属地	Force refresh: ignore the cache and look up the public IP and location again now
强制退出	Force Quit
归属地	Location
归属地数据来自	Location data from
当前 {} · 发布于 {} · {} · {}	Current {} · Released {} · {} · {}
当前为临时签名的开发构建，辅助工具只能校验应用标识。使用 Developer ID 证书构建后会自动启用团队校验。	This is an ad-hoc signed development build, so the helper can only check the bundle ID. Team verification turns on automatically with a Developer ID build.
当前效果（实时数据）	Preview (live data)
当前版本	Current version
当前版本 {}	Current version {}
当前版本 {} · {} · {}	Current version {} · {} · {}
当前用户	Current User
录制快捷键	Record Shortcut
影音	Video
循环 {} 次	{} cycles
循环次数	Cycle count
微信	WeChat
忙	Busy
快捷开关	Quick Toggles
快照名称格式不认识，没有删除	Unrecognized snapshot names; nothing was deleted
性能核	Performance
总占用	Total
总览	Overview
恢复系统睡眠失败：{}	Failed to restore system sleep: {}
我的	Mine
截图已输出到 {}	Snapshots saved to {}
所属应用：{}（{}）	App: {} ({})
所有内容先移到废纸篓。	Everything goes to the Trash first.
所有指标合成一个图标，点击弹出状态总览，可切到各项详情	All metrics in one icon; click for a status overview, with tabs for each metric's details
所有检测目标都连不上。请检查网络连接，或者代理软件是否正常运行。	None of the test targets could be reached. Check your network connection and whether your proxy app is running properly.
所有用户	All Users
所有用户与系统级的启动项需要管理员权限，请在系统设置的登录项中管理	All-users and system items need admin rights; manage them in Login Items in System Settings
所有磁盘合计	All disks
手动	Manual
手动下载	Download Manually
打包版本、系统与辅助工具状态、主要设置、最近 3 天的运行日志和崩溃报告，反馈问题时附上；会去掉序列号、IP 与硬件地址	Bundles version, system and helper status, main settings, and the last 3 days of logs and crash reports to attach to a bug report. Serial numbers, IP and hardware addresses are removed.
打包生成的 .xcarchive，删除后无法重新符号化旧版本崩溃日志	.xcarchive bundles; without them old crash logs can't be symbolicated
打开 XStats	Open XStats
打开 XStats 主窗口	Open the XStats Window
打开 SMC 失败 ({})	Failed to open SMC ({})
打开登录项设置	Open Login Items Settings
打开网络详情时向 Cloudflare（1.1.1.1）或 ipify 查询一次公网地址，10 分钟内不重复请求；归属地、ASN、网络类型与纯净度由这台 Mac 直接向 cleanip.io 查询，只发送公网地址	When network details open, asks Cloudflare (1.1.1.1) or ipify for your public address, at most once every 10 minutes; location, ASN, network type and cleanliness are looked up by this Mac directly at cleanip.io, sending only the public address
打开进程页	Show Processes
打开通知设置	Open Notification Settings
托管	Hosting
执行中	Working
扫描中	Scanning
扫描中…	Scanning…
扫描于 	Scanned 
抖动	Jitter
抖音	Douyin
折线历史	Line History
折线是最近 30 次采样（约 1 分钟）的走势	The line shows the last 30 samples (about a minute)
拷贝	Copy
拷贝 PID	Copy PID
拷贝 PID {}	Copy PID {}
持续时间	Duration
按下快捷键…	Press shortcut…
按单核满载为 100% 计：{}	Per core (one full core = 100%): {}
按应用	By App
按应用汇总	By App
按文件夹	By folder
按系统代理访问国际网站	International sites via system proxy
按系统休眠	System sleep
按规则分流	Rule-Based Routing
按进程	By Process
换一台 Mac 登录后，菜单栏、外观、通知与快捷键等偏好会自动恢复。不登录也能使用全部功能。	Sign in on another Mac and your menu bar, appearance, notification and hotkey preferences come back automatically. Everything works without signing in.
换入 / 换出	Swap in / out
掌托	Palm rest
排队程度	Run Queue
探测目标	Probe Target
探针一直没有返回结果，稍后再试	The probes never returned a result; try again later
探针数量，一个探针占一次额度	Number of probes; each probe uses one test from the quota
接入 Cloudflare 的网站能实测出口，其余按国内 / 国际规则推断	Exits are measured for sites behind Cloudflare and inferred for the rest
接口	Interface
接通电源	Plugged in
推出	Eject
推出中…	Ejecting…
推断	Inferred
搜索名称、PID 或用户	Search name, PID or user
搜索应用	Search apps
撤销	Undo
收起	Collapse
改回开机后累计	Back to since-boot totals
政府	Government
教育网	Education
散热模式	Cooling
数据	Data
数据来源	Source
整体风格	Overall style
整体风格套用到所有项目。想让某个项目不一样，在下面“显示项目”里给它单独选一种，比如 CPU 用圆环、风扇用数字。	The overall style applies to every item. To make one item different, pick a style for it under Items below, say a ring for CPU and plain numbers for the fan.
整机	System
整机 {}	System {}
整机功耗	System Power
文件系统检查	File system check
文件系统结构完好，没有发现错误	The file system structure is intact; no errors found
新版本未通过 Apple 公证检查，已放弃安装	The new version failed Apple notarization; installation stopped
新版本需要 macOS {} 或更高版本	The new version requires macOS {} or later
无	None
无 Bundle ID	No bundle ID
无法创建电源断言（{}）	Couldn't create power assertion ({})
无法创建签名要求	Couldn't create the signing requirement
无法打开	Couldn't open
无法打开登录窗口	Couldn't open the sign-in window
无法推出“{}”：{}	Couldn't eject “{1}”: {2}
无法确认是否经过代理	Can't Confirm Proxy Use
无法移到废纸篓：{}	Couldn't move to the Trash: {}
无法读取	Unreadable
无法读取签名	Couldn't read the signature
无法连接辅助工具	Couldn't connect to the helper
无法连接辅助工具：{}	Couldn't connect to the helper: {}
无需清理	Nothing to clean
日志与崩溃报告	Logs & Crash Reports
显卡信息	GPU info
显示 / 隐藏主窗口	Show / Hide Main Window
显示 {} 项	{} shown
显示为 {}×{}	Looks like {}×{}
显示名称：{}	Display name: {}
显示器	Displays
显示序列号	Show Serial Number
显示项目	Items
暂时没有拿到评分，稍后会再试	No score yet; it will try again later
更新内容	What's New
更省电，负责后台和轻量任务	More efficient; handles background and light work
替换后未找到应用	App not found after replacement
替换应用失败：{}	Failed to replace the app: {}
最低 {} · 最高 {} · 目标 {} RPM	Min {} · Max {} · Target {} RPM
最大的文件	Largest files
最小化	Minimize
最强	Strongest
最忙的核心	Busiest core
最快，重活优先交给它们	Fastest; heavy work goes here first
最近 24 小时	Last 24 hours
最近 60 秒	Last 60 seconds
最近没有应用在读写磁盘	No apps are reading or writing right now
最近的内存压力走势	Recent memory pressure
最近错误	Last error
最高	Max
最高 / 平均	Max / Avg
最高温度	Max temperature
服务器在 getopenstats.com，不上传任何监控数据；随时可以删除。	The server is at getopenstats.com; no monitoring data is uploaded, and you can delete everything at any time.
服务器返回 {}	Server returned {}
服务器返回的数据格式不正确	The server returned malformed data
未使用	Unused
未使用代理	No Proxy in Use
未保存的内容可能会丢失。强制退出会立即结束，不给应用保存的机会。	Unsaved work may be lost. Force Quit ends it immediately without letting it save.
未发现	None found
未安装	Not Installed
未完成的下载	Incomplete Downloads
未开启，Mac 按系统设置休眠	Off; your Mac sleeps as usual
未找到 AppleSMC 服务	AppleSMC service not found
未检出	None detected
未检测到可调节的风扇	No adjustable fans found
未检测到风扇	No fans detected
未知状态	Unknown status
未签名或临时签名	Unsigned or ad-hoc signed
未签名（开发构建）	Unsigned (development build)
未设置	Not set
未连接	Not connected
未连接网络	No network
本地 IPv4	Local IPv4
本地 IPv6	Local IPv6
本地快照	Local snapshots
本机 IP 这一小时还剩 {}/{} 次探针额度	{}/{} probe tests left this hour for this Mac's IP
本机信息	This Mac
本机宽带	Your Connection
本机网络	Your Network
本次用掉 {}	{} used
机型	Model
机型标识符	Model Identifier
机房	Data center
机房 IP	Data center IP
极好	Excellent
极高风险	Very high risk
构建	Build
查看	View
查看{}详情	Show {} details
查看全部进程	All Processes
查看包含的项目	Show items
查看完整更新日志	Full Changelog
查看清理日志	View Cleanup Log
查询中…	Looking up…
查询公网 IP	Look Up Public IP
查询已关闭	Lookup off
柱状历史	Bar History
标签与数值同一行，最易读	Label and value on one line; easiest to read
标识	Identifier
核心	Cores
核心 {}	Core {}
核心 {}（{}）· {}	Core {} ({}) · {}
核心分工	Core Types
核心数	Cores
核心最高温度；余量是离 100°C 还差多少度，越接近 0 越可能因过热降频	Hottest core; headroom is how many degrees remain before 100°C — the closer to 0, the more likely thermal throttling
核心热力图	Core Heatmap
核心负载	Core Load
检查	Check
检查 VPN 与代理是否生效、各网站从哪个出口出去	Check whether your VPN and proxy work and which exit each site uses
检查中…	Checking…
检查完成，但没有得到明确结论	The check finished without a clear verdict
检查更新	Check for Updates
检查更新…	Check for Updates…
检查更新失败	Update check failed
检查未能完成（退出码 {}）	The check didn't complete (exit code {})
检测中 {}/{}	Checking {}/{}
检测到 {}，但测试的网站都在直连，没有经过代理出口。	{} was detected, but all tested sites connect directly without going through a proxy exit.
模式	Mode
模拟器	Simulators
模拟器缓存	Simulator Caches
正在下载	Downloading
正在使用	In use
正在修改 DNS…	Changing DNS…
正在同步	Syncing
正在同步…	Syncing…
正在安装，完成后 XStats 会自动重启。	Installing. XStats will relaunch when it's done.
正在导出…	Exporting…
正在导出诊断信息…	Exporting diagnostics…
正在扫描应用…	Scanning apps…
正在收集走势…	Collecting trend…
正在本机生成…	Generating on this Mac…
正在查找残留…	Finding leftovers…
正在查询…	Looking up…
正在核对启动盘的文件系统结构，通常几秒到几十秒	Verifying the startup disk's file system structure; this usually takes seconds to a minute
正在核对校验值、开发者签名与 Apple 公证…	Verifying checksum, developer signature and Apple notarization…
正在检查…	Checking…
正在检查更新	Checking for updates
正在检测出口与分流…	Checking egress and routing…
正在测 {}/{}	Testing {}/{}
正在测上行	Measuring upload
正在测下行	Measuring download
正在测延迟	Measuring latency
正在清理…	Cleaning…
正在移除…	Removing…
正在统计…	Counting…
正在统计各进程流量…	Measuring per-process traffic…
正在计算可清理空间	Calculating cleanable space
正在读取 SMART 信息；外置磁盘或不支持 NVMe SMART 的磁盘不显示	Reading SMART data; external disks and disks without NVMe SMART aren't shown
正在读取…	Loading…
正在读取传感器…	Reading sensors…
正在读取进程…	Reading processes…
正在读取风扇…	Reading fans…
正在释放…	Freeing…
正常	Normal
此刻各核心的占用；超过 60% 变橙色、85% 变红色	Current load of each core; orange above 60%, red above 85%
此设备没有可调节的风扇	This Mac has no adjustable fans
每个应用占整机 CPU 的比例：{} 个核心全部跑满为 100%，与顶部的总占用是同一把尺子。鼠标悬停在数值上可以看按单核计的占用（活动监视器的算法）	Each app's share of total CPU: all {} cores fully busy is 100%, the same scale as the total above. Hover a value to see it per core (the Activity Monitor way)
每个指标一个图标，点击弹出该项详情	One icon per metric; click for its details
每分钟把主要指标的平均值与峰值写入本机数据库，保留 7 天，不上传	Writes averages and peaks of key metrics to a local database every minute. Kept for 7 days, never uploaded.
每核 {}	{} per core
每根柱子一个核心，按核心类型着色	One bar per core, colored by core type
每点 {}	{} per point
每秒让 CPU 从空闲中唤醒的次数，越高越耗电	Times per second the CPU is woken from idle; higher uses more power
每秒读写磁盘的字节数	Bytes read and written per second
每行一个核心（共 {} 个），每列一次采样，颜色越深越忙；右侧粗条是此刻的占用	One row per core ({} in total), one column per sample, darker means busier; the wide bar on the right is the current load
每项独立	Separate
比 30 秒前低 {}%	{}% lower than 30s ago
比 30 秒前高 {}%	{}% higher than 30s ago
永久删除废纸篓中的内容，无法恢复	Permanently deletes items in the Trash; can't be undone
沙盒容器	Containers
没有匹配的进程	No matching processes
没有启动项	No startup items
没有已连接的蓝牙设备	No connected Bluetooth devices
没有检测到 VPN 或系统代理，所有流量都从本机网络直接出去。	No VPN or system proxy detected. All traffic leaves directly from your network.
没有检测到显示器	No displays detected
没有电池	No battery
没有移动任何文件{}	Nothing was moved{}
没有超过 50 MB 的文件	No files over 50 MB
流量历史	Traffic History
流量经过 {}，系统 DNS 可能由它接管，修改后不一定生效。	Traffic goes through {}, which may take over system DNS, so changes might not apply.
浅色	Light
浅色菜单栏预览	Light menu bar preview
测延迟	Latency
测本机宽带、国内分省三网延迟与全球节点	Test your broadband, per-province latency in China and global nodes
测试的网站都经 {} 的{}，没有暴露本机网络的地址。	All tested sites go through {}'s {}, so your network's own address isn't exposed.
测速	Test
浏览器	Browsers
淘宝	Taobao
深色	Dark
深色菜单栏预览	Dark menu bar preview
清理	Cleanup
清理中…	Cleaning…
清理可回收的缓存内存（需要管理员授权或辅助工具）	Frees reclaimable cached memory (needs admin approval or the helper)
清理所选 {}	Clean Selected {}
清空废纸篓	Empty Trash
清除	Clear
清除…	Clear…
清除全部历史记录？	Clear all history?
清除历史	Clear History
清除快捷键	Clear shortcut
清除搜索	Clear search
温度	Temperature
温度与风扇	Thermals
温度传感器	Temperature sensors
温度单位	Temperature Unit
满载	Maxed out
滥用记录	Abuse reports
点击拷贝	Click to copy
版本	Version
版本 {}	Version {}
版本 {}{}	Version {}{}
版本是 {}，清单写的是 {}	Version is {}, but the manifest says {}
版本清单格式不正确	Invalid version manifest
物理地址	Hardware address
状态	Status
状态圆点	Status Dot
状态总览	Status Overview
状态正常	Healthy
状态良好	Healthy
现在	Now
现在没有本地快照	No local snapshots right now
用 Apple 智能解释	Explain with Apple Intelligence
用户	User
用户 {}	User {}
用户资源库	User Library
用系统图标代替文字标签	System icons instead of text labels
由 Apple 智能在这台 Mac 上生成，不联网；内容可能不准确，结束进程前请自行确认。	Generated on this Mac by Apple Intelligence, offline. It may be inaccurate; double-check before ending a process.
由 SMC 与系统能耗统计读取；新款芯片不提供可靠的 CPU 单独功耗	Read from the SMC and system energy stats; newer chips don't report reliable CPU-only power
由 macOS 调节	Managed by macOS
由辅助工具执行	Handled by the helper
电池	Battery
电池 {}	Battery {}
电池供电	On battery
电池健康	Battery health
电池健康度下降	Battery Health Low
电池充电	Battery charging
电池放电	Battery discharging
电池最大容量为 {}，续航会明显缩短。可以在“系统设置 › 电池”查看是否建议维修。	Battery maximum capacity is {}, so battery life will be noticeably shorter. Check System Settings › Battery for service recommendations.
电池最大容量低于 80%，每 30 天最多提醒一次	Battery maximum capacity drops below 80%; at most once every 30 days
电池温度	Battery temperature
电池电量	Battery level
电池设置	Battery Settings
电源	Power
电源供电	On power adapter
电源输入	Adapter input
电源适配器{}	Power adapter{}
电量	Battery
电量下限	Battery floor
电量与充电状态；没有电池的 Mac 显示蓝牙设备电量	Charge level and charging state; Macs without a battery show Bluetooth device batteries
电量低于 {}%，已关闭合盖运行	Battery below {}%; lid mode turned off
电量历史	Charge history
电量条	Meter
登录以同步设置	Sign in to sync settings
登录启动项	Launch Agents
登录回调不正确	Invalid sign-in callback
登录已失效，请重新登录	Your session has expired. Please sign in again.
登录时启动	Launch at Login
登录时运行	Runs at login
登录项设置	Login Items
百度	Baidu
监控	Monitor
目标转速	Target speed
直连	Direct
相当于“磁盘工具”里的急救，但只检查不修改：核对启动盘的目录结构、文件分配与快照元数据是否一致。	Like First Aid in Disk Utility, but read-only: checks that the startup disk's directory structure, allocation and snapshot metadata are consistent.
省份	Province
确认清理	Clean
确认通知能正常显示	Check that notifications appear
磁盘	Disk
磁盘已用 {}	Disk {} used
磁盘报告了严重警告，建议尽快备份	The disk reported a critical warning; back up soon
磁盘清理	Disk Cleanup
磁盘空间不足	Low Disk Space
磁盘空间偏紧	Disk space is tight
社交	Social
移到废纸篓	Move to Trash
移到废纸篓？	Move to the Trash?
移动网络	Mobile
移动网络 IP	Mobile IP
移动运营商	Mobile carrier
空	empty
空格	Space
空闲	Idle
空间占用	Space usage
窗口	Window
窗口状态	Saved State
立即切换；显示器、应用名称等由系统提供的文字在下次启动时切换	Applies right away; names supplied by macOS, such as displays and apps, switch at next launch
立即同步	Sync now
竖向电量条表示当前占用比例	A vertical meter shows current usage
等待批准	Waiting for Approval
等待选择	Waiting for your choice
签名团队	Signing team
签名方：{}	Signed by: {}
签名校验未通过：{}	Signature check failed: {}
粘贴	Paste
系统	System
系统代理	System Proxy
系统或其他用户的进程，XStats 不提供结束	A system or other user's process; XStats can't end it
系统服务	System Services
系统正在把内存写到磁盘，可能会变慢。可以关掉占用大的应用。	The system is swapping memory to disk and may slow down. Quit apps that use a lot of memory.
系统版号	Build
系统电池设置…	System Battery Settings…
系统级资源库（第三方驱动、辅助工具或后台服务）	System Library (third-party drivers, helpers or background services)
系统维护	Maintenance
系统自动	Automatic
系统自带的应用不能卸载	Built-in apps can't be uninstalled
系统调节	System
累计写入	Data written
累计读取	Data read
繁忙	Busy
纯净度 {} 分	Cleanliness score {}
纯净度看信誉、来路、邻居与网络类型四项；机房 IP 常见信誉高、来路和类型偏低。数据来自 cleanip.io	Cleanliness weighs reputation, origin, neighbors and network type; data-center IPs often score high on reputation but low on origin and type. Data from cleanip.io
线程	Threads
线程 {}	Threads {}
线程数（只能读取自己的进程）	Thread count (your processes only)
经 Cloudflare {} 边缘节点	Via the Cloudflare {} edge
经 {}	Via {}
经 {} 直接连接	Direct via {}
经代理	Proxied
结束 {} 失败：{}	Failed to end {}: {}
结束“{}”？	End “{}”?
结束它会注销当前用户，已禁止	Ending it would log you out, so it's blocked
结束进程…	End Process…
统一内存（CPU 与 GPU 共享）	Unified memory (shared by CPU and GPU)
统计家目录里每个文件夹占多少空间，并找出最大的文件；只读取大小，不改动任何文件。文件多时需要几十秒。	Measures how much space each folder in your home folder takes and finds the largest files. It only reads sizes and changes nothing; with many files it can take a minute.
继续运行	Keep running
绿色正常、橙色偏高（60% 以上）、红色很高（85% 以上）	Green is normal, orange is high (above 60%), red is very high (above 85%)
缓存	Caches
缓存与日志直接删除，下载内容移到废纸篓。	Caches and logs are deleted; downloads go to the Trash.
缓存也先移到废纸篓	Move caches to Trash too
编辑	Edit
网站	Site
网站分流	Site Routing
网站没有接入 Cloudflare，读不到出口，按国内 / 国际规则归到对应出口	This site isn't behind Cloudflare, so its exit can't be read. It's grouped by the China / international rule.
网络	Network
网络不通	No Connection
网络名称	Network name
网络已恢复	Network Restored
网络断开	Network Down
网络测速	Network Speed Test
网络环境变了，下面是之前的结果，正在重新检测。	The network changed. These are the previous results; checking again.
网络类型	Network type
网络详情打开时每秒 ping 一次，通了是绿格、不通是红格，显示最近 60 次	Pings once a second while network details are open: green when reachable, red when not, showing the last 60
网络运营方	Network operator
网络连接中断超过 20 秒，恢复后再提示一次	Network has been down for over 20 seconds; notifies again when it's back
网络连接已中断超过 20 秒。可以打开网络详情查看接口与路由器状态。	The network has been down for over 20 seconds. Open network details to check the interface and router.
网络连接已经恢复。	The network connection is back.
网络：{}	Network: {}
网页数据	Web Data
网页缓存与脚本缓存，不涉及 Cookie、历史记录和密码	Web and script caches; cookies, history and passwords are untouched
置信度	Confidence
联动	Wired
能效核	Efficiency
腾讯 DNSPod	Tencent
腾讯（119.29.29.29）	Tencent (119.29.29.29)
自 {} 起	Since {}
自动	Auto
自动代理配置	Auto proxy config
自动检查更新	Check Automatically
自动（由路由器分配）	Automatic (from router)
自定义	Custom
自定义模式下 CPU 达到 {}°C 会自动交还系统控制；退出应用时风扇恢复自动。	In Custom mode, fans return to system control when the CPU reaches {}°C, and to automatic when you quit.
自定义转速时，CPU 达到该温度自动恢复系统控制	With a custom speed, fans return to system control at this CPU temperature
自己的进程为实际占用内存，系统进程为常驻内存	Footprint for your processes, resident memory for system processes
致谢	Acknowledgements
良好	Good
节点	Edge
芯片	Chip
菜单栏	Menu Bar
菜单栏图标	Menu Bar Icons
菜单栏布局	Menu Bar Layout
菜单栏里的图标可以调整顺序：按住 ⌘ 键拖动任意一个，松开后位置会一直保留。新开启的项目由系统安排位置，可能离其他图标较远，拖一下就能挪到一起。	You can reorder the icons in the menu bar: hold ⌘ and drag any of them, and the position sticks. macOS picks where a newly enabled item first appears, sometimes away from the others; just drag it over.
菜单栏里还没有开启任何项目。	No items are turned on in the menu bar yet.
菜单栏项目	Menu Bar Items
菜单栏风格	Menu bar style
蓝牙设备	Bluetooth Devices
蓝牙设备电量 {}%	Bluetooth device battery {}%
蓝牙设备电量低	Bluetooth Battery Low
蓝牙设备电量低时提示	Low Bluetooth battery hint
解压失败：{}	Unzip failed: {}
计算中	Calculating
记录历史数据	Record History
设置	Settings
设置 · {}	Settings · {}
设置…	Settings…
设置改动后 2 秒内上传；启动、唤醒与每 15 分钟检查一次云端	Changes upload within 2 seconds; the cloud is checked at launch, on wake and every 15 minutes
设置风扇目标转速，或恢复系统自动控制	Set fan target speeds, or return them to automatic
评分由 cleanip.io 提供，点击查看完整报告	Score by cleanip.io. Click to open the full report
该项目在菜单栏里的实时效果	Live preview of this item in the menu bar
详情关闭时，菜单栏显示网络项期间每 {} 秒探测一次，打开详情就能看到最近的连接情况；关闭后只在打开详情时探测，更省电	While details are closed and the network item is in the menu bar, probes every {} seconds so recent results are ready when you open details. Turn off to probe only while details are open and save power.
语言	Language
请从菜单退出 XStats	Quit XStats from its menu
请先在“系统设置 → Apple 智能与 Siri”中开启 Apple 智能。	Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri first.
请在“系统设置 › 通用 › 登录项”中允许 XStats 的后台项目。	Allow XStats in System Settings › General › Login Items.
请填写一个域名，例如 example.com	Enter a domain, for example example.com
请打开系统自带的“磁盘工具”，选择启动盘运行“急救”进行修复	Open the built-in Disk Utility, select the startup disk and run First Aid to repair it
读 {} · 写 {}	Read {} · Write {}
读写最多的应用	Top Disk Activity
读写速度	Read & Write
读到了这次连接的出口	The exit of this connection was read directly
读取	Read
读取中	Loading
调节风扇需要安装辅助工具，仅需管理员授权一次。	Fan control needs the helper, which requires one-time admin approval.
调速模式	Fan Mode
负载在上升	Load rising
负载在下降	Load falling
负载平稳	Load steady
账号	Account
账号与云端设置会立即删除，无法恢复。	The account and cloud settings are deleted immediately and cannot be recovered.
账号与同步	Account & Sync
走势图显示最近多长时间	How far back the trend chart shows
走势时长	Trend duration
超时	Timed out
超级核	Super
超过 1 天未更新的 .crdownload / .part / .download	.crdownload / .part / .download files untouched for over a day
跟随整体	Follow global
跟随整体（{}）	Follow overall ({})
跟随系统	System
路径不可读	Path not readable
路径包含 ..	Path contains ..
路径包含控制字符	Path contains control characters
路由器	Router
路由器（网关）	Router (gateway)
跳过 {} 项	{} skipped
跳过此版本	Skip This Version
转速 {}	Speed {}
转速最高的风扇	Fastest fan
软件更新	Software Update
轻量的 macOS 菜单栏系统监控：CPU、GPU、内存、网络、温度、风扇、防休眠与清理。	A lightweight macOS menu bar monitor: CPU, GPU, memory, network, temperature, fans, keep awake and cleanup.
较弱	Weak
辅助工具	Helper
辅助工具未启用	Helper is not enabled
辅助工具版本比应用旧，部分功能可能无法使用，请重新安装一次（需要管理员授权）。	The helper is older than the app and some features may not work. Reinstall it (admin approval required).
过热温度	Overheat Threshold
运行中 · PID {}	Running · PID {}
还可用	Available
还有 {} 个	{} more
还没有足够的记录。菜单栏显示电池或打开这个页面时，每分钟记录一次电量	Not enough records yet. The level is recorded every minute while Battery is in the menu bar or this page is open
还能用 {}	{} left
这一类没有检测结果	No results in this category
这个小时的免费额度用完了，{} 分钟后可以再试	The free quota for this hour is used up; try again in {} minutes
这个小时的免费额度用完了，过一会儿再试	The free quota for this hour is used up; try again later
这个快捷键已被其他应用或系统占用，请换一个	This shortcut is used by another app or the system. Choose another.
这台 Mac 不提供功耗读数	This Mac doesn't report power
Apple 智能本机模型当前不可用。	The on-device Apple Intelligence model is currently unavailable.
这台 Mac 没有电池	This Mac has no battery
这台 Mac 没有电池：菜单栏显示电量最低的蓝牙设备，弹窗只列蓝牙设备	This Mac has no battery: the menu bar shows the Bluetooth device with the lowest battery, and the popover lists Bluetooth devices only
这段时间没有记录	No records for this period
这段时间还没有记录。XStats 运行时每分钟记录一次，睡眠与锁屏期间不记录。	No records for this period yet. XStats records once a minute while running, except during sleep and lock.
这里列出资源库里的 LaunchAgents 与 LaunchDaemons。停用只写入系统的停用记录并卸载，不删除文件，随时可以重新启用；登录时打开的应用与后台权限在系统设置里管理。	Lists LaunchAgents and LaunchDaemons from your Library folders. Turning one off records it as disabled and unloads it without deleting files, so you can turn it back on anytime. Login apps and background permissions are managed in System Settings.
这里显示已配对蓝牙配件，以及最近 30 分钟内读到的电量	Shows paired Bluetooth accessories and battery readings seen in the last 30 minutes
进程	Processes
进程 {} · 线程 {}	Processes {} · Threads {}
进程名：{}	Process name: {}
进程启动以来累计占用的 CPU 时间	Total CPU time since the process started
进程页刷新频率调整为每 2 秒	Processes page now refreshes every 2 seconds
连不上	Unreachable
连接探测	Connectivity
连接探测历史	Probe History
连接探测只在需要时运行，更省电	Connectivity probing runs only when needed, saving power
退出	Quit
退出 XStats	Quit XStats
退出应用	Quit App
退出应用…	Quit App…
退出登录	Sign out
适中	Moderate
选择显示项目	Choose Items
通用	General
可选功能	Optional Features
通电时间	Power-on hours
通电次数	Power cycles
通知	Notifications
通知可以正常显示。发生你打开的状况时，会像这样提醒你。	Notifications are working. You'll be alerted like this when something you turned on happens.
通过 {} 登录	Signed in with {}
速度与省电介于两者之间	In between on speed and efficiency
部分网站直连、部分经代理，每个网站走哪个出口见下方。	Some sites connect directly and some go through a proxy. See below for the exit each site uses.
部分项目需要“完全磁盘访问权限”才能扫描（Safari 缓存、废纸篓）。	Some items need Full Disk Access to scan (Safari caches, Trash).
配置方式	Configuration
释放内存	Free Memory
重做	Redo
重新分析	Analyze again
重新安装	Reinstall
重新扫描	Rescan
重新查询公网 IP	Look Up Public IP Again
重新检测	Check Again
重新生成	Regenerate
重新读取蓝牙设备电量	Read Bluetooth device batteries again
重置上传与下载统计：从现在起重新累计。重启后自动回到开机后的累计；右键可改回	Reset the upload and download totals and count from now on. After a restart they go back to since-boot totals; right-click to switch back
重置后上传	Uploaded since reset
重置后下载	Downloaded since reset
键盘、鼠标、耳机等低于 20% 时，在菜单栏的电池项目旁显示该设备的图标与电量；需要开启电池项目	When a keyboard, mouse, headphones or similar drops below 20%, show its icon and level next to the Battery item in the menu bar; requires the Battery item
闲	Idle
防休眠	Keep Awake
防休眠已开启	Keep Awake is on
阿里云	Alibaba Cloud
阿里云（223.5.5.5）	Alibaba Cloud (223.5.5.5)
降温	Cooling
隐私	Privacy
隐私政策	Privacy policy
法律与隐私	Legal & Privacy
服务条款	Terms of Service
了解 XStats 的使用条件与责任边界	Read XStats's terms of use and responsibilities
了解本机数据、联网功能与信息处理方式	Learn how local data and online features are handled
无法读取法律文件	Unable to load legal document
关闭文档	Close
隐藏 XStats	Hide XStats
隐藏序列号	Hide Serial Number
需要 macOS 26 及以上，并在系统设置中开启 Apple 智能。	Requires macOS 26 or later with Apple Intelligence turned on in System Settings.
需要完全磁盘访问权限	Needs Full Disk Access
需要注意	Needs attention
需要管理员授权	Needs admin approval
需要管理员权限。已完成的 Time Machine 备份不受影响，只是本机上这些快照对应的时间点无法再从本地恢复。	Requires administrator privileges. Completed Time Machine backups are unaffected; you just won't be able to restore these points in time from this Mac.
非常干净	Very clean
风扇	Fans
风扇 {}	Fan {}
风扇安全温度	Fan Safety Temperature
风扇模式	Fan mode
风扇设置	Fan Settings
风扇转速	Fan Speed
风格	Style
风险标记	Risk flags
风险评分	Risk score
饼图	Pie
饼图表示当前占用比例	A pie shows current usage
尚未启用	Not enabled
正在刷新	Refreshing
立即刷新	Refresh Now
默认关闭	Off by default
首次发送时系统会询问是否允许通知	The system asks for permission the first time
高占用进程	Top Processes
高负载	Heavy load
高负载时着色	Color High Load
高风险	High risk
默认只在菜单栏运行；打开后，主窗口开着时图标出现在程序坞与 ⌘Tab 中	XStats lives in the menu bar by default. Turn this on to show its icon in the Dock and ⌘Tab while the main window is open
（{}）	 ({})
，	, 
，{} 项未能移动	, {} couldn't be moved
，充电中	, charging
，已从程序坞移除	, removed from the Dock
：{}	: {}
"""#
}
