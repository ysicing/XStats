<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

An open-source macOS menu-bar app for system monitoring and maintenance.

[![Release](https://img.shields.io/badge/release-0.9.0-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20silicon-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[Download](https://github.com/ysicing/xstats/releases) · [Changelog](CHANGELOG.md) · [Development guide](DEVELOPMENT.md)

[简体中文](README.md) · **English** · [日本語](README.ja.md) · [한국어](README.ko.md)

</div>

XStats shows CPU, GPU, memory, disk, network, battery, temperature and fan activity in the menu bar. Open a metric for history and details, or use the built-in tools to control fans, keep your Mac awake, clean caches and uninstall apps.

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats dashboard in dark mode">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats dashboard in light mode">
</p>

## Features

- **System monitoring:** choose menu-bar metrics and styles; inspect trends, processes and hardware in popovers or the main window.
- **System tools:** fan control, keep-awake, cache cleanup, app removal and startup-item management, with previews and confirmation for destructive actions.
- **Network tools:** inspect connections, DNS and public IPs; optionally check IP reputation and connectivity.
- **Optional modules:** a separate menu-bar calendar, plus local Codex / Claude Code session-token statistics and subscription quota checks.

## Install

Download XStats from [GitHub Releases](https://github.com/ysicing/xstats/releases). It requires an **Apple silicon Mac running macOS 14 or later**. You can also [build from source](DEVELOPMENT.md).

The interface supports Simplified and Traditional Chinese, English, Japanese, Korean, German, Spanish, French and Arabic. When an update is available, you decide whether to install it.

## Data and privacy

System-monitoring data stays on your Mac; no XStats account is required. AI Usage & Quotas is off by default. If enabled, local statistics read session logs, while quota checks read the corresponding CLI credentials without modifying them and contact the providers directly. You may configure your own Sub2API server as a fallback quota source.

Public-IP lookups and connection probes go online only when you use those features. Update checks send the app version and a SHA-256 hash of a random installation ID; the server does not persist request IPs. WebDAV sync uses a server you configure yourself and runs only when you start it; it transfers settings, not monitoring history or credentials.

Read the [Privacy Policy](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.en.md) and [Terms of Service](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.en.md) for details.

## Build and contribute

You need Xcode 26+, Go 1.25+, [Go Task](https://taskfile.dev/) and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Common commands:

```bash
task test
task build BUMP=0 INSTALL=0
```

Issues and pull requests are welcome. See [DEVELOPMENT.md](DEVELOPMENT.md) for setup and releases, and [ARCHITECTURE.md](ARCHITECTURE.md) for the project structure.

## Releases

<!-- changelog:start -->
<!-- Generated from CHANGELOG.md by scripts/sync_changelog.py. Do not edit by hand. -->

Latest release **0.9.0** (2026-09-24) · [full changelog](CHANGELOG.md) (kept in Chinese)

<!-- changelog:end -->

## Credits and license

XStats builds on [OpenStats](https://github.com/gentpan/OpenStats). Thanks to its maintainers and the other open-source projects listed in [ThirdPartyNotices.md](ThirdPartyNotices.md), which includes their licenses and copyright notices. XStats is an independent third-party app, not affiliated with Apple or the other companies mentioned.

New XStats code and modifications are licensed under **AGPL-3.0-or-later**; see [LICENSE](LICENSE) and [LICENSING.md](LICENSING.md). Upstream OpenStats code retains its [MIT license](LICENSES/OpenStats-MIT.txt).
