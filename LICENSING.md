# 许可说明

XStats 自行编写的新增代码、测试及对上游代码的修改，自本次许可变更起采用 **AGPL-3.0-or-later**（GNU Affero General Public License 第 3 版或更新版本），全文见 [LICENSE](LICENSE)。分发包含这些内容的组合版本时，须遵守该许可并保留适用的上游及第三方声明；源码提供等义务以许可全文为准。

## 上游与第三方

- OpenStats 原有代码保留 MIT 许可及 `Copyright (c) 2026 GiantAccel, LLC`，全文见 [LICENSES/OpenStats-MIT.txt](LICENSES/OpenStats-MIT.txt)。
- 其他第三方代码、图标及素材保留各自的许可、版权和商标声明，见 [ThirdPartyNotices.md](ThirdPartyNotices.md)。DB-IP Lite 数据采用 CC BY 4.0，Natural Earth 数据为 Public Domain，相关 `ATTRIBUTION.md` 随安装包分发。
- 本次变更不撤销历史版本已有的 MIT 授权，也不改变上游原创代码的许可及使用权利。

## 贡献与文件头

- 新增源码和测试标注 `SPDX-License-Identifier: AGPL-3.0-or-later`。本项目当前版权署名为 `Copyright (C) 2026 ysicing`；其他贡献者按实际归属署名，年份按首次发布及后续实质修改记录，不机械改年。文件头不写应用版本号或虚构邮箱。
- 修改上游文件时保留原声明，区分修改部分的授权。含 MIT 上游代码及 AGPL 修改的文件追加 `XStats modifications Copyright (C) 2026 ysicing`，使用 `AGPL-3.0-or-later AND MIT` 并说明各部分范围。
- 引入第三方内容时记录来源、保留声明并核对许可兼容性；不得为本项目新增代码添加冲突的 MIT 声明。

## 无文件头的许可记录

以下原创内容采用 AGPL-3.0-or-later；因格式不支持注释或由工具生成，在此统一声明：

- 更新摘要译文：`docs/ReleaseNotes.json`、`docs/NetworkComponentReleaseNotes.json`。
- 格式化配置：`.swift-format`。
- XcodeGen 配置：`Apps/XStats/App/XStats.entitlements`、`Apps/NetworkMonitor/Extension/Info.plist`、`Apps/NetworkMonitor/Extension/XStatsNetworkExtension.entitlements`、`Apps/Capture/App/Info.plist`、`Apps/Capture/App/XStatsCapture.entitlements`。
- Capture 图标及资源配置：`Apps/Capture/App/Assets.xcassets`，由 `scripts/render_capture_icon.swift` 原创生成，未使用第三方字体或图形素材。

网络连接模块和 Capture 为独立实现；FreeSnitch、Vorssaint 分别仅用于架构和功能流程调研，未复制其代码或素材。
