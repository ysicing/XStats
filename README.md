<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

**Mac 菜单栏里的系统监控与常用工具。**

CPU、内存、网络与温度一眼可见，展开即可查看趋势与应用占用；AI 用量、日历、风扇控制等工具按需启用。

[![Release](https://img.shields.io/github/v/tag/ysicing/xstats?label=version&style=flat-square)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20%E8%8A%AF%E7%89%87-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)
[![Twitter](https://img.shields.io/badge/follow-YsiCing-red?style=flat-square&logo=Twitter)](https://twitter.com/YsiCing)

[下载最新版](https://github.com/ysicing/xstats/releases) · [功能](#功能) · [安装](#安装) · [数据与隐私](#数据与隐私) · [更新日志](CHANGELOG.md)

**简体中文** · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

<img src="Assets/readme/menubar-dark.png" width="626" alt="XStats 菜单栏读数">

</div>

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats 深色仪表盘">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats 浅色仪表盘">
</p>

## 功能

XStats 使用 Swift、AppKit 与 SwiftUI 原生开发，免费开源，无需注册账号。

### 菜单栏布局

指标可**独立显示**、**合并为一组**或**仅保留一个图标**。显示项目、顺序与样式（文字、图标、圆环、进度条、历史图）均可自定义。

### 系统监控

| 模块 | 内容 |
|---|---|
| **CPU** | 用户 / 系统 / 空闲占用、逐核与核心组负载、负载平均、频率与温度、热压力提示 |
| **GPU** | 图形负载、核心数、温度与功耗 |
| **内存** | 内存压力、应用 / 压缩 / 缓存构成、交换空间与换入换出速率 |
| **磁盘** | 容量、读写速率、应用读写排行、SMART 健康信息 |
| **网络** | 上传 / 下载速率、网络接口与连接概况 |
| **电池与蓝牙** | 电量、供电状态、健康度、循环次数与蓝牙设备电量 |
| **温度与风扇** | 温度传感器、风扇转速与功耗 |
| **显示器** | 分辨率、缩放与刷新率；支持 DDC/CI 的外接屏可调节亮度、对比度与音量 |

频率、温度、功耗等读数取决于机型和系统是否提供。

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="49%" alt="CPU 占用与核心详情">
  <img src="Assets/readme/popover-memory-dark.png" width="49%" alt="内存构成与压力详情">
</p>

### 网络监视器

> 即将随 **1.0** 发布，以下功能与截图来自开发分支。

按应用、进程、域名或国家/地域查看网络连接，支持搜索、活动连接筛选与世界地图分布。

- **只读**：全部连接放行，不读取通信内容，不保存连接历史。
- **按需运行**：仅在页面可见且未暂停时读取，内存中最多保留 512 条记录。
- **独立组件**：macOS 15+ 可选启用；首次启用时安装 XStats Network Monitor 组件并授权网络扩展，组件独立更新。

<p align="center">
  <img src="Assets/readme/connections-zh-Hans-light.png" width="49%" alt="网络监视器浅色连接总览，演示数据">
  <img src="Assets/readme/connections-zh-Hans-dark.png" width="49%" alt="网络监视器深色连接总览，演示数据">
</p>

截图为演示数据。地图使用离线 IP 地理数据库，定位到国家或地域，不代表设备精确位置。

### AI 用量

在菜单栏查看 Codex / Claude Code 用量：

- **Token 统计**：今日按小时、近 7 / 30 天按天统计，并提供年度活动热力图。
- **订阅额度**：已用 / 剩余百分比、重置时间与套餐信息；可配置 Sub2API 作为备用来源。
- **费用估算**：按公开 API 基础单价估算，支持美元 / 人民币，不代表订阅账单。

本机统计读取 CLI 会话日志；查询额度需要对应 CLI 已登录。

### 工具

| 工具 | 说明 |
|---|---|
| **风扇控制** | 在支持的设备上切换自动或手动控制 |
| **防休眠** | 保持系统或屏幕唤醒，可配置合盖运行 |
| **清理与卸载** | 清理缓存、项目产物与应用残留，先预览再确认 |
| **启动项** | 管理登录项目与后台启动项 |
| **网络诊断** | 测速、DNS 查询、出口检测、公网 IP 归属地与纯净度、连通性探测 |
| **菜单栏日历** | 农历、节假日与调休、黄历，以及系统日程和提醒事项 |
| **音频** | 系统音量与输入 / 输出设备切换；macOS 14.4+ 可按应用调节音量与输出，仅在本机处理 |
| **番茄钟与护眼休息** | 专注与休息计时、多屏休息幕布、迷你 HUD |
| **进程管理** | 搜索、排序、按应用分组与结束进程 |

可选模块默认关闭，可在设置中启用。风扇控制、合盖防休眠等特权操作需要在应用内安装并授权辅助工具。

<details>
<summary>更多截图</summary>

截图中的用量、额度、单价、设备状态和日程均为演示数据。

<p align="center">
  <img src="Assets/readme/thermal-dark.png" width="49%" alt="温度与风扇控制">
  <img src="Assets/readme/keepawake-light.png" width="49%" alt="防休眠设置">
</p>
<p align="center">
  <img src="Assets/readme/cleaner-light.png" width="49%" alt="清理预览">
  <img src="Assets/readme/ip-purity-light.png" width="49%" alt="公网 IP 与纯净度检测">
</p>
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

### 集成

- **桌面小组件**：系统概览、番茄钟、AI 额度、日历与整月日历、明天上班吗、IP 纯净度与公网 IP。
- **多语言**：简体中文、繁體中文、English、日本語、한국어、Deutsch、Español、Français、العربية。
- **深链**：通过 `xstats://` 从启动器、快捷指令或终端打开常用入口；已关闭的模块会转到设置，不会被隐式启用。

```bash
open 'xstats://open/connections'   # 打开网络监视器
open 'xstats://panel/cpu'          # 显示 CPU 弹窗
```

完整路径与操作见[深链协议](docs/DEVELOPMENT.md#xstats-深链)。

## 安装

需要 **Apple 芯片 Mac 与 macOS 14 或更新版本**。

```bash
brew tap ysicing/tap
brew trust ysicing/tap
brew install --cask xstats
```

也可从 [GitHub Releases](https://github.com/ysicing/xstats/releases) 下载 DMG，将 XStats 拖入“应用程序”。应用内置更新检查，是否安装新版本由你决定。

## 数据与隐私

监控数据、本机历史与 AI Token 统计均在本机处理，不上传到 XStats 更新服务。以下功能会连接外部服务，可关闭或按需使用：

- **检查更新**：发送当前版本与安装标识的哈希，获取更新清单。
- **查询 AI 额度**：使用本机 CLI 登录查询对应服务；配置备用来源后，查询你指定的服务器。
- **费用估算**：按需获取公开模型单价与参考汇率，不发送会话日志或 Token 统计。
- **网络监视器**：下载组件及公共地理数据库时联网；连接记录和目标 IP 不上传。
- **网络诊断**：公网 IP、归属地、测速、DNS、连接探测与全球探针会请求相应服务；全球探针的测量目标与结果可能被他人查询。

完整说明见[隐私政策](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.zh-Hans.md)和[服务条款](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.zh-Hans.md)。

## 构建与贡献

需要 Xcode 26+、Go 1.25+、[Go Task](https://taskfile.dev/) 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

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
