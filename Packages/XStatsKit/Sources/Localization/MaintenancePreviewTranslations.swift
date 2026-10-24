// SPDX-License-Identifier: AGPL-3.0-or-later

extension Translations {
  static let maintenancePreviewEnglish = #"""
    启动代理目标	Launch Agent Targets
    仅检查当前用户启动代理的绝对程序路径；不删除或停用。	Checks only absolute program paths in your launch agents; does not delete or disable them.
    遗留偏好覆盖	Legacy Preference Overrides
    检查用户偏好文件中的 App Nap 和磁盘映像验证覆盖；不修改设置。	Checks App Nap and disk image verification overrides in user preference files; does not change settings.
    用户目录权限	User Folder Permissions
    仅检查主目录、Library 和 Preferences 的所有者与可写性。	Checks only ownership and write access for the home folder, Library and Preferences.
    未安装 Homebrew	Homebrew Is Not Installed
    Homebrew 依赖预览	Homebrew Dependency Preview
    预览内容过长，仅显示部分结果。	The preview is too long. Only part of the result is shown.
    由 Homebrew 列出不再需要的依赖，仅供审阅。	Homebrew lists dependencies that are no longer needed, for review only.
    无法完成检查，请稍后重试。	Unable to complete the check. Try again later.
    已达到扫描条目上限	Scan Entry Limit Reached
    已达到扫描时间上限	Scan Time Limit Reached
    扫描已取消	Scan Cancelled
    系统检查	System Check
    CPU 短时检查	Short CPU Check
    仅报告连续两个采样区间均占用至少 25% 单核 CPU 的进程；不代表长期故障。	Reports only processes using at least 25% of one CPU core in both consecutive sampling intervals; this does not indicate a long-term fault.
    内存压力	Memory Pressure
    累计交换空间占用不单独视为异常。	Accumulated swap usage alone is not considered abnormal.
    采样期间换出 {}	Swapped out during sampling: {}
    交换空间占用 {}	Swap used: {}
    DNS 维护	DNS Maintenance
    检测到代理或隧道环境；DNS 维护可能影响现有连接，请先排查代理设置。	A proxy or tunnel was detected. DNS maintenance may affect existing connections; check your proxy settings first.
    刷新 DNS 仅是可选维护；当前检查不执行刷新，也不据此判断网络故障。	Flushing DNS is optional maintenance. This check does not flush DNS or use it to diagnose network failures.
    开始检查	Start Check
    按需检查资源、配置和维护建议，仅预览，不执行修复。	Check resources, configuration and maintenance suggestions on demand. Preview only; no repairs are performed.
    部分完成	Partially Complete
    需关注	Needs Attention
    可选维护	Optional Maintenance
    不适用	Not Applicable
    未检查	Not Checked
    仅查看项目占用 {}	View-only items use {}
    仅查看	View Only
    仅查看 · {}	View only · {}
    未发现缓存	No cache found
    曾安装	Previously installed
    缓存残留	Remaining cache
    未发现内容（{}）	No content found ({})
    工具缓存容量单独列出，不计入文件合计。	Tool cache estimates are listed separately and excluded from the file total.
    所选工具缓存将由对应工具永久清理，此操作无法撤销。	The selected tool caches will be permanently cleaned by their tools. This cannot be undone.
    应用保存状态审阅	Saved Application State Review
    未找到当前用户的 Saved Application State 目录。	The current user's Saved Application State folder was not found.
    运行中的应用，未计量	Running app; size not measured
    只审阅超过 30 天的直接 savedState 目录，跳过运行应用；仅展示完整计量占用，不判断可安全丢弃，不提供清理。	Reviews only immediate savedState folders older than 30 days, skipping running apps. Shows only fully measured usage; does not determine whether states can be safely discarded or offer cleanup.
    已解析文件：{}	Files parsed: {}
    共享文件列表格式	Shared File List Format
    偏好文件格式	Preference File Format
    仅检查共享列表根目录的 sfl2、sfl3、sfl4 文件格式；跳过最近文档，不解档或解析书签。	Checks only the format of sfl2, sfl3 and sfl4 files at the shared list root. Skips recent documents; does not unarchive objects or resolve bookmarks.
    仅解析 Preferences 与 ByHost 顶层的非受保护 plist；不判断偏好内容是否正确。	Parses only unprotected plist files directly inside Preferences and ByHost; does not assess whether preference values are correct.
    Finder 外置卷元数据偏好	Finder Metadata Preferences for External Volumes
    只读用户保存的网络盘与 USB .DS_Store 偏好；默认值或关闭不表示故障，不代表卷上现有文件状态。	Reads the user's saved .DS_Store preferences for network and USB volumes. Default or disabled settings do not indicate a fault or describe existing files on those volumes.
    Spotlight 索引与有限查询	Spotlight Index and Scoped Query
    启动卷 Spotlight 索引已关闭；未发起搜索，也不建议重建。	Spotlight indexing is disabled on the startup volume. No search was run, and no rebuild is recommended.
    启动卷报告索引已启用	The startup volume reports indexing enabled
    有限查询超过 3 秒；单次结果不能判断索引故障	The scoped query took over 3 seconds; a single result cannot establish an index fault
    只查询声明的应用目录并返回计数；成功或零结果均不能证明索引完整，不执行重建。	Queries only the specified app folders and returns counts. Success or zero results cannot prove index completeness; no rebuild is performed.
    索引状态或有限查询证据不足；工具缺失、权限、超时和异常输出均不视为正常。	Insufficient evidence from index status or the scoped query. Missing tools, permission issues, timeouts and unexpected output are not treated as normal.
    已找到本地应用	Local app found
    有限范围内未确认归属，不能判定失效	Ownership unconfirmed within the limited scope; cannot determine invalidity
    Spotlight 搜索规则归属	Spotlight Search Rule Ownership
    保留 System 与 Apple 规则；仅核对应用目录两层内的 bundle 标识，未确认归属不等于孤儿规则。	Retains System and Apple rules. Checks bundle identifiers only within two levels of app folders; unconfirmed ownership does not mean an orphaned rule.
    周期维护记录	Periodic Maintenance Records
    当前系统未提供 periodic 工具；不根据系统版本推测维护状态。	The periodic tool is unavailable on this system; maintenance status is not inferred from the OS version.
    只读 daily、weekly、monthly 记录的修改时间；超过 7 天仅供审阅，记录新鲜也不能证明维护成功。	Reads only modification times of daily, weekly and monthly records. Records older than 7 days are for review only; recent records do not prove successful maintenance.
    目标未在本次范围内核对	Target not verified within this check's scope
    记录目标存在	Recorded target exists
    记录目标不存在，可能已移动	Recorded target is missing; it may have moved
    登录项目独立来源	Independent Login Item Source
    仅在已有自动化权限时只读 System Events 登录项目；不含现代后台项目，不以启动代理替代，不判断应用已卸载。	Reads System Events login items only when automation permission is already granted. Excludes modern background items, does not substitute launch agents, and does not infer that an app was uninstalled.
    登录项目来源未授权、未运行或读取失败；不弹出授权，不将未知状态视为空列表。	The login item source is unauthorized, not running or unreadable. No permission prompt is shown, and an unknown state is not treated as an empty list.
    默认路由	Default Routes
    分别读取 IPv4 与 IPv6 默认路由；缺失一种路由不代表网络故障。	Reads IPv4 and IPv6 default routes separately; the absence of one does not indicate a network failure.
    DNS 单次探测	One-Time DNS Probe
    仅测试当前 DNS 对 apple.com 的一次解析；代理、过滤或离线均可能影响结果。	Tests a single lookup of apple.com using the current DNS. Proxies, filtering or being offline may affect the result.
    已挂载磁盘映像	Mounted Disk Images
    展示映像来源与挂载位置；未判断是否闲置，不执行卸载。	Shows image sources and mount locations; does not assess inactivity or unmount anything.
    信息数据库	Messages Database
    Safari 历史数据库	Safari History Database
    Safari 常用网站数据库	Safari Top Sites Database
    下载隔离记录	Download Quarantine Records
    通知数据库	Notification Database
    使用记录数据库	Usage History Database
    系统缓存与更新	System Caches and Updates
    仅审阅系统管理目录占用，不判断过期或可回收；更新状态未知。	Reviews only usage in system-managed folders; does not determine expiry or reclaimability. Update status is unknown.
    Rosetta 数据	Rosetta Data
    仅审阅固定 Rosetta 缓存位置，不判断是否仍被系统使用。	Reviews only fixed Rosetta cache locations; does not determine whether the system still uses them.
    设备备份	Device Backups
    备份是用户数据，不是固件或缓存；请在设备管理或空间分析中审阅。	Backups are user data, not firmware or caches. Review them in device management or storage analysis.
    虚拟机与虚拟磁盘	Virtual Machines and Virtual Disks
    仅审阅固定虚拟机数据目录；使用与挂载状态未知，不判断闲置。请复用空间分析入口。	Reviews only fixed virtual machine data folders. Usage and mount status are unknown; inactivity is not assessed. Use the storage analysis view.
    AI 模型数据	AI Model Data
    模型数据与虚拟磁盘分开审阅，不判断闲置；其他位置请复用 AI 数据专项或空间分析入口。	Reviews model data separately from virtual disks without assessing inactivity. For other locations, use the AI data or storage analysis view.
    Finder 元数据与最近项目	Finder Metadata and Recent Items
    仅审阅主目录及桌面、文稿、下载目录顶层的 Finder 元数据和共享列表占用，不读取最近文档内容。	Reviews only Finder metadata and shared list usage at the top level of the home, Desktop, Documents and Downloads folders; does not read recent document contents.
    Time Machine 备份审阅	Time Machine Backup Review
    主库 {} 字节	Main database: {} bytes
    主库空闲页估算 {} 字节（不代表可回收空间）	Estimated free pages in main database: {} bytes (does not indicate reclaimable space)
    附属文件 {} 字节	Sidecar files: {} bytes
    隔离记录 {} 条	Quarantine records: {}
    只读估算，不执行数据库维护；不读取下载 URL。	Read-only estimate; does not perform database maintenance or read download URLs.
    仅有主库或部分证据；日志、并发变化或读取限制使当前数据库状态未知。	Only the main database or partial evidence is available. Journals, concurrent changes or read limits leave the current database state unknown.
    邮件索引数据库	Mail Index Database
    占用 {} 字节	Usage: {} bytes
    大小未知	Size Unknown
    设备固件	Device Firmware
    仅审阅 iTunes 固定目录中的 IPSW 固件，与设备备份分开；不判断是否仍有需要。	Reviews only IPSW firmware in fixed iTunes folders, separately from device backups; does not determine whether it is still needed.
    OrbStack 虚拟机数据	OrbStack Virtual Machine Data
    应用数据归属审阅	App Data Ownership Review
    尚未加载应用清单，未检查应用数据归属；请复用选定应用的残留审阅。	The app inventory has not been loaded, so app data ownership was not checked. Use the leftover review for a selected app.
    仅列有明确归属的待审阅项目：未在已加载应用清单中匹配，不代表卸载或孤儿；不是垃圾，不提供清理授权。	Lists only items with explicit ownership for review. No match in the loaded app inventory does not mean an uninstalled app or orphaned data. These are not junk, and no cleanup authorization is provided.
    仅检查旧式本地备份标记，不能证明备份失败或已停止；请复用快照入口或 Time Machine 管理。	Checks only legacy local backup markers, which cannot prove that backups failed or stopped. Use the snapshots view or Time Machine management.
    权限、路径、格式或扫描预算不足，结果未知；未执行任何修改。	Permissions, paths, formats or scan limits prevented a result; the state is unknown. No changes were made.
    资源与维护	Resources and Maintenance
    配置审阅	Configuration Review
    网络检查	Network Check
    存储审阅	Storage Review
    检查范围	Check Scope
    本次检查会向当前 DNS 查询 apple.com。	This check will query the current DNS for apple.com.
    仅查看占用，不提供清理。	Shows usage only; cleanup is unavailable.
    优化清理	Optimize & Clean
    优化	Optimize
    按需清理缓存与项目产物，预览依赖并执行维护。	Clean caches and build artifacts on demand, preview dependencies, and run maintenance.
    在优化清理页查看已安装的 AI 工具及关联数据目录，并管理 worktree。	View installed AI tools and their associated data folders, and manage worktrees from Optimize & Clean.
    遇到域名解析异常时手动刷新，不修改 DNS 服务器或代理设置。	Refresh manually when domain name resolution fails; DNS servers and proxy settings stay unchanged.
    手动释放可回收缓存；再次打开应用时可能需要重新加载，不建议频繁执行。	Manually release reclaimable caches. Apps may need to reload data afterward; avoid frequent use.
    没有可移除的依赖	No removable dependencies
    """#
}
