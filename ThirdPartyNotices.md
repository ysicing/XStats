# 第三方声明

XStats 新增代码与修改采用 AGPL-3.0-or-later，范围见 [LICENSING.md](LICENSING.md)。以下原有第三方许可与版权声明继续保留。

## gentpan/OpenStats

XStats 基于 [gentpan/OpenStats](https://github.com/gentpan/OpenStats) 开发，感谢原项目的开源贡献。
原项目使用 MIT License，Copyright (c) 2026 GiantAccel, LLC；完整许可证与版权声明保留在 [LICENSES/OpenStats-MIT.txt](LICENSES/OpenStats-MIT.txt) 中。

## flag-icons

`Assets/flags-svg/` 中的国旗 SVG（应用内为 `Scripts/render_flags.sh` 渲染的 PNG）来自
[lipis/flag-icons](https://github.com/lipis/flag-icons)，MIT License，Copyright (c) 2013 Panayiotis Lipiridis。

## 保留的登录品牌标志资源

账号登录入口已移除。以下为暂时保留的旧资源及原使用说明。

`Packages/XStatsKit/Sources/XStatsUI/Resources/Logos/github.svg` 来自
[primer/octicons](https://github.com/primer/octicons) 的 mark-github，MIT License，Copyright (c) GitHub Inc.；
`google.svg` 是 Google 的品牌标志，仅按其品牌规范用于“使用 Google 登录”按钮。Apple 标志使用系统 SF Symbols 的 `apple.logo`。
GitHub、Google 与 Apple 的名称和标志均为各自公司的商标。

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
