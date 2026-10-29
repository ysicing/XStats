# XStats architecture

XStats is a native macOS 14+ menu-bar application for Apple Silicon, using Swift 6,
AppKit window and status-item controllers, and SwiftUI views. XcodeGen reads
`project.yml`; testable code lives in `Packages/XStatsKit`.

This document describes ownership, data flow and constraints. Commands, signing,
validation and release procedures belong in [DEVELOPMENT.md](DEVELOPMENT.md).
Detailed product guides are indexed in [README.md](README.md).

## Products and modules

| Location | Responsibility |
| --- | --- |
| `Apps/XStats/App` | Main application entry point and application metadata |
| `Apps/XStats/Widget` | Sandboxed WidgetKit extension |
| `Apps/XStats/Helper` | Privileged, allowlisted XPC operations |
| `Apps/Capture/App` | Independent Capture application |
| `Apps/NetworkMonitor/App`, `Apps/NetworkMonitor/Extension` | Independent network component and its system extension; macOS 15+ |
| `Packages/XStatsKit/Sources/XStatsUI` | Application state, AppKit controllers and SwiftUI presentation |
| `Metrics`, `SMC` | Demand-driven collection, hardware access and fan control |
| `AIUsage`, `WidgetData` | Magpie API models/client and shared widget summaries |
| `Cleaner`, `HelperShared` | Cleanup safety/operations and privileged IPC contracts |
| `AudioControl`, `AudioDSP` | Core Audio control, per-application routing and real-time processing |
| `NetworkObservation` | Network component discovery, authenticated IPC and connection models |
| `CaptureCore`, `CaptureUI` | Shared capture engine and workspace for both hosts |
| `Updates`, `WebDAVSync`, `Localization` | Updates, explicit settings synchronization and translations |
| `server/api` | Regional update API, signed-feed forwarding and legacy JSON compatibility |

Module names in the table refer to `Packages/XStatsKit/Sources` unless a full path
is given. The main app, Capture and network component have independent product
identities and release versions. Main-app changes normally reuse the installed
network component; only the component embeds the network extension.

## State, sampling and persistence

`AppController` coordinates application lifetime. `AppModel` combines settings,
visible surfaces and feature controllers; `MetricsHub` owns one demand-driven
sampling loop. Views consume published snapshots rather than starting collectors.

- **Enablement** permits collection. **Demand** comes from displayed menu readings,
  visible pages/popovers, enabled alerts, history recording and safety consumers.
  Enabling a feature alone does not request continuous sampling.
- Adding a monitoring menu item enables its module; removing it only hides the item.
  Disabling a module clears live data, removes its ordinary monitoring entries and
  stops related alerts and new history records. Existing history and settings remain.
- Energy retains the persisted `battery` identifier and controls temperatures, power,
  App Energy, sleep assertions and battery history/alerts. Fans retain `thermal` and
  remain independent. Preserve these identifiers and their migration behavior.
- Battery basics and its selected menu entry survive Energy being off; adding that
  entry does not enable Energy. Display information is likewise independent of
  enabling DDC/CI parameter controls.
- Disabled monitoring pages show hardware/basic information without mounting live
  charts, rankings or controls. Disk capacity and local network information use
  one-shot reads on appearance; these reads do not create continuous demand.
- History requests enabled CPU, memory and network readings at the background
  interval. Other metrics retain their visibility-driven recording. Empty demand
  stops the loop; new demand refreshes immediately.
- Lock, sleep and inactive surfaces release or reduce demand. Cancellation and
  generation checks reject queued results; feature gates are checked again before
  publishing or recording. Safety consumers, including fan protection and lid-closed
  battery protection, remain until control has been safely handed back.

Collectors retain their own cadence within this loop: disk at most every 30 seconds,
battery every 10 seconds and IOReport roughly every two seconds. App Energy uses
process energy-counter deltas only while its section is visible, clears baselines
on suspension and bounds metadata to live processes. Its CPU energy reading is not
whole-application or whole-machine power.

Collection invariants:

- Release kernel allocations from `host_processor_info`; use the actual host page
  size for memory accounting. Process CPU and wall-time deltas share mach units.
- Read core groups from `hw.perflevelN`; incomplete topology falls back to one
  generic group rather than inferring core types from the chip name.
- Network rates use one selected interface's 64-bit `NET_RT_IFLIST2` counters.
  Automatic selection follows a physical routed service, avoiding physical/tunnel
  double counting. A missing manual interface stays selected with no traffic.
  Interface name/index changes, failures and counter rollbacks reset the baseline;
  cumulative reset baselines also belong to the current boot session.
- Per-process network traffic comes from bounded `nettop` sampling and need not sum
  to the selected interface's counters. Process and port views collect only while
  needed; failed reads clear live rates and cancelled reads cannot republish them.

`HistoryRecorder` stores bounded SQLite minute aggregates, retains eight days and
leaves gaps where collection was disabled. Preferences use `UserDefaults`; settings
backups use an explicit `SettingsDocument` allowlist. Credentials use Keychain.
Installation identifiers, machine-specific interface/device choices, private paths
and histories stay local. Shared preferences, including preferred AI account keys,
follow the settings document's explicit field contracts.

## Menu bar and window ownership

`MenuBarController` owns separate status items, a combined item, or the compact
three-part icon. AppKit controllers own panels and windows and host SwiftUI content.
Popover content is created on opening and released on closing. Detail expansion
adds only the detail's demand; collapsing or switching releases it. Hidden or
minimized windows cannot retain foreground sampling through a mounted view.

Combined mode opens the status overview by default. An opt-in advanced preference,
`combinedItemDetailsEnabled`, opens the clicked metric's standalone detail instead.
Hit regions come from the same rendering as the displayed image and also anchor
the panel. Gaps, the keep-awake marker and keyboard activation retain the overview;
the context menu and accessibility actions provide explicit overview access.
Changing this interaction or removing an open metric dismisses its detail.

`menuBarOrder` stores the complete metric order, including hidden items. Combined
indicators and overview rows share it; separate status items retain macOS ordering.
Drag operations preview a local draft and persist only a valid drop. Cancellation
or invalidation discards the draft; handles retain accessible move actions.

Combined mode follows the menu selection for Status Overview by default. Its opt-in
custom-display-locations setting enables an independent overview selection. First
activation copies the current menu selection only if no independent choice exists;
disabling it preserves that choice. Explicit empty selections and older backup
imports must retain their documented meaning. Adding an overview item follows the
same enablement rules as a menu item; removing it only changes that destination.

Custom popover content is a separate preference. Effective section visibility and
order drive both rendering and collection demand. Hidden sections keep their saved
positions; unavailable hardware is filtered without rewriting preferences. Main
pages keep their own layouts. Imported orders reject unrelated/duplicate keys and
append new sections in canonical order.

AI service order is independent of the four-service selection set. Reordering
replaces selected slots in the complete saved sequence, preserving hidden services'
positions and backup round trips. Its default order is Claude, Codex, Grok, Gemini.
Menu indicators, compact-icon quota dots and quota widgets consume this order;
changes reload widget summaries without another Magpie request.

Deep links use `AppDeepLink`'s fixed route allowlist and a bounded, serial command
queue. Navigation reuses controllers, repeated opens are idempotent, and disabled
optional features lead to settings without enabling themselves. Destructive tools
remain interactive entry points; lid-closed privileged actions are not dispatched
by deep link. The route contract is in the development guide.

Layout measurement must not create synchronous window-resize feedback. Menu images
reuse readings and invalidate on relevant style changes. Animations use existing
motion tokens, honor Reduce Motion and stop with their surface; high-frequency
menu actions remain immediate.

Experimental menu-bar folding is local to macOS 27 and explicitly selected apps.
It modifies only granted Control Center visibility fields, preserves unknown data
and rejects concurrent changes. A recovery journal precedes hiding and restores
only entries XStats changed. Failed restoration retains recovery state across
startup and requires an explicit quit decision; readback confirms preference state,
not that the system has visually applied it. Bookmarks and selections stay local.

## Magpie and widgets

`AIUsageController` reads only Magpie's public loopback quota and usage endpoints.
The default port is 3425; bounded local settings supply the port. Tests and native
screenshots inject `MagpieFetching`. The refresh default is five minutes; saved
intervals are retained, and token statistics can be disabled independently of quotas.

A refresh reads the visible usage period and today's total, plus cumulative usage
when the Token widget is installed. Usage requests run sequentially alongside the
quota request, with at most two requests in flight, four cached period summaries,
bounded timeouts, an 8 MiB response limit and rejected redirects. Pause/cancellation
stops work. Endpoint failures are independent and preserve stale last-good data;
yesterday's total cannot become today's total. Magpie availability determines the
connection/install guide; there is no second statistics source.

Quotas retain account boundaries and original window names. Preferred accounts are
configured in AI Usage and shared by the menu bar and all quota widgets. The default
is the first account Magpie returns for that service; `last` identifies recent
request handling, not routing preference. Saved identities use provider, kind,
remote source and user identity, falling back to name only without a user. Aliases
and plan names must not invalidate an established user identity.

A successful response that confirms account removal clears its preference and
restores following Magpie. Failed requests, unavailable quotas and ambiguous
identities preserve the choice. Only multi-account services expose default-account
actions, inline with their accounts; the title menu restores following Magpie.
An existing but unavailable preferred account is not silently replaced.

Menu-bar readings reuse `WidgetSnapshot.Quota`; activity requests and selection use
`MagpiePeriod`. Token totals are input plus output, with cache traffic separate.
Cost and request counts come from Magpie. Generation speed uses bucket
`decode_out * 1000 / decode_ms` only with positive duration and `decode_n`;
missing fields remain unknown rather than being estimated or filled with zero.

The WidgetKit extension has two data paths:

- System widgets sample CPU, memory, disk and battery independently through `Metrics`.
- AI, IP and calendar widgets read display summaries from the App Group. Only the
  main app queries Magpie. Snapshots contain no credentials or session logs; optional
  fields preserve decoding compatibility with installed older versions. Missing,
  unreadable or invalid snapshots mean unavailable data, not disabled features.

Quota widgets have four slots: 2-by-2 in small, one row in medium. Selected providers
with accounts present in Magpie come first in saved order, then other present
providers, then missing selected providers and default brands as gray placeholders.
Presence comes from the account list, not this refresh's quota success, so a transient
failure cannot reshuffle services. Old snapshots without a provider list retain
legacy placement. Account and appearance changes trigger the relevant reloads.

AI settings choose single-ring (default) or double-ring presentation globally. The
outer ring always means remaining quota; the optional inner ring means remaining
weekly time only for known weekly windows with reset dates. Relative reset labels
and hourly precomputed entries update through the next reset or midnight without
extra polling. Bundled brand mappings use explicit provider IDs and appearance-aware
logos. The cumulative Token widget receives bounded input/output summaries; its
daily secondary value resets at local midnight.

Calendar widgets read eight days of holiday/almanac summaries and six-week grids
for the current and next month. Missing coverage retains Gregorian dates without
inventing holiday/lunar annotations. Shared-container validation requires authorized
team signing; an ad-hoc preview cannot establish working App Group access.

## Hardware and privileged operations

`SMC` discovers plausible temperature keys and samples bounded groups rather than
hard-coding chip models. Fan reads are unprivileged; writes pass through the helper.
Unknown capability must not rewrite saved visibility. Manual mode is verified by
readback: try directly, then use optional `Ftst` only if present and needed, with
bounded retries even when that key is absent. Chip generation is not a capability
check. A manual fan not owned by XStats remains another controller's responsibility.

The helper is registered with `SMAppService.daemon`. Its fixed XPC interface accepts
allowlisted operations, validates arguments and requires exact identifiers, matching
signing teams and a compatible version handshake. Registration alone is not readiness;
ad-hoc builds cannot register or use it. The current contract lives in `HelperShared`.
Fan and sleep changes requiring recovery are journaled locally and reverted on the
last client disconnect or next startup. Failed handoff retains recovery ownership;
the service exits after its client-free idle interval. Maintenance fallbacks keep
their existing explicit administrator prompts and fixed operations.

`DisplayController` keeps display inventory independent of parameter control.
DDC/CI uses runtime-resolved native APIs, exact connection identity and validated
replies. Ambiguous matches disable controls. Each write rechecks capability/range
and confirms by readback; values are never automatically restored. Visible controls
poll with cancellation and connection-generation guards. One bounded serial slot
contains blocking calls: a caller timeout does not free a still-blocked native call
and permit accumulating retries.

## Network details and observation

`NetworkController` separates local interface reads, optional connection probes,
public-IP lookup and process traffic. Wi-Fi reads use CoreWLAN/SystemConfiguration
and existing foreground demand, without scanning. Bluetooth and network subprocess
reads use bounded executors; suspension cancels work and rejects late results.

Public-address lookup obtains the requesting Mac's exit and metadata, with explicit
IPv4/IPv6 handling, bounded caches and rate-limit backoff. Disabling lookup clears
its cache and invalidates outstanding work. Menu-bar location reuses this result.
The on-demand IP comparison sheet keeps each source's address and metadata together.
This path is separate from the network observer's downloaded geography tables.

`EgressWindowSession` owns routing, WebRTC and DNS tests as one window session.
Opening or rechecking starts them together; category changes only change presentation.
The shared environment watcher restarts on network change and checks missing,
unfinished or stale results on reopen/resume. Failure alone does not retry on every
watcher tick. Closing, hiding, minimizing, lock and sleep stop active work while
retaining completed results.

WebRTC uses an ephemeral WebView and one PeerConnection per STUN service; a native
deadline handles throttled WebKit timers. Completion/cancellation closes connections
and releases the bridge/view. DNS probes use bounded requests and service-observed
resolver records. Empty or failed tests cannot imply safety, and address differences
must not be treated as proof of leakage. These tests describe XStats' request path.

The optional network observer requires macOS 15+. Its independent companion owns
system-extension activation, authorization and removal through an on-demand
LaunchAgent. The main app has no embedded extension or extension-install entitlement.
Installation verifies exact product identity, same-Team signing, notarization and
Gatekeeper. Versioned control/data contracts authenticate both peers; extension
changes require a new build number for macOS activation to replace installed code.

The filter always allows connections and observes metadata only. A visible reader
renews a six-second lease through two-second reads. Without a reader, observation
expires even after GUI failure. Verdict handling does not wait for observation locks.
Events use a bounded 256-entry ring, batches of at most 64 events below 256 KiB,
epoch/cursor validation and active-ID snapshots; the UI retains at most 512 entries
in memory. Missing active-ID support is an upgrade error. Three consecutive read
failures stop the viewer; no background retry timer remains.

Local geography uses validated DB-IP Lite IPv4/IPv6 tables, fetched only while needed
and reused for 30 days. Bounded downloads, decompression and hashing run off the main
actor. Both tables must pass size/hash checks before an atomic generation switch;
failure preserves the previous cache. Map pins aggregate countries, not device
positions. No per-connection geolocation request or on-disk connection history is made.

Shutdown/update/removal serializes SDK state changes and acknowledges handoff before
releasing ownership. Pending-reboot removal retains the companion. Control services
start on demand and exit when idle. Component versions, signing profiles and release
procedures remain independent; see the development guide for installation validation.

## Cleanup and application services

Cleanup candidates pass `SafetyGuard` at scan and immediately before execution.
Roots are allowlisted; path traversal, unsafe symlinks, protected data and running-app
conflicts reject an operation. Recent files and incomplete scans must not appear safe
or complete. Cache deletion and user-file recycling retain their different semantics.

Native developer-tool operations execute reviewed `ToolCachePlan` values. Resolved
roots and command options are pinned through execution; failed resolution cannot
fall back to guessed directories. Exclusions apply to both previews and actual
operation scope. Generic scans exclude native-tool roots to avoid double counting
or bypassing protections. Full rules, catalogs and Mole boundaries are in
[CLEANUP.md](CLEANUP.md).

Application services are always available and group Apps, Homebrew, Startup Items
and Services. The legacy uninstaller switch no longer gates access. Reads are
visibility-driven and cancellable; in-progress mutations finish under their existing
ownership and quit guards. Launchd operations are limited to supported user-owned
entries. Homebrew mutations share one operation state; uncertain timeout outcomes
require reconciliation rather than blind retries. Uninstall revalidates ownership,
shared containers, duplicate apps and protected paths before recycling selected items.

Disk tools reuse bounded scans and fixed validated helper operations. Analysis and
verification remain distinct from explicitly confirmed snapshot deletion or repair.

## Audio, calendar, timers and Capture

Core Audio HAL access and writes are serialized. Device identity and generation
checks reject stale work; mute, routing and listening-mode writes use bounded
confirmation. Listeners belong to visible controls and stop on close or suspension.
Bluetooth matching uses normalized hardware addresses, not device names; optional
controls require advertised capabilities. Battery reads share demand and connection
events, coalesce changes and stop on inactivity without nearby-device discovery.

Per-app audio is opt-in on macOS 14.4+. Default-output 100% remains native passthrough.
Adjusted apps own bounded tap/aggregate pipelines (at most eight), with a bounded
paused-playback grace period. Saved gains/routes stay local and do not persist PIDs.
The real-time callback allocates no memory or locks; changes ramp and use a limiter.
Only active pipelines share a health timer and a bounded repair budget. Failed stop
retains resource ownership until confirmed cleanup instead of forgetting live objects.
Disabling processing removes its demand while preserving settings and system controls.

`CalendarEngine` confines Tyme's mutable tables to the main actor. Civil dates use
the selected calendar/system timezone rather than adding 86,400 seconds. Unsupported
holiday years stay unknown. EventKit access is opt-in and limited to the visible
calendar range; private event identifiers do not enter backups or widget summaries.
Standalone calendar status-item and date/wake updates retain their own lifecycle.

Countdown, Pomodoro, stopwatch and eye-break controllers use absolute monotonic
deadlines and reconcile after wake rather than accumulating ticks. One-shot event
timers schedule transitions; second-by-second display timers exist only with visible
demand. Competing sessions use explicit pause/resume coordination. Focus/rest history
is bounded and written off the main actor. Sound previews and playback have explicit
ownership; imported audio is validated, app-owned and excluded from settings backups.

Capture's shared engine supports embedded and standalone hosts without starting
monitoring. Permission prompts follow capture demand. Recording queues and temporary
storage are bounded; stopping producers, export cancellation and recovery retain
ownership of unfinished media. Active-session locks protect caches across hosts.
See [CAPTURE.md](CAPTURE.md) for capture/export contracts, cache policy, independent
release details and historical validation limits.

## Updates, synchronization and diagnostics

`UpdateController` owns one long-lived Sparkle updater and custom user driver.
Sparkle owns scheduling, skipped versions, signature verification and confirmed
installation. Automatic downloads/installation stay disabled. Regional feed failures
try remaining endpoints serially; archive/install failures do not restart installation
through another endpoint. XStats preserves its UI, notification preferences and
availability state without another check timer.

The regional API forwards original signed XML bytes selected by the published
manifest and retains legacy JSON compatibility. Artifacts use immutable versioned
URLs; upload and public hash verification precede manifest publication. Chinese and
English summaries are validated against release sources. Local release gates cover
full tests, source provenance, signing, notarization, Gatekeeper, public hashes and
update endpoints. GitHub Actions is asynchronous and is not a release gate.

Update requests include the product version and hashed installation identifier.
Existing random identities remain stable; new ones hash the local serial or use a
saved random fallback. Raw serials are not sent and identifiers are excluded from
settings backups. Main-app, Capture and component update lifecycles remain separate.

WebDAV synchronization is an explicit, single in-flight HTTPS GET/PUT of an allowlisted
settings envelope. Requests reject redirects, bound downloads to 1 MiB and use normal
certificate validation. Upload confirmation overwrites without merging or automatic
retry; download validation and confirmation precede applying preferences. Cancellation
or failure leaves settings intact. Endpoint credentials stay in local Keychain;
settings documents contain no connection credentials or monitoring history.

User-facing strings use `Localization` and the application locale for dates/numbers,
including RTL layouts. Tests prefer explicit translation tables; changes affecting
global language state require full-suite isolation checks. Public screenshots use
isolated demo data through the documented native snapshot entry points; generation
and privacy checks are in the development guide. Historical measurements in
[PERFORMANCE.md](PERFORMANCE.md) retain their stated
build, hardware and coverage limits rather than implying current energy results.

Lifecycle, significant operation outcomes and recovery use Apple unified logging.
Sensitive errors are bounded/private; protocol stdout remains machine-readable.
On-device process explanations and diagnostic subprocesses are bounded and cancellable.
Diagnostic export bounds duration/size and redacts addresses and home paths.
