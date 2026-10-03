<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

**免费开源的 macOS 菜单栏系统监控。** 一眼看清 CPU、内存、网络、温度，顺手清理、控风扇、防休眠。

[![Release](https://img.shields.io/badge/%E7%89%88%E6%9C%AC-0.14.5-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20%E8%8A%AF%E7%89%87-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[下载](https://github.com/ysicing/xstats/releases) · [更新日志](CHANGELOG.md) · [开发指南](DEVELOPMENT.md)

**简体中文** · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

<img src="Assets/readme/menubar-dark.png" width="626" alt="XStats 菜单栏读数">

</div>

```bash
brew tap ysicing/tap
brew trust ysicing/tap
brew install --cask xstats
```

## 为什么用 XStats

- **一个应用顶替好几个**：系统监控、风扇控制、防休眠、缓存清理、应用卸载、网络测速和 IP 检测都在菜单栏里。
- **原生、开源、免费**：Swift 与 SwiftUI 编写，源码公开（AGPL-3.0），无需账号。
- **动手前先确认**：清理和卸载先列出将要处理的内容，确认后才执行；也可以设置为先移到废纸篓。
- **你决定看什么**：菜单栏指标、顺序和显示样式都能自选，不用的模块可以整个关掉。
- **支持 9 种界面语言**：简体中文、繁體中文、English、日本語、한국어、Deutsch、Español、Français、العربية。

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats 深色仪表盘">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats 浅色仪表盘">
</p>

## 功能

**系统监控**：在菜单栏选择 CPU、GPU、内存、磁盘、网络、电池、温度与风扇读数；点开任意指标查看历史趋势、占用最多的应用和硬件详情。

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="24%" alt="CPU 详情">
  <img src="Assets/readme/popover-memory-dark.png" width="24%" alt="内存详情">
  <img src="Assets/readme/popover-disk-light.png" width="24%" alt="磁盘详情">
  <img src="Assets/readme/ip-purity-light.png" width="24%" alt="IP 纯净度">
</p>

**系统工具**：风扇控制、防休眠（可合盖运行）、应用卸载和启动项管理；缓存与项目产物清理在设置中开启后使用。

**网络工具**：查看连接、DNS 和公网 IP；按需测速，检测 IP 纯净度和到各地的连通情况。

**可选模块**，默认关闭，按需打开：

- 进程：查看全部进程，支持搜索、排序、按应用分组与结束进程。
- 菜单栏日历：农历、节假日与调休、黄历，可显示系统日程和提醒事项。
- 番茄钟与护眼休息：多屏休息幕布，可随时跳过、暂停或收起到迷你 HUD。
- AI 用量：统计 Codex / Claude Code 本机 Token 用量，查询订阅额度。

**桌面小组件**：系统概览、番茄钟、AI 额度、日历与整月日历、明天上班吗、IP 纯净度和公网 IP。

## 安装

需要 **Apple Silicon Mac、macOS 14 或更新版本**。推荐用上方的 Homebrew 命令安装，之后 `brew upgrade --cask xstats` 即可更新。

也可以从 [GitHub Releases](https://github.com/ysicing/xstats/releases) 下载 DMG，或按 [开发指南](DEVELOPMENT.md) 从源码构建。应用内置更新检查，发现新版本后由你决定是否安装。

## 数据与隐私

无需账号。以下功能会联网，均可在设置中关闭或按需使用：

- **检查更新**：发送版本号和安装标识的哈希。
- **AI 用量**（默认关闭）：通过本机 Codex / Claude CLI 的登录查询订阅额度，可选配置 Sub2API 作为备用来源。
- **公网 IP、测速与连接探测**：仅在使用时请求对应服务。

完整说明见[隐私政策](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.zh-Hans.md)和[服务条款](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.zh-Hans.md)。

## 构建与贡献

需要 Xcode 26+、Go 1.25+、[Go Task](https://taskfile.dev/) 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。常用命令：

```bash
task test
task build BUMP=0 INSTALL=0
```

欢迎提交 Issue 和 Pull Request。项目结构、开发环境与发布流程见 [DEVELOPMENT.md](DEVELOPMENT.md)，架构说明见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 版本记录

<!-- changelog:start -->
<!-- 由 scripts/sync_changelog.py 从 CHANGELOG.md 生成，请勿手改。 -->

最新版本 **0.14.5**（2026-10-03） · [完整更新日志](CHANGELOG.md)

<!-- changelog:end -->

## 致谢与许可

XStats 基于 [OpenStats](https://github.com/gentpan/OpenStats) 开发。感谢原项目及其他开源项目的贡献；来源、许可和版权信息见 [ThirdPartyNotices.md](ThirdPartyNotices.md)。XStats 是独立的第三方应用，与 Apple 及其他提及的公司没有隶属关系。

XStats 新增代码与修改采用 **AGPL-3.0-or-later**，见 [LICENSE](LICENSE) 和 [LICENSING.md](LICENSING.md)。OpenStats 上游代码保留原 [MIT 许可](LICENSES/OpenStats-MIT.txt)。
