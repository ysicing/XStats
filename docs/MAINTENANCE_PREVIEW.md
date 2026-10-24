# 清理优化与 Mole 对照

## 范围与实现约束

对照基线为 Mole `2ef9747535725d6370d4aebb4a3a58ecd1521488`（2026-10-23）。XStats 使用独立的 Swift 实现，不依赖或执行 Mole 脚本。本文逐项说明该固定版本的 15 类清理范围与 19 个 optimize 操作；有限检查不等于与 Mole 的路径、候选、容量或执行行为完全一致。

- 现有清理规则保留原有确认和执行流程。26 个仅查看的缓存项目覆盖 29 个固定目录，内部标记为 `previewOnly`，默认未选中，不能勾选清理，执行引擎也不得接受其删除请求。
- 只读预览只返回证据和建议，不修复配置、运行写命令、请求管理员授权或扩大删除白名单。
- 常规清理、依赖预览、项目产物、Agent 数据、空间分析和快照分别按需发起，不因打开常规清理而扫描所有专项，也不进行全盘搜索。
- 判断状态与检查完整性分别展示。权限不足、工具缺失、超时、异常输出、预算耗尽或采样不足均不能解释成正常或零占用。
- 同一对象、父子路径和跨专项范围可能重叠；只读占用、工具汇总与可清理容量分别呈现，不直接相加成“垃圾总量”。

## 当前界面入口

“清理优化”使用两个 Tab：

| Tab | 功能 | 执行边界 |
| --- | --- | --- |
| 清理 | 缓存、日志、项目产物及仅查看的缓存目录 | 沿用选择、保留项目和确认流程；仅查看项目不能清理 |
| 优化 | 刷新 DNS 缓存、重置缩略图、Spotlight 修复步骤、释放内存、Homebrew 依赖预览 | DNS 和内存操作沿用辅助工具或管理员授权；缩略图只调用系统 `qlmanage -r cache`；Spotlight 只展示步骤并打开设置；Homebrew 仅执行 `brew autoremove --dry-run`，不移除依赖 |

打开优化 Tab 不启动扫描或维护。切换到优化会取消清理扫描；切回清理、离开页面、隐藏主窗口、锁屏或休眠时取消依赖预览，恢复后需手动重新预览。维护操作由用户单独触发，不自动运行。

系统检查卡片及“资源与维护”“配置审阅”“网络检查”“存储审阅”选择器已移除，对应内部实现与测试也已删除，不再提供这些检查。仅查看的缓存目录仍在清理 Tab 展示，没有新增删除权限。

## Mole 清理类别对照

“有限交付”仅指当前交付的仅查看缓存目录及明确复用的既有能力；右列均未达到上游的完整路径或执行覆盖，不承诺照搬其删除行为。

| Mole 类别 | 有限交付 / 既有复用 | 延后或未实现的精确对齐 |
| --- | --- | --- |
| System | 复用本地快照入口 | 不计量系统级缓存与更新目录；不执行系统级清理、提权、快照自动删除 |
| User essentials | 复用用户缓存、日志与废纸篓 | 不审阅 `.DS_Store` 和共享列表，不全盘发现 Finder 元数据，不清最近文档、共享列表或所有用户数据 |
| App caches | 复用既有应用缓存规则；增加下表明确缓存路径的只读预览与现有运行保护 | 不覆盖 Mole 全部沙盒、群组容器及版本变体；不把整个容器作为缓存，不保证识别所有 CLI 活动 |
| Browsers | 复用既有浏览器清单；增加 Opera、Vivaldi、Orion 三个固定缓存路径预览 | 不扩展至所有 Profile、容器和浏览器变体；不清 Cookies、历史或离线数据 |
| Cloud & Office | Dropbox、Google Drive、OneDrive 与 Word、Excel、PowerPoint、Outlook 的固定缓存路径预览 | 不扫描云盘同步根、离线文档或 Office 容器数据；未对齐所有账户及版本路径 |
| Developer tools | 复用开发者清理与 Homebrew 原生预览；增加 Zed、Poetry、Postman、Insomnia 固定缓存预览 | 未新增 Gradle / Maven 本地制品删除、构建锁判断或其他工具完整路径发现；不执行 Homebrew autoremove |
| Apps & utilities | Teams、Zoom、Telegram、WhatsApp、ChatGPT、Figma 等固定缓存预览；既有专属规则继续复用 | 其他通信、媒体和创作软件的容器、数据库、附件与离线内容未完整覆盖 |
| Virtualization | VMware Fusion、UTM、Lima 缓存预览 | 不计量 Docker、Lima、OrbStack、Claude VM 数据目录，不判断 VM 所有者、运行或闲置状态，不执行 prune、压缩、删除虚拟磁盘或卸载映像；未覆盖所有产品及自定义数据根 |
| Application Support | 增加 Zed Node、Battle.net 明确缓存叶子；复用既有应用专属缓存 | 不清空 Application Support，不泛化发现所有日志或数据目录，不将会话和资产视为缓存 |
| App leftovers | 复用选定应用的残留审阅 | 未实现全盘安装库存、真正孤儿判定、系统服务或空容器自动清理；不对未匹配候选做应用数据归属审阅 |
| Apple Silicon | 未交付 | 不计量 Rosetta 更新数据，不删除 Rosetta、系统组件或进行架构裁剪 |
| Device backups & firmware | 未交付 | 不计量 `.ipsw` 与 MobileSync 备份，不判固件过期、备份可丢弃，不删除设备备份 |
| Time Machine | 复用既有快照入口 | 不读取旧式 `.inprogress` 标记；现代 APFS 备份状态、备份会话核验与删除均未实现；不挂载卷或运行 tmutil |
| Large files | 复用空间分析与安装包入口 | 不进行全盘大文件发现，不按体积或时间推断垃圾；不计量模型、备份、VM 数据目录 |
| Project artifacts | 复用 ProjectPurge 的独立扫描、项目审阅、Git / 保留保护与既有删除确认 | 未承诺覆盖 Mole 所有产物类型、扫描根和忽略策略；不另建一套清理扫描 |

上述 15 类来自固定源 `bin/clean.sh` 的常规分段。其独立外部卷清理模式不在本批对齐范围。

## 29 个仅查看的缓存目录

Zed、Poetry 与 QuickLook 的两处路径分别合并为一条规则，合计 26 个仅查看项目；合并不扩大固定路径范围。所有路径均相对 `~/Library/`，精确保留固定源中的名称与大小写。表中“来源”是固定 Mole 提交内的文件与行号，仅用于路径溯源，不表示 XStats 执行该脚本。规则复用 `ApplicationCacheCatalog.cache`，不为容器增加通用预览或删除白名单。

| 规则 | 相对路径 | 固定源证据 |
| --- | --- | --- |
| Microsoft Teams | `Caches/com.microsoft.teams2` | `lib/clean/app_caches.sh:910` |
| Zoom | `Caches/us.zoom.xos` | `lib/clean/app_caches.sh:906` |
| Telegram | `Caches/ru.keepcoder.Telegram` | `lib/clean/app_caches.sh:908` |
| WhatsApp | `Caches/net.whatsapp.WhatsApp` | `lib/clean/app_caches.sh:911` |
| ChatGPT | `Caches/com.openai.chat` | `lib/clean/app_caches.sh:945` |
| Figma | `Caches/com.figma.Desktop` | `lib/clean/app_caches.sh:964` |
| Opera | `Caches/com.operasoftware.Opera` | `lib/clean/user.sh:2145` |
| Vivaldi | `Caches/com.vivaldi.Vivaldi` | `lib/clean/user.sh:2148` |
| Orion | `Caches/com.kagi.kagimacOS` | `lib/clean/user.sh:2168` |
| Dropbox | `Caches/com.getdropbox.dropbox` | `lib/clean/user.sh:794` |
| Google Drive | `Caches/com.google.GoogleDrive` | `lib/clean/user.sh:2215` |
| OneDrive | `Caches/com.microsoft.OneDrive` | `lib/clean/user.sh:2235` |
| Microsoft Word | `Caches/com.microsoft.Word` | `lib/clean/user.sh:2258` |
| Microsoft Excel | `Caches/com.microsoft.Excel` | `lib/clean/user.sh:2265` |
| Microsoft PowerPoint | `Caches/com.microsoft.Powerpoint` | `lib/clean/user.sh:2272` |
| Microsoft Outlook | `Caches/com.microsoft.Outlook` | `lib/clean/user.sh:2273` |
| Zed | `Caches/Zed` | `lib/clean/app_caches.sh:444` |
| Poetry | `Caches/pypoetry/artifacts` | `lib/clean/dev.sh:864` |
| Poetry | `Caches/pypoetry/cache` | `lib/clean/dev.sh:865` |
| Postman | `Caches/com.postmanlabs.mac` | `lib/clean/dev.sh:4181` |
| Insomnia | `Caches/com.konghq.insomnia` | `lib/clean/dev.sh:4182` |
| VMware Fusion | `Caches/com.vmware.fusion` | `lib/clean/user.sh:2396` |
| UTM | `Caches/com.utmapp.UTM` | `lib/clean/user.sh:2294` |
| Lima | `Caches/lima/download/by-url-sha256` | `lib/clean/user.sh:2400` |
| Zed | `Application Support/Zed/node/cache` | `lib/clean/app_caches.sh:447` |
| Battle.net | `Application Support/Battle.net/Cache` | `lib/clean/app_caches.sh:1880` |
| QuickLook | `Caches/com.apple.QuickLook.thumbnailcache` | `lib/optimize/tasks.sh:207` |
| QuickLook | `Caches/Quick Look` | `lib/clean/user.sh:1173` |
| Icon Services | `Caches/com.apple.iconservices` | `lib/optimize/tasks.sh:209` |

这些路径是有限静态清单，不是对同名应用全部缓存的承诺。Teams 使用用户 Caches 路径，不扫描新版 Teams 容器。运行保护复用可确认的 bundle、应用名称及既有工厂逻辑；多数新增项只登记应用名称，不从缓存目录名推定真实 bundle 身份，Poetry、Lima 等 CLI 的活动状态尤其不能据此完整确认。检测到保护条件时跳过；没有触发保护不代表对象闲置。

通用缓存与日志规则必须让出这些预览保留范围，执行旧计划时也要复核，避免通过父目录或其他入口绕过只读权限。不能仅依靠结果展示时去重。未改变原有可执行规则的确认流程或 `SafetyGuard` 删除根。

## Mole optimize 操作对照

固定源 `lib/optimize/catalog.sh` 共登记 19 个操作。XStats 不批量执行上游优化动作；当前优化 Tab 开放 DNS 刷新、缩略图重置、Spotlight 修复步骤、内存释放及 Homebrew 依赖预览。

| Mole 操作 | 有限交付 / 既有复用 | 延后或未实现的精确对齐 |
| --- | --- | --- |
| `cache_refresh` | 清理 Tab 展示 QuickLook 与 Icon Services 固定目录占用；优化 Tab 手动重置 QuickLook 缩略图 | 不重启 Finder 或图标服务，不覆盖所有系统临时缓存位置 |
| `network_optimization` | 复用既有 DNS 刷新入口 | 不重启服务或判断所有 DNS 问题；不提供网络检查 |
| `disk_verify` | 保留既有独立手动磁盘验证入口 | 不自动运行 verifyVolume 或修复文件系统，不将未运行验证描述为磁盘健康 |
| `spotlight_index_optimize` | 展示 Apple 修复步骤并打开 Spotlight 设置 | 不直接执行索引重建、不判断完成状态 |
| 其余 15 项 | 未交付 | `saved_state_cleanup`、`fix_broken_configs`、`sqlite_vacuum`、`prevent_network_dsstore`、`legacy_overrides_audit`、`network_stack_optimize`、`disk_permissions_repair`、`spotlight_orphan_rules_cleanup`、`periodic_maintenance`、`shared_file_list_repair`、`login_items_audit`、`quarantine_cleanup`、`launch_agents_cleanup`、`notification_cleanup`、`coreduet_cleanup`。曾有的只读审阅已删除，不检查、不修复、不清理 |

LaunchServices 重建、自动释放内存与其他写入型优化均不属于本次预览交付。DNS 刷新、内存释放与磁盘验证等既有手动工具仍遵循各自入口与执行边界。

## 隐私、资源预算与验收边界

Homebrew 依赖预览通过带超时与完整输出限制的 `inspectTool`（30 秒 / 1 MiB）运行 `brew autoremove --dry-run`，超限即拒绝解析；证据行限 20 行、每行 500 字符，取消后不发布过期结果。进程、路径和工具输出只供本机审阅，不写入运行日志。

交付验收需分别核对以下条件，文档本身不代表测试或实机资源验证已通过：

- 预览项即使被调用方显式选中，执行引擎仍拒绝；通用父目录和旧执行计划不能绕过预览保留范围。
- 相同对象、父子路径与跨专项重叠不直接累计；仅展示完整计量对象，未知不填零。
- 临时目录及假工具覆盖运行保护、权限、工具缺失、异常输出、取消和旧结果隔离；不实际扫描测试机用户文件。
- 清理与优化两个 Tab 分工明确，无系统检查入口；打开优化不自动启动工作，依赖预览仅运行 Homebrew dry-run，取消后不发布旧结果。
- Cleaner、XStatsUI 与 Localization 相关回归及统一格式检查由整合方执行；发布前继续满足既有完整发布门禁。空闲、运行、取消和关闭后的资源行为须另行实测，未测不作性能或长期稳定性结论。
