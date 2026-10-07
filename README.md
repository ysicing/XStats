<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

**把系统状态与常用工具，放进 Mac 菜单栏。**

一眼查看 CPU、内存、网络与温度，展开了解趋势和应用占用。
需要时，再开启 AI 用量、日历、风扇控制与清理工具。

[![Release](https://img.shields.io/badge/%E7%89%88%E6%9C%AC-0.15.0-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20%E8%8A%AF%E7%89%87-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[下载最新版](https://github.com/ysicing/xstats/releases) · [界面预览](#界面预览) · [功能亮点](#功能亮点) · [安装](#安装) · [更新日志](CHANGELOG.md)

**简体中文** · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

<img src="Assets/readme/menubar-dark.png" width="626" alt="XStats 菜单栏读数">

</div>

## 界面预览

主窗口集中查看系统状态，浅色与深色界面跟随你的偏好。

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats 深色仪表盘">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats 浅色仪表盘">
</p>

## 功能亮点

XStats 使用 Swift、AppKit 与 SwiftUI 原生开发，免费开源，无需注册 XStats 账号。显示哪些指标、使用哪些工具，都由你决定。

### 菜单栏显示，你来决定

- **独立显示**：为常看的指标保留各自的菜单栏入口。
- **合并显示**：将多个读数放在一组，点开查看状态总览。
- **仅图标**：只保留一个 XStats 图标，展开后查看所选项目。

显示项目、排列顺序和样式都能调整。指标按支持的样式提供文字、图标、圆环、进度条或历史图；不用的项目可以关闭。

### 系统监控，展开查看详情

| 模块 | 可以查看什么 |
|---|---|
| **CPU** | 用户 / 系统 / 空闲占用、逐核负载圆环、核心组占用、负载平均，以及可读取的频率与温度；热压力来自 macOS，异常时突出提示 |
| **GPU** | 图形负载、图形核心等硬件信息，以及可读取的温度与功耗 |
| **内存** | 内存压力、应用与压缩内存、缓存、交换空间与换入换出速率 |
| **磁盘** | 容量、读写速率、应用读写排行，以及可读取的 SMART 健康信息 |
| **网络** | 上传 / 下载速率、网络接口与连接概况 |
| **电池与蓝牙** | 电池电量、供电状态、健康度与循环次数；支持的蓝牙设备电量，无电池的 Mac 也可在菜单栏查看 |
| **温度与风扇** | 多组温度传感器、风扇转速与可用的功耗信息 |
| **显示器** | 型号、分辨率、缩放分辨率、刷新率；支持的外接屏可调节亮度、对比度与音量 |

CPU 核心类型由系统报告，按实际的超级核、性能核和能效核分组，不按机型固定两组或三组。“本机信息”还提供机型、系统版本和运行时间。

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="49%" alt="CPU 占用与核心详情">
  <img src="Assets/readme/popover-memory-dark.png" width="49%" alt="内存构成与压力详情">
</p>

**外接显示器控制**依赖显示器、线材和连接方式的 DDC/CI 支持，各控制项独立检测。不支持或暂时无法读取时会显示状态，支持的项目才提供滑杆。

### 网络监视器：按应用查看连接

> 以下网络监视器功能与截图来自当前开发分支，正在为 **1.0.0 稳定版**做准备；当前公开版本仍见页面顶部的版本标识。

- **默认关闭，macOS 15+ 可选启用**：首次启用时提示安装独立的 XStats Network Monitor 组件，安装成功后继续启用，并按 macOS 提示授权网络扩展。
- **连接总览**：查看全部连接，或按应用、进程、域名、国家或地域汇总；支持搜索、活动连接筛选与暂停／恢复。
- **世界地图**：展示观察到的新连接的国家或地域分布，位置为国家级代表位置，不是设备精确位置。
- **只读与按需运行**：全部连接放行，不读取通信内容；仅在页面可见且未暂停时读取，最多保留 512 条内存记录，不保存连接历史。
- **组件管理**：在“设置 → 功能 → 网络监视器 → 管理组件”中查看状态、检查更新或卸载；组件独立更新，主程序无需内置网络扩展。

<p align="center">
  <img src="Assets/readme/connections-zh-Hans-light.png" width="49%" alt="网络监视器浅色连接总览，演示数据">
  <img src="Assets/readme/connections-zh-Hans-dark.png" width="49%" alt="网络监视器深色连接总览，演示数据">
</p>

截图使用虚构连接与文档示例地址。首次使用地图时下载公共 IP 地理数据库，随后离线查询；不会把连接目标 IP 发送给地理查询服务。重新开始观察之前已建立的连接不会被补录。

### AI 用量与订阅额度

在菜单栏看 Codex / Claude Code 用量，展开后查看统计与额度：

- **Token 统计**：今天按小时、最近 7 天 / 30 天按天展示；主窗口还提供年度活动热力图。
- **订阅额度**：可切换已用 / 剩余百分比，查看重置时间，以及来源提供的套餐、有效期和可用重置次数等信息。
- **费用估算**：按模型公开 API 基础单价估算，支持美元 / 人民币；不含阶梯加价，也不代表订阅账单。
- **显示偏好**：自选刷新间隔，数字单位支持中文万 / 亿与 K / M / B。

AI 用量默认关闭。本机统计读取 Codex / Claude Code 会话日志；查询订阅额度需要相应 CLI 已登录，也可手动配置 Sub2API 作为备用来源。

### 常用工具，按需开启

- **风扇控制**：查看运行状态，在支持的设备上切换自动或手动控制。
- **防休眠**：保持系统或屏幕唤醒，需要时配置合盖运行。
- **清理与卸载**：清理缓存、项目产物与应用相关文件；先预览再确认，也可选择移到废纸篓。
- **启动项管理**：查看和管理登录项目及后台启动项。
- **网络诊断**：按需测速、查询 DNS、检测出口、公网 IP 归属地与纯净度，并探测目标连通情况。
- **菜单栏日历**：农历、节假日与调休、黄历；授权后可查看系统日程和提醒事项。
- **音频**：默认关闭；支持系统音量、静音与输出/输入设备切换；已配对的蓝牙音频设备可在选择后尝试连接，就绪后切换。macOS 14.4 及以上授权后可调节正在播放声音的应用音量（0–200%）、静音、独立输出与恢复；音频仅在本机实时处理，不录制或上传。设备不支持的音量控制显示说明。
- **番茄钟与护眼休息**：专注与休息计时、多屏休息幕布，可暂停、跳过或收起到迷你 HUD。
- **进程管理**：启用后查看全部进程，支持搜索、排序、按应用分组与结束进程。

清理、进程、日历、番茄钟与 AI 用量默认关闭，需要时再启用。风扇控制、合盖防休眠等特权操作需要在应用内安装并授权辅助工具。

<details>
<summary>查看更多工具截图</summary>

<p align="center">
  <img src="Assets/readme/thermal-dark.png" width="49%" alt="温度与风扇控制">
  <img src="Assets/readme/keepawake-light.png" width="49%" alt="防休眠设置">
</p>
<p align="center">
  <img src="Assets/readme/cleaner-light.png" width="49%" alt="清理预览">
  <img src="Assets/readme/ip-purity-light.png" width="49%" alt="公网 IP 与纯净度检测">
</p>


下列新增截图中的用量、额度、单价、设备状态和日程均为演示数据，不代表个人数据或当前价格。

<p align="center">
  <img src="Assets/readme/ai-usage-zh-Hans-light.png" width="49%" alt="AI 用量与统计">
  <img src="Assets/readme/history-zh-Hans-dark.png" width="49%" alt="历史趋势">
</p>

<p align="center">
  <img src="Assets/readme/audio-zh-Hans-light.png" width="49%" alt="音频与应用混音">
  <img src="Assets/readme/displays-zh-Hans-dark.png" width="49%" alt="外接显示器控制">
</p>

<p align="center">
  <img src="Assets/readme/calendar-zh-Hans-light.png" width="49%" alt="菜单栏日历">
  <img src="Assets/readme/rest-zh-Hans-dark.png" width="49%" alt="番茄钟与护眼休息">
</p>

</details>

### 启动器与深链

支持 `xstats://` 链接，可从能打开 URL 的启动器、快捷指令或终端调用常用入口：

```bash
open 'xstats://open/connections'       # 打开网络监视器
open 'xstats://open/audio'             # 打开音频页
open 'xstats://panel/cpu'              # 显示 CPU 弹窗
open 'xstats://rest/start'             # 开始或继续番茄钟
open 'xstats://keep-awake/start'       # 开启普通防休眠
```

重复打开保持当前窗口或弹窗可见；已关闭的模块会转到设置，不会被链接隐式启用。
完整路径与操作见 [深链协议](docs/DEVELOPMENT.md#xstats-深链)。

### 桌面小组件与多语言

小组件包括系统概览、番茄钟、AI 额度、日历与整月日历、明天上班吗、IP 纯净度和公网 IP。

界面支持 **9 种语言**：简体中文、繁體中文、English、日本語、한국어、Deutsch、Español、Français、العربية。

## 安装

需要 **Apple Silicon Mac、macOS 14 或更新版本**。

**Homebrew**：

```bash
brew tap ysicing/tap
brew trust ysicing/tap
brew install --cask xstats
```

之后可运行 `brew upgrade --cask xstats` 更新。

**直接下载**：从 [GitHub Releases](https://github.com/ysicing/xstats/releases) 下载 DMG，打开后将 XStats 拖入“应用程序”并启动。

应用内置更新检查，发现新版本后，由你决定是否下载安装。源码构建方式见[开发指南](docs/DEVELOPMENT.md)。

## 数据与隐私

监控数据、本机历史与 AI Token 统计在本机处理，不上传到 XStats 更新服务。以下功能会连接外部服务，可关闭或按需使用：

- **检查更新**：发送当前版本与安装标识的哈希，获取更新清单。
- **查询 AI 额度**：使用本机 CLI 登录查询对应服务；手动配置备用来源后，查询你指定的服务器。
- **费用估算**：按需获取公开模型单价与参考汇率，不发送会话日志或 Token 统计。
- **网络监视器**：下载组件及公共地理数据库时会联网；连接记录和目标 IP 不上传。
- **网络诊断**：公网 IP、归属地、测速、DNS、连接探测与全球探针会请求相应服务；全球探针的测量目标与结果可能被他人查询。

完整说明见[隐私政策](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.zh-Hans.md)和[服务条款](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.zh-Hans.md)。

## 构建与贡献

需要 Xcode 26+、Go 1.25+、[Go Task](https://taskfile.dev/) 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。常用命令：

```bash
task test
task build BUMP=0 INSTALL=0
```

欢迎提交 Issue 和 Pull Request。开发环境与发布流程见 [DEVELOPMENT.md](docs/DEVELOPMENT.md)，模块边界与实现约束见 [ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 版本记录

<!-- changelog:start -->
<!-- 由 scripts/sync_changelog.py 从 CHANGELOG.md 生成，请勿手改。 -->

最新版本 **0.15.0**（2026-10-05） · 开发中 **6** 项改动尚未发布 · [完整更新日志](CHANGELOG.md)

<!-- changelog:end -->

## 致谢与许可

XStats 基于 [OpenStats](https://github.com/gentpan/OpenStats) 开发。感谢原项目及其他开源项目的贡献；来源、许可和版权信息见 [ThirdPartyNotices.md](ThirdPartyNotices.md)。XStats 是独立的第三方应用，与 Apple 及其他提及的公司没有隶属关系。

XStats 新增代码与修改采用 **AGPL-3.0-or-later**，见 [LICENSE](LICENSE) 和 [LICENSING.md](LICENSING.md)。OpenStats 上游代码保留原 [MIT 许可](LICENSES/OpenStats-MIT.txt)。
