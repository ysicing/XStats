<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

开源的 macOS 菜单栏系统监控与维护工具。

[![Release](https://img.shields.io/badge/%E7%89%88%E6%9C%AC-0.9.2-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20%E8%8A%AF%E7%89%87-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[下载](https://github.com/ysicing/xstats/releases) · [更新日志](CHANGELOG.md) · [开发指南](DEVELOPMENT.md)

**简体中文** · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md)

</div>

XStats 在菜单栏显示 CPU、GPU、内存、磁盘、网络、电池、温度与风扇状态。点开指标可查看历史和详细读数；需要时还能控制风扇、保持唤醒、清理缓存和卸载应用。

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats 深色仪表盘">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats 浅色仪表盘">
</p>

## 功能

- **系统监控**：可自选菜单栏指标与显示样式，在弹窗或主窗口查看趋势、进程和硬件信息。
- **系统工具**：风扇控制、防休眠、缓存清理、应用卸载和启动项管理；危险操作先预览、再确认。
- **网络工具**：查看连接、DNS 和公网 IP；按需检测 IP 纯净度与连接情况。
- **可选模块**：独立菜单栏日历；Codex / Claude Code 本机会话 Token 统计和订阅额度查询。
- **桌面小组件**：系统概览、AI 额度、节日黄历日历、明天上班吗、IP 纯净度和公网 IP；AI、IP 与日历数据只读取主应用的本地缓存。

## 安装

从 [GitHub Releases](https://github.com/ysicing/xstats/releases) 下载。需要 **Apple Silicon Mac 和 macOS 14 或更新版本**。也可以按 [开发指南](DEVELOPMENT.md) 从源码构建。

应用支持简体中文、繁體中文、English、日本語、한국어、Deutsch、Español、Français 和 العربية。发现更新后由用户决定是否安装。

## 数据与隐私

系统监控数据留在本机，不需要 XStats 账号。AI 用量与额度默认关闭；启用后，本地统计读取本机会话日志，订阅额度查询只读使用对应 CLI 的登录凭据并直接请求服务商。可自行配置 Sub2API 作为额度备用来源。

公网 IP 查询和连接探测仅在使用相关功能时联网。检查更新会发送版本号和随机安装标识的 SHA-256；服务端不持久化请求 IP。WebDAV 同步由用户自行配置服务器并手动触发，只同步设置，不上传监控历史或凭据。

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

最新版本 **0.9.2**（2026-09-24） · [完整更新日志](CHANGELOG.md)

<!-- changelog:end -->

## 致谢与许可

XStats 基于 [OpenStats](https://github.com/gentpan/OpenStats) 开发。感谢原项目及其他开源项目的贡献；来源、许可和版权信息见 [ThirdPartyNotices.md](ThirdPartyNotices.md)。XStats 是独立的第三方应用，与 Apple 及其他提及的公司没有隶属关系。

XStats 新增代码与修改采用 **AGPL-3.0-or-later**，见 [LICENSE](LICENSE) 和 [LICENSING.md](LICENSING.md)。OpenStats 上游代码保留原 [MIT 许可](LICENSES/OpenStats-MIT.txt)。
