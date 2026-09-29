<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

**Free, open-source system monitoring in your Mac menu bar.** See CPU, memory, network and temperature at a glance, then clean up, control fans or keep your Mac awake.

[![Release](https://img.shields.io/badge/release-0.14.0-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20silicon-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[Download](https://github.com/ysicing/xstats/releases) · [Changelog](CHANGELOG.md) · [Development guide](DEVELOPMENT.md)

[简体中文](README.md) · **English** · [日本語](README.ja.md) · [한국어](README.ko.md)

<img src="Assets/readme/menubar-dark.png" width="626" alt="XStats menu bar readings">

</div>

```bash
brew tap ysicing/tap
brew trust ysicing/tap
brew install --cask xstats
```

## Why XStats

- **One app instead of several**: system monitoring, fan control, keep-awake, cache cleanup, app uninstalling, speed tests and IP checks, all from the menu bar.
- **Native, open source, free**: written in Swift and SwiftUI, source available under AGPL-3.0, no account needed.
- **Review before anything changes**: cleanup and uninstalling list what will be removed and act only after you confirm; you can also have items moved to the Trash first.
- **You choose what to see**: pick the menu bar metrics, their order and style, and turn off whole modules you don't need.
- **9 interface languages**: 简体中文, 繁體中文, English, 日本語, 한국어, Deutsch, Español, Français, العربية.

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats dashboard, dark">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats dashboard, light">
</p>

## Features

**System monitoring**: choose CPU, GPU, memory, disk, network, battery, temperature and fan readings for the menu bar; open any metric for history, the apps using it most and hardware details.

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="24%" alt="CPU details">
  <img src="Assets/readme/popover-memory-dark.png" width="24%" alt="Memory details">
  <img src="Assets/readme/popover-disk-light.png" width="24%" alt="Disk details">
  <img src="Assets/readme/ip-purity-light.png" width="24%" alt="IP purity">
</p>

**System tools**: fan control, keep-awake (including with the lid closed), app uninstalling and startup item management. Cache and project build-artifact cleanup is available after you turn it on in Settings.

**Network tools**: view connections, DNS and your public IP; run speed tests and check IP purity and connectivity to regions around the world on demand.

**Optional modules**, off by default:

- Processes: view all processes, search, sort, group by app, and end processes.
- Menu bar calendar: Chinese lunar calendar, public holidays and make-up workdays, almanac, plus your calendar events and reminders.
- Pomodoro and eye-rest breaks: a break screen on every display that you can skip, pause or shrink to a mini HUD at any time.
- AI Usage: local Codex / Claude Code token usage and subscription quota checks.

**Desktop widgets**: system overview, Pomodoro, AI quotas, calendar and month view, "Work tomorrow?", IP purity and public IP.

## Install

Requires an **Apple silicon Mac with macOS 14 or later**. Installing with the Homebrew commands above is recommended; update later with `brew upgrade --cask xstats`.

You can also download the DMG from [GitHub Releases](https://github.com/ysicing/xstats/releases) or [build from source](DEVELOPMENT.md). XStats checks for updates itself, and you decide whether to install a new version.

## Data and privacy

No account is required. These features go online, and each can be turned off or used only on demand:

- **Update checks**: send the app version and a hashed installation ID.
- **AI Usage** (off by default): checks subscription quotas through your local Codex / Claude CLI sign-in, with an optional Sub2API fallback.
- **Public IP, speed tests and connection probes**: contact their services only when used.

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

Latest release **0.14.0** (2026-09-29) · [full changelog](CHANGELOG.md) (kept in Chinese)

<!-- changelog:end -->

## Credits and license

XStats builds on [OpenStats](https://github.com/gentpan/OpenStats). Thanks to its maintainers and the other open-source projects listed in [ThirdPartyNotices.md](ThirdPartyNotices.md), which includes their licenses and copyright notices. XStats is an independent third-party app, not affiliated with Apple or the other companies mentioned.

New XStats code and modifications are licensed under **AGPL-3.0-or-later**; see [LICENSE](LICENSE) and [LICENSING.md](LICENSING.md). Upstream OpenStats code retains its [MIT license](LICENSES/OpenStats-MIT.txt).
