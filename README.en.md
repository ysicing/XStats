<div align="center">

<img src="Assets/icon.png" alt="XStats" width="96" height="96">

# XStats

**System monitoring and everyday Mac tools, with a full app window and menu bar access.**

See CPU, memory, network and temperature at a glance, and open the details for trends and app usage. Enable tools such as AI Usage, calendar and fan control when you need them.

[![Release](https://img.shields.io/github/v/tag/ysicing/xstats?label=version&style=flat-square)](https://github.com/ysicing/xstats/releases)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20silicon-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)
[![Twitter](https://img.shields.io/badge/follow-YsiCing-red?style=flat-square&logo=Twitter)](https://twitter.com/YsiCing)

[Download the latest release](https://github.com/ysicing/xstats/releases) · [Features](#features) · [Install](#install) · [Data and privacy](#data-and-privacy) · [Changelog](CHANGELOG.md)

[简体中文](README.md) · **English** · [日本語](README.ja.md) · [한국어](README.ko.md)

<img src="Assets/readme/menubar-layouts-zh-Hans-dark.png" width="760" alt="XStats menu bar layouts: separate, aggregated and three-in-one">

</div>

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="XStats dashboard, dark">
  <img src="Assets/readme/overview-light.png" width="49%" alt="XStats dashboard, light">
</p>

## Features

XStats is a free, open-source native app built with Swift, AppKit and SwiftUI. No account is required.

### Menu bar layout

Show metrics **separately**, in **Aggregated Mode**, or as **a three-in-one icon** with freely combined sources. In icon-only mode, the Dock icon shows the same live status. Items, order and styles (text, icons, rings, progress bars, history charts) are all configurable.

The aggregated overview brings metrics together and opens individual details.

<p align="center">
  <img src="Assets/readme/combined-overview-zh-Hans-light.png" width="360" alt="Aggregated menu bar overview, light mode">
  <img src="Assets/readme/combined-overview-zh-Hans-dark.png" width="360" alt="Aggregated menu bar overview, dark mode">
</p>

Menu bar layouts and the status overview use demo data to illustrate different layouts and combinations.

### Feature activation and menu bar visibility

Manage Basic and Optional Features separately in Settings → Features.

- **Basic monitoring**: turn CPU, GPU, memory, disk, network, energy and fan monitoring on or off individually. Disabling a module stops live collection, related alerts and new history records while keeping basic information, page access and existing history. System widgets refresh independently.
- **Menu bar visibility**: selecting Show in Menu Bar for basic monitoring, AI Usage or Audio also enables that feature, except for the battery information entry. Clearing it removes the entry while leaving the feature enabled. AI Usage and Audio have their own display options.
- **Display parameter controls**: enable or disable brightness, contrast and volume reads and adjustments. Display information remains available, with a separate information-only menu bar option.

<p align="center">
  <img src="Assets/readme/monitoring-features-zh-Hans-light.png" width="49%" alt="Basic Features: separate activation and menu bar display controls">
  <img src="Assets/readme/optional-features-zh-Hans-light.png" width="49%" alt="Optional Features: grouped tools, modules, Timers and calendar">
</p>

### System monitoring

| Module | Details |
|---|---|
| **CPU** | User / system / idle utilization, per-core and core-group load, load averages, frequency and temperature, thermal pressure alerts |
| **GPU** | Graphics utilization, core count, temperature and power |
| **Memory** | Memory pressure, app / compressed / cached composition, swap space and swap rates |
| **Disk** | Capacity, read/write rates, per-app I/O ranking, SMART health |
| **Network** | Upload/download rates, network interfaces and connection summary |
| **Energy** | Temperatures, system power, app CPU energy, apps preventing sleep, battery status and Bluetooth device battery levels |
| **Fans** | Fan speeds and controls on supported Macs |
| **Displays** | Resolution, scaling and refresh rate; brightness, contrast and volume on DDC/CI-capable external displays |
| **System information** | Mac and system identifiers; click the detail icon beside Apple Intelligence to view feature configuration, on-device model availability and storage |

Frequency, temperature and power readings depend on what the Mac model and macOS expose.

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="49%" alt="CPU utilization and core details">
  <img src="Assets/readme/popover-memory-dark.png" width="49%" alt="Memory composition and pressure">
</p>

### Network Monitor

**Optional on macOS 15 or later, disabled by default.** View new connections observed while monitoring, grouped by app, process, domain, country or region, with search, active-connection filtering, pause and resume.

- **Read-only**: all traffic is allowed, communication content is never inspected, and no connection history is stored.
- **On demand**: reads only while the page is visible and not paused, retaining at most 512 records in memory. It does not enumerate every connection that existed before observation began.
- **World map**: download the public IP geography database only when first used, then look up locations offline. Positions represent countries or regions, not precise device locations.

First use: enable Network Monitor in Settings → Features → Optional Features, follow the component installation guide, and approve the system extension and network filter in macOS. Installation requires an administrator account. Use Manage Component to check independent updates or remove the component.

If you used a preview network component, upgrade the main app first, uninstall the old component through Manage Component, complete any restart requested by macOS, and enable it again to move to the current update source.

<p align="center">
  <img src="Assets/readme/connections-zh-Hans-light.png" width="49%" alt="Network Monitor connection overview, light mode, demo data">
  <img src="Assets/readme/connections-zh-Hans-dark.png" width="49%" alt="Network Monitor connection overview, dark mode, demo data">
</p>

<p align="center">
  <img src="Assets/readme/component-install-zh-Hans-light.png" width="49%" alt="First-time network component installation panel, demo state">
  <img src="Assets/readme/component-management-zh-Hans-light.png" width="49%" alt="Network component management panel, demo version information">
</p>

Connections, addresses, countries or regions and component version information are demo data.

### AI Usage

Track AI service usage from the menu bar:

- **Token statistics**: hourly for today, daily for the last 7 / 30 days, plus a yearly activity heatmap in local-log mode.
- **Subscription quotas**: used / remaining percentages, reset times and plan details.
- **Estimated costs**: based on public base API prices in USD / CNY; not a subscription bill.

When Magpie is installed, account quotas, tokens and costs come from its local API, including Grok and other supported services. Only requests routed through Magpie count toward token usage; costs are shown in USD. Without Magpie, statistics read Codex / Claude Code session logs and quota queries require the corresponding CLI to be signed in.

### Tools

| Tool | Description |
|---|---|
| **XStats Capture** | Built-in screenshot annotation, local redaction, and screen recording with audio; also available as a [standalone Capture download](https://github.com/ysicing/XStats/releases/tag/capture-v0.1.5). See [Capture usage and permissions](docs/CAPTURE.md) |
| **Fan control** | Switch between automatic and manual control on supported Macs |
| **Keep awake** | Keep the system or display awake, with optional lid-closed operation |
| **Apps & Services** | Manage apps, Homebrew packages, startup items and Homebrew services; view app information and available updates |
| **Clean & Optimize** | Review caches and build artifacts, preview Homebrew dependencies, and manually refresh DNS or release memory · [Cleanup scope](docs/CLEANUP.md) |
| **Network diagnostics** | Speed tests, DNS queries, egress checks, local interface addresses and multi-source public IP lookup, location and purity, connectivity probes |
| **Menu bar calendar** | Chinese lunar calendar, holidays and make-up workdays, almanac, calendar events and reminders |
| **Audio** | System volume and input/output switching; per-app volume and output on macOS 14.4+, processed locally |
| **Timers** | Countdown, Pomodoro and stopwatch; multi-display break screens, mini HUD, independent eye-break reminders and local focus statistics |
| **Process manager** | Search, sort, group by app and end processes |

Timers brings together countdown, Pomodoro and stopwatch, with on-demand short and long breaks, optional display sleep, independent eye-break reminders, break sounds and local focus statistics.

Optional tools can be enabled as needed. Privileged actions such as fan control and lid-closed keep-awake require an authorized helper. Cleanup and uninstall require preview and confirmation. Cleanup moves items to Trash or deletes them directly depending on the item type and settings; uninstall uses Trash.

<details>
<summary>More screenshots</summary>

Menu bar layouts, the status overview, Wi-Fi details, network connections, AI usage and quotas, history, audio, displays and calendar screenshots use demo data. Other system monitoring screenshots include read-only measurements from this Mac. Hardware capabilities vary by model.

<p align="center">
  <img src="Assets/readme/trio-settings-zh-Hans-light.png" width="720" alt="Three-in-one icon sources and appearance">
</p>
<p align="center">
  <img src="Assets/readme/popover-order-zh-Hans-light.png" width="600" alt="Custom popover sections and ordering">
</p>
<p align="center">
  <img src="Assets/readme/wifi-details-zh-Hans-light.png" width="360" alt="Wi-Fi signal, link and security details">
</p>
<p align="center">
  <img src="Assets/readme/thermal-dark.png" width="49%" alt="Temperature and fan control">
  <img src="Assets/readme/keepawake-light.png" width="49%" alt="Keep-awake settings">
</p>
<p align="center">
  <img src="Assets/readme/cleaner-light.png" width="49%" alt="Cleanup preview">
  <img src="Assets/readme/ip-purity-light.png" width="49%" alt="Public IP and purity checks">
</p>
<p align="center">
  <img src="Assets/readme/ai-usage-zh-Hans-light.png" width="760" alt="Magpie AI usage, service selection and subscription quotas">
</p>
<p align="center">
  <img src="Assets/readme/history-zh-Hans-dark.png" width="760" alt="History trends">
</p>
<p align="center">
  <img src="Assets/readme/audio-zh-Hans-light.png" width="49%" alt="Audio and app mixing">
  <img src="Assets/readme/displays-zh-Hans-dark.png" width="49%" alt="External display controls">
</p>
<p align="center">
  <img src="Assets/readme/calendar-zh-Hans-light.png" width="49%" alt="Menu bar calendar">
  <img src="Assets/readme/rest-zh-Hans-dark.png" width="49%" alt="Timers: Pomodoro, reminders and today’s activity">
</p>

</details>

### Integrations

- **Desktop widgets**: system overview, Pomodoro, AI quotas and cumulative tokens, calendar and month view, “Work tomorrow?”, IP purity and public IP.
- **Languages**: 简体中文, 繁體中文, English, 日本語, 한국어, Deutsch, Español, Français, العربية.
- **Deep links**: open common views via `xstats://` from launchers, Shortcuts or the terminal. Disabled modules lead to Settings and are never enabled implicitly.

```bash
open 'xstats://open/connections'   # Open Network Monitor
open 'xstats://panel/cpu'          # Show the CPU popover
```

See the [deep-link protocol](docs/DEVELOPMENT.md#xstats-深链) for all routes and actions.

## Install

Requires an **Apple silicon Mac with macOS 14 or later**.

```bash
brew tap ysicing/tap
brew trust ysicing/tap
brew install --cask xstats
```

Or download the DMG from [GitHub Releases](https://github.com/ysicing/xstats/releases) and drag XStats into Applications. XStats checks for updates, and you decide whether to install them.

## Data and privacy

Monitoring data, local history and AI token statistics are processed locally and are not uploaded to the XStats update service. These features connect to external services and can be disabled or used on demand:

- **Update checks**: the main app, independent network component and standalone Capture send their version and a hashed installation ID to retrieve their update feed.
- **AI quota queries**: use your local CLI sign-in to query the provider; a configured fallback queries the server you specify.
- **Cost estimates**: fetch public model prices and reference exchange rates on demand, without sending session logs or token statistics.
- **Network Monitor**: downloads the component and a public geography database; connection records and destination IPs are not uploaded.
- **Network diagnostics**: public IP, location, speed tests, DNS, connectivity probes and global probes contact their services; global-probe targets and results may be queried by others.

Experimental menu bar folding on macOS 27 asks for access to one system configuration file to hide and restore selected apps. It does not require screen recording or upload the app list.

See the [Privacy Policy](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.en.md) and [Terms of Service](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.en.md) for details.

## Build and contribute

Requires Xcode 26+, Go 1.25+, [Go Task](https://taskfile.dev/) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
task test
task build BUMP=0 INSTALL=0
```

Issues and pull requests are welcome. See [DEVELOPMENT.md](docs/DEVELOPMENT.md) for setup and releases, and [ARCHITECTURE.md](docs/ARCHITECTURE.md) for module boundaries and implementation constraints.

## Releases

<!-- changelog:start -->
<!-- Generated from CHANGELOG.md by scripts/sync_changelog.py. Do not edit by hand. -->

Latest release **1.4.8** (2026-10-23) · [full changelog](CHANGELOG.md) (kept in Chinese)

<!-- changelog:end -->

## Credits and license

XStats builds on [OpenStats](https://github.com/gentpan/OpenStats). Thanks to its maintainers and the other open-source projects listed in [ThirdPartyNotices.md](ThirdPartyNotices.md), which includes their licenses and copyright notices. XStats is an independent third-party app, not affiliated with Apple or the other companies mentioned.

New XStats code and modifications are licensed under **AGPL-3.0-or-later**; see [LICENSE](LICENSE) and [LICENSING.md](LICENSING.md). Upstream OpenStats code retains its [MIT license](LICENSES/OpenStats-MIT.txt).
