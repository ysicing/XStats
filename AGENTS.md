# XStats 仓库规则

## 代码许可

- 本仓库自行编写的新增代码、测试及对上游代码的修改，采用 **AGPL-3.0-or-later**（GNU Affero General Public License 第 3 版或更新版本）。许可范围以 [LICENSING.md](LICENSING.md) 为准，完整许可见 [LICENSE](LICENSE)。
- 本次确认的 XStats 版权所有者署名为 `ysicing`。新建源码和测试文件时，使用对应语言的注释语法添加 `Copyright (C) <首次发布年份> ysicing` 和 `SPDX-License-Identifier: AGPL-3.0-or-later`；当前年份为 2026。脚本保留首行 shebang，将声明放在其后。不支持注释的文件在许可说明中记录，不破坏文件格式。
- 跨年发生实质修改时可扩展版权年份范围，不机械刷新年份。文件头不写应用版本号，不虚构邮箱；如需联系邮箱，使用用户确认的地址集中记录在项目文档。其他贡献者按真实归属署名，不将其贡献自动归给 ysicing。
- 修改上游或第三方文件时，保留原有版权与许可声明，明确区分 XStats 修改部分的授权；禁止批量覆盖第三方许可证或将上游原始代码声称为 AGPL 独占授权。
- OpenStats 原有 MIT 许可与版权声明保留在 [LICENSES/OpenStats-MIT.txt](LICENSES/OpenStats-MIT.txt)，其他第三方声明见 [ThirdPartyNotices.md](ThirdPartyNotices.md)。
- 引入第三方代码、依赖或素材时，核对许可兼容性并保留来源、版权及必要声明；不新增与本项目新增代码许可相冲突的默认 MIT 声明。
- 调整许可相关内容时，同步核对 LICENSE、LICENSING.md、第三方声明及四语言 README。不得声称本次许可变更撤销了历史版本已有的 MIT 授权。

Swift 新文件示例：

```swift
// Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later
```

含 OpenStats 上游代码及 XStats 修改的文件示例（仍需保留文件原有的其他声明）：

```swift
// Copyright (c) 2026 GiantAccel, LLC
// XStats modifications Copyright (C) 2026 ysicing
// SPDX-License-Identifier: AGPL-3.0-or-later AND MIT
//
// Upstream portions retain their MIT license.
// XStats modifications are licensed under AGPL-3.0-or-later.
// See LICENSE, LICENSING.md and LICENSES/OpenStats-MIT.txt.
```
