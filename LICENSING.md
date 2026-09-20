# 许可范围与新增代码要求

XStats 自行编写的新增代码以及对上游代码的修改，自本次许可变更起采用 **GNU Affero General Public License v3.0 or later**，SPDX 标识为 **AGPL-3.0-or-later**。

许可全文见 [LICENSE](LICENSE)，官方文本见 [GNU AGPL v3](https://www.gnu.org/licenses/agpl-3.0.html)。其中 “or later” 允许接收者选择 AGPL 第 3 版或自由软件基金会以后发布的版本。

## 上游与第三方代码

- OpenStats 原有代码仍保留其 MIT 许可与 Copyright (c) 2026 GiantAccel, LLC 声明，全文见 [LICENSES/OpenStats-MIT.txt](LICENSES/OpenStats-MIT.txt)。本次变更不声称重新许可上游作者的原创部分。
- 其他第三方代码、图标与素材继续适用各自的许可，见 [ThirdPartyNotices.md](ThirdPartyNotices.md)。原有版权、许可和商标说明不得移除。
- 分发包含 XStats 新增代码或修改的组合版本时，应遵守 AGPL-3.0-or-later，并同时保留适用的上游及第三方声明；源码提供等义务以许可全文为准。
- 本次变更不撤销已经按 MIT 发布的历史版本的授权，也不改变第三方可依据原许可证使用上游代码的权利。

## 后续开发与贡献

XStats 本次确认的版权所有者署名为 **ysicing**，当前新增代码声明为 **Copyright (C) 2026 ysicing**。其他贡献者的署名应反映实际归属。年份记录首次发布年份，跨年发生实质修改时可扩展范围；不机械改年，不在源码头维护应用版本号，也不虚构联系邮箱。

1. 本项目新写的代码和测试默认采用 AGPL-3.0-or-later。Swift 文件在开头添加下列标识，其他语言使用对应注释语法：

   ```swift
   // Copyright (C) 2026 ysicing
   // SPDX-License-Identifier: AGPL-3.0-or-later
   ```

2. 修改包含上游代码的文件时保留原版权及许可说明，清楚区分新增修改的授权；不得把第三方文件机械替换成上述标识。
3. 引入第三方代码或素材时记录来源与原许可证，保留必要声明，并检查其与本项目许可的兼容性。
4. 除明确标识的上游或第三方内容外，提交到本项目的新增代码和修改按 AGPL-3.0-or-later 提供；不要新增与此相冲突的默认 MIT 声明。

对于含 MIT 上游代码及 AGPL 修改的混合文件，保留上游版权并追加 `XStats modifications Copyright (C) 2026 ysicing`，使用 `AGPL-3.0-or-later AND MIT` 标识并说明各部分的许可范围。具体文件头示例见 [AGENTS.md](AGENTS.md)。
