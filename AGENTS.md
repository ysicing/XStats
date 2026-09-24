# XStats 仓库规则

## 技术栈（Tech Stack）

- macOS 客户端使用 Swift 6、AppKit 与 SwiftUI，包含 WidgetKit 扩展；目标为 macOS 14+、Apple Silicon（arm64）。
- `project.yml` 由 XcodeGen 生成 Xcode 工程；可测试模块位于 Swift Package `Packages/XStatsKit`，构建任务定义在 `Taskfile.yml`。
- 系统采集使用 IOKit / SMC；特权操作通过 `SMAppService` 注册的 XPC 辅助工具完成。本机历史和 AI 统计使用 SQLite，偏好设置使用 UserDefaults，凭据使用 Keychain。
- 日历使用 Tyme4Swift；更新检查服务位于 `server/api`，使用 Go、Fiber v3、GORM 和 SQLite。依赖版本以 `Packages/XStatsKit/Package.swift` 和 `server/api/go.mod` 为准，构建与发布步骤见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 架构与代码质量

- macOS 客户端优先使用系统原生框架和现有模块；引入新的运行时、跨平台 UI 层、依赖或抽象前，先说明当前需求为何不能由现有机制满足。此约束不排斥已有的 Go 服务和必要的第三方库。
- 新代码保持直接、可读：优先提前返回、清晰分支和有意义的局部变量，避免深层嵌套与层层转发的控制流。
- 尽量少写嵌套函数；仅在框架回调要求，或局部闭包明显比新增符号更简单时使用。
- 不要仅为缩短调用方，把只有一个调用点、又不表达稳定业务概念的逻辑抽成模块级辅助函数。可复用行为、接口或框架回调、导出 API、测试夹具，以及值得直接测试的复杂业务逻辑，可以独立成函数；保留单次使用的辅助函数时，名称应表达持久的领域概念，而不是机械步骤。

## 性能与资源

- 监控采样沿用现有需求驱动机制；新增后台任务应在功能未启用、界面不可见或系统休眠等不需要工作时停止或降频，避免无必要的常驻轮询、重复采集和主线程阻塞。
- 处理日志、网络响应与历史数据时控制内存、磁盘 I/O 和刷新频率；长任务支持取消，并按实际风险验证耗电、内存及响应性，不为未出现的性能问题提前增加缓存或并发层。

## 国际化（i18n）

- 新增或修改用户可见文案时以简体中文为源文案，使用 `Packages/XStatsKit/Sources/Localization` 的 `tr(...)` 与现有翻译资源，同步补齐受影响语言的译文；不要只在某个视图中硬编码单一语言。系统名称、日志标识和协议字段不作为界面文案翻译。
- 日期、数字、单位使用当前应用语言对应的 Locale；检查长译文、动态文本及阿拉伯语从右到左布局，避免靠固定宽度或字符串拼接假定中文语序。相关界面改动至少验证受影响语言和布局。

## 代码许可

- 本仓库自行编写的新增代码、测试及对上游代码的修改，采用 **AGPL-3.0-or-later**（GNU Affero General Public License 第 3 版或更新版本）。许可范围以 [LICENSING.md](LICENSING.md) 为准，完整许可见 [LICENSE](LICENSE)。
- 新建源码和测试文件在支持注释时标注 `SPDX-License-Identifier: AGPL-3.0-or-later`；脚本保留首行 shebang。不支持注释的文件在许可说明中记录，不破坏文件格式；文件头不写应用版本号或虚构邮箱。
- 修改上游或第三方文件时，保留原有版权与许可声明，明确区分 XStats 修改部分的授权；其他贡献者按真实归属署名，不机械改写已有年份，也不将上游原始代码声称为 AGPL 独占授权。
- OpenStats 原有 MIT 许可与版权声明保留在 [LICENSES/OpenStats-MIT.txt](LICENSES/OpenStats-MIT.txt)，其他第三方声明见 [ThirdPartyNotices.md](ThirdPartyNotices.md)。
- 引入第三方代码、依赖或素材时，核对许可兼容性并保留来源、版权及必要声明；不新增与本项目新增代码许可相冲突的默认 MIT 声明。
- 调整许可相关内容时，同步核对 LICENSE、LICENSING.md、第三方声明及四语言 README。不得声称本次许可变更撤销了历史版本已有的 MIT 授权。
