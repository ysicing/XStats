# XStatsKit 开发指南

`XStatsKit` 是 XStats 的共享 Swift Package，包含 Metrics、Cleaner、Localization、XStatsUI 等模块及对应测试。依赖版本以 `Package.swift` 和 `Package.resolved` 为准。

## 命令

- 构建测试目标：`cd Packages/XStatsKit && swift build --build-tests`。
- 定向测试：`swift test --skip-build --filter "^<TestTarget>\."`，测试目标名见 `swift package describe`。
- 全量测试以仓库根目录的 `task test-swift` 为准；UI、Cleaner 相关测试由该任务串行运行。
- 格式化在仓库根目录执行 `task format` 与 `task format-check`，使用 `.swift-format`，不要混用 swiftformat。

## 约定

- 新增或修改用户可见文案以简体中文为源文案，通过 `tr(...)` 接入 `Localization` 资源，并同步受影响语言的译文。
- UI 测试与其他用例不得修改进程全局的 `L10n` 语言；翻译断言使用显式语言的翻译表，避免写死中文或依赖系统语言。
- 新建源码与测试文件保留文件头：`SPDX-License-Identifier: AGPL-3.0-or-later`。
- 采样、扫描与阻塞 I/O 放在后台执行，长任务在循环和阶段边界响应取消，取消后不发布过期结果。
- 常驻菜单栏的开销需保持低：只在页面或已启用功能需要时采样，不新增不可见界面的持续动画或定时器。
- 注释默认使用简体中文，解释原因与约束，不逐行翻译代码。
