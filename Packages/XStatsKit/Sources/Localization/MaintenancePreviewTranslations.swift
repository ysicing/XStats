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
    仅预览占用 {}	Preview-only usage: {}
    仅预览	Preview Only
    工具缓存容量单独列出，不计入文件合计。	Tool cache estimates are listed separately and excluded from the file total.
    所选工具缓存将由对应工具永久清理，此操作无法撤销。	The selected tool caches will be permanently cleaned by their tools. This cannot be undone.
    """#
}
