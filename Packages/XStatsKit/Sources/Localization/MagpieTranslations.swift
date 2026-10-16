// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

extension Translations {
  static let magpieEnglish = #"""
    到期：{}	Expires: {}
    显示 Token 用量	Show token usage
    从 Magpie 读取 Token 与费用；关闭后只读取额度。	Reads tokens and costs from Magpie; when off, only quotas are read.
    检测到已安装 Magpie，自动使用其本地数据。	Magpie is installed; its local data is used automatically.
    费用由 Magpie 估算，以美元显示；不代表订阅账单。	Costs are estimated by Magpie in USD; they are not a subscription bill.
    模型用量	Model usage
    Magpie 未能读取此账户的额度。	Magpie could not read this account’s quota.
    不限额	Unlimited
    缓存读取	Cache reads
    缓存写入	Cache writes
    请求数	Requests
    部分请求缺少价格，费用估算不完整。	Some requests have no pricing; the cost estimate is incomplete.
    Magpie 的 Token 总量不包含缓存读写；仅统计经过 Magpie 的请求。	Magpie’s token total excludes cache reads and writes; only requests routed through Magpie are counted.
    无法连接 Magpie，请确认它已运行。	Cannot connect to Magpie. Make sure it is running.
    Magpie 数据无法读取，请检查版本或数据大小。	Cannot read Magpie data. Check its version or data size.
    显示上次成功读取的数据。	Showing the last successfully read data.
    按周统计	By week
    额度按账户分别显示；菜单栏优先显示最近使用的账户。	Quotas are shown per account; the menu bar prefers the most recently used account.
    查看 AI 服务的 Token 用量与账户额度。	View token usage and account quotas for AI services.
    查看账户剩余额度与重置时间	View remaining account quotas and reset times
    查看今天的 Token 用量	View today’s token usage
    """#
}
