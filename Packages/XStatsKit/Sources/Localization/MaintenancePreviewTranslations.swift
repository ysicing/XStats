// SPDX-License-Identifier: AGPL-3.0-or-later

extension Translations {
  static let maintenancePreviewEnglish = #"""
    引擎	Engine
    使用 Mole 优化	Optimize with Mole
    使用 Mole 优化？	Optimize with Mole?
    执行 mo optimize	Run mo optimize
    将执行 mo optimize，由 Mole 决定并应用优化。预览不是固定执行清单，Mole 可能请求管理员授权。停止不能撤销已完成的更改。	This runs mo optimize. Mole determines and applies the optimizations. The preview is not a fixed execution plan, and Mole may request administrator authorization. Stopping cannot undo completed changes.
    扫描执行 mo optimize --dry-run；优化执行 mo optimize，由 Mole 决定优化内容。	Scanning runs mo optimize --dry-run; optimization runs mo optimize. Mole determines the tasks.
    点击重新扫描，查看 Mole 的优化预览。	Click Scan Again to preview optimization with Mole.
    已停止，已完成的优化不会撤销	Stopped; completed optimizations will not be undone
    安装 Mole 后，可在终端预览更多清理项目，不会删除文件。	After installing Mole, preview more cleanup items in Terminal without deleting files.
    安装 Mole 后，可在终端预览更多优化项目，不会执行优化。	After installing Mole, preview more optimization tasks in Terminal without applying changes.
    复制命令	Copy Command
    清理引擎	Cleanup Engine
    重新检测 Mole	Detect Mole Again
    使用 Mole 清理	Clean with Mole
    使用 Mole 清理？	Clean with Mole?
    执行 mo clean	Run mo clean
    将执行 mo clean，按 Mole 自己的规则重新扫描并永久删除文件。XStats 的勾选、保留项目和移到废纸篓设置不适用于 Mole；扫描结果不是固定清单。没有可用管理员授权时，Mole 会跳过系统级清理。	This runs mo clean, which rescans and permanently deletes files using Mole’s own rules. XStats selections, exclusions, and Move to Trash settings do not apply; the preview is not a fixed plan. Mole skips system cleanup if administrator authorization is unavailable.
    扫描执行 mo clean --dry-run；清理执行 mo clean，由 Mole 决定清理范围。	Scanning runs mo clean --dry-run; cleanup runs mo clean. Mole determines the scope.
    正在停止…	Stopping…
    日志较长，仅保留最近 128 KiB。	The log is long. Only the latest 128 KiB is retained.
    执行日志	Execution Log
    跟随输出	Follow Output
    点击重新扫描，查看 Mole 的清理预览。	Click Scan Again to preview cleanup with Mole.
    命令已退出（退出码 {}）	Command exited (exit code {})
    命令未能启动	Could Not Start Command
    未安装 Homebrew	Homebrew Is Not Installed
    Homebrew 依赖预览	Homebrew Dependency Preview
    预览内容过长，仅显示部分结果。	The preview is too long. Only part of the result is shown.
    由 Homebrew 列出不再需要的依赖，仅供审阅。	Homebrew lists dependencies that are no longer needed, for review only.
    无法完成检查，请稍后重试。	Unable to complete the check. Try again later.
    已达到扫描条目上限	Scan Entry Limit Reached
    已达到扫描时间上限	Scan Time Limit Reached
    扫描已取消	Scan Cancelled
    系统检查	System Check
    内存压力	Memory Pressure
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
    工具预览超时，暂不可清理	Tool preview timed out; cleanup unavailable
    {} 个文件或目录无法读取	{} files or folders could not be read
    占用 {}	Uses {}
    不支持清理 · {}	Cleanup unavailable · {}
    曾安装	Previously installed
    缓存残留	Remaining cache
    未发现内容（{}）	No content found ({})
    工具缓存容量单独列出，不计入文件合计。	Tool cache estimates are listed separately and excluded from the file total.
    所选工具缓存将由对应工具永久清理，此操作无法撤销。	The selected tool caches will be permanently cleaned by their tools. This cannot be undone.
    默认路由	Default Routes
    占用 {} 字节	Usage: {} bytes
    配置审阅	Configuration Review
    检查范围	Check Scope
    本次检查会向当前 DNS 查询 apple.com。	This check will query the current DNS for apple.com.
    仅查看占用，不提供清理。	Shows usage only; cleanup is unavailable.
    清理优化	Clean & Optimize
    优化	Optimize
    按需清理缓存与项目产物，预览依赖并执行维护。	Clean caches and build artifacts on demand, preview dependencies, and run maintenance.
    在清理优化页查看已安装的 AI 工具及关联数据目录，并管理 worktree。	View installed AI tools and their associated data folders, and manage worktrees from Clean & Optimize.
    遇到域名解析异常时手动刷新，不修改 DNS 服务器或代理设置。	Refresh manually when domain name resolution fails; DNS servers and proxy settings stay unchanged.
    手动释放可回收缓存；再次打开应用时可能需要重新加载，不建议频繁执行。	Manually release reclaimable caches. Apps may need to reload data afterward; avoid frequent use.
    没有可移除的依赖	No removable dependencies
    重置缩略图	Reset Thumbnails
    预览缩略图空白或未更新时重置，文件内容不受影响。	Reset blank or outdated preview thumbnails without changing your files.
    缩略图缓存已重置，缩略图将在浏览文件时重新生成。	Thumbnail cache reset. Thumbnails will be regenerated as you browse files.
    修复 Spotlight 搜索	Repair Spotlight Search
    查看修复步骤	View Repair Steps
    搜索找不到文件时，在系统设置中重建指定位置的索引。	If search cannot find files, rebuild the index for a chosen location in System Settings.
    在系统设置中打开 Spotlight 的“搜索隐私”或“Spotlight 隐私”。	In System Settings, open Spotlight’s Search Privacy or Spotlight Privacy.
    将需要重建索引的文件夹或磁盘加入列表，等待几秒，再从列表中移除。	Add the folder or disk you want to reindex, wait a few seconds, then remove it from the list.
    macOS 随后会重新建立索引，完成前搜索结果可能不完整。	macOS will then rebuild the index. Search results may be incomplete until it finishes.
    无法打开系统设置，请手动前往 Spotlight 设置。	Unable to open System Settings. Open Spotlight settings manually.
    查看 Apple 修复步骤	View Apple’s Repair Steps
    打开 Spotlight 设置	Open Spotlight Settings
    """#
}
