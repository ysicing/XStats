# 清理范围与执行清单

XStats 在扫描后生成本次清理清单，展示候选、大小和跳过原因。确认后仅处理选中的候选或工具操作；清理前重新检查保留项、应用运行状态和路径安全。

目录清理支持逐项选择。包管理器缓存由原生工具整体处理，大小是已扫描缓存的容量，实际释放量以完成后的结果为准。“保留项目”列表仅存储在本机，最多 50 条；包含保留项的父候选也不会被删除。

## 开发者清理清单

| 项目 | 扫描范围 | 执行方式与限制 |
|---|---|---|
| Xcode 编译缓存 | `~/Library/Developer/Xcode/DerivedData` 下的候选 | 按选中目录清理；Xcode 运行时跳过 |
| 模拟器缓存 | `~/Library/Developer/CoreSimulator/Caches` 下的候选 | 按选中目录清理；模拟器运行时跳过 |
| npm | 查询实际 cache 下的 `_cacache` | 固定 `--cache` 后执行 `npm cache clean --force` |
| Yarn Classic | 查询缓存目录并确认配置根 | 固定 `--cache-folder`；原生命令删除整个配置根，包含版本目录的兄弟项 |
| Yarn Berry | 查询 `cacheFolder` 与 `globalFolder` 的缓存位置 | 固定配置位置后执行 `cache clean --all`；插件可能有额外全局操作，有保留项时暂停 |
| pnpm | `pnpm store path` 返回的当前版本存储 | `--store-dir` 使用经过验证的配置父目录，预览只计量版本目录；执行 `store prune` |
| Bun | `bun pm cache` 返回的实际缓存 | 用 `BUN_INSTALL_CACHE_DIR` 固定范围；隔离临时工作目录，执行结束后释放 |
| Go | `go env -json GOCACHE GOMODCACHE` | 编译与模块缓存使用同一份规范化路径预览和执行；`GOCACHE=off` 单独处理 |
| Rust | `CARGO_HOME` 下的 `registry` 和 `git` | 固定 `CARGO_HOME` 后执行 `cargo-cache -r all`；不清理已安装的二进制工具 |
| uv | `uv cache dir` 返回的实际缓存 | 固定 `--cache-dir` 后执行 `uv cache clean` |
| pip | `pip3 cache dir` 返回的实际缓存 | 固定 `--cache-dir` 后执行 `pip3 cache purge`；不清理虚拟环境和已安装的包；缓存格式支持取决于本机 pip3 版本 |
| Homebrew | `brew cleanup --prune=30 --dry-run` 的原生预览 | 清理旧版本与缓存，不自动移除依赖；仅空目录、断链等 0 字节维护项显示“无需清理”；全局操作无法锁定完整路径，有保留项时暂停 |
| VS Code | Code、Code - Insiders 下的 `Cache`、`Code Cache`、`GPUCache` | 应用退出后按目录清理；保留设置、扩展、工作区状态与会话 |
| Cursor | Cursor 下的 `Cache`、`Code Cache`、`GPUCache` | 应用退出后按目录清理；保留设置、扩展、工作区状态与会话 |
| Xcode 归档 | `~/Library/Developer/Xcode/Archives` 下的候选 | 默认不选，确认后移到废纸篓；删除归档会影响旧版本崩溃符号化 |

新增的 pip、VS Code 和 Cursor 项目默认不勾选。只识别已有工具和明确目录，不自动安装或更新开发工具。工具查询失败、路径无法确认或扫描不完整时，不执行整项原生清理。

Gradle、Maven、Docker、AI 模型和历史会话不在本次新增范围中：这些项目还涉及构建锁、本地制品、运行资源或用户数据，不能直接作为普通下载缓存处理。

## 执行边界

- 每条开发者规则由 `DeveloperCleanupCatalog` 定义，原生规则只生成一份 `ToolCachePlan`。确认后的执行复用这份计划，不回退到默认路径或另一套命令。
- 支持限制缓存位置的工具通过参数或环境变量锁定目录。Homebrew 和 Yarn Berry 属于全局工具操作，预览不等于不可变的逐文件删除清单。
- 工具缓存从通用缓存和日志候选中去重，避免重复计量或绕过工具直接删除。
- 扫描最多并发四条规则；只读工具查询有超时和输出大小限制。关闭或取消后不维持额外轮询。
- 卸载扫描会分别保留已验证的候选与读取失败的位置。确认窗口会提示可能仍有残留；应用本体不可读或扫描被取消时停止操作。

## 参考与验证

功能范围参考 [dusty](https://github.com/yagcioglutoprak/dusty)、[MacSai](https://github.com/iliyami/MacSai)、[PureMac](https://github.com/momenbasel/PureMac)；清理命令按各工具实际行为验证，未照搬其删除实现。来源说明见 [ThirdPartyNotices.md](../ThirdPartyNotices.md)。

测试使用临时目录与模拟工具覆盖路径锁定、保留保护、原生报告解析和编辑器用户数据保护。开发验证命令与截图入口见 [DEVELOPMENT.md](DEVELOPMENT.md)。
