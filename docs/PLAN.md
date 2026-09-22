# XStats 方案：macOS 菜单栏监控 + 系统清理

> 调研日期：2026-09-13 ｜ 开发机：macOS 27.0 / Xcode 27 / Swift 6.4 / Apple Silicon

## ⚠️ 范围调整（2026-09-13，已实现）

以下原始方案中的**清理功能已取消**，第 5 节及相关里程碑仅作存档。当前实现的范围：

| 模块 | 状态 |
|---|---|
| 菜单栏：CPU / GPU / 内存（数字、柱状图、圆环、饼图、柱状+数字五种样式）、网速两行、温度、风扇 | ✅ |
| 面板：概览仪表盘（健康评分、三列指标卡、核心负载、电池、高占用进程、快捷开关）、进程、散热、防休眠 | ✅ |
| 液态玻璃面板（macOS 26+），浅色 / 深色 / 跟随系统 | ✅ |
| 风扇调速（自动 / 降温 / 强冷 / 自定义），CPU 过热自动交还系统 | ✅ 需安装辅助工具 |
| 防休眠：屏幕常亮、仅系统不休眠、合盖后继续运行（电量保护、定时） | ✅ 合盖模式需辅助工具 |
| 温度传感器：启动时枚举 SMC 键按前缀归类，不硬编码芯片型号 | ✅ |
| Developer ID 签名、公证、Sparkle 自动更新 | ⏳ 下一阶段 |

工程结构与运行方式见根目录 [README.md](../README.md)。

---

## 0. 结论

| 决策 | 选择 | 理由 |
|---|---|---|
| 语言 / UI | Swift 6 + AppKit（`NSStatusItem`）+ SwiftUI（面板、设置页） | 菜单栏图标自绘需要 AppKit，面板用 SwiftUI 开发效率高 |
| 最低系统 | macOS 14 Sonoma | 可用 `@Observable`、`SMAppService`、`Task.sleep(for:tolerance:)` |
| 监控层 | 参考并部分移植 **exelban/stats**（MIT） | 许可证允许，保留版权声明即可 |
| 清理层 | 参考 **tw93/Mole** 的**规则与安全模型**，用 Swift **自己重写** | Mole 是 **GPL-3.0**，不能直接复制代码进非 GPL 项目（详见 §1） |
| 沙盒 | **不沙盒**，不上 Mac App Store | 清理要访问 `~/Library` 各处，温度传感器要走 IOKit/SMC，沙盒内做不到 |
| 分发 | Developer ID 签名 + 公证（notarize）+ Sparkle 2 自动更新 + Homebrew Cask | Stats 与 Mole 都是这条路 |
| 工程组织 | Xcode App 工程 + 本地 Swift Package（多 target） | 采集、清理、UI 分离，便于单测 |

---

## 1. 参考项目核查（有几处需要纠正）

| 项目 | 核查结果 | 能怎么用 |
|---|---|---|
| [exelban/stats](https://github.com/exelban/stats) | MIT，Swift，约 4.2 万 Star，2026-09 仍在更新 | ✅ 可移植代码，需在 `LICENSE`/致谢页保留 `Copyright © Serhiy Mytrovtsiy`。注意作者声明“开源但不接受贡献” |
| [tw93/Mole](https://github.com/tw93/Mole) | **GPL-3.0**（不是 MIT），Shell + Go，约 6.7 万 Star；另有 `TRADEMARK.md` 商标声明；它的 GUI 版“Mole for Mac”是闭源商业产品 | ⚠️ 不能把它的脚本/Go 代码搬进 MIT 或闭源项目；可以参考思路、清理目录清单、安全设计（这些是事实和设计，不是代码表达）。不能用 “Mole” 名称 |
| mhaeuser/Battery-Toolkit | BSD-3-Clause，Swift | ✅ 参考特权辅助进程（Privileged Helper）+ XPC 的规范写法 |
| Sam-Spencer/bar-charts | **GitHub 上不存在**（API 返回 404） | ❌ 忽略。图表直接用系统自带 Swift Charts 即可 |
| 补充：vladkens/macmon | MIT，Rust | ✅ Apple Silicon 下无需 sudo 读功耗 / GPU 的 `IOReport` 用法参考 |

**关于 Mole 的两条路**

- **A（推荐）：项目用 MIT，清理模块自己用 Swift 实现。** 只把 Mole 当“需求说明书”：看它清哪些目录、有哪些保护规则、踩过哪些坑（`SECURITY_AUDIT.md` 很有价值），然后自己写。
- B：项目整体采用 GPL-3.0，就可以直接移植 Mole 的逻辑，甚至打包调用 `mo` CLI。代价是整个 App 必须开源为 GPL，以后无法闭源或商业授权；而且调用 Shell 脚本在 GUI 里做进度、取消、错误处理都很别扭。

---

## 2. 功能范围

### MVP（第 1 阶段）
- 菜单栏：CPU 百分比 + 迷你折线（可选显示内存、网速）
- 弹出面板：CPU 总量 / 用户态 / 内核态、每核心（区分 P 核 / E 核）、Top 5 进程；内存（App / 联动 / 压缩 / 内存压力）；实时网速
- 清理（仅用户态，无需管理员密码）：扫描 → 分类预览 → 勾选 → **移到废纸篓** → 记录日志
- 设置：刷新频率、菜单栏显示项、开机自启（`SMAppService.mainApp`）

### V1（第 2 阶段）
- GPU 使用率、温度、功耗、风扇转速、电池健康度、磁盘读写与剩余空间
- 清理扩展：开发者缓存（Xcode / npm / pnpm / Homebrew…）、项目构建产物（`node_modules`、`target`）、安装包（`.dmg/.pkg`）、大文件查找
- 应用卸载（连带清理偏好设置、缓存、LaunchAgent）
- 白名单、历史记录、通知（CPU 持续过高、磁盘将满）

### V2（第 3 阶段）
- 需要 root 的操作：刷新 DNS、系统日志清理、Time Machine 本地快照 → 通过 `SMAppService.daemon` 安装特权辅助进程 + XPC
- 磁盘占用可视化（类似 `mo analyze`，树图）
- 桌面小组件（WidgetKit）

---

## 3. 总体架构

```
┌──────────────────────────── XStats.app（主进程，非沙盒）────────────────────────────┐
│                                                                                       │
│  UI 层（@MainActor）                                                                   │
│  ├─ StatusItemController   NSStatusItem，自绘 NSImage（数字 + 迷你图），不用 SwiftUI 重建  │
│  ├─ PopoverPanel           NSPanel/NSPopover 承载 SwiftUI：监控页 / 清理页 / 设置入口     │
│  └─ SettingsWindow         SwiftUI Settings                                           │
│                 ▲ @Observable 状态（只存“最新值 + 环形缓冲历史”）                         │
│                 │                                                                     │
│  调度层（actor MetricsHub）                                                            │
│  ├─ 分级：menuBar 档（2s，只跑 CPU 总量/网速）  popover 档（1s，全量 + 进程列表）          │
│  ├─ 暂停：锁屏 / 屏幕休眠 / 系统睡眠时停止；低电量模式下降频                              │
│  └─ Samplers：CPU / Memory / Network / GPU / Sensors / Battery / Disk / Process        │
│                                                                                       │
│  清理层（actor CleanEngine）                                                           │
│  ├─ RuleCatalog     清理规则（数据化，Swift 静态表或 JSON）                               │
│  ├─ Scanner         并发扫描计算大小（只读，可取消）                                      │
│  ├─ SafetyGuard     路径校验 / 保护名单 / 符号链接 / 运行中应用检测 / 白名单                │
│  ├─ Executor        trashItem（默认）或 removeItem（用户显式选择）                        │
│  └─ OperationLog    ~/Library/Logs/XStats/operations.jsonl                         │
│                                                                                       │
└──────────────────────────────────────┬────────────────────────────────────────────────┘
                                       │ XPC（NSXPCConnection，V2 才需要）
                          ┌────────────▼─────────────┐
                          │ PrivilegedHelper（root）   │  SMAppService.daemon 注册
                          │ 只接受白名单内的固定操作     │  校验调用方签名（Team ID）
                          └──────────────────────────┘
```

### 工程目录

```
xstats/
├─ XStats.xcodeproj
├─ App/                         # App target：AppDelegate、StatusItem、窗口管理
├─ Packages/XStatsKit/       # 本地 Swift Package
│  ├─ Sources/
│  │  ├─ Metrics/               # 各 Sampler + MetricsHub（纯逻辑，可单测）
│  │  ├─ SMCBridge/             # C/ObjC 桥接：SMC、IOHIDEventSystemClient、IOReport
│  │  ├─ Cleaner/               # RuleCatalog、Scanner、SafetyGuard、Executor
│  │  ├─ DesignSystem/          # 颜色 / 字号 / 间距 token
│  │  └─ Features/              # SwiftUI 页面：MonitorView、CleanView、SettingsView
│  └─ Tests/
├─ Helper/                      # V2：特权辅助进程
├─ ThirdPartyNotices.md         # Stats 的 MIT 版权声明
└─ docs/
```

---

## 4. 监控层：每个指标从哪里读

| 指标 | API | 要点 / 坑 |
|---|---|---|
| CPU 总量 & 每核 | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`，两次采样取差值 | 返回的数组是内核分配的，**每次必须 `vm_deallocate`**，否则持续泄漏；计数器用 `&-` 防回绕 |
| P 核 / E 核划分 | `sysctl hw.perflevel0.logicalcpu`（P）/ `hw.perflevel1.logicalcpu`（E） | 核心编号顺序：Apple Silicon 上 E 核通常在前，按 perflevel 数量切分 |
| 内存 | `host_statistics64(HOST_VM_INFO64)` | 与活动监视器同口径：App = `internal - purgeable`，已用 = App + wired + compressed；页大小用 `host_page_size()`（Apple Silicon 为 16K） |
| 内存压力 | `sysctl kern.memorystatus_vm_pressure_level`（1/2/4） | 需要事件时可叠加 `DispatchSource.makeMemoryPressureSource` |
| 网速 | `sysctl(NET_RT_IFLIST2)` → `if_msghdr2.ifm_data`（`if_data64`） | ⚠️ 纠正原文：`getifaddrs` 里的 `if_data.ifi_ibytes` 是 **32 位**，流量超过 4 GiB 会回绕，应改用 64 位计数器 |
| 进程列表 | `proc_listallpids` + `proc_pid_rusage(RUSAGE_INFO_V4)` / `proc_pidinfo(PROC_PIDTASKINFO)` | 只在面板展开时跑；CPU% 同样靠两次 `ri_user_time + ri_system_time` 差值 |
| GPU 使用率 | `IOServiceMatching("IOAccelerator")` → `PerformanceStatistics["Device Utilization %"]` | Stats 的 `Modules/GPU/reader.swift` 可直接参考 |
| 温度（Apple Silicon） | `IOHIDEventSystemClient` 私有 API（`kIOHIDEventTypeTemperature`）+ SMC 键 | 私有 API，需 ObjC/C 桥接头；参考 Stats `Modules/Sensors/reader.m` |
| 功耗 / GPU 频率 | `IOReport`（`libIOReport.dylib`，“Energy Model”、“GPU Stats” 通道） | 无需 sudo；参考 macmon |
| 风扇 | SMC 键 `FNum`、`F0Ac` | 读取无需 root；**写入（调速）需要 root helper**，建议不做或放到最后 |
| 电池 | `IOPSCopyPowerSourcesInfo` + `IOServiceMatching("AppleSmartBattery")` | 循环次数、设计容量、当前最大容量 |
| 磁盘空间 | `URLResourceValues.volumeAvailableCapacityForImportantUsage` | 比 `statfs` 更接近 Finder 显示（含可清除空间） |
| 磁盘读写 | `IOBlockStorageDriver` 的 `Statistics` 字典 | 两次采样取差值 |

### 功耗预算（硬指标）

| 场景 | 目标 |
|---|---|
| 面板关闭，只显示 CPU | 平均 CPU < 0.3%，常驻内存 < 40 MB |
| 面板展开，全量 | 平均 CPU < 2% |
| 锁屏 / 屏幕休眠 | 采样完全停止 |

实现手段：
1. **分级采样**：面板关闭时只跑 CPU 总量和网速；进程列表、温度、GPU 仅面板展开时启用（温度传感器是 Stats 里最耗电的模块）。
2. **定时器合并**：`Task.sleep(for:tolerance:)` 给 0.5s 容差，让系统合并唤醒。
3. **菜单栏自绘**：每次刷新只重画一张小 `NSImage` 赋给 `statusItem.button.image`，不在菜单栏里挂 SwiftUI 视图（后者每秒重建开销大）。
4. **历史数据用固定大小环形缓冲**（例如 60 个点），不做持久化数据库。
5. 监听 `NSWorkspace.screensDidSleepNotification` / `willSleepNotification` / `com.apple.screenIsLocked` 暂停；`ProcessInfo.isLowPowerModeEnabled` 时降到 5s。
6. 用 Instruments 的 **Energy Log / Time Profiler** 与活动监视器“能耗影响”列做回归测试。

---

## 5. 清理层设计（参考 Mole，Swift 重写）

### 5.1 流程

```
扫描（只读、并发、可取消）→ 分类展示大小 → 用户勾选 → 二次确认 → SafetyGuard 逐项再校验
 → 移到废纸篓（默认）/ 永久删除（需用户显式开启）→ 写操作日志 → 显示释放空间
```

所有删除只走 **一个出口函数**（对应 Mole 的 `safe_remove`），便于审计和测试。

### 5.2 规则数据化

```swift
struct CleanRule: Identifiable, Sendable {
    enum Risk: Sendable { case safe, review }         // safe 默认勾选，review 默认不勾选
    enum Requirement: Sendable { case none, fullDiskAccess, admin }

    let id: String                 // "user.caches"
    let category: Category         // .system / .browser / .developer / .apps / .downloads
    let title: LocalizedStringResource
    let paths: [PathPattern]       // ~/Library/Caches/*、~/Downloads/*.crdownload
    let minAge: Duration?          // 如 7 天内修改过的跳过
    let skipIfAppRunning: [String] // bundle id，运行中则跳过
    let risk: Risk
    let requirement: Requirement
    let postAction: PostAction?    // 例如调用 `xcrun simctl delete unavailable`
}
```

### 5.3 首批规则（参考 Mole 实际清理的目录整理）

| 分类 | 目录 / 操作 | 风险 | 备注 |
|---|---|---|---|
| 系统 | `~/Library/Caches/*` | safe | **所属应用正在运行则跳过**（Mole 踩过坑：删除正在使用的 SQLite 缓存会让进程写满磁盘） |
| 系统 | `~/Library/Logs/*`、`~/Library/Application Support/CrashReporter` | safe | |
| 系统 | `~/.Trash` | review | 调用 Finder 清空更稳妥 |
| 浏览器 | Chrome / Edge / Brave / Arc / Firefox 的 **Cache、Code Cache、GPUCache** 子目录 | safe | ❌ 绝不碰 Cookies、History、Login Data；浏览器运行中跳过 |
| 浏览器 | Chromium 系旧版本目录（`…/Versions/<旧版本>`） | safe | |
| 下载 | `~/Downloads/*.crdownload`、`*.part`、`*.download` | safe | 用 `lsof` 或文件修改时间确认未在下载 |
| 下载 | `~/Downloads/*.dmg / *.pkg / *.xip` | review | 列出让用户选 |
| 邮件 | `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads` | safe | 需要完全磁盘访问权限 |
| 开发 | `~/Library/Developer/Xcode/DerivedData` | safe | |
| 开发 | `~/Library/Developer/Xcode/Archives`、iOS DeviceSupport | review | |
| 开发 | 模拟器：`xcrun simctl delete unavailable` | safe | 调用命令而不是直接删目录 |
| 开发 | npm `~/.npm/_cacache`、pnpm `~/Library/pnpm/store`、yarn、pip `~/Library/Caches/pip`、Go `go clean -modcache`、Homebrew `brew cleanup` | safe | 优先调用各工具自带清理命令 |
| 开发 | Maven `~/.m2/repository`、Gradle `~/.gradle/caches`、NuGet、conda pkgs | review | 删除后需重新下载 |
| 项目产物 | 用户指定目录下的 `node_modules`、`target`、`build`、`dist`、`.next` | review | 7 天内修改过的标记为“最近使用”；避免父子目录重复删除 |
| 云盘 | Dropbox / Google Drive / OneDrive 缓存 | review | 客户端运行中跳过 |
| 备份 | `~/Library/Application Support/MobileSync/Backup` | review | **只提示，不默认勾选** |

### 5.4 SafetyGuard 规则（照搬 Mole 的安全边界思路）

1. 拒绝：空路径、相对路径、含 `..` 路径段、含控制字符的路径。
2. 保护前缀永不删除：`/`、`/System`、`/bin`、`/sbin`、`/usr`、`/etc`、`/var`、`/private`、`/Library/Extensions`；仅放行 `/private/tmp`、`/private/var/folders` 等少数子路径。
3. **符号链接**：解析后的真实路径也要过一遍拒绝规则，而且解析结果只能“更严格”不能“放行”；父目录是符号链接也要检查。
4. 保护类别：钥匙串、密码管理器、VPN/代理工具（Clash、Tailscale、WireGuard…）、AI 工具数据（Claude、ChatGPT、Cursor、Ollama）、浏览器 Cookie/历史、iCloud `Mobile Documents`、`~/Library/Messages`、Apple 自带 Group Containers、用户自己的 `~/Library/LaunchAgents/*.plist`。
5. 执行前再次校验（扫描和删除之间可能过了几分钟，应用可能已启动）。
6. 判断不了就**跳过**，不扩大删除范围。

### 5.5 权限

- **完全磁盘访问（FDA）**：尝试读取受 TCC 保护的文件（如 `~/Library/Safari/Bookmarks.plist`）判断是否已授权；未授权时引导打开 `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`。没有 FDA 时对应规则显示为“需要授权”，不报错。
- **管理员权限**（V2）：`SMAppService.daemon(plistName:)` 注册 helper，XPC 协议只暴露固定的枚举操作（如 `.flushDNS`、`.cleanSystemLogs`），**绝不暴露“删除任意路径”接口**；helper 端校验调用方代码签名。

---

## 6. 技术选型清单

| 用途 | 选择 | 备注 |
|---|---|---|
| 菜单栏 | `NSStatusItem` + 自绘 `NSImage` | 不用 `MenuBarExtra`：label 不能自由绘图、点击行为难控制 |
| 弹出面板 | `NSPanel`（非激活、点击外部关闭）+ `NSHostingView` | 比 `NSPopover` 动画和定位更可控；想省事可先用 `NSPopover` |
| 状态管理 | Observation（`@Observable`） | |
| 并发 | Swift 6 严格并发，采样和清理放 `actor` | UI 更新 `@MainActor` |
| 图表 | Swift Charts | 面板内的历史曲线；菜单栏迷你图用 Core Graphics 自绘 |
| 设置存储 | `UserDefaults` + `@AppStorage` | |
| 开机自启 | `SMAppService.mainApp.register()` | 不需要单独的 LaunchAtLogin helper |
| 自动更新 | Sparkle 2 | 通过 SPM 引入 |
| 快捷键 | sindresorhus/KeyboardShortcuts（MIT） | 可选 |
| 图标 | 默认使用 SF Symbols；工具和网站可使用有来源声明的品牌标志 | 16pt 行内 / 20pt 独立 |
| 日志 | `os.Logger` + 清理操作 JSONL 文件 | |
| 测试 | Swift Testing；清理用临时目录做沙箱测试 | SafetyGuard 必须覆盖符号链接、`..`、保护路径等用例 |
| CI | GitHub Actions `macos-latest`：构建、测试、签名、公证、生成 DMG | 用 `xcrun notarytool` |

### 界面设计 token（与你的全局设计规范一致）

- 颜色：`primary` / `secondary` / `neutral` 灰阶 / `success` / `warning` / `error`，定义在 Asset Catalog 并提供深色变体；CPU 负载颜色：< 60% 中性色，60–85% `warning`，> 85% `error`
- 字号：12 / 14 / 16 / 20 / 24 / 32；间距：4 / 8 / 12 / 16 / 24 / 32
- 圆角：统一 token（如 `radius.sm = 6`、`radius.md = 10`、`radius.lg = 14`）区分卡片 / 面板
- 卡片只用边框或阴影之一；不用渐变、不用毛玻璃（系统面板自带材质除外）

---

## 7. 关键代码骨架

完整可运行版本见 [prototype/Samplers.swift](prototype/Samplers.swift)（本机实测输出：`CPU total 25.7% … cores=18`、`MEM used 43775MB / 65536MB … pressure=1`、`NET rx 692486 B/s`，进程常驻内存约 6.6 MB）。

### 7.1 应用入口与菜单栏

```swift
import AppKit
import SwiftUI

@main
struct XStatsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { SettingsView() } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MetricsStore()          // @Observable，UI 读取
    private let hub = MetricsHub()
    private var statusItem: NSStatusItem!
    private var panel: StatusPanel!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // 不显示 Dock 图标（也可在 Info.plist 设 LSUIElement）
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        panel = StatusPanel(rootView: MonitorView().environment(store))
        panel.onVisibilityChange = { [hub] visible in
            Task { await hub.setTier(visible ? .popover : .menuBar) }
        }

        Task {
            await hub.start { [weak self] cpu, mem, net in
                guard let self else { return }
                store.apply(cpu: cpu, memory: mem, network: net)
                statusItem.button?.image = MenuBarRenderer.image(cpu: store.cpuHistory, network: net)
            }
        }
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        panel.toggle(relativeTo: button)
    }
}
```

### 7.2 CPU 采样（节选）

```swift
struct CPUSampler: Sampler {
    private var prevTicks: [[UInt32]] = []

    mutating func sample() -> CPULoad? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {   // 内核分配的内存必须归还
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        // …读取每核 user/system/nice/idle，与上一次做差值…
    }
}
```

### 7.3 调度器（分级采样）

```swift
actor MetricsHub {
    private var cpu = CPUSampler()
    private var mem = MemorySampler()
    private var net = NetworkSampler()
    private var tier: SampleTier = .menuBar
    private var loop: Task<Void, Never>?

    func setTier(_ t: SampleTier) { tier = t }

    func start(onUpdate: @escaping @MainActor @Sendable (CPULoad?, MemoryUsage?, NetRate?) -> Void) {
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                let c = cpu.sample(), n = net.sample()
                let m = tier == .popover ? mem.sample() : nil   // 面板关闭时不读细节
                await onUpdate(c, m, n)
                try? await Task.sleep(for: tier == .popover ? .seconds(1) : .seconds(2),
                                      tolerance: .milliseconds(500))
            }
        }
    }
}
```

### 7.4 清理执行出口

```swift
actor CleanEngine {
    func execute(_ items: [CleanItem], mode: DeleteMode) async -> CleanReport {
        var report = CleanReport()
        for item in items {
            do {
                try SafetyGuard.validate(item.url)                         // 执行前再校验一次
                if try await RunningAppProbe.isInUse(item) { report.skipped(item, .inUse); continue }
                switch mode {
                case .trash:  try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                case .delete: try FileManager.default.removeItem(at: item.url)
                }
                report.cleaned(item)
            } catch {
                report.failed(item, error)
            }
            OperationLog.append(item, result: report.last)
        }
        return report
    }
}
```

---

## 8. 里程碑

| 周 | 交付 |
|---|---|
| 第 1 周 | 工程搭建（App + 本地 Package）、`NSStatusItem` 自绘 CPU、`MetricsHub` 分级调度、锁屏暂停 |
| 第 2 周 | 弹出面板：CPU 每核（P/E）、内存、网速、Top 进程；Swift Charts 历史曲线；设置页、开机自启 |
| 第 3 周 | 清理引擎：`SafetyGuard` + 单测、规则表（系统 / 浏览器 / 下载 / Xcode）、扫描与预览 UI、废纸篓执行、操作日志 |
| 第 4 周 | FDA 权限引导、白名单、Energy Log 功耗回归、签名 + 公证 + Sparkle + DMG 打包，发布 0.1 |
| 第 5–6 周 | V1：GPU / 温度 / 功耗（IOHID + IOReport 桥接）、电池、磁盘、开发者缓存与项目产物清理、应用卸载 |
| 之后 | V2：特权 helper（DNS、系统日志）、磁盘占用可视化、小组件 |

---

## 9. 风险

| 风险 | 应对 |
|---|---|
| 误删用户数据 | 默认只移到废纸篓；review 类默认不勾选；单一删除出口 + 单测；操作日志可追溯 |
| 私有 API（IOHID 温度、IOReport）随系统更新失效 | 封装在 `SMCBridge` 内，读取失败时隐藏对应模块而不是崩溃；每个 macOS beta 回归 |
| 自身耗电过高 | §4 功耗预算作为发布门槛，CI 外手动跑 Energy Log |
| 许可证 | Stats 代码保留 MIT 声明并写入 `ThirdPartyNotices.md`；Mole 只参考不复制 |
| 公证被拒 | 开启 Hardened Runtime；私有框架用 `dlopen` 动态加载；不申请不必要的 entitlement |
