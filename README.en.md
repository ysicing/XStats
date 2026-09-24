<div align="center">

<img src="Assets/icon.png" alt="XStats" width="112" height="112">

# XStats

**Your Mac at a glance — CPU, GPU, memory, network and temperatures in the menu bar, with fan control, keep-awake, one-click cleanup, an app uninstaller and an IP cleanliness check.**

[![Release](https://img.shields.io/badge/release-0.9.0-6ee02b)](https://github.com/ysicing/xstats/releases)
[![Stars](https://img.shields.io/github/stars/ysicing/xstats?style=flat&color=f5c518&label=stars)](https://github.com/ysicing/xstats/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/ysicing/xstats?color=black&label=last%20commit)](https://github.com/ysicing/xstats/commits/main)
[![Commit activity](https://img.shields.io/github/commit-activity/m/ysicing/xstats?color=black&label=commits)](https://github.com/ysicing/xstats/graphs/commit-activity)
[![CI](https://github.com/ysicing/xstats/actions/workflows/ci.yml/badge.svg)](https://github.com/ysicing/xstats/actions/workflows/ci.yml)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20silicon-black)](https://github.com/ysicing/xstats/releases)
[![License](https://img.shields.io/badge/license-AGPL--3.0--or--later-blue)](LICENSE)

XStats is a macOS menu-bar app that shows what your Mac is doing right now — per-core
CPU load, GPU, memory pressure, network speed, disk, battery, temperatures and fans, with optional local Codex / Claude Code model usage — and
lets you act on it: spin the fans up, keep the Mac awake with the lid closed, clear caches, fully
uninstall apps and disable startup items. Network details also check how clean your public IP is —
whether it is flagged as a VPN, proxy, data center or for abuse.
All system-monitoring metrics are read on your own Mac and are never uploaded. No XStats account is required: configure a WebDAV server yourself to manually back up and restore preferences; XStats does not provide or preconfigure a sync server. Update checks send the current version and the SHA-256 of a random installation ID for deduplicated installation and version-distribution statistics; the original random value remains in local preferences, is not a credential, and is excluded from WebDAV sync. Other optional network features include a public-IP and cleanliness lookup, a ping probe, and a daily update check.

[Download](https://github.com/ysicing/xstats/releases) ·
[Changelog](CHANGELOG.md) ·
[Development](DEVELOPMENT.md)

[简体中文](README.md) · **English** · [日本語](README.ja.md) · [한국어](README.ko.md)

</div>

## Calendar
Enable the independent date item in **Settings → Menu Bar → Calendar**. Browse months and years,
return to today, and select a day for details. Gregorian dates stay visible; lunar dates, weekdays,
festivals, solar terms, Chinese holidays and makeup workdays, sexagenary cycles, dog days and
traditional plum-rain days each have a display switch. Tibetan and Hijri details are opt-in.
The item stays separate when metrics are combined; calendar preferences are included in WebDAV backups.

Calculations run locally using [Tyme4Swift 1.5.0](https://github.com/6tail/tyme4swift), licensed under MIT
(see [third-party notices](ThirdPartyNotices.md)). Browse 1900–2100; Tibetan data covers Gregorian
1951-01-08 through 2051-02-11. Chinese holiday data currently ends in 2026; unsupported dates show a notice.
Plum-rain days follow traditional calendar rules and are not weather forecasts.

Click a day for its traditional almanac: favorable and avoided activities, Na Yin, clashes, day deities, twelve-hour fortunes, twelve officers, fetal deity, Peng Zu taboos and lunar mansions. Returning to the month preserves the selection.


---

## Install

Download the Apple Silicon build from [GitHub Releases](https://github.com/ysicing/xstats/releases).
If no build is available, follow the [development guide](DEVELOPMENT.md) to build from source.

XStats has no website yet. Automatic updates and the existing GeoIP service are unchanged; account login has been replaced with manual WebDAV sync.
The update installer still verifies bundle identity and signatures: packages built for OpenStats cannot replace XStats.

Requires an Apple silicon Mac with macOS 14 (Sonoma) or later. The interface supports Simplified Chinese,
Traditional Chinese, Japanese, Korean, English, German, Spanish, French and Arabic.
It detects your preferred system language by default. Search and switch languages in Settings → General → Language;
Arabic uses a right-to-left layout.

## Recent updates

<!-- changelog:start -->
<!-- Generated from CHANGELOG.md by Scripts/sync_changelog.py. Do not edit by hand. -->

Latest release **0.8.0** (2026-09-23) · [full changelog](CHANGELOG.md) (kept in Chinese)

<!-- changelog:end -->

## Activity

<p align="center">
  <img src="Assets/readme/activity.svg" alt="Commits per day over the last 26 weeks" width="760">
</p>

<p align="center">
  <a href="https://star-history.com/#ysicing/xstats&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=ysicing/xstats&type=Date&theme=dark">
      <img alt="Star history" src="https://api.star-history.com/svg?repos=ysicing/xstats&type=Date" width="760">
    </picture>
  </a>
</p>

## At a glance

<p align="center">
  <img src="Assets/readme/overview-dark.png" width="49%" alt="Main window dashboard, dark">
  <img src="Assets/readme/overview-light.png" width="49%" alt="Main window dashboard, light">
</p>

## Where the numbers show

**Menu bar**
- Eight styles, chosen once for every metric: two-line text, one-line text, icons, rings,
  pies, history bars, level meters and status dots. Any metric can be given its own style;
  Settings previews each one with sample data and says what the shape means.
- Network speed in two rows with dots or arrows, or on one line — green for upload, blue for
  download, always with its unit (`KB/s`, `MB/s`, `GB/s`).
- Small and consistent type: 7 pt labels over 10 pt figures, 11 pt on one line, 9 pt for
  network speed. Figures are fixed-width, so the bar does not jitter. Hover for every reading.

<p align="center"><img src="Assets/readme/menubar-dark.png" width="600" alt="Menu bar"></p>

**Detail popovers** — each metric gets its own menu-bar item; click it for a narrow popover.
Choose which sections each popover shows in Settings. `Esc` closes it.
- **CPU.** Usage with a status and 30-second change, thermal headroom; a per-core heatmap; load by core type;
  queueing (load average per core, rising or falling); usage summed by app.
- **Memory.** What is still available with a pressure timeline; a waterline bar; memory saved by compression and
  live swap I/O; usage summed by app.
- **Network.** Traffic history; a connection-probe grid (green when reachable, red when not, last 60 pings); interface,
  Wi-Fi signal, VPN / proxy; local and public IPv4 / IPv6 with a flag, region and ASN; an IP cleanliness score with an F to A+
  grade and risk flags (VPN, proxy, Tor, data center, abuse); DNS flush
  and one-click switching to Cloudflare, Google, Tencent, Alibaba Cloud or manual servers;
  per-process traffic.
- **Disk.** Startup disk capacity as a segmented bar (used, purgeable, available); read / write speed with a
  60-second history; SSD health; the apps reading and writing the most.
- **GPU**, **Temperature & fans.** History, sensor groups, fan speeds and quick modes.
- **Battery.** Charge level, time remaining, adapter wattage and battery temperature; a 24-hour charge curve; power draw; health and cycle count; the batteries of connected Bluetooth devices (AirPods, Magic Keyboard / Mouse / Trackpad). Macs without a battery show the Bluetooth devices only.
- **AI Usage & Quotas**: reads local Codex / Claude Code session logs for token totals, cache hit rate, daily trends and model ranking. Defaults to a one-year activity heatmap; switch between daily, weekly and cumulative year views and filter by model. SQLite persists parser checkpoints and statistics across restarts; appended logs are read incrementally. When enabled, it also reads local CLI login credentials and directly queries five-hour and weekly quotas.
When both sources are enabled and at least one has quota data, the menu bar AI item shows Codex and Claude separately; a source without quota data shows a dash, and the tooltip lists reset times.

<p align="center">
  <img src="Assets/readme/popover-cpu-light.png" width="32%" alt="CPU popover">
  <img src="Assets/readme/popover-disk-light.png" width="32%" alt="Disk popover">
  <img src="Assets/readme/popover-memory-dark.png" width="32%" alt="Memory popover, dark">
</p>

**IP cleanliness check** — see at a glance whether your public IP is clean: the CleanIP.io score with an F to A+ grade
band, a risk score and the risk flags it hits (VPN, proxy, Tor, data center, abuse history and more); the IP address
block marks native vs. broadcast and residential vs. data center with badges. IPv4 and IPv6 are checked separately,
and results are cached on the Mac for 7 days unless the address changes or you refresh.

<p align="center">
  <img src="Assets/readme/ip-purity-light.png" width="40%" alt="IP address and IP cleanliness, light">
  <img src="Assets/readme/ip-purity-dark.png" width="40%" alt="IP address and IP cleanliness, dark">
</p>

**Main window** — a sidebar with Dashboard, This Mac, History, CPU, GPU, Memory, Disk, Network, Temperature & fans,
Battery, plus the Processes, Startup items, Keep awake, Clean and Uninstall tools; resizable in both directions. See [Cleanup](#cleanup).

**Explain a process with Apple Intelligence** — on supported macOS versions, right-click a process to ask the on-device model what it does, whether its resource use is normal, and what quitting it may affect. If the model is unavailable, XStats shows the reason and does not call another provider. Verify the answer before quitting a process.

White and blue in light mode, black and blue in dark mode — one look across windows and popovers,
switched with one click or following the system.

<p align="center">
  <img src="Assets/readme/thermal-dark.png" width="49%" alt="Temperature & fans">
  <img src="Assets/readme/keepawake-light.png" width="49%" alt="Keep awake">
</p>

## Fans and sleep

| Fan mode | What it does |
|---|---|
| Auto | Hands the fans back to macOS |
| Cool | Holds them at 60% between minimum and maximum speed |
| Max | Full speed |
| Custom | A slider, anywhere in the fan's range |

In Custom, the fans are handed back to macOS the moment the CPU reaches the safety
temperature (95 °C by default). Quitting XStats, or the app crashing, restores automatic
control. Running with the lid closed switches itself off on battery below a floor you choose.

Both need system privileges, provided by a small helper registered with `SMAppService` and
approved once in System Settings → General → Login Items. The helper offers a fixed set of
operations — set a fan's target speed, return fans to auto, toggle `pmset disablesleep`,
flush the DNS cache, purge memory — and **never runs arbitrary commands**. It checks the
caller's code signature, restores fans and sleep when the app disconnects, and after an
unclean exit restores them at the next boot.

## Cleanup

- **What it scans.** App caches, logs and crash reports, browser caches (Chrome, Edge,
  Brave, Arc, Firefox, Safari), Xcode DerivedData, simulator caches, npm, Yarn, pnpm, Bun,
  Go, Rust and uv caches, Xcode archives, unfinished downloads, installers and the Trash.
- **Review first.** Sizes by category, every rule expandable to its items, a second click to
  confirm. Caches and logs are deleted outright so the space comes back at once; downloads go
  to the Trash. Developer-tool caches are cleaned by their own commands rather than by
  deleting internal folders; the Trash preference applies only to folder-based caches.
  Developer-tool caches start unselected and remember their local selection afterwards.
- **Safety.** Only allow-listed folders are ever touched. Keychains, password managers,
  VPNs, cookies and history are off limits. Caches of running apps are skipped, browsers must
  be quit first, and every item is checked again right before it goes. Each action is logged
  to `~/Library/Logs/XStats/cleanup.log`.
- **Maintenance.** Flush the DNS cache and purge memory — through the helper if it is
  installed, otherwise after a one-time administrator prompt.

<p align="center"><img src="Assets/readme/cleaner-light.png" width="600" alt="Cleanup"></p>

## Uninstaller and startup items

- **Uninstall apps**: lists third-party apps in Applications with their size. Pick one or drop an app in, and XStats finds
  what it left in your Library — app data, caches, preferences, sandbox containers, saved window state, logs, web data and
  login items — each of which you can untick. Confirming moves everything, app included, to the Trash (restorable) and
  removes its Dock icon. Matching is by bundle identifier and same-named folders only; built-in and Apple apps are not
  listed, and running apps must be quit first.
- **Startup items**: lists LaunchAgents for the current user and all users, plus system LaunchDaemons, with the owning app,
  executable, whether it runs at login or is kept alive, and whether it is running, loaded or disabled. Your own items can
  be disabled or re-enabled in place (recorded in launchd's disabled list and unloaded, no files deleted); the rest are
  read-only, with a shortcut to the system Login Items settings.

<p align="center"><img src="Assets/readme/startup-items-light.png" width="600" alt="Startup items"></p>

## Your data

Metrics come from the kernel (`host_processor_info`, `host_statistics64`, `sysctl`), IOKit and the
SMC on your own Mac. Preferences live in the app's user defaults. Apart from update-statistics aggregates and settings backups you manually upload to WebDAV, the app's other persisted data stays on your Mac. Network tools still send the requests needed for a lookup or test to the relevant third party.
Monitoring metrics, history, the hardware serial number and process lists are never uploaded.

Every feature that touches the network can be turned off. Public IP and connection probes live on the Network page, update checks in Settings → About:

- **Public IP**: when you open network details, one request to Cloudflare `1.1.1.1` (ipify as fallback)
  for your public address, cached for 10 minutes. Location, ASN, network type and the cleanliness score
  come from `cleanip.io`, queried directly from each Mac with nothing but the public address and never
  through our servers; a result is kept for a week unless the address changes or you refresh.
- **Connection probe**: an ICMP ping to the target you pick (Cloudflare, Google, Alibaba Cloud,
  Tencent or your router) once a second while network details are open (every 10 seconds in the background), only while the network item is in the menu bar
  or network details are open.
- **Update check and installation statistics**: at launch and once a day, the app sends the current version and the
  SHA-256 of a random installation ID and reads the version manifest. China-region locales prefer
  `x-stats.china.12306.work`; all others prefer `xstats-apps.12306.work`. The app falls back serially to the other endpoint
  only after a failure and stops after the first success. The server stores only that
  hash, the current version, first and last check times, and the check count; it does not store a hardware serial number
  or persist request IPs (an IP is used only for an in-memory one-minute rate limit). The original random value stays in local preferences and does not access Keychain. Turning off automatic update checks stops these
  automatic requests. When a new version is out it asks; nothing installs without your click.

**AI Usage & Quotas** is off by default. When enabled, local token statistics read only Codex / Claude Code session logs; quota checks read CLI login credentials and contact `chatgpt.com` / `api.anthropic.com` directly for five-hour and weekly usage. Tokens go only to the corresponding provider and are not saved in XStats preferences or its statistics database. Session logs are not sent with quota requests; quota failures do not affect local statistics.
The last successful quota for each source stays in a local SQLite database. XStats shows it with its fetch time after a restart, then replaces it when a scheduled or manual refresh succeeds. Authentication failure or removal of a manual configuration clears that source’s cache.

If local Codex or Claude Code sign-in cannot provide quota data, you can configure a separate Sub2API HTTPS address, admin email and password, and account ID for each source in AI Usage & Quotas settings. Each fallback is used only when that source's automatic lookup fails, and XStats checks the account platform before displaying its quota. Background requests use `force=false` to read cached data without triggering an active probe. Five-hour and seven-day windows are supported, along with Sonnet and Fable weekly windows when a Claude account provides them. The two admin passwords stay separately in this Mac's Keychain; connection settings stay local and are excluded from WebDAV backups. Sign-in sends the admin email and password to the configured Sub2API server; quota data is never uploaded to XStats servers.
When Sub2API provides no Fable value, the page says that quota data is unavailable instead of treating the missing value as 0% used.

WebDAV sync sends only preferences when you configure a server and start a transfer manually. It excludes monitoring data, history and WebDAV credentials.

Read the [Privacy Policy](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Privacy.en.md) and [Terms of Service](Packages/XStatsKit/Sources/XStatsUI/Resources/Legal/Terms.en.md) in the repository or under Settings → About in the app.

### WebDAV settings sync

1. Create a directory on your WebDAV server, then open **Settings → Settings Sync**.
2. Enter the directory's HTTPS URL, username and password (or app password), then save. Basic authentication and a valid TLS certificate are required; redirects are rejected, so use the final directory URL.
3. **Upload Local Settings** writes xstats-settings.json. Confirming the upload replaces any previous file; changes from other Macs are not merged.
4. On another Mac, configure the same directory and select **Download and Apply**. The backup is checked before you confirm applying it to local preferences.

Sync is manual; nothing is uploaded at startup, on wake or when a setting changes. Configure each Mac separately.
Passwords are stored only in the local Keychain. The JSON backup is not encrypted at rest by XStats, so use a private WebDAV directory.
The first download returns “no remote settings file” until you upload once. Files over 1 MB, invalid backups and unsupported versions are rejected without changing local settings.
Legacy GitHub/Google/Apple login and the old account backend have been removed. Settings sync only needs your WebDAV server.

Apple process explanations stay on device; process information is not sent to another AI service.

## Development

See [DEVELOPMENT.md](DEVELOPMENT.md) for secondary development, builds, tests, versioning,
signing, releases and project structure. See [ARCHITECTURE.md](ARCHITECTURE.md) for deeper
architecture notes.

## Acknowledgements

XStats builds on these open-source projects. Thank you.

| Project | Author | License | What XStats took |
|---|---|---|---|
| [OpenStats](https://github.com/gentpan/OpenStats) | GiantAccel, LLC | MIT | The upstream project on which XStats is based; thank you for making it open source |
| [Stats](https://github.com/exelban/stats) | Serhiy Mytrovtsiy | MIT | SMC access, the Apple Silicon fan unlock sequence and the menu-bar mini widget metrics |
| [Mole](https://github.com/tw93/Mole) | tw93 | GPL-3.0 | Which folders are worth cleaning and which must never be touched; the cleaner is an independent Swift implementation and contains no Mole code |
| [QuotaBar](https://github.com/gentpan/quotabar) | GiantAccel, LLC | MIT | This README's layout, the changelog sync and the activity chart |
| [AI Usage](https://github.com/burakgon/ai-usage-menubar) / [OpenUsage](https://github.com/robinebers/openusage) | Burak Gon / Robin Ebers | MIT | AI provider contracts and test fixtures |
| [usage-bar](https://github.com/methol-dev/usage-bar) | Krystian | BSD-2-Clause | Provider state and last-good-value design references |

Details in [ThirdPartyNotices.md](ThirdPartyNotices.md).

XStats is an independent third-party app. It is not affiliated with, endorsed by, or
sponsored by Apple or any other company it mentions. Their names and logos belong to their
respective owners.

## License

New XStats code and modifications are licensed under **AGPL-3.0-or-later**. See [LICENSE](LICENSE) and [licensing scope and contribution requirements](LICENSING.md) (Chinese).

Upstream OpenStats code retains its [MIT license and copyright notice](LICENSES/OpenStats-MIT.txt). Other third-party terms are listed in [ThirdPartyNotices.md](ThirdPartyNotices.md).
