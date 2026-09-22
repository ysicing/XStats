# XStats

macOS 14+ menu-bar system monitor. Swift 6 language mode, AppKit status item and panels
hosting SwiftUI, no third-party dependencies. The Xcode project is generated from
`project.yml` by XcodeGen; everything testable lives in the local Swift package.

- `App/` — `main.swift` and the asset catalog.
- `Widget/` — the sandboxed WidgetKit extension (“System overview”), embedded in `Contents/PlugIns`.
  It samples CPU, memory, disk and battery itself through `Metrics`, so it works without the app.
- `Helper/` — the privileged helper (`XStatsHelper`) and its launchd plist, embedded in
  the app bundle for `SMAppService.daemon`.
- `Packages/XStatsKit/Sources/Localization` — `tr(_:)`, language resolution and nine-language catalogs (see below).
- `Packages/XStatsKit/Sources/SMC` — the AppleSMC user client, fan control, temperature
  key discovery.
- `Packages/XStatsKit/Sources/Metrics` — one sampler per metric and `MetricsHub`; power and CPU
  frequency (`PowerSampler`), disk activity and NVMe SMART (`DiskSamplers`), Bluetooth battery,
  the SQLite history store.
- `Packages/XStatsKit/Sources/Cleaner` — cleanup rules, `SafetyGuard`, `CleanEngine`, the app
  uninstaller's leftover search and the launchd startup-item list.
- `Packages/XStatsKit/Sources/Updates` — the update manifest and the download → verify →
  replace → relaunch steps.
- `Packages/XStatsKit/Sources/HelperShared` — the XPC protocol and maintenance commands
  shared by the app and the helper.
- `Packages/XStatsKit/Sources/WebDAVSync` — manual WebDAV GET/PUT and endpoint-specific Keychain passwords.
- `Packages/XStatsKit/Sources/XStatsUI` — design tokens, panel pages, settings,
  menu-bar renderer, app controller, snapshot renderer.
- `Packages/XStatsKit/Tests` — metrics, SMC decoding, cleanup safety, updates, UI logic and
  localization.
- `server/api` — the Fiber/GORM update API, SQLite installation counters and server-rendered statistics dashboard.

## Build

**Xcode 26 or later is required** — CommandLineTools does not ship the SwiftUI macro plugins.

```bash
brew install go-task xcodegen
task build            # Release build, then replace /Applications/XStats.app and relaunch
task test             # swift test in the package
```

Versions read `1.0.0 (110)`: `MARKETING_VERSION` is the semver from the first release heading in
`CHANGELOG.md`, while `CURRENT_PROJECT_VERSION` is an independent, monotonically increasing build
number. `task build` advances only the build number (`BUMP=0` skips it); `task release` takes the
public version from the changelog and advances the build number once. Every `task build` runs
`Scripts/install_local.sh`: it ends the running app (the helper restores fans and sleep when the
connection drops), deletes the old `/Applications/XStats.app`, *moves* the new bundle there so no
copy stays in the build folder, re-registers it with Launch Services, and relaunches. Only one
XStats ever exists on the machine, so Spotlight and the widget gallery never show duplicates.
`INSTALL=0` compiles without installing; `Scripts/release.sh` uses it and installs the notarized
build at the end.

`project.yml` defaults to ad-hoc signing so the project opens anywhere. The Taskfile.yml passes
the first Developer ID Application identity from the keychain (and `--timestamp` for Release)
when there is one. `task release` runs `Scripts/release.sh`: build, verify team, timestamp and
hardened runtime on both binaries, notarize and staple the app, build and notarize the DMG,
write the online-update zip and `appcast.json`, and write a Homebrew cask (`auto_updates true`)
whose URLs point at the object storage prefix `https://c.ysicing.net/oss/apps/macOS/XStats`.
The release records the source commit plus version-file hashes in `dist/release-provenance.json`;
publishing accepts only a clean descendant that changed release metadata, so the Git tag cannot
silently include source different from the packaged binaries. `task release-all` runs tests, builds,
commits and pushes only release metadata, then publishes every external target; `task publish`
resumes the idempotent external half without rebuilding. The helper derives its client
requirement from its own signing team at run time, so no team ID is hard-coded.

## Sampling

`MetricsHub` is an actor that runs one loop. `AppModel.demand` describes what is on screen —
which menu-bar items are enabled, whether the panel is open and on which tab — and the hub
samples only that: CPU always; memory and network cheaply; GPU, disk, processes, sensors and
fans only when a visible surface needs them. Disk is read at most every 30 s, battery every
10 s. The loop pauses on screen sleep, system sleep and session switch.

Things that are easy to get wrong and are handled on purpose:

- `host_processor_info` returns kernel-allocated memory; it is `vm_deallocate`d every sample.
- `getifaddrs`' `if_data` counters are 32-bit and wrap at 4 GiB; network uses
  `NET_RT_IFLIST2` and `if_data64`.
- Memory follows Activity Monitor: app memory is `internal − purgeable` pages; the page size
  comes from `host_page_size` (16 KB on Apple Silicon).
- Process CPU time and wall time are both in mach absolute units, so their ratio needs no
  timebase conversion.
- Core types come from `hw.perflevelN`; logical CPUs are numbered from the lowest
  performance level up.

## SMC

Temperatures are not hard-coded per chip. On first use the sampler enumerates every SMC key
once (≈3,800 keys in about 10 ms on an M5 Max), groups `Tp*`/`Te*` as CPU, `Tg*` as GPU,
`Tm*` as memory, `TB*` as battery and `Ts0P`/`Ts1P` as palm rest, keeps keys whose first
reading is plausible, and samples at most 12 per group.

Fans are read without privileges. Writing needs root and goes through the helper. On M5
the mode key (`F0md`) accepts a direct write; M1–M4 first need `Ftst=1` and a pause while
`thermalmonitord` lets go. The firmware records only manual or automatic, not who set it, so
a fan in manual mode that XStats did not set is shown as controlled by another program.

## Helper

Protocol 5 removes the identifier-only ad-hoc authentication fallback. Ad-hoc apps refuse helper
registration and unregister any previously registered helper without connecting to it. Fan and
lid-closed controls require team signing; maintenance operations keep their existing admin-prompt fallback.
Readiness requires an authenticated version handshake, not just an enabled SMAppService registration.
For older helpers, the client unregisters the service before re-registering the current bundle and
verifying its version. Unregister/handshake failures leave privileged calls disabled and surface an error.

Registered with `SMAppService.daemon`; `RunAtLoad` so that an unclean exit is repaired at
boot. The XPC interface is a fixed list of operations — no arbitrary commands — and each
connection gets `setCodeSigningRequirement`. State that must be undone (manual fans, disabled
sleep) is persisted to `/Library/Application Support/XStats/helper-state.plist` and
reverted when the last client disconnects or at the next start. The helper exits after 30 s
without clients.

## Cleanup

Every rule lists candidate items; every item passes `SafetyGuard` twice — at scan and again
right before deletion, because apps start in between.

- Deny by default: an item must sit strictly inside an allow-listed root under the home
  folder, never be the root itself, contain no `..` or control characters, and still pass
  after symlinks are resolved (resolution can only reject, never allow).
- Under `Application Support`, only folders named like caches (`Code Cache`, `GPUCache`,
  `CacheStorage`, …) are allowed.
- Any path component matching a protected keyword (keychains, password managers, VPNs,
  cookies, history, …) is rejected.
- Reverse-DNS cache folders whose app is running are skipped; browser rules are blocked while
  the browser runs; items modified in the last two minutes count as in use.

Regenerable caches are deleted outright; user files go to the Trash. Each action is appended
to `~/Library/Logs/XStats/cleanup.log` as a JSON line.

## Disk tools

The disk page is also where users act on the disk. `DiskToolsController` (`XStatsUI/State`) fronts four
pieces of read-mostly logic in `Cleaner/DiskTools.swift`, each testable without the UI:

- `SpaceScanner` walks a root (the home folder) once, sums every top-level entry and keeps the largest files;
  packages (`.app`, `.photoslibrary`, …) count as one item. It never follows symlinks and skips folders it
  cannot read. `canTrash` allows Trash only for files inside the home folder, outside `Library`, with no hidden
  path component, checked again after resolving symlinks; everything else only gets "reveal in Finder".
- `VolumeVerifier` runs `diskutil verifyVolume /` (read-only, no privileges) and reduces the output to OK /
  problem plus the offending line.
- `LocalSnapshots` parses `tmutil listlocalsnapshots /`. Deleting goes through the helper
  (`deleteLocalSnapshots`, protocol version 4) and falls back to a one-off administrator prompt; both paths only
  accept identifiers shaped like `2026-09-14-120000` (`HelperShared/LocalSnapshotCommand`).
- `MountedVolumes` lists browsable non-root volumes; ejecting uses `NSWorkspace`.

## Menu bar, popovers and main window

`MenuBarController` owns the status items. In the *separate* layout every enabled metric gets
its own `NSStatusItem` (created in reverse so they read left to right) and opens a 320 pt
popover for that metric; in the *combined* layout a single item opens `CombinedPopoverView`: a status
overview with one row per enabled metric, plus tabs that switch to each metric's full popover content
(`PopoverDetail`, shared with the separate layout). While a detail tab is showing, `AppModel.openPopover`
is set to that metric so sampling matches the standalone popover.

Popovers are borderless, non-activating `NSPanel`s. The SwiftUI tree is created on open and
destroyed on close, so a hidden popover costs nothing. Height comes from measuring a flat,
scroll-free copy of the same view; placeholders keep that height stable until data arrives, and
the window is resized without animation because animating it makes SwiftUI re-lay out every
frame. Charts are drawn with `Canvas`, not Swift Charts.

The main window reuses the popover content with `isDetailPage` set (all sections, taller charts)
next to the dashboard and tool pages. Windows use a transparent, full-size-content title bar with
an empty compact toolbar, so the traffic lights sit on the same ground colour as the sidebar and
line up with the 40 pt page header; the app switches to a regular activation policy while a window
is open and back to accessory when all are closed.

## Network details

`NetworkController` runs only while it is needed:

- **Connection probe** — an unprivileged `SOCK_DGRAM` ICMP echo (`ConnectivityProbe`), matched on
  sequence number and a random payload token because the kernel rewrites the identifier.
- **Interface and addresses** — `SCDynamicStore` / `SCPreferences` for the primary and physical
  service, `getifaddrs` for addresses, CoreWLAN for signal and rate.
- **Public IP** — Cloudflare trace (ipify as fallback) for the address only. Location, ASN, network
  type, native / broadcast and the cleanliness score come from `cleanip.io/cli?json=1`, queried directly
  from each Mac by `PublicAddressLookup`. The endpoint only reports the caller's own address, so
  `AddressFamilyRequest` opens one Network.framework connection pinned to IPv4 and one pinned to IPv6
  (URLSession cannot choose the family) and speaks plain HTTP/1.1 over TLS; when a pinned connection
  cannot be set up it falls back to URLSession and keeps the answer only if it is for the same family.
  If cleanip.io sees a different exit than Cloudflare (split-routing proxies), its address is shown.
  Results are cached per IP for an hour in memory and for a week on disk (failed lookups are not
  cached), and a 429 stops further calls until the next UTC day. Country
  codes are validated before being used as flag file names. `server/geoip/` still holds the systemd
  timer that syncs MaxMind GeoLite2 onto `getopenstats.com/geoip/` (account and key in
  `/etc/openstats/maxmind.env` on the server); the app no longer downloads those files, they are kept
  for other uses.
- **Per-process traffic** — cumulative bytes from `/usr/bin/nettop`, diffed between samples.
- **DNS** — `networksetup -setdnsservers` through the helper (protocol 3), which re-validates the
  service name and every address; without the helper, a one-off administrator prompt runs the
  same fixed command.

## Online updates

### Battery and Bluetooth

The battery item reuses `BatterySampler` (IOKit power sources, sampled every 10 s while the item is in the
menu bar or its popover / page is open). `BatteryPopover` is both the popover and the main-window page
(`DetailPage`). The 24-hour charge curve comes from the history database, which gained a `battery` column
(migrated with `ALTER TABLE` on first open); `HistoryRecorder.loadBattery()` queries it independently of
the History page's range. Macs without a battery show only Bluetooth devices, and the menu-bar segment
falls back to the Bluetooth device with the lowest battery.

`BluetoothController` (`XStatsUI/State`) wraps `BluetoothBatteryReader`, which shells out to
`system_profiler` and takes a second or two, so it polls only on demand: every minute while the battery
popover / page or the System page is open, every five minutes when the menu bar needs it (the
low-battery hint or a Mac without a battery), otherwise not at all. `AppModel.bluetoothDemand` derives
that from the same visibility state as `demand`.

`UpdateController` posts the current version and a hashed random installation ID at launch and daily.
China-region locales prefer `https://x-stats.china.12306.work/api/v1/update/check`; other locales prefer
`https://xstats-apps.12306.work/api/v1/update/check`. Failures fall back serially to the other endpoint,
and the first success stops further requests so one check is not reported twice. Requests use the stable
`XStats/<app-version> (macOS <system-version>)` User-Agent format for regional routing and diagnostics.
The original 32-byte
random value is generated with `SecRandomCopyBytes` and remains in the device-only Keychain; no hardware
serial number is used. The response has the same release manifest fields previously read from the static appcast (version,
date, notes taken from `CHANGELOG.md` by `Scripts/appcast.py`, zip URL, sha256 and size). An
update is installed only after: sha256 matches, the zip holds exactly one `.app`, its bundle ID and
version match, `SecStaticCodeCheckValidity` passes with a requirement pinned to the running app's
team, and `spctl --assess` accepts it (notarized). The old bundle is renamed into a same-volume
temporary folder, the new one moved into place (restored on failure; an administrator prompt is
used when the folder is not writable), and a detached shell waits for the process to exit before
reopening the app. After an update the old helper may still be running; the app unregisters an outdated
helper, re-registers the bundled version, and verifies the protocol before privileged calls resume.

`server/api` is one Go program. Fiber exposes `POST /api/v1/update/check`, authenticated
`PUT /api/v1/releases/current`, and the aggregate `GET /stats` dashboard. GORM uses
`github.com/libtnb/sqlite` with WAL and one database connection so concurrent checks cannot compete for
SQLite's single writer. Each installation row stores only the SHA-256 installation ID, current version,
first/last check times and check count; request IPs and monitoring data are not persisted. The release
endpoint requires `XSTATS_RELEASE_TOKEN`. `Scripts/publish_release.sh` uploads the dmg and zip to
object storage with `mc`, verifies each one by re-reading it from the CDN, creates the GitHub Release
that carries the dmg for manual downloads, and only then submits the generated appcast through
`Scripts/publish_api.py` to both regional services. The manifest lands last, so an installed app never
sees a version whose package is not yet in place.

`server/api/Dockerfile` cross-compiles a CGO-free binary for amd64 and arm64, then runs it as the
distroless `nonroot` user with `/data` as the writable SQLite volume. When a branch push changes
`server/**`, `.github/workflows/server-image.yml` builds both platforms and publishes
`ghcr.io/<owner>/xstats-server:<sanitized-branch>-<full-commit-sha>`. Pull requests do not run this workflow.

## WebDAV settings sync

Account login, OAuth callbacks and the old account backend have been removed.
Sync only needs the user's WebDAV server and does not run at startup, on wake or on settings changes.

WebDAVSync uses Basic authentication over HTTPS and reads/writes xstats-settings.json in an
existing directory via GET/PUT. The temporary URLSession does not share cookies or credentials,
uses normal certificate validation, refuses redirects, and streams downloads with a 1 MB limit.
GET requires HTTP 200; PUT accepts 200, 201 or 204. Writes are not retried automatically.
See [WebDAV PUT semantics](https://www.rfc-editor.org/rfc/rfc4918#section-9.7).

SyncController runs on the main actor and allows one request at a time. Upload requires confirmation
and overwrites the remote file without merging. Download validates a SettingsBackup envelope
(format, version, timestamp and SettingsDocument schema), then waits for confirmation before applying
the existing per-field validation. Cancellation and failures do not change local preferences.

SettingsDocument remains an explicit allowlist. WebDAV credentials, connection settings, local page,
helper state, monitoring data and history are excluded. Directory URL and username are saved separately
in local defaults. Passwords use the file-based login Keychain service work.12306.xstats.webdav,
with a separate account hash for each endpoint and username. Password storage must succeed before
new connection details are committed. JSON backups are not additionally encrypted at rest.

Configure every Mac separately. This version does not create remote directories, poll in the background,
merge concurrent edits, or use iCloud. A missing remote file requires an initial upload.

## Power, disk and history

- System, adapter and battery power come from SMC `PSTR`, `PDTR`, `PPBR`. GPU power comes from the
  IOReport *Energy Model* `GPU Energy` counter; CPU energy counters on recent chips barely update,
  so CPU power is not shown. Cluster frequencies are residency-weighted averages of *CPU Complex
  Performance States*, using the `voltage-states*-sram` tables of `pmgr` (Hz on older chips, MHz on
  newer ones). Each IOReport sample costs about 5 ms of CPU, so it runs at most every 2 s and only
  while a page shows it.
- Disk activity diffs `IOBlockStorageDriver` statistics; SSD health reads the NVMe SMART log
  through the system `NVMeSMARTLib` plug-in (no root).
- `HistoryRecorder` folds each sample into a per-minute record (averages, CPU and temperature
  peaks, worst memory pressure) and writes it to `history.sqlite`; records older than 8 days are
  pruned hourly. Queries bucket by 1, 5 or 30 minutes and charts break lines across gaps.

## Localization

Source strings are Simplified Chinese. `Scripts/l10n_wrap.py` wraps every Chinese literal in
`tr(...)` (skipping logger calls, `case` patterns and multi-line strings) and lists the keys.
`tr` returns the source for Simplified Chinese. English uses the Swift tables; Traditional Chinese,
Japanese, Korean, German, Spanish, French and Arabic load bundled TSV catalogs from Localization/Resources.
Exact keys take priority, followed by templates with {} or numbered placeholders. Captured strings
are translated recursively; inserted values are not reinterpreted as placeholders. Missing entries
fall back to English, then the source. Translation tables are immutable; global language and caches
share a lock because background collectors also call tr.

The language picker uses a searchable native popover, native language names, a selected checkmark,
and keyboard navigation. Search accepts Chinese, English, native names and language codes.
Automatic detection walks global AppleLanguages in preference order, distinguishing zh-Hans from
zh-Hant/TW/HK/MO and falling back to English if no supported language is found. Existing system,
chinese and english preference values and WebDAV settings remain readable.

Changing language rebuilds SwiftUI roots and AppKit menu/window titles. Each SwiftUI window and popover
receives the selected locale and layout direction; Arabic uses right-to-left layout and isolates
interpolated paths/numbers with Unicode directional isolates. Dates use L10n.locale. For remote geographic
data available only in Chinese/English, other languages use English names; country names use the locale.
Some macOS-provided names follow the application's AppleLanguages on the next launch.

The nine supported languages are zh-Hans, zh-Hant, ja, ko, en, de, es, fr and ar. Snapshots accept these
codes through --snapshot <dir> --language <code>, include the language picker, and record missing
translations in untranslated.txt. New interface strings must be added to all catalogs; coverage and
placeholder checks accompany the localization tests.

`--snapshot <dir>` renders every main-window page, popover, settings section and the menu bar in light and
dark, through real `NSHostingView`s in off-screen windows — `ImageRenderer` washes out pages
that contain bitmaps.
