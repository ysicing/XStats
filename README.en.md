<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

**System status and everyday tools, right in your Mac menu bar.**

Check CPU, memory, network and temperature at a glance, then open the details for trends and app usage.
Enable AI Usage, calendar, fan control and cleanup tools when you need them.

[![Release](https://img.shields.io/badge/release-0.14.5-6ee02b)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20silicon-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

[Download the latest release](https://github.com/ysicing/xstats/releases) · [Screenshots](#screenshots) · [Features](#features) · [Install](#install) · [Changelog](CHANGELOG.md)

[简体中文](README.md) · **English** · [日本語](README.ja.md) · [한국어](README.ko.md)

<img src="Assets/readme/menubar-dark.png" width="626" alt="XStats menu bar readings">

</div>

## Screenshots

The main window brings system readings together, with light and dark appearances to match your preference.

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats dashboard, dark">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats dashboard, light">
</p>

## Features

XStats is a free, open-source native app built with Swift, AppKit and SwiftUI. No XStats account is required. You choose which readings and tools to use.

### Choose your menu bar layout

- **Separate**: keep a dedicated menu bar item for each metric you check often.
- **Combined**: put several readings in one group and open a status overview.
- **Icon only**: keep one XStats icon and expand it to see your selected items.

Choose the items, their order and their styles. Depending on the metric, styles include text, icons, rings, progress bars and history charts. Turn off the items you do not need.

### System monitoring, with details on demand

| Module | What you can see |
|---|---|
| **CPU** | User / system / idle utilization, per-core load rings, core-group utilization, load averages, and available frequency and temperature readings; macOS thermal pressure is highlighted when elevated |
| **GPU** | Graphics utilization, hardware information such as core count, and available temperature and power readings |
| **Memory** | Memory pressure, app and compressed memory, caches, swap space, and swap-in / swap-out rates |
| **Disk** | Capacity, read/write rates, app I/O rankings, and available SMART health information |
| **Network** | Upload/download rates, network interfaces and connection summaries |
| **Battery and Bluetooth** | Battery charge, power source, health and cycle count; supported Bluetooth device battery levels, also available in the menu bar on Macs without a battery |
| **Temperature and fans** | Sensor groups, fan speeds and available power readings |
| **Displays** | Model, resolution, scaled resolution and refresh rate; brightness, contrast and volume controls on supported external displays |

Core types come from the system. XStats groups the reported super, performance and efficiency cores rather than assuming two or three groups for a chip model. This Mac also shows the model, OS version and uptime.

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="49%" alt="CPU utilization and core details">
  <img src="Assets/readme/popover-memory-dark.png" width="49%" alt="Memory composition and pressure">
</p>

**External display controls** depend on DDC/CI support from the monitor, cable and connection. Each control is detected independently. Unsupported or temporarily unreadable controls show their status; sliders are offered only for supported controls.

### AI Usage and subscription quotas

Check Codex / Claude Code usage in the menu bar, then open the statistics and quota details:

- **Token statistics**: hourly for today and daily for the last 7 / 30 days; the main window also provides a yearly activity heatmap.
- **Subscription quotas**: switch between used / remaining percentages and view reset times, plus plan, expiry and available reset-credit information when supplied by the source.
- **Estimated costs**: based on public base API prices, with USD / CNY display; excludes tiered pricing and does not represent a subscription bill.
- **Display preferences**: choose the refresh interval and Chinese 万 / 亿 or K / M / B number units.

AI Usage is off by default. Local statistics read Codex / Claude Code session logs; subscription quota queries require the corresponding CLI to be signed in. You can also configure Sub2API as a fallback source.

### Everyday tools, enabled as needed

- **Fan control**: inspect operating status and switch between automatic and manual control on supported devices.
- **Keep awake**: keep the system or display awake, with lid-closed operation available when configured.
- **Cleanup and uninstalling**: remove caches, project build artifacts and app-related files; preview and confirm first, with an option to move items to the Trash.
- **Startup items**: view and manage login items and background startup entries.
- **Network diagnostics**: run speed tests, DNS queries, egress checks, public IP location and purity checks, and connectivity probes on demand.
- **Menu bar calendar**: Chinese lunar dates, holidays and make-up workdays, and almanac information; calendar events and reminders are available after permission is granted.
- **Audio**: disabled by default; system volume, mute, and output/input device switching. On macOS 14.4 or later, authorization enables 0–100% volume, mute and reset for apps playing audio. Audio is processed locally without recording or uploading. Unsupported device volume controls are indicated.
- **Pomodoro and eye-rest breaks**: focus and break timers, break screens across displays, and options to pause, skip or shrink to a mini HUD.
- **Process manager**: when enabled, view all processes, search, sort, group by app and end processes.

Cleanup, processes, calendar, Pomodoro and AI Usage are off by default. Enable them when needed. Privileged actions such as fan control and lid-closed keep-awake require installing and authorizing the helper from the app.

<details>
<summary>More tool screenshots</summary>

<p align="center">
  <img src="Assets/readme/thermal-dark.png" width="49%" alt="Temperature and fan control">
  <img src="Assets/readme/keepawake-light.png" width="49%" alt="Keep-awake settings">
</p>
<p align="center">
  <img src="Assets/readme/cleaner-light.png" width="49%" alt="Cleanup preview">
  <img src="Assets/readme/ip-purity-light.png" width="49%" alt="Public IP and purity checks">
</p>

</details>

### Desktop widgets and languages

Widgets include system overview, Pomodoro, AI quotas, calendar and month view, “Work tomorrow?”, IP purity and public IP.

The interface supports **9 languages**: 简体中文, 繁體中文, English, 日本語, 한국어, Deutsch, Español, Français, العربية.

## Install

Requires an **Apple silicon Mac with macOS 14 or later**.

**Homebrew**:

```bash
brew tap ysicing/tap
brew trust ysicing/tap
brew install --cask xstats
```

Update later with `brew upgrade --cask xstats`.

**Direct download**: get the DMG from [GitHub Releases](https://github.com/ysicing/xstats/releases), open it, drag XStats into Applications and launch it.

XStats checks for updates, and you decide whether to download and install a new version. See the [development guide](DEVELOPMENT.md) to build from source.

## Data and privacy

Monitoring data, local history and AI token statistics are processed locally and are not uploaded to the XStats update service. These features connect to external services and can be disabled or used on demand:

- **Update checks**: send the current version and a hashed installation ID to retrieve the update feed.
- **AI quota queries**: use your local CLI sign-in to query the provider; a configured fallback queries the server you specify.
- **Cost estimates**: fetch public model prices and reference exchange rates on demand, without sending session logs or token statistics.
- **Network diagnostics**: public IP, location, speed tests, DNS, connectivity probes and global probes contact their services; global-probe targets and results may be queried by others.

See the [Privacy Policy](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.en.md) and [Terms of Service](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.en.md) for details.

## Build and contribute

You need Xcode 26+, Go 1.25+, [Go Task](https://taskfile.dev/) and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Common commands:

```bash
task test
task build BUMP=0 INSTALL=0
```

Issues and pull requests are welcome. See [DEVELOPMENT.md](DEVELOPMENT.md) for setup and releases, and [ARCHITECTURE.md](ARCHITECTURE.md) for module boundaries and implementation constraints.

## Releases

<!-- changelog:start -->
<!-- Generated from CHANGELOG.md by scripts/sync_changelog.py. Do not edit by hand. -->

Latest release **0.14.5** (2026-10-03) · [full changelog](CHANGELOG.md) (kept in Chinese)

<!-- changelog:end -->

## Credits and license

XStats builds on [OpenStats](https://github.com/gentpan/OpenStats). Thanks to its maintainers and the other open-source projects listed in [ThirdPartyNotices.md](ThirdPartyNotices.md), which includes their licenses and copyright notices. XStats is an independent third-party app, not affiliated with Apple or the other companies mentioned.

New XStats code and modifications are licensed under **AGPL-3.0-or-later**; see [LICENSE](LICENSE) and [LICENSING.md](LICENSING.md). Upstream OpenStats code retains its [MIT license](LICENSES/OpenStats-MIT.txt).
