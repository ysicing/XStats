# 清理预览与系统检查

## 范围与实现约束

对照基线为 Mole `2ef9747535725d6370d4aebb4a3a58ecd1521488`（2026-10-23）。
XStats 使用现有 Swift 模块实现检查，不依赖或执行 Mole。

- 现有清理规则保留原有确认和执行流程。此次新增的文件规则仅供预览，不能勾选或传入执行引擎清理。
- 系统检查只提供观察证据和建议，不执行修复、清理、管理员授权或配置写入。
- 常规扫描、项目构建产物、AI 数据、空间分析与快照分别按需发起，不因打开常规清理而扫描全部专项。
- 扫描大小为已完整计量的候选占用估计，不保证实际释放量。大文件、数据库、AI 数据、虚拟磁盘和备份不自动计入可清理空间。
- 规则具有独立的判断结果与检查完整性。权限不足、缺失工具、超时、预算耗尽和采样不足不能解释成正常或零占用。
- 任务有条目数、时间和输出预算；取消后丢弃旧结果、停止后续工作并回收自身拥有的读取进程。不影响其他采样需求。

## 结果约定

| 字段 | 语义 |
| --- | --- |
| 正常 | 已完成检查，在已声明范围内未发现关注项 |
| 需关注 | 存在可以展示的观测证据，不等于必须修复 |
| 可选维护 | 偏好或维护建议，不表示检测到故障 |
| 不适用 | 系统、工具或对象不适用于该检查 |
| 未检查 / 部分完成 | 缺少证据或未完成；展示原因，不给出正常结论 |
| 清理候选占用 | 现有可执行清理规则的已计量对象；仍须确认和执行前复核 |
| 预览对象占用 | 新增只读规则的已计量对象，不提供清理授权 |

CPU 判断使用两个有效采样区间，首次采样只建立基线。内存判断以系统压力和交换活动为依据，不以累计 Swap 占用单独判定异常。进程、路径和网络证据仅在本机界面展示，不记录到运行日志。

## 清理类别对照

表中迭代为交付范围分配，不代表已经实现。验收以对应源码、定向测试和实际资源验证为准。

| Mole 类别 | XStats 复用 / 新增范围 | 迭代 |
| --- | --- | --- |
| System | 复用本地快照入口；系统缓存另做只读检查 | P2 / P6 |
| User essentials | 复用缓存、日志、废纸篓；Finder 元数据和最近项目仅审阅 | P2 / P6 |
| App caches | 复用应用专属目录与运行状态保护，扩充明确缓存叶子 | P2 / P4 |
| Browsers | 复用现有六类浏览器，扩充路径与浏览器 | P2 / P4 |
| Cloud & Office | 新增已确认的缓存叶子，不扫描整个容器 | P4 |
| Developer tools | 复用现有开发工具及 Homebrew；补充工具覆盖 | P2 / P4 |
| Apps & utilities | 通信、设计、影音等应用缓存 | P4 |
| Virtualization | 缓存与虚拟磁盘分别列出，使用状态不明不判断闲置 | P4 / P5 |
| Application Support | 仅明确的日志与缓存目录 | P4 |
| App leftovers | 复用选定应用的身份保护；新增全局疑似孤儿发现 | P6 |
| Apple Silicon | 更新 / Rosetta 缓存，只读检查归属与状态 | P6 |
| Device firmware | 固件下载与设备备份分别审阅 | P6 |
| Time Machine | 复用快照入口；失败备份需状态和卷检查 | P2 / P6 |
| Large files | 复用空间分析与安装包入口，数据大小不等于垃圾 | P2 |
| Project artifacts | 复用 ProjectPurge，保留扫描根、Git 保护和预算 | P2 |

## 优化目录对照

| Mole 操作 | 预览检查 | 迭代 |
| --- | --- | --- |
| cache_refresh | QuickLook / 图标缓存占用 | P4 |
| saved_state_cleanup | 超过保留期的应用状态 | P4 |
| fix_broken_configs | 受保护范围外的 plist 解析 | P5 |
| network_optimization | DNS 维护适用性与代理环境 | P3 |
| sqlite_vacuum | 只读数据库大小和空闲页；不运行 VACUUM / checkpoint | P6 |
| prevent_network_dsstore | 网络盘 / USB Finder 偏好，可选维护 | P5 |
| legacy_overrides_audit | App Nap 与磁盘映像验证覆盖设置 | P3 |
| network_stack_optimize | 有界路由与 DNS 探测，区分离线和代理 | P5 |
| disk_permissions_repair | Home、Library、Preferences 有限权限检查 | P3 |
| spotlight_index_optimize | 索引状态、有限查询耗时 | P5 |
| spotlight_orphan_rules_cleanup | 应用归属与无效规则检查 | P5 |
| periodic_maintenance | 工具存在性与维护记录，不支持则不适用 | P5 |
| shared_file_list_repair | 共享列表解析，保护最近文档 | P5 |
| disk_verify | Mole dry-run 跳过；保留现有手动验证入口 | P2 |
| login_items_audit | 独立登录项来源，不与 LaunchAgents 混同 | P5 |
| quarantine_cleanup | 下载隔离记录数量，只读 | P6 |
| launch_agents_cleanup | 失效绝对程序路径；未挂载卷、无法解析和权限问题单列 | P3 |
| notification_cleanup | 通知数据库占用，只读 | P6 |
| coreduet_cleanup | Knowledge 数据库与附属文件占用，只读 | P6 |

目录以外的资源诊断：P3 检查持续 CPU 占用及内存压力，P5 补充虚拟机与磁盘映像归属。LaunchServices 重建与自动释放内存不属于本次预览对齐范围。

## 验收

- 仅预览项即使被调用方显式选中，执行引擎仍拒绝清理。
- 不重复累计相同对象或父子路径；工具汇总与无法确认重叠的专项不直接相加。
- 部分结果只包含完整计量对象，预算耗尽不发布部分目录大小。
- 覆盖权限、工具缺失、异常输出、应用运行、取消与重开后的旧结果。
- 各阶段执行 Cleaner / Metrics / XStatsUI / Localization 相关定向测试；发布前执行既有完整发布门禁。
- 实测空闲、运行、取消和关闭后的资源行为；未实测的性能和长期稳定性不作结论。
