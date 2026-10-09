# 第三方声明

XStats 新增代码与修改采用 AGPL-3.0-or-later，范围见 [LICENSING.md](LICENSING.md)。以下原有第三方许可与版权声明继续保留。

## 使用统计设计参考

本机 Codex 模型统计参考 [CC Switch](https://github.com/farion1231/cc-switch)（MIT，Copyright (c) 2025 Jason Young）
的时间/模型筛选、总览、趋势与模型排行，以及 OpenUsage 的本地会话日志解析边界。
本轮 SwiftUI 界面与本机扫描器为 XStats 独立实现，未引入 CC Switch 的 Rust/React 源码或依赖。

## 项目产物清理范围参考

项目产物的候选目录、默认搜索位置及安全检查参考 [tw93/Mole 的 `mo purge`](https://github.com/tw93/Mole)（GPL-3.0）。
XStats 使用独立编写的 Swift 扫描与废纸篓流程，未引入 Mole 的 Shell 源码或运行时依赖。

## 健康提醒设计参考

专注与健康参考 [MeowOut](https://github.com/huangy7/MeowOut/tree/1085b5a3e6b902610701bf1d1f4a17b51084edd6)
（MIT，Copyright (c) 2026 huangy）的独立饮水提醒、手动确认、呼吸节奏和今日/七日回顾交互。
XStats 的 Swift 状态机、提醒合并、SQLite 记录与原生界面为独立实现，未引入上游源码、像素宠物素材或运行时依赖。
默认舒缓呼吸不屏息，不作诊断、饮水量计算或医疗效果承诺。

## 粉红噪音滤波参考

番茄钟的粉红噪音使用 [Paul Kellett 的滤波系数](https://www.musicdsp.org/en/latest/Filters/76-pink-noise-filter.html)
近似 1/f 频谱；Swift 音频生成器由 XStats 独立编写，未引入音频素材或第三方音频依赖。

## Apple 智能诊断参考

Apple 智能功能对应的偏好键、模型集合和资产清单字段参考
[RemoveMacAI](https://github.com/omlahore/RemoveMacAI/tree/b20c58aec41f5555e2978c9184e10ee0589354cb)（MIT）及其注明的
[pared](https://github.com/4evy/pared)（MIT）研究。XStats 的 Swift 状态判定、只读资产查询、限时子进程与浮层为独立实现，
未引入上游源码或运行时依赖，不执行其模型重置、删除、下载阻断或配置描述文件操作。

## gentpan/OpenStats

XStats 基于 [gentpan/OpenStats](https://github.com/gentpan/OpenStats) 开发，感谢原项目的开源贡献。
原项目使用 MIT License，Copyright (c) 2026 GiantAccel, LLC；完整许可证与版权声明保留在 [LICENSES/OpenStats-MIT.txt](LICENSES/OpenStats-MIT.txt) 中。

本次网络测速线路选择、传输与延迟计算移植自上游提交
[b98c670](https://github.com/gentpan/OpenStats/commit/b98c670c160512385284fc953f6727ddd747f4d9)，
按 XStats 的模块与标识适配。

## 运营商标志

`Packages/XStatsKit/Sources/XStatsUI/Resources/Logos/carrier-*.svg` 来自上述 OpenStats 提交，
分别是中国电信、中国联通、中国移动的标志，仅用于标明网络测速中的运营商。三家的名称和标志均为各自公司的商标。

## flag-icons

`Assets/flags-svg/` 中的国旗 SVG（应用内为 `scripts/render_flags.sh` 渲染的 PNG）来自
[lipis/flag-icons](https://github.com/lipis/flag-icons)，MIT License，Copyright (c) 2013 Panayiotis Lipiridis。

## XStats API Go 依赖

`server/api` 使用以下与 AGPL-3.0-or-later 兼容的依赖：

- [gofiber/fiber](https://github.com/gofiber/fiber) v3.5.0，MIT License，Copyright (c) 2019-present Fenny and Contributors
- [libtnb/sqlite](https://github.com/libtnb/sqlite) v1.2.2，MIT License，Copyright (c) TreeNewBee、glebarez、Jinzhu
- [go-gorm/gorm](https://github.com/go-gorm/gorm) v1.31.2，MIT License，Copyright (c) 2013-present Jinzhu
- [modernc.org/sqlite](https://gitlab.com/cznic/sqlite) v1.56.0（由 libtnb/sqlite 引入），BSD-3-Clause，Copyright (c) 2017 The Sqlite Authors

随二进制分发时需要保留的完整文本见 [LICENSES/XStats-API-Dependencies.txt](LICENSES/XStats-API-Dependencies.txt)。

## 品牌标志资源

GitHub 标志用于主窗口侧边栏的项目入口。账号登录入口已移除，其余登录品牌标志作为旧资源保留。

`Packages/XStatsKit/Sources/XStatsUI/Resources/Logos/github.svg` 来自
[primer/octicons](https://github.com/primer/octicons) 的 mark-github，MIT License，Copyright (c) GitHub Inc.；
`google.svg` 是 Google 的品牌标志，仅按其品牌规范用于“使用 Google 登录”按钮。Apple 标志使用系统 SF Symbols 的 `apple.logo`。
GitHub、Google 与 Apple 的名称和标志均为各自公司的商标。

## 开发工具品牌图标

`Packages/XStatsKit/Sources/XStatsUI/Resources/Logos/tool-{npm,yarn,pnpm,bun,go,rust,uv}.svg` 来自
[Simple Icons](https://github.com/simple-icons/simple-icons/tree/b86d5c9a0bdd4f3f5c30898a63654dd32f39fd76)，
使用 CC0-1.0。npm、Yarn、pnpm、Bun、Go、Rust、uv 的名称与标志均为各自权利人的商标，XStats 仅用这些图标标识对应工具的缓存。

## exelban/stats

XStats 的以下部分移植自 [exelban/stats](https://github.com/exelban/stats)：

- `Packages/XStatsKit/Sources/SMC/SMCConnection.swift`：SMC 参数结构体布局与读写流程
- `Packages/XStatsKit/Sources/SMC/FanControl.swift`：Apple Silicon 风扇手动模式解锁流程
- 菜单栏迷你样式的字号与基线参数

```
MIT License

Copyright (c) 2019 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## AI Provider 契约参考

XStats 的 AI Provider 契约与状态设计参考了以下项目公开的 Provider 契约与行为说明。
当前版本未包含这些项目的源码或素材：

- [burakgon/ai-usage-menubar](https://github.com/burakgon/ai-usage-menubar)，MIT License，Copyright (c) 2026 Burak Gon
- [robinebers/openusage](https://github.com/robinebers/openusage)，MIT License，Copyright (c) 2026 Robin Ebers

## Tyme4Swift

日历功能通过 Swift Package Manager 使用 [6tail/tyme4swift](https://github.com/6tail/tyme4swift)
1.5.0（MIT License，Copyright (c) 2026 6tail），提供公历、农历、藏历、回历、干支、
节气、节日、调休、三伏与传统梅雨日期计算。未修改上游源码。
完整许可见 [LICENSES/Tyme4Swift-MIT.txt](LICENSES/Tyme4Swift-MIT.txt)。

## Sparkle

应用内安装通过 Swift Package Manager 使用 [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle)
2.10.0。未修改上游源码；完整上游许可随应用资源中的 `Sparkle-License.txt` 分发。
完整许可证及其内部组件声明见 [LICENSES/Sparkle-License.txt](LICENSES/Sparkle-License.txt)。

## 网络地图与国家级 IP 位置

- 地图轮廓及国家代表坐标来自 [Natural Earth 1:110m](https://github.com/nvkelso/natural-earth-vector)，Public Domain。转换为精简 JSON，仅用于国家级示意，不代表远端设备精确位置。
- 离线 IP 国家表来自 [DB-IP Lite](https://db-ip.com/db/download/ip-to-country-lite)，© DB-IP，采用 [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。每次发布从 DB-IP 官方本月 CSV 获取 IPv4／IPv6 数据；合并相邻同国家范围，转换为大端二进制只读表并经系统 LZFSE 压缩，发布到 c-ip 后由启用监视的客户端按需下载。查询结果可能不准确或随地址分配变化，应用不向 DB-IP 发送目标 IP。
- 数据保留原许可；地图界面保留 DB-IP 链接。转换脚本见 `scripts/build_network_geography.py`，应用内资源 `Resources/NetworkGeography/ATTRIBUTION.md` 随安装包分发。
