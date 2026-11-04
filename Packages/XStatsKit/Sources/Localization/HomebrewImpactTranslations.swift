// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later

extension Translations {
  static let homebrewImpactEnglish = #"""
    Homebrew（缓存）	Homebrew (cached)
    来源识别依据	Source Evidence
    来自本次读取的 Homebrew 安装清单。	Found in the Homebrew inventory read during this session.
    应用路径与 Cask 的安装产物匹配。	The app path matches an installed Cask artifact.
    来自上次保存的 Homebrew 来源记录，尚未通过本次清单核实。	Based on a saved Homebrew source record; not yet verified against this session's inventory.
    应用包中存在 App Store 收据；未验证收据签名。	The app bundle contains an App Store receipt; its signature has not been verified.
    未找到可确认来源的记录，不能仅凭名称或目录判断。	No record confirms the source. A name or directory alone is not sufficient.
    查看来源依据	View Source Evidence
    软件包状态已变化，请刷新后重试	The package state has changed. Refresh and try again.
    无法生成操作预览，请刷新清单后重试	Couldn't prepare the operation preview. Refresh the inventory and try again.
    正在读取操作影响…	Reading operation impact…
    请重新读取操作预览	Reload the operation preview
    操作影响	Operation Impact
    查看影响预览	View Impact Preview
    未发现依赖此项目的已安装软件包。	No installed packages were found to depend on this item.
    以下已安装软件包依赖此项目，暂不能卸载。	These installed packages depend on this item. Uninstall is currently blocked.
    不自动移除依赖，不执行额外的用户数据清理。	Dependencies are not automatically removed. No additional user data cleanup is performed.
    预览基于当前清单；实际影响由执行时的 Homebrew 状态决定。	This preview uses the current inventory. Actual impact depends on Homebrew's state when the command runs.
    执行命令	Command
    """#
}
