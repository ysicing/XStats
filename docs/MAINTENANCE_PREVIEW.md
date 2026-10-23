# 优化清理与 Mole 对照

## 范围与实现约束

对照基线为 Mole `2ef9747535725d6370d4aebb4a3a58ecd1521488`（2026-10-23）。XStats 使用独立的 Swift 实现，不依赖或执行 Mole 脚本。本文逐项说明该固定版本的 15 类清理范围与 19 个 optimize 操作；有限检查不等于与 Mole 的路径、候选、容量或执行行为完全一致。

- 现有清理规则保留原有确认和执行流程。29 条静态缓存预览规则全部为 `previewOnly`，默认未选中，不能勾选清理，执行引擎也不得接受其删除请求。
- 只读预览只返回证据和建议，不修复配置、运行写命令、请求管理员授权或扩大删除白名单。保存状态、数据库、备份、模型和虚拟磁盘审阅不生成清理规则或执行计划。
- 常规清理、依赖预览、项目产物、Agent 数据、空间分析和快照分别按需发起，不因打开常规清理而扫描所有专项，也不进行全盘搜索。
- 判断状态与检查完整性分别展示。权限不足、工具缺失、超时、异常输出、预算耗尽或采样不足均不能解释成正常或零占用。
- 同一对象、父子路径和跨专项范围可能重叠；只读占用、工具汇总与可清理容量分别呈现，不直接相加成“垃圾总量”。

## 当前界面入口

“优化清理”使用两个 Tab：

| Tab | 功能 | 执行边界 |
| --- | --- | --- |
| 清理 | 缓存、日志、项目产物及只读缓存预览 | 沿用选择、保留项目和确认流程；只读预览项不能清理 |
| 优化 | 刷新 DNS 缓存、释放内存、Homebrew 依赖预览 | 前两项为已有手动维护操作，沿用辅助工具或管理员授权；Homebrew 仅执行 `brew autoremove --dry-run`，不移除依赖 |

打开优化 Tab 不启动扫描或维护。切换到优化会取消清理扫描；切回清理、离开页面、隐藏主窗口、锁屏或休眠时取消依赖预览，恢复后需手动重新预览。维护操作由用户单独触发，不自动运行。

系统检查卡片及“资源与维护”“配置审阅”“网络检查”“存储审阅”选择器已移除。对应内部实现与测试保留，当前无界面入口，也不会因打开优化清理而运行。下文的资源、配置、网络及存储审阅对照记录这些内部实现的能力与限制，不表示当前可在界面发起。静态缓存规则仍在清理 Tab 展示，没有新增删除权限。

## 内部预览结果与容量语义

| 结果 | 含义 |
| --- | --- |
| 正常 | 在已声明且完成的检查范围内未发现关注项，不表示全系统正常 |
| 需关注 | 有可展示的观测证据，不等于必须修复 |
| 可选维护 | 偏好、维护或数据审阅建议，不表示检测到故障 |
| 不适用 | 当前系统、工具或对象不适用于该检查 |
| 未检查 / 部分完成 | 证据不足或检查未完成，展示原因；已有关注证据可与“部分完成”并存 |
| 清理候选占用 | 现有可执行规则的已计量对象，仍须确认并在执行前复核 |
| 预览对象占用 | 完整计量对象的占用估计，不提供清理授权，也不保证实际释放量 |

CPU 首次采样建立基线，随后两个有效区间均达到单核 25% 的进程或进程组才列为持续占用证据；这只是短时观察。内存关注判断依据系统压力，交换活动作为区间证据，不以累计 Swap 占用单独判定异常。未知大小不填零，未完成的目录计量不发布部分体积。

## Mole 清理类别对照

“有限交付”包含已保留的内部只读实现及明确复用的既有能力；当前界面入口以上节为准；右列均未达到上游的完整路径或执行覆盖，不承诺照搬其删除行为。

| Mole 类别 | 有限交付 / 既有复用 | 延后或未实现的精确对齐 |
| --- | --- | --- |
| System | 复用本地快照入口；只读计量 `/Library/Caches`、`/Library/Updates` 与用户 `Library/Updates` | 不执行系统级清理、提权、快照自动删除；不判断更新是否过期、完成或可回收 |
| User essentials | 复用用户缓存、日志与废纸篓；审阅四个用户位置顶层 `.DS_Store` 和共享列表占用 | 不全盘发现 Finder 元数据，不清最近文档、共享列表或所有用户数据 |
| App caches | 复用既有应用缓存规则；增加下表明确缓存路径的只读预览与现有运行保护 | 不覆盖 Mole 全部沙盒、群组容器及版本变体；不把整个容器作为缓存，不保证识别所有 CLI 活动 |
| Browsers | 复用既有浏览器清单；增加 Opera、Vivaldi、Orion 三个固定缓存路径预览 | 不扩展至所有 Profile、容器和浏览器变体；不清 Cookies、历史或离线数据 |
| Cloud & Office | Dropbox、Google Drive、OneDrive 与 Word、Excel、PowerPoint、Outlook 的固定缓存路径预览 | 不扫描云盘同步根、离线文档或 Office 容器数据；未对齐所有账户及版本路径 |
| Developer tools | 复用开发者清理与 Homebrew 原生预览；增加 Zed、Poetry、Postman、Insomnia 固定缓存预览 | 未新增 Gradle / Maven 本地制品删除、构建锁判断或其他工具完整路径发现；不执行 Homebrew autoremove |
| Apps & utilities | Teams、Zoom、Telegram、WhatsApp、ChatGPT、Figma 等固定缓存预览；既有专属规则继续复用 | 其他通信、媒体和创作软件的容器、数据库、附件与离线内容未完整覆盖 |
| Virtualization | VMware Fusion、UTM、Lima 缓存预览；固定 Docker、Lima、OrbStack、Claude VM 数据目录占用及映像挂载证据 | 不判断 VM 所有者、运行或闲置状态，不执行 prune、压缩、删除虚拟磁盘或卸载映像；未覆盖所有产品及自定义数据根 |
| Application Support | 增加 Zed Node、Battle.net 明确缓存叶子；复用既有应用专属缓存 | 不清空 Application Support，不泛化发现所有日志或数据目录，不将会话和资产视为缓存 |
| App leftovers | 复用选定应用的残留审阅；对明确元数据归属与已加载有限应用清单作比较 | 未实现全盘安装库存、真正孤儿判定、系统服务或空容器自动清理；未匹配不代表卸载 |
| Apple Silicon | 只读计量两个固定 Rosetta 更新数据位置 | 不判断是否仍在使用，不删除 Rosetta、系统组件或进行架构裁剪 |
| Device backups & firmware | iTunes 四类更新目录顶层 `.ipsw` 与 MobileSync 备份分别计量 | 不判固件过期、备份可丢弃，不覆盖全部设备管理位置，不删除设备备份 |
| Time Machine | 复用既有快照入口；只读列出已挂载本地卷上的旧式 `.inprogress` 标记 | 标记不证明失败或停止；现代 APFS 备份状态、备份会话核验与删除均未实现；不挂载卷或运行 tmutil |
| Large files | 复用空间分析与安装包入口；补充固定模型、备份、VM 数据目录占用 | 不进行全盘大文件发现，不按体积或时间推断垃圾；未对齐所有 Mole 大文件位置 |
| Project artifacts | 复用 ProjectPurge 的独立扫描、项目审阅、Git / 保留保护与既有删除确认 | 未承诺覆盖 Mole 所有产物类型、扫描根和忽略策略；不另建一套清理扫描 |

上述 15 类来自固定源 `bin/clean.sh` 的常规分段。其独立外部卷清理模式不在本批对齐范围；当前只读取已挂载本地卷中的有限备份证据。

## 29 条静态缓存预览规则

所有路径均相对 `~/Library/`，精确保留固定源中的名称与大小写。表中“来源”是固定 Mole 提交内的文件与行号，仅用于路径溯源，不表示 XStats 执行该脚本。规则复用 `ApplicationCacheCatalog.cache`，不为容器增加通用预览或删除白名单。

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

固定源 `lib/optimize/catalog.sh` 共登记 19 个操作。下表记录内部保留的对应观察范围；XStats 不批量执行上游优化动作。当前优化 Tab 仅开放 DNS 刷新、内存释放及 Homebrew 依赖预览。

| Mole 操作 | 有限交付 / 既有复用 | 延后或未实现的精确对齐 |
| --- | --- | --- |
| `cache_refresh` | QuickLook、旧版 Quick Look、Icon Services 三个缓存路径占用预览 | 不刷新缓存、重启 Finder 或图标服务，不覆盖所有系统临时缓存位置 |
| `saved_state_cleanup` | 配置审阅中枚举用户 Saved Application State 的直接 `.savedState` 目录，以目录 mtime 超过 30 天筛选，跳过运行应用，仅发布完整计量占用 | 不读取恢复内容或判断最后使用时间，不提供清理；不扫描其他用户或容器内的保存状态 |
| `fix_broken_configs` | Preferences / ByHost 顶层非受保护 plist 格式解析 | 不判断设置语义，不修复或删除 plist，不递归全部偏好目录 |
| `network_optimization` | 复用 DNS 维护适用性与代理环境提示；手动网络检查提供一次 DNS 解析证据 | 不刷新 DNS 缓存、重启服务或判断所有 DNS 问题 |
| `sqlite_vacuum` | 固定 Mail、Safari、Messages 等主库头、空闲页估计与附属文件占用 | 不运行 VACUUM / checkpoint；不保证估计对应实时逻辑库，不把空闲页视为可回收容量 |
| `prevent_network_dsstore` | 读取存盘的网络盘 / USB Finder 偏好，作为可选维护 | 不写偏好，不检查所有卷中实际存在的 `.DS_Store` |
| `legacy_overrides_audit` | 复用 App Nap 及磁盘映像验证覆盖的严格布尔值检查 | 不删除设置，不替代整个系统配置审计 |
| `network_stack_optimize` | 分别读取 IPv4 / IPv6 默认路由，查询当前 DNS 的一次 `apple.com` A 记录 | 不刷新路由或 ARP，不更换 DNS，不重置网络栈；不能由单次失败确定故障原因 |
| `disk_permissions_repair` | 复用 Home、Library、Preferences 的所有者与可写性检查 | 不修复权限，不递归审计 ACL 或系统目录 |
| `spotlight_index_optimize` | 启动卷索引状态及三个声明应用目录的有限应用计数查询；慢查询仅展示观察 | 不重建索引，不凭成功、零结果或单次耗时判定索引完整或损坏 |
| `spotlight_orphan_rules_cleanup` | 保留 System / Apple 规则，对其他 EnabledPreferenceRules 用有限应用目录内的实际 bundle 标识核对 | 未确认归属不等于失效或孤儿；不删除规则，不覆盖其他卷和所有安装位置 |
| `periodic_maintenance` | 工具存在性与 daily / weekly / monthly 记录 mtime；工具不存在则不适用 | 不运行 periodic；超过 7 天只供审阅，记录新鲜也不能证明维护成功 |
| `shared_file_list_repair` | 共享列表根目录的 `.sfl2` / `.sfl3` / `.sfl4` plist 格式，跳过最近文档 | 不解档对象、解析书签或修复收藏；子目录未检查时保留不完整状态 |
| `disk_verify` | 保留既有独立手动磁盘验证入口；本批预览不发起验证，固定 Mole dry-run 也跳过该操作 | 不将未运行验证描述为磁盘健康，不自动运行 verifyVolume 或修复文件系统 |
| `login_items_audit` | 仅在已有自动化权限且 System Events 已运行时，从其登录项来源读取记录并核对范围内目标 | 不请求授权或启动服务，不用 LaunchAgents 替代；不覆盖现代后台登录项目，不据缺失目标推断卸载 |
| `quarantine_cleanup` | 固定隔离库占用；满足大小与完整性条件时，仅在内存副本中统计记录数 | 不查询或展示下载 URL，不清除记录或更改 Gatekeeper；未知记录数不填零 |
| `launch_agents_cleanup` | 复用当前用户顶层 LaunchAgents 的绝对程序路径检查；未挂载卷、权限与解析问题单列 | 不停用或删除代理，不替代系统服务清理，也不等同于独立登录项检查 |
| `notification_cleanup` | 固定 usernoted 通知数据库及附属文件占用 | 不读取通知内容、按年龄删记录或修改数据库；未覆盖所有系统版本布局 |
| `coreduet_cleanup` | 固定 Knowledge 数据库及附属文件占用 | 不读取使用记录内容、清理历史或修改数据库；未覆盖所有布局 |

LaunchServices 重建、自动释放内存与其他写入型优化均不属于本次预览交付。DNS 刷新、内存释放与磁盘验证等既有手动工具仍遵循各自入口与执行边界。

## 深入审阅的有限范围

### 配置与保存状态

plist 格式检查只读取不超过 1 MiB 的普通文件，跳过 `com.apple.*`、`.GlobalPreferences*` 与 `loginwindow.plist`；专门的 Finder、Spotlight 和遗留偏好检查只读取各自声明的键。合法数组、标量及 OpenStep 字符串不会因不是字典而被误判为损坏。共享列表不使用对象解档，也不解析最近文档书签。

Spotlight 查询仅限 `~/Applications`、`/Applications`、`/System/Applications`；归属核对只读取这些目录的直接应用及一层子目录内应用的 Info.plist。登录项检查使用独立 System Events 来源，仅核对声明的本地应用目录，不探测任意脚本、网络位置或未挂载卷；该来源始终不能代表完整的现代登录项清单。

Saved State 的 30 天阈值来自同一固定源 `lib/core/base.sh:162` 的 `MOLE_SAVED_STATE_AGE_DAYS=30`。只枚举 `~/Library/Saved Application State` 的直接 `.savedState` 目录，拒绝符号链接候选，测量前后复核目录身份、mtime 与运行保护。mtime 是目录修改时间，不是应用最后使用时间；恢复状态可能仍有价值。结果只有可选审阅和占用证据，不能选择清理。

### 数据库与目录占用

数据库审阅只读取固定主库的 100 字节 SQLite 头，并分别计量 `-wal`、`-shm`、`-journal`。WAL 模式、附属文件或并发变化会使结论保留不完整或未知；空闲页只是主库估计，不代表可释放空间。隔离记录计数另要求完整、稳定且不超过 16 MiB 的主库副本，复制到只读内存数据库后仅作 COUNT，不对源库建立 SQLite 连接或创建附属文件。

| 对象 | 固定读取或计量位置 |
| --- | --- |
| Mail / Safari / Messages | `~/Library/Mail/V*/MailData/Envelope Index`；`~/Library/Safari/History.db`、`TopSites.db`；`~/Library/Messages/chat.db` |
| 隔离 / 通知 / 使用记录 | `~/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2`；`~/Library/Group Containers/group.com.apple.usernoted/db2/db`；`~/Library/Application Support/Knowledge/knowledgeC.db` |
| 系统缓存与更新 | `/Library/Caches`、`/Library/Updates`、`~/Library/Updates` |
| Rosetta | `/Library/Apple/usr/share/rosetta/rosetta_update_bundle`、`~/Library/Caches/com.apple.rosetta.update` |
| 设备备份 | `~/Library/Application Support/MobileSync/Backup`，作为用户数据审阅 |
| 固件下载 | `~/Library/iTunes/` 下 iPhone、iPad、iPod、Apple TV Software Updates 四个目录的顶层 `.ipsw` |
| VM 数据 | `~/Library/Containers/com.docker.docker/Data`、`~/.lima`、`~/OrbStack`、`~/Library/Application Support/Claude/claude-code-vm`；另计用户 Group Containers 直接子项中名称后缀为 `dev.orbstack` 的 `data` 目录 |
| 模型数据 | `~/.lmstudio/models`、`~/.cache/huggingface`，不跟随 HF_HOME 等环境重定向 |
| Finder 元数据 / 最近项目占用 | 家目录、Desktop、Documents、Downloads 各自顶层 `.DS_Store`；`~/Library/Application Support/com.apple.sharedfilelist` 目录，仅计量、不读取最近文档内容 |

固定目录可能包含大量数据；只在预算内计量，不能完成则显示大小未知，不扩展为整个 Containers / Group Containers 或用户目录扫描。VM 与模型分开展示。`hdiutil info -plist` 仅提供映像来源与挂载位置，排除系统与 CoreSimulator 运行时映像；它不能证明虚拟机归属或闲置，也不会卸载映像。

### 应用归属与备份标记

应用数据审阅依赖界面已加载的有限应用标识清单。尚未加载时明确显示“尚未加载应用清单，未检查应用数据归属；请复用选定应用的残留审阅。”。只对 Preferences 顶层 plist 和 Containers 直接候选读取身份元数据，要求 `CFBundleIdentifier` 或 `MCMMetadataIdentifier` 与候选标识准确匹配；不靠目录名称猜测，不遍历容器数据。Apple 及共享身份保护不能反向作为归属证据。

结果说明为“仅列有明确归属的待审阅项目：未在已加载应用清单中匹配，不代表卸载或孤儿；不是垃圾，不提供清理授权。”。这项审阅始终标记为有限、不完整。其他卷、非标准位置或未加载的应用仍可能使用这些数据。

Time Machine 只从内核挂载表选取 `/Volumes` 下已挂载的本地卷，有限读取 `Backups.backupdb/<machine>/*.inprogress` 旧式标记，不挂载卷或触发网络卷探测。即使发现标记，结果仍为未检查 / 不完整；不能证明备份已失败、已停止或可安全删除，也不代表现代 APFS 备份状态。备份管理继续使用系统 Time Machine 或既有快照入口。

## 隐私、资源预算与验收边界

当前优化清理不提供网络检查入口，不触发 `apple.com` 查询。内部保留的网络检查实现若被单独调用，只查询一次 A 记录并读取默认路由，不上传本机检查清单。进程、路径和工具输出只供本机审阅，不写入运行日志；其他内部配置和存储检查读取本地证据。

配置扫描与 Saved State 各有最多 2,000 条目、20 秒、500 候选的预算，并服从调用环境的更小限制；配置工具查询再受单次 5 秒与剩余预算约束。存储扫描共用 20,000 条目、15 秒、200 候选预算，发现时计遍历条目，筛选后计实际审阅候选。只读工具统一使用带超时与完整输出限制的 `inspectTool`（30 秒 / 1 MiB），超限即拒绝解析；配置查询另限制为少于 8,192 字节，磁盘映像 plist 可使用完整的 1 MiB 预算。检查结果的证据行也有限额；取消后不发布过期结果。预算和证据上限意味着结果不是全量清单。

交付验收需分别核对以下条件，文档本身不代表测试或实机资源验证已通过：

- 预览项即使被调用方显式选中，执行引擎仍拒绝；通用父目录和旧执行计划不能绕过预览保留范围。
- 相同对象、父子路径与跨专项重叠不直接累计；仅展示完整计量对象，未知不填零。
- 临时目录及假工具覆盖运行保护、权限、工具缺失、异常输出、取消、预算耗尽和旧结果隔离；不实际扫描测试机用户文件。
- 清理与优化两个 Tab 分工明确，无系统检查入口；打开优化不自动启动工作，依赖预览仅运行 Homebrew dry-run，取消后不发布旧结果。
- Cleaner、Metrics、XStatsUI 与 Localization 相关回归及统一格式检查由整合方执行；发布前继续满足既有完整发布门禁。空闲、运行、取消和关闭后的资源行为须另行实测，未测不作性能或长期稳定性结论。
