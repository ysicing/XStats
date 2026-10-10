# XStats architecture

macOS 14+ menu-bar system monitor. Swift 6 language mode, AppKit status item and panels
hosting SwiftUI. The Xcode project is generated from `project.yml` by XcodeGen;
the app's testable components live in the local Swift package. For directory layout, build, test,
and release instructions, see [DEVELOPMENT.md](DEVELOPMENT.md).

## Deep links

The app registers only the `xstats` URL scheme. `AppDeepLink` parses a fixed ASCII route allowlist
independent of saved preference names; it rejects credentials, ports, queries, fragments, escaped
paths, unknown commands and links over 2048 bytes. AppKit's URL delegate feeds a bounded queue of
16 typed commands, drained serially on the main actor after application controllers are ready.
No raw URLs are retained or logged. Termination cancels pending commands.

Navigation reuses existing window and popover controllers. Repeated opens do not toggle a visible
surface closed; missing menu items fall back to main-window pages. Disabled optional modules lead
to Features settings without changing their preference. Pomodoro and ordinary keep-awake commands reuse
the existing controllers; explicit start/pause/stop are idempotent. Keep-awake links never dispatch
lid-closed privileged settings: a requested or active lid mode redirects to its page. Destructive
tools remain UI entry points. The public route contract is listed in DEVELOPMENT.md.

## Settings navigation

General contains app-wide preferences and keyboard shortcuts. Features contains the existing
process manager, Pomodoro and eye breaks, AI usage, audio, cleaner and menu-bar calendar switches.
It reuses their persisted preferences and enablement behavior; disabled rows remain available.
Disabled-module entry points lead to Features, including calendar and Pomodoro deep links.

## Sampling

`MetricsHub` owns one demand-driven loop. Basic monitoring has separate feature and menu-bar
preferences: `enabledMonitoringModules` gates CPU, GPU, memory, disk, network, thermals/fans,
battery/Bluetooth, and display parameter controls. Enabling a monitoring menu-bar item enables its module; removing the item
keeps the module enabled. Disabling a module removes its menu-bar items, clears live caches,
suspends its alerts, and excludes its values from new history records. Saved styles, alert
preferences, and existing database history remain intact. Settings backups include the feature set.

Enabled is permission to collect, not a continuous sampling request. `AppModel.demand` combines
visible pages/popovers, drawn menu-bar readings, history recording, and active alerts. History
continues to request enabled CPU, memory, and network readings at the configured background
interval; other metrics retain their visibility-driven recording. Hidden, disabled pages cannot
create demand. The normal app no longer primes every metric at launch; newly requested collectors
refresh immediately. When no samples are requested the loop stops, and cancelled generations do
not deliver queued snapshots. Late snapshots are also filtered against current feature preferences
before entering the store or history. Disk is read at most every 30 s, battery every 10 s;
IOReport remains limited to roughly every 2 s. Sleep and inactivity continue to pause the loop.

Safety consumers are explicit exceptions: lid-closed keep-awake retains battery protection, and
manual fan control retains thermal/fan demand until it has been handed back to macOS. A failed
handoff re-enables the thermal controls and reports the helper error. Display control and network
lookup/probe tasks follow their feature gates; stale network completions cannot publish after
disable. WidgetKit system widgets keep their independent sampling lifecycle, separate from the
main app's monitoring switches. Displays are an explicit exception: their switch gates only DDC
parameter reads/writes (brightness, contrast and volume). Device names, resolution and refresh rate
remain visible and refresh on system display events. The information-only menu-bar item is retained
when controls are off; showing it does not enable parameter control. Disabled control generations
cancel queued DDC work and discard late replies without clearing the display catalog.

The Features page uses two native segmented tabs, Basic Features and Optional Features.
Basic Features contains seven monitoring groups. Each row has a feature enable switch and
a directly visible Show in Menu Bar checkbox below its title, distinguishing collection from
display without repeating the switch state in text. AI Usage and Audio have the same display
checkboxes in Optional Features. Thermals exposes temperature and fan checkboxes separately, respecting detected hardware
support. Detailed appearance settings remain in the existing Menu Bar settings page. Display Parameter Controls is in
Optional Features; its information-only menu-bar toggle stays independent of DDC enablement.
Optional Features uses separate cards: Network Monitor, Processes, Uninstaller and Cleanup;
AI Usage, Audio and Display Parameter Controls; Focus & Eye Care; and Menu Bar Calendar.
Each card has consistent separators between rows, with no divider above its first row.
Uninstaller is also optional and off by default. Its preference persists in settings backups;
disabling it hides the sidebar entry, redirects its page/deep link to feature settings, cancels
scans and pending confirmations, and releases the running-application observer. Already-started
Trash operations finish normally; the feature switch is unavailable during removal.
The selector shares the fixed page header with its title; both tab lists start under a short
explanation at the same position. Pointer changes crossfade content using the existing 180 ms
opacity token, with no slide, bounce or animated row geometry. Keyboard and Reduce Motion changes
are immediate. Each tab starts at the top and changes no feature preferences. Tab selection is
transient window navigation state and does not enter backups or add sampling demand. Disabled metric pages show an
inline enable action rather than mounting stale detail views; the dashboard omits disabled cards.
Feature rows use immediate native control feedback with no additional state-text or layout
animation. Switches, sampling, menu-bar layout, and displayed metrics change immediately.

The full process manager is an optional module, disabled by default through `processesEnabled`.
Its sidebar entry and process-explanation shortcuts are available only when enabled. The process
hotkey remains registered: it opens XStats's process page when enabled, or macOS Activity Monitor
when disabled, without changing the module preference. Its settings label follows the destination;
the process-page header also provides a direct Activity Monitor button.
Disabling the module returns an open process page to Features settings, cancels an explanation,
and removes full-system process sampling demand. Existing CPU, memory and disk detail lists and
main-window overview app-usage lists retain their own visibility-based sampling. The compact aggregate menu-bar
overview only shows selected menu-bar metrics; enabling Processes adds neither a ranking card nor
process sampling to the collapsed overview. Expanding CPU, memory or disk details still requests
their process data. The feature row explains the resource cost of refreshing the process list
inline, before enabling, without a confirmation dialog. The preference is backed up; older documents without
it preserve the current setting. Saved process-page routes fall back to Features settings when disabled.

The sandboxed WidgetKit extension samples CPU, memory, disk, and battery through `Metrics`
independently, so it remains useful when the app is not running.
AI, IP, and calendar widgets instead read a credential-free App Group snapshot. The main app
precomputes an eight-day holiday and almanac window; missing coverage is shown as unavailable,
not guessed from weekdays.
The large month-calendar widget reads lightweight six-week grids for the current and next
month from the same snapshot. It keeps Gregorian dates visible if that cache is missing,
without inventing lunar or holiday annotations.
The daily Token widget receives only per-provider totals and the local day, never session logs;
its displayed count resets at local midnight even if the main app has not refreshed yet.
The tomorrow-work widget uses the official 2026 holiday schedule to distinguish statutory
holidays, adjusted days off, ordinary weekends, and makeup workdays; later years need their
own confirmed schedule before receiving those specific labels.
The combined solar-term and seasonal setting covers solar terms, dog days, traditional
plum-rain days, and the nine cold periods. Month cells and the large month widget show solar
terms on their dates, phase starts and the
plum-rain exit; the small daily widget and selected-day details keep the exact day count.
Existing solar-term, seasonal, dog-day or plum-rain preferences migrate to the combined
`seasonalInfo` setting if any were enabled. The new key invalidates old widget summaries
so both solar terms and seasonal annotations are regenerated.

Things that are easy to get wrong and are handled on purpose:

- `host_processor_info` returns kernel-allocated memory; it is `vm_deallocate`d every sample.
- `getifaddrs`' `if_data` counters are 32-bit and wrap at 4 GiB; network uses
  `NET_RT_IFLIST2` and `if_data64`.
- Memory follows Activity Monitor: app memory is `internal − purgeable` pages; the page size
  comes from `host_page_size` (16 KB on Apple Silicon).
- Process CPU time and wall time are both in mach absolute units, so their ratio needs no
  timebase conversion.
- Core types come from `hw.perflevelN`; logical CPUs are numbered from the lowest
  performance level up. The reported names distinguish super, performance and efficiency cores;
  groups are never inferred from the chip brand. Invalid or incomplete core counts fall back to
  one generic group covering all logical CPUs.
- CPU snapshots include macOS `ProcessInfo.thermalState` through the existing sampling loop,
  without another timer or observer. Thermal pressure stays in the CPU header tooltip;
  elevated states add an inline warning beside temperature, also available without a sensor.
  It remains independent of SMC temperature. Temperature headroom uses 100°C only as
  a reference, not as a device-specific throttling threshold.

## SMC

Temperatures are not hard-coded per chip. On first use the sampler enumerates every SMC key
once (≈3,800 keys in about 10 ms on an M5 Max), groups `Tp*`/`Te*` as CPU, `Tg*` as GPU,
`Tm*` as memory, `TB*` as battery and `Ts0P`/`Ts1P` as palm rest, keeps keys whose first
reading is plausible, and samples at most 12 per group.

Fans are read without privileges. Writing needs root and goes through the helper. On M5
the mode key (`F0md`) accepts a direct write; M1–M4 first need `Ftst=1` and a pause while
`thermalmonitord` lets go. The firmware records only manual or automatic, not who set it, so
a fan in manual mode that XStats did not set is shown as controlled by another program.

Fan controls appear only after a positive fan count has been sampled. Unknown capability keeps
sampling demand active; a confirmed count survives transient read failures for the current run.
Capability filtering never overwrites the user's saved display preferences.

Zero-RPM fans use the firmware startup state when present, falling back to a positive manual
target only when that state is unavailable. A monotonic, per-fan 10-second window bounds the
startup label; persistent zero RPM remains visible after that window. No extra timer or fan
write is added, and existing thermal safety behavior is unchanged.

## Helper

Protocol 5 removes the identifier-only ad-hoc authentication fallback. Ad-hoc apps refuse helper
registration and unregister any previously registered helper without connecting to it. Fan and
lid-closed controls require team signing; maintenance operations keep their existing admin-prompt fallback.
Readiness requires an authenticated version handshake, not just an enabled SMAppService registration.
For older helpers, the client unregisters the service before re-registering the current bundle and
verifying its version. Unregister/handshake failures leave privileged calls disabled and surface an error.

Registered with `SMAppService.daemon`; `RunAtLoad` so that an unclean exit is repaired at
boot. The XPC interface is a fixed list of operations — no arbitrary commands — and each
connection gets `setCodeSigningRequirement`, derived from the helper's own signing team rather
than a hard-coded team ID. State that must be undone (manual fans, disabled sleep) is persisted
to `/Library/Application Support/XStats/helper-state.plist` and
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

Application uninstallation uses a separate controller and scans only app-specific paths.
Identity comes from the app's names and bounded embedded bundles (512 entries, 64 bundles,
depth 8); application groups come only from validated signatures. Container metadata identifies
UUID-named containers. Recent documents, CrashReporter, Sparkle and Sentry caches, vendor
subdirectories and explicit VS Code/Insiders/Arc/Chrome locations are covered. Shared groups,
helper data and name-only matches require review and start unselected. Shared parent directories
are retained. Scans and recycling reject redirected paths and validate each target again before
handing it to the system recycler. The current
bundle identifier is rejected in validation, drag-in selection and quit requests; the current process
is never terminated by the uninstaller. App-list and selected-app scans each own one cancellable task
and generation token. Background traversal is structured under those tasks and checks cancellation
between files. Leaving the page, closing or minimizing the main window cancels scanning; completed
results are kept, while incomplete work resumes on reopening. Re-selecting an app cannot let an older
scan restore deselected files.

Trash operations are confirmed separately. The completion dictionary, rather than the number of
moved files, determines whether the app itself was removed. Only a moved app loses its list and Dock
entries. Successfully moved residue is removed from the selection; failed and unselected items
remain available for confirmed cleanup even after the app itself has been removed. Reported sizes include only files actually moved. This flow
currently does not unregister third-party background services or stop independently running helpers.

Homebrew cleanup uses `brew cleanup --prune=30 --dry-run` for candidates and the native cleanup
command after confirmation. Previews have a 60-second timeout and a 2 MB output limit; execution
keeps bounded diagnostics, supports cancellation, and reports only confirmed reclaimed space.
Homebrew caches stay outside generic cleanup rules; automatic updates and dependency removal are disabled.

Project-artifact scans run only on request, descend at most six levels, and flag recent seven-day
activity. Scan roots persist locally outside settings backups. App bundles, tracked Git content,
nested repositories, credentials and symlinks cannot become deletion candidates. Before moving a
selected item to Trash, recheck Git tracking and path identity; warn for cloud-synced locations.
Scanning and post-cleanup size checks respond to cancellation without publishing partial measurements.

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
overview of compact metric rows. Clicking a row expands its existing `PopoverDetail` inline;
only one row expands at a time. Summary rows remain visible, so their sampling demand is retained
alongside the expanded detail demand. Only visible system-metric rows raise the overview's
sampling rate; an empty overview or one containing only AI usage and displays retains the
configured background interval unless a live window or system-metric detail requires more.
Standalone AI usage and display popovers likewise keep the background interval.
The header keeps the main-window and settings
actions outside the scroll area; no bottom action bar is shown. Header and content contribute to
the same measured panel height. Collapsing or switching a row releases its
detail-only demand without rebuilding the panel. No timer or continuous animation is added.
The AI summary prioritizes the available subscription window with the least remaining quota,
including its provider and period; local Token usage remains in the expanded detail and is the
summary fallback when enabled and no subscription quota is available. Subscription quota has a
progress track matching the selected used/remaining percentage; unbounded Token counts do not.

The *iconOnly* layout draws only the XStats symbol (plus the keep-awake indicator when active).
It preserves selected metrics and styles; its 360 pt overview uses the same selection as combined
mode. Additional GPU, disk, battery, temperature and fan demand exists only while corresponding
rows or details are shown. A Mac without a built-in battery labels the row as Bluetooth devices
and shows the lowest connected accessory charge. The optional three-row process summary follows
`processesEnabled` and appears when all rows are collapsed;
it does not request full-system process enumeration. Closing the panel releases these demands,
while baseline CPU, memory, network, history and safety requirements keep their existing behavior.

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

Status-item drawing retains only the previous readings and image; unchanged readings reuse it,
while history styles also compare their history. Settings, language, appearance and layout invalidate
the image. Settings previews stop observing samples when the main window closes or minimizes.
Panel height updates coalesce absolute content measurements within a layout cycle and apply on the
next cycle; they never synchronously accumulate viewport deltas or replace actual interaction state.
Regression coverage includes `StatusPanelLayoutTests`.

Shared selection controls use `DS.Motion.select` to keep keyboard and eventless activation
immediate; pointer selection retains each control's existing transition. `dsSelectionAnimation`
removes self-drawn selection movement when Reduce Motion is enabled. Custom button press feedback
is separate from hover and disabled state, while interactive system glass keeps native feedback.
Supporting text colors are tested against window, card and elevated solid backgrounds in both
appearances. These policies add no timers or retained per-interaction state.

## Focus and wellness

`RestSession` uses absolute `mach_continuous_time` deadlines and recalculates after wake instead
of accumulating timer ticks. Rest features default off and require a manual start. Phase changes
preserve their remaining time. Duration changes do not pause or reset the current phase; a new length applies the next time that phase starts, while a phase that has not started uses it immediately. The UI has one focus flow, with
Start / Pause / Resume / End actions shared by the page and HUD. An opt-in setting starts the next
round automatically after a break; changing it preserves the current deadline and running state.
The stored `single`, `cycle` and `workday` preference values remain readable, with the latter two
represented by the same switch. End resets the session to its focus start without deleting today’s
completed count or activities. Phase selectors and mode selectors are absent from the main page. Daily completion counts
and HUD placement stay local. The Mini HUD uses a 276×184 panel with a stable time display, a
left close action, right style selector, and 32-point footer controls. Only non-control regions drag;
old restored window sizes are resized and clamped to the screen without discarding the saved origin.
The three presentations are digits, a progress ring and a progress bar; the historical `hourglass`
preference value now selects the bar. macOS 26 uses native Liquid Glass; macOS 14–15 uses
native frosted material without an opaque tint. Reduce Transparency and offscreen snapshots
use a solid fallback. Hover/press
feedback does not animate layout; progress updates reuse the existing demand-driven timer.
The menu-bar entry keeps a stable timer symbol and uses 12-point monospaced digits.
Current phase and pending eye-rest reminders are conveyed in its tooltip and accessibility label.
Curtains, the menu-bar timer and Mini HUD belong to the main app;
noise is synthesized through `AVAudioSourceNode` during rest or an explicit five-second preview. The Widget reads shared phase
and deadline values, so WidgetKit refresh timing cannot provide second-accurate reminders.

`WellnessController` coordinates opt-in eye-break reminders with Pomodoro and voluntary eye breaks.
One monotonic next-event timer schedules reminders; only an independent visible eye break needs its
own 1 Hz countdown. Embedded eye breaks reuse Pomodoro updates. Settings separate between-round and
long breaks from the eye-break duration and reminder interval. Lock/sleep cancels active eye breaks,
pauses reminder intervals and discards pending reminders without a catch-up burst.

The eye-break global shortcut uses the existing Carbon hotkey registration and wellness start path.
It is unbound by default, survives settings backup and restore, and opens Features when Focus & Eye Care
is disabled. Repeated activation during an eye break does not reset its deadline.

Reminders within five minutes of a Pomodoro break merge into the existing curtain. A completed break
satisfies the reminder. A voluntary eye break pauses focus and offers an explicit resume afterward;
an eye break during a Pomodoro break is bounded by that break’s deadline and does not double-count
rest time. Notifications use the existing delegate and respect permission/Focus settings.

`WellnessActivityStore` performs bounded SQLite operations off the main actor, recording only focus
and rest transitions in `Application Support/XStats/wellness.sqlite`. It retains at most 20,000 rows
for 90 days. The UI queries seven days on entry or activity events. Removed water/breathing rows are
ignored while their existing data and database schema remain intact; no destructive migration runs.
`WellnessPreferences` decodes remaining eye-break settings from older backups, ignores removed keys
and exports only the current fields. Clearing activity history starts a fresh active segment and
preserves legacy Pomodoro completion counts.

Break sound previews reuse the rest audio engine, end after five seconds, and stop on sound changes,
popover dismissal or suspension. A real break cancels the preview deadline and takes playback ownership.

Rest sound choices include light rain, stream and wind, synthesized locally alongside white and
pink noise. The persisted `rain` identifier now displays as Light Rain; older preferences and
backups remain valid. Natural soundscapes use sample-rate-aware low-pass bands with different slow gain envelopes.
Stream adds two short, overlapping bubble resonances with rising pitch and smooth attack/decay,
against a quieter flowing-water bed. Occupied voices are allowed to finish rather than cut off.
Coefficients are computed at creation or bubble onset; the audio callback owns its generator
and performs no allocation, UI access, locks or per-sample trigonometry. A 200 ms onset ramp avoids
an abrupt full-level first frame. The existing five-second preview and rest playback lifecycle
continue to stop the engine and release its configuration observer. No recordings, downloads,
microphone access or new dependencies are introduced.

Custom break audio is selected through the native file picker. `RestCustomAudioStore` validates a
regular file of at most 50 MiB, copies it to `Application Support/XStats/RestAudio` and validates the
copy before publishing metadata. Failed/cancelled imports keep the prior selection. Replacement
removes only the previously selected app-owned copy after the new one is published. Relative UUID
filenames prevent metadata from escaping the audio directory. Local metadata and audio are excluded
from settings backups; a custom selection exports as Off. No source-path bookmarks are required.
`AVAudioPlayer` loops the local file at the same low volume as built-in audio, and is released on
stop or switching back to a built-in sound. The existing five-second preview deadline still applies.
The preview button is hidden when sound is Off or no custom file has been selected.

## AI process explanations

The Apple Intelligence row in System Information and the process explanation card share a native
detail button and popover. It reads fourteen
feature settings and five model sets only when opened or manually refreshed. The feature configuration
section follows RemoveMacAI's `status` rules: managed-off, explicit-off, model-only state, then default
on, including absent and partially disabled preferences. All Siri and external integration keys are
read. Model-only features also honor the installed RemoveMacAI profile's restriction markers.
Configuration on does not establish Foundation Models readiness; the separate availability row uses
the public Foundation Models API. Detailed preference/model detection is gated to macOS
27, while the existing public Foundation Models availability summary remains available on supported
systems. Unknown inventory entries never contribute a fabricated zero to the total.

`AppleIntelligenceDiagnostics` isolates optional UnifiedAssetFramework inventory reads in a short-lived
copy of the current executable (`--apple-intelligence-report`), before UI, samplers or preference writes
are initialized. The caller bounds execution to five seconds and output to 64 KiB; dismissal cancels
and reaps that child. Blocking process work runs on a GCD utility thread, with a locked cancellation
flag and a bounded reap after SIGKILL; it never calls `waitUntilExit()` from a non-RunLoop thread or
blocks Swift's cooperative executor. Cancellation and the deadline are checked again after exit,
before decoding; empty or malformed output stays unreadable. No model reset, deletion, download override, settings write, timer or retained
inventory is added. A complete asset inventory takes precedence; if it cannot be read, each set's
read-only asset status is queried instead. Failed queries stay unknown rather than becoming zero.
The feature/asset identifiers were researched from RemoveMacAI and pared; the
read-only implementation is independent.

`ProcessExplainer` uses only the on-device Apple Intelligence model. It checks framework and
macOS support before exposing the action, then checks model availability at request time. If
the device, system setting or model is unavailable, the explanation card shows the reason and
does not call another provider. Successful requests stream local output and can be cancelled.
The model receives process identity, path, signer and resource usage; nothing is sent to a CLI
or network service. Model response instructions follow the resolved application language.
## Calendar

`CalendarMenuBarController` owns a separate, opt-in status item, independent of the metrics
layout and `MetricsHub`. It reuses `StatusPanel`, updates the displayed date every minute and
on day/time-zone changes or wake, and stops its timer when disabled. `CalendarPopover` uses a
six-week Gregorian grid (1900–2100) and month/year navigation. Clicking a day opens an almanac
page in the same panel; returning preserves the selected date and month. `CalendarAlmanac`
loads Tyme's daily advice, deities and hour fortunes only for the selected day and caches the
value model by civil-date ID. The twelve-hour grid uses early Zi through Hai, excluding the
next day's late Zi entry at 23:00; each cell exposes its exact time range in a tooltip. Browsing
history preserves the selection across midnight; a selection on today follows the new day.

`CalendarEngine` is the sole adapter for the pinned MIT-licensed Tyme4Swift 1.5.0 dependency.
All Tyme calls run on MainActor because upstream exposes mutable static tables; only value
models leave the adapter. Civil dates use the system time zone and calendar day arithmetic,
not 24-hour intervals. Tibetan conversion is guarded to the upstream Gregorian coverage
1951-01-08 through 2051-02-11. Holiday data currently ends in 2026; unknown years show a notice and skip legal-holiday
lookups. Changing to an unsupported display year clears the holiday overview before cache
reuse or daily planning, so the current year's countdown cannot appear in the next year.
Plum-rain dates describe traditional calendar rules, not observed or forecast weather.

Weekday headers and weekday labels in selected-day dates are always visible, matching the
month widget. Legacy `weekdays` settings are ignored without discarding other choices.
Selected-day almanac is always enabled; legacy `showAlmanac` preferences are ignored.
Details still calculate on demand, while widgets reuse the bounded eight-day summary.
The snapshot keeps `showsAlmanac = true` to invalidate old disabled-almanac caches.
Calendar enablement, optional features and week start persist through `AppSettings` and the
optional fields in `SettingsDocument`. Fresh installs take region defaults and `Calendar.current.firstWeekday`; existing installs
(an existing `calendarEnabled` key) without saved calendar values keep the legacy defaults and
Monday. Both then persist independently of later system changes; all seven weekdays are supported by the
settings picker, backups, month grids and widgets. Menu-bar lunar modes remain available in
every app language and use localized lunar dates when lunar display is enabled. Disabling
lunar display hides its menu-bar presets and text-style controls, renders the saved lunar
preset as date and weekday, and stops applying lunar text styles without overwriting them. Older backups preserve those settings. Additional
calendars default off and appear only in selected-day details. EventKit schedules and due reminders
are opt-in, request permission explicitly, and query only the visible panel's 42-day range. They are
read-only and excluded from widgets, settings backups and server requests; list IDs stay local.
Month data caches only the most recent month, keyed by week start and time zone. Event date markers
are computed in the worker actor; notifications coalesce for 300 milliseconds, and closing the panel
cancels pending refreshes. The panel measures its initial height once and scrolls subsequent changes.
Use `--snapshot <directory> --calendar-only` for deterministic
light/dark calendar screenshots without starting unrelated samplers or scans.

## AI usage and quotas

The local Codex provider reads JSONL rollouts from CODEX_HOME (default ~/.codex),
including sessions and archived_sessions. It never reads credentials or calls quota APIs;
independent quota providers do that only while the master AI Usage switch is enabled.
Parsing runs in a background actor pinned to a dedicated serial executor, so a cold scan (tens of
seconds over a multi-gigabyte log directory) never occupies a Swift concurrency cooperative thread
and cannot stall per-second metric sampling. It uses bounded line buffers and a SQLite checkpoint store at
~/Library/Application Support/XStats/ai-usage.sqlite. Each source/path row atomically stores file
identity, size, mtime, newline-aligned byte offset and Codable parser/aggregate state. The preview
state is stored only when the final line is still unterminated, so the common case keeps one copy.
Rows whose files were not seen in a completed scan are pruned, which covers rollouts moved to
archived_sessions, deleted project directories and superseded parser namespaces. Unchanged
files reuse stored results even after restart. Appends validate prefix/boundary hashes and read
only the suffix; truncation, replacement, parser namespace or time-zone changes rebuild that file.
An unterminated final line is previewed separately from committed state, so completing it cannot
double-count usage. No raw log lines, prompts or credentials are persisted. Directory metadata is
still enumerated on each scheduled refresh; only currently discovered files contribute to totals.
The dashboard defaults to today and retains the last 365 local-calendar days by model. It shows
input/output tokens, cache hit rate, record count, period totals and model ranking. The menu bar shows today's token total.
Cached input is a subset of input; reasoning is a subset of output, so neither is added twice.
Rows are aggregated by day and model before leaving the provider, and ordered by day then model, so
`ModelTokenUsage.id` stays unique and an unchanged corpus produces an equal report. Each daily row
also retains a bounded histogram of hour-start timestamps to token counts (23–25 entries per local
day). Only same-day/model aggregation merges these histograms; period totals and model rankings
sum numeric fields without constructing a year-long hourly map. Parser namespace v3 rebuilds old
checkpoints once to recover hours, then resumes normal unchanged-file and suffix-only reuse.
Duplicate session IDs and unchanged cumulative snapshots are excluded. Child replayed history
only seeds the cumulative baseline until the first `task_started`, which always follows that
history; `started_at` is not compared against the session creation time, because a subagent's
`started_at` is its parent turn's start and recent Codex builds omit the field entirely.
Unknown models remain unknown.
Local logs cannot reliably identify the paying account or usage on other devices. Public base API
prices may estimate token costs, explicitly excluding tiered surcharges and subscription billing.
Subscription limits and HTTP success rates are not inferred from local logs. The separate quota
snapshot prefers the installed Codex CLI's local app-server `account/rateLimits/read`; the CLI
owns token refresh and XStats receives quota and read-only subscription/reset-credit metadata. If that path is unavailable, XStats
queries Codex `wham/usage` using its cached CLI OAuth token. Claude uses its CLI OAuth token for
`api/oauth/usage`. It maps five-hour and seven-day windows, plus Claude's model-specific weekly
windows, without combining them with local token totals. Direct credential discovery is repeated
on each refresh; Codex reads `auth.json` under CODEX_HOME or the standard locations, while Claude
reads its CLI credential file first, then a non-interactive Keychain item. The legacy login
Keychain does not honor `LAContext.interactionNotAllowed`: its interaction switch is process-wide.
XStats therefore reads that item in a short-lived mode of the same signed executable, before UI
or background services initialize, with `SecKeychainSetUserInteractionAllowed(false)`. This mode
requires its parent's code identity to satisfy XStats' own designated requirement, preventing
external callers from using XStats' Keychain authorization to extract a token. The parent
receives the token only through an anonymous pipe, with a 64 KiB limit, a five-second deadline,
and cancellation that terminates the child. Denied or locked items return unavailable without an
authorization prompt; neither credentials nor Keychain access controls are modified. Tokens are
not persisted by XStats. Each provider's last
successful quota snapshot is stored in a separate table of `ai-usage.sqlite`, without credentials.
The controller restores it before the first network request and labels it with its fetch time.
Requests use isolated URL sessions and reject redirects so bearer tokens cannot be forwarded.
Codex app-server uses bounded stdio JSONL and falls back to direct HTTP if unavailable.
An HTML 403 from an intermediary is a transient network failure, not proof of expired login.
Codex quota snapshots retain optional plan type, subscription validity, reset-credit count and earliest
available expiry. CLI camelCase and direct HTTP snake_case fields are normalized into the same summary.
Local ID-token subscription dates are accepted only for matching account IDs, and never inferred from
JWT expiry. Valid start/end claims supply a remaining-time progress bar; without a valid start only
the expiry date is shown, never an assumed 30-day cycle. This bar uses existing page/usage refreshes
and adds no timer. Reset-card count and earliest expiry sit next to the provider/plan heading. Old CLIs or missing claims leave the date absent. The direct fallback reads reset-credit
details only when the known count is positive, with a four-second timeout and no retry; an auxiliary
failure preserves the quota/count. No redeem/consume operation is implemented. Persisted metadata
contains no account identifier, token or reset-credit IDs; legacy quota snapshots still decode.
The existing per-provider Sub2API option is tried only after both automatic Codex paths fail.
Missing or expired credentials clear that provider's quota display; transient errors keep the last
successful result marked stale across restarts. Authentication failures or removal of a manual
account delete that provider's cached snapshot. Both quota readers stop when AI Usage is disabled;
disabled providers are hidden while their cached snapshot remains available on re-enable.
Codex and Claude Code each have an optional, independently configured Sub2API source, tried only
when that provider's direct quota fetch fails. Each HTTPS base URL, admin email and account ID remain
in local preferences outside settings backups; passwords use separate Keychain items. The fallback
signs in to its configured server, reads the account record to verify its platform (`openai` or
`anthropic`), then reads `/api/v1/admin/accounts/{id}/usage` with `source=active&force=false`.
If the detailed endpoint is unavailable, the account's `extra` fields provide coarser five-hour and
weekly windows. Claude may also expose Sonnet and Fable weekly windows. Credentials and quota results
are never sent to XStats servers; the UI marks fallback results as Sub2API.
When one provider has a subscription snapshot, the menu bar AI reading shows its name and remaining
percentage. It prefers the weekly window (or five-hour window if weekly is unavailable); the tooltip
shows the chosen window and reset time without crowding the 22-point menu bar.
When both sources are enabled and either has quota data, the item shows a compact named reading
for each source; one without quota data shows a dash. The tooltip lists reset times and missing
data by source. Without any subscription snapshot it keeps the local daily Token reading.
The AI menu bar item follows the global or per-item style. Ring, pie, meter, and dot styles
show remaining quota beside its percentage for each available source; a source without quota
shows a dash rather than a zero gauge. Since quota history is not stored, global history or
line styles use a current-value ring for this item.
Icon style uses the bundled OpenAI and Claude logo shapes for the corresponding quota source,
including a dash when that source has no quota; aggregated local-only tokens keep the generic AI icon.
The quota detail card presents remaining allowance (not used allowance) and, when the server
provides a reset date, a separate bar for elapsed time in that five-hour or seven-day window.
Allowance turns red as it runs low; the reset bar turns green as reset approaches and updates
while the view is open.
The UI follows CC Switch's filter/summary/trend/model-table organization, implemented in SwiftUI.
The desktop toolbar groups source controls and actions. In the compact menu-bar popover, its header
owns refresh and AI Usage settings; the content shows a source switch only when multiple sources
are enabled. Token totals use compact notation with
exact hover/VoiceOver values. Cache details are
disclosed on demand. AI usage settings open in a separate window so users can copy account details
from another app without closing the form. Unsaved Sub2API fields stay in memory for the current
app session across page changes; passwords are not written to preferences.
The main-window activity selector offers Today, 7 days, 30 days and Cumulative; menu-bar popovers
only offer the first three and select at most 30 days for charts. Today shows hourly bars;
the trailing 7/30 local-calendar days (including today) show daily bars. Cumulative shows a daily
heatmap over the retained 365-day window. Summary, cost estimate and model ranking use the same
source/model filters and time window as the chart. Hour buckets span actual 60-minute intervals from local midnight, with a shorter final bucket on
fractional DST days, so parser and chart agree even across half-hour daylight-saving transitions. Missing legacy hourly details
are reported, never assigned to midnight. Empty buckets remain zero and do not add to the totals.
The heatmap legend explicitly labels the daily peak, separately from the cumulative summary.
Pointer hover and accessibility expose exact bucket counts. The main-window year grid shrinks cells
to fit the available width. Charts have no timers
or continuous animation and use existing usage-refresh updates.
Numbers and dates follow the app language rather than the system locale.
Pointer selection fades only the selected control background (180 ms); keyboard selection and
background data refresh do not animate the data layout. Reduced motion uses the existing quick fade.

Claude Code is a second local provider. It scans projects/ recursively (including subagents) under
CLAUDE_CONFIG_DIR when set, otherwise ~/.claude and XDG_CONFIG_HOME/claude (default ~/.config/claude).
A checkpoint keeps every assistant event for its file, because the retention window is recomputed from
the current date on each fetch: a stored cutoff would freeze at the first scan and keep aged-out events
forever instead of dropping them.
Assistant message IDs are deduplicated across files: completed messages win over partial snapshots,
then the greater output count wins. Claude input is normalized as fresh input + cache reads + cache
creation; nested 5-minute/1-hour creation counts are a fallback, never added to the aggregate twice.
Independent local source switches enable Codex and Claude Code (both default on under the master
opt-in). Disabled sources are not scanned or included in cached reports/menu totals, and are hidden
from the source selector. Disabling the selected source resets the filter to all enabled sources.
Both switches may be off, in which case polling stops and the page offers the source settings.
The menu bar totals enabled sources for today; enabling the menu-bar item also turns scanning on,
since that item is the most natural place to discover the feature.
Refreshes are queued rather than dropped: a refresh arriving while another is in flight runs after it,
so rebuilding the polling cadence cannot mistake a skipped call for a completed initial refresh and
then sleep out the whole interval. Stopping cancels the in-flight scan. These settings are local and not synced through WebDAV.
Local usage aggregates are reused only while the file set, metadata, local date and time zone remain
unchanged. In-memory caching retains only the previous metadata and successful aggregate; failed
scans do not populate it. Incremental parsing checkpoints stay in SQLite. Regression coverage includes
`LocalUsageScanCacheTests` and `ScanCancellationTests`.
Cache creation is shown separately but already included in the input total. Claude credentials,
account data, Cowork containers and subscription limits remain outside the local scanner's scope;
the quota reader has no access to session-log content.

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
  codes are validated before being used as flag file names. The app does not download or read local
  GeoIP databases; the retired database synchronization and deployment scripts have been removed.
  Each public-IP query owns a cancellable task and generation token. Disabling lookup clears the
  cache and invalidates the query; sleep or lock pauses it. Every asynchronous stage and final cache
  write checks both generation and current settings, so late callbacks cannot restore cleared data
  or replace a newer lookup. An old completion cannot clear the newer query's loading state.
- **Per-process traffic** — cumulative bytes from `/usr/bin/nettop`, diffed between samples.
- **Menu bar IP location** — optional flag or localized region name after network speeds, disabled
  by default. The compact overview's network row follows the same display preference.
  Both read the same `NetworkController.publicAddresses.countryCode` as network details,
  including the selected IPv4 / IPv6 family and its fallback. It follows the existing cache and manual
  refresh, adds no network requests or timers, and hides when public-IP lookup is disabled or no region
  is available. Only the display preference is included in settings backups.
- **DNS** — `networksetup -setdnsservers` through the helper (protocol 3), which re-validates the
  service name and every address; without the helper, a one-off administrator prompt runs the
  same fixed command.

## Battery and Bluetooth

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
Charging state comes from named `pmset -g accps` accessory entries. For anonymous entries, it is
attached only when the reported percentage matches exactly one connected Bluetooth battery device;
ambiguous matches remain unknown. Disconnected cached devices never retain a charging label.

## Online updates

The current release's Chinese summaries come from `CHANGELOG.md`; `docs/ReleaseNotes.json` stores the
matching source summaries and one English translation. The XML publisher validates their version
and content, emits Chinese/English `description` nodes and signed `xstats:notes-zh-Hans` and
`xstats:notes-en` fields, and binds the translation file to release provenance. The custom UI shows
Chinese summaries for both Simplified and Traditional Chinese app languages, and English for all
other languages, without another request. Legacy feeds without English notes keep their original
description. The legacy JSON protocol continues to expose Chinese `notes` and the same ZIP metadata.
GitHub Release notes retain the full Chinese changelog section and append the same English release
summaries, including user actions and compatibility notes. Publication validates both sections before
uploading artifacts and uses the same bilingual body for release creation and edits.

The overview and standalone metric popover headers share a conditional update button; expanded
rows inside the overview omit it so each panel has only one entry. It opens the existing
update window from the cached release, without another check or an automatic install. Settings
buttons keep their existing destinations. Skipped versions are hidden immediately; after Sparkle
persists the skip, the matching cached release is cleared while a newer known release is retained.
The About badge uses the same availability state. Only live availability changes fade for 150 ms;
initial presentation is immediate, and Reduce Motion disables the fade.

`UpdateController` owns one long-lived Sparkle 2.10.0 updater and custom user driver. Sparkle
schedules checks, stores skipped builds, verifies signed feeds/archives and installs only after explicit
confirmation. China-region locales prefer `https://apps.china.12306.work/api/v1/apps/xstats/update/appcast.xml`;
other locales prefer `https://apps.12306.work/api/v1/apps/xstats/update/appcast.xml`, followed by the
overseas backup `https://apps-api.xiai.me/api/v1/apps/xstats/update/appcast.xml`. China-region order is
China, overseas primary, overseas backup; other locales try overseas primary, overseas backup, China.
Failed feed checks try each remaining endpoint once, serially; the cycle ends after the final failure.
Archive or installation failures never restart installation through a fallback. Each GET includes the current version and hashed installation ID, so no separate telemetry
POST or second check timer is needed. System profiling and automatic download/install stay disabled.
Existing installations retain the hash of their saved 32-byte random value, which remains in local
`UserDefaults` and is excluded from WebDAV settings sync. New installations without a saved value hash
the Mac serial number read through IOKit. If the serial is unavailable, they generate and save a random
value with `SecRandomCopyBytes`. None of these paths invokes Keychain authorization, and the raw serial
is never sent. Clearing preferences on an older installation can produce a new ID; historical rows are
not merged. The API selects the versioned sibling XML of the current JSON manifest's ZIP, with
`Cache-Control: no-store`, a ten-second upstream deadline and a 256 KiB read limit. It returns the
original signed bytes without holding a signing key. Publishing the existing manifest switches the
fixed feed immediately, while ZIP/XML CDN objects remain immutable. Old clients retain the JSON POST
protocol and existing installer.

`SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` require signed feeds and archive verification
before extraction. Inline notes, release date, manual DMG and full changelog links are part of the
signed XML. The driver checks the build, display version, URL, size and minimum OS against the user's
confirmed release before starting a new install or skip check. Sparkle owns the skip record through its
public user-choice callback; legacy skips and newly requested offline skips are held locally only until
the matching signed item can be passed through Sparkle's public skip reply.
Manual checks can still reveal skipped versions. Notification Center preferences, permission handling
and successful-submission deduplication remain in XStats; background discoveries never open a window.
A thin policy layer preserves launch-only success/retry semantics, quiet mode and calendar-month
intervals; Sparkle supplies the only check timer. Policy changes take effect through Observation.
The client no longer downloads the package twice to run a separate same-Team/Gatekeeper preflight.
Instead, release scripts enforce the expected Developer ID team, arm64, hardened runtime and secure
timestamps for the app, Widget, helper and every Sparkle executable, then notarize, staple and require
Gatekeeper acceptance before packaging. Public releases must keep these gates intact.

Downloads expose progress in the existing update window with redraws coalesced to half-percent steps.
Checks and downloads can be cancelled; extraction/replacement must finish once started. Widget
processes belonging to this exact installation path are stopped before installation; other installations
are untouched. The controller owns the updater; its user driver keeps only a weak updater reference,
so failures, retries and controller teardown do not create a retain cycle.
The shared `Updates.SparkleInstaller` implements the driver contract for both applications, while each
application owns its updater and release policy. Main-app feeds do not require network-extension
metadata, and main-app updates never replace the independently installed network component.
The component's updater uses its own build number and fixed signed CDN feed. The main app's existing
Sparkle check completion also requests one component check; there is no second scheduler or automatic
download/install. The main Settings and monitor menu expose component management, updates and removal. Before a
component update, its driver compares the signed extension version with the installed extension.
Only a changed extension disables the filter and queries its lifecycle status until shutdown is confirmed;
the same version reuses the existing extension. Component installation and user-requested termination
share the same preparation task. Failures cancel installation and restore the previous filter intent.
The main viewer restores its latest demand after component relaunch; explicit stop/cancel wins over an
earlier resume intent. The observation XPC listener lives with the extension
process so status remains available after filtering stops; configuration values, generic disconnections
and a resident process alone are insufficient evidence. Each extension build uses its own Mach service
suffix, and the installed build selects the old service for shutdown queries. Component ZIP validation
checks the exact root bundle path, application Bundle ID, extension Bundle ID and signed version metadata.
Versioned ZIP and XML objects are uploaded and read back before either regional JSON API is published;
old clients continue using the unchanged JSON response and their existing installer for the transition.
After an update the old helper may still be running; the app unregisters an outdated
helper, re-registers the bundled version, and verifies the protocol before privileged calls resume.

Current XStats requests use `POST /api/v1/apps/xstats/update/check`, authenticated
`PUT /api/v1/apps/xstats/releases/current`, and signed `GET /api/v1/apps/xstats/update/appcast.xml`.
The service keeps the original paths for installed clients; both route sets share the same XStats
release and installation records. The in-repository `server/api` retains the legacy implementation
and compatibility tests. The XML route verifies the original Ed25519 feed signature, RSS structure
and release/archive metadata before recording a successful check, then returns the signed bytes
unchanged. Invalid feeds return 502 without changing statistics; JSON checks remain independent.
Both regions use the client public key and must be updated together if it rotates. The service seeds
XStats on first startup, so routine releases keep the existing JSON fields without supplying application
metadata. New applications register their public key through their own publication path. Release and
admin endpoints require `XSTATS_RELEASE_TOKEN`. `scripts/publish_release.sh` uploads the dmg and zip to
object storage with `mc`, verifies each one by re-reading it from the CDN, creates the GitHub Release
that carries the dmg for manual downloads, and only then submits the generated appcast through
`scripts/publish_api.py` to all three configured endpoints across both regions. The manifest lands last, so an installed app never
sees a version whose package is not yet in place.

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

Source strings are Simplified Chinese. `scripts/l10n_wrap.py` wraps every Chinese literal in
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

## Display information and DDC/CI

`DisplayController` caches the public NSScreen/CoreGraphics display inventory and refreshes it on
screen-configuration events. The optional display menu item shows the count; the same information
and control view is available in This Mac. DDC polling runs only while that control view is visible,
at a five-second interval, and stops on close, lock or sleep. Dragging a slider defers polling; release
submits one target value. Wake and reconfiguration settling gates also block manual reads and writes.

`NativeDisplayDDC` resolves IOAVService and CoreDisplay entry points at runtime for the direct macOS
build. The information view remains usable if these entry points are unavailable. These non-public
control calls are not a Store-target compatibility claim; a future sandboxed target must exclude this
backend. Services are matched by the CoreDisplay registry location, not by a guessed model name;
ambiguous/missing matches disable controls. `DCPAVServiceProxy` is not a descendant of its
framebuffer, so it is paired by registry order and then rejected if the service's own EDID
(vendor, product, serial) disagrees with the CG display. An unreadable EDID is accepted only when a
single external display is online; with several, unverifiable proxies are rejected.
Match results, including misses, are cached per connection on the I/O queue and dropped on
screen reconfiguration or wake, so polling does not rescan the registry. Device signatures and
controller generations reject stale requests after reconnects. No brightness/volume/contrast values are automatically restored.

Only standard brightness (0x10), contrast (0x12), and speaker volume (0x62) are supported. An intact
Get VCP reply and nonzero range enable each control independently. Unsupported replies, invalid
frames, timeouts, busy transport, and unconfirmed writes remain distinct. Every set rechecks the
range and connection and reads the value back; a successful I2C send is never presented as proof
that the display applied it. No software dimming or speculative compatibility writes are performed.

Blocking native work uses one bounded serial execution slot with a two-second caller deadline.
A timed-out kernel call retains the slot until it returns, so retries cannot accumulate stuck work.
Each display read gets its own cancellation ticket, so one timed-out display does not skip the
others in the same refresh; a display that timed out last time is read last, so while its stuck call
still holds the execution slot, responsive displays are not starved by `.busy`. Cancellation is checked between bus operations; late results cannot repopulate a closed or replaced
view. Protocol, timeout, cancellation and write-confirmation tests use simulated devices. To generate
a repeatable, read-only report on actual hardware (no Set VCP):

```bash
XSTATS_DDC_READ_REPORT=/tmp/xstats-displays.json \
  swift test --package-path Packages/XStatsKit --filter DisplayHardwareReadTests
```

## Audio controls

The optional audio module is disabled by default. `AudioHardwareClient` reads Core Audio HAL devices,
volume and mute properties on a serial queue, checks the current device UID before writes, and
confirms mute writes by reading them back. Volume readback is published by the following refresh
rather than compared against a fixed tolerance, because devices may quantize to dB steps or accept
only per-channel writes. Mute readback checks every written element. Without a writable master
volume, per-channel writes scale the current channel values together to preserve balance, falling
back to one shared value when readings are incomplete or silent. Unsupported hardware controls remain unavailable; this path
is independent of display DDC/CI volume. Output and microphone selection use the system default
routing properties.
The system pickers and HAL default-device writes check each direction's
`kAudioDevicePropertyDeviceCanBeDefaultDevice` capability. Stream presence remains independent so
valid per-app output endpoints are not removed from the shared catalog. Capability changes are
observed without adding a polling timer.

On macOS 14.4 and later, explicit user activation starts a short unmuted tap/aggregate input to
trigger the system audio capture prompt. Its IOProc discards input, clears output and reports only
initialization progress; physical microphone streams are disabled. The local activation preference
is a user choice, not proof of a current macOS grant: Core Audio still enforces access when capture
starts. The legacy flag migrates to `audio.appVolumeEnabled` and cannot override an explicit newer
choice. Closing the controls, disabling or sleeping cancels pending activation without publishing
a late enabled state. Probe objects use the same owned cleanup path as other audio resources.
Applications keep stable rows while their audio connection is paused.
The visible application list excludes idle registrations that have never played during this run.
It retains playing apps, volume/mute or output-route adjustments, and previously playing or explicitly
reset apps while their Core Audio objects still overlap the current connection. Reconnection or module shutdown
discards this display history. The history is bounded by the sampled live objects, is not persisted,
and adds no polling. The full application snapshot remains available to the mixing lifecycle.
Applications with changed volume, mute or an independent output create private process taps and
aggregate outputs according to playback demand. Display history does not extend processing demand.
An unavailable selected device falls back to the system output while its preference is retained.
100% on the default output stays native passthrough. Per-app gains and output UIDs stay local and
are not included in setting backups; PID-based identities never persist.

Each application owns its pipeline, so another app's route change leaves it intact. At most eight
applications are processed concurrently, including paused applications in their grace window.
Existing pipelines keep their slots; excess requests create no HAL resources and are shown as
unapplied controls. System-output switches retain the prior slot identities until the transition
guard is released, restoring those apps before admitting new fixed-route processing demand.
A subsequent demand update retries capacity failures when a slot is freed.
Route replacement may briefly use one additional silent pipeline. Replacement
starts silently, waits for its first valid render frame, then stops the predecessor and ramps up.
All lifecycle work runs on a serial queue and checks cancellation between setup stages. Callback
contexts are retained until IOProc shutdown succeeds. A failed stop blocks replacement; retired
contexts receive at most two cleanup retries, then remain retained with a manual-retry error. Duplex hardware inputs are skipped and
disabled for the IOProc. Core Audio drift compensation clocks taps to the selected output; the
renderer supports compatible PCM formats and mono/stereo/channel mapping. Unsupported rates or
formats fail visibly. Failure caching blocks rebuilding the requested route, but still updates the
gain of any retained pipeline so subsequent volume and mute controls remain effective. System-output
switches use an owned temporary mute tap during replacement, including playing fixed-route apps
that currently use native passthrough on the system output. A failed destroy first attempts to
unmute it, retains the object and reports the error; the same bounded cleanup and manual retry path
also owns failed transition guards and activation probes. Disable/stop cleans guards even if the
switching caller has not yet returned its handle.

Stereo output follows the device's preferred left/right channel pair, translated through each
stream's starting channel and IOProc buffer offset. Interleaved and planar mapping supports pairs
within one output stream; ambiguous multichannel layouts or pairs across streams fail before taps
are created. A sole mono output downmixes, and standard 1–2 stereo keeps the Float32 fast path.
Preferred-channel and starting-channel changes invalidate the pipeline's format signature and use
the existing device listeners to trigger rebuilding.

The C callback allocates no memory and takes no locks. Gains use atomics, changes ramp over 40ms,
and 0–200% gain uses a channel-linked peak limiter with immediate attenuation and an 80ms release.
Callback frame progress uses a lock-free counter. A single health timer checks active pipelines at
1.5-second intervals with tolerance; it disappears when processing stops. A frozen pipeline gets
one automatic replacement, then returns control to native audio and exposes manual retry. A new
process/output configuration gets its own recovery budget; a replacement's first frame alone does
not replenish the old budget. No audio is recorded or uploaded.

Device volume writes are serialized and retain only the newest pending level per direction.
Each request captures its device identity, and HAL rechecks the current default before writing.
Per-direction sequence numbers reject superseded completion; readback publication also checks
both device ID and UID. Closing the feature or sleeping drops queued requests and rejects late completion; a HAL write
already executing cannot be assumed cancellable. Device/stream listeners drive discovery and
format changes. Some process playback flags change without delivering their registered HAL
notification. Application demand requires app volume to be enabled: before activation the visible
controls only show the authorization prompt and read neither the application catalog nor playback
flags. While application demand exists, a tolerant checker reads only process IDs, PIDs
and output-running flags every second for visible controls, or every two seconds for background
app-volume demand. Unchanged flags do not trigger device or application catalog reads. The full
snapshot acknowledges flags from the same reads used to construct application state, so a quick
playback transition cannot be acknowledged before its data is published. Checking stops when
application demand ends, on disable, and during sleep. Screen lock, display sleep and fast user
switching use the app's existing inactivity lifecycle to drop visible demand; only background
processing for saved adjustments remains. Closing the interface preserves requested app
adjustments; disabling and sleeping release unnecessary processing. App volume changes apply to the
mixer immediately, while preference encoding is deferred until 500ms of idle input and flushed on
stop. If a capture-permission failure disables app volume, empty demand is submitted immediately so
pipelines retained for other apps are torn down, and the permission prompt is preserved. A paused adjusted app keeps
its pipeline for 60 seconds after the observed playing-to-paused transition so resumed audio does not leak at the original
volume; one tolerant wake-up then releases it. Wake-up rebuilds only current demand.
Reconciliation that repeats the in-flight targets and output does not supersede it; the request is
rechecked once on completion, so HAL events from the mixer's own aggregate devices cannot cancel a
rebuild that is still waiting for its first frames.
Ordinary device switches and queued mute operations also receive cancellation when controls close,
the module is disabled or the Mac sleeps; cancellation is checked before HAL writes and after waits.
Writes already executing may complete, but late results cannot publish over a newer operation.

Audio presentation shares the same native controls across main window and popover. The window
uses adjacent input/output cards; the popover keeps a vertical layout. Sliders and numeric feedback
are immediate, with localized percentages and a distinct boost tone. Application rows use two lines:
an app/status header with percentage, mute and an options menu, followed by the 0–200% slider.
Independent output and reset actions live in the menu; playback and failure statuses share one fixed
caption line so controls do not move as state changes. Accessibility labels identify the affected app or audio direction, and
values use localized percentages. Device switching and pending app routes expose explicit status;
late or superseded completion cannot announce a stale successful switch. Only ongoing work displays
an indeterminate indicator; Reduce Motion uses a static hourglass. App icons load when bundle identity
changes, rather than on slider redraws. No decorative or idle animation is scheduled.
Device slider drafts distinguish dragging, waiting for the final write, and idle readback. Mouse-up
waits for the existing write/readback tasks before discarding the draft; new drags, device changes,
errors and disappearance invalidate old completion tokens without cancelling an in-flight volume
write or adding a refresh timer.

The audio device picker also includes paired Bluetooth audio devices whose selected direction is
not yet present in HAL. The paired catalog reads cached class/SDP information on page open and
when validating a user selection. It rechecks a permission failure once when the visible audio controls return to the foreground.
The activation observer is removed when controls close, the module is disabled, or the Mac sleeps;
successful catalogs do not refresh on every activation. It does not run discovery, SDP queries,
or background reconnects. A user selection opens the paired
connection on a serial background queue with a 10-second Bluetooth page timeout, then waits up to
8 seconds for the matching HAL address and direction. Names are not used as device identity. The
existing guarded device-switch path runs only after audio readiness. Closing the audio interface,
disabling it, or sleeping cancels pending selection; an already issued OS connection may still
complete, but its late result cannot issue an app-side route switch or clear a newer operation.

## Read-only network connection observation

The component logs lifecycle, registration, filter changes and update milestones through Apple's
unified logging subsystem `work.12306.xstats.networkmonitor`, with `service`, `registration`,
`filter` and `update` categories. Error descriptions are bounded to 1024 characters and private.
Routine status polling, download progress and observed connection payloads are not logged.
The system extension records only filter lifecycle and observation settings outcomes.
Diagnostic exports include the exact app, helper, component and extension subsystems and retain
address/home-path redaction. Unified-log collection stops after 15 seconds or 8 MiB and preserves
partial output with a truncation note. CLI registration continues to write only protocol JSON to stdout.

The optional Network Monitor module requires macOS 15+ and is disabled by default. The main
app and other features continue to support macOS 14. The feature switch, sidebar and routes are gated
on OS availability; saved preferences are retained, but cannot activate the module on older systems.
The controller and native backend also reject unsupported use. The system extension itself has a
macOS 15 deployment target. Enabling its feature switch only
exposes the page; the explicit viewer button installs a missing, independently signed
`/Applications/XStats Network Monitor.app` from the fixed c-ip ZIP alias, then asks this component to
activate `work.12306.xstats.app.networkextension` and configure its socket content filter after macOS approval.
The main `XStats.app` contains no system extension and has neither System Extension installation nor
Network Extension entitlements. Its first-install path checks the exact bundle identity, same-Team
signature, notarization and Gatekeeper before writing the missing component, and never replaces an
existing or running component. The component owns its extension and lifecycle operations through a
SMAppService LaunchAgent. Its stable user-domain Mach service is independent of the extension's
versioned data service. Both directions require exact Bundle IDs and the same Developer ID Team. The provider returns `allow` for every
flow, including errors and missing metadata. It never requests payload inspection, packet filtering,
pausing or dropping. A socket allow verdict requests a flow-closed report while observation is active;
the provider uses these metadata-only reports to remove closed IDs from a 512-slot active ring.
Batches include bounded active IDs so journal eviction cannot leave false active rows.
The host rejects replies without an active-ID snapshot with an explicit extension-update error.
Extension code or protocol changes require a new CFBundleVersion: macOS can retain an older
installed extension when activation requests have the same version and build number. Only connections
opened during observation are covered; pre-existing sessions are not enumerated.

A same-Team, exact-identifier XPC channel carries metadata only. The extension uses a 256-entry
ring and batches at most 64 events, bounded below 256 KiB including JSON escaping. Reads use an
epoch and cursor; replacement or restart resets the epoch. The UI retains at most 512 entries in
memory. Its native split view defaults to grouping by app and also groups counts by process, domain or country, with a linked country map
and connection table. Group order remains alphabetical to preserve selection during refresh.
Pausing cancels reads and freezes the display; resumed sessions replace the active-ID snapshot.
Hostnames and destinations may be absent;
no reverse DNS or geolocation service is called, and no connection history is written to disk.
Only Natural Earth outlines and representative coordinates are bundled. While the viewer is visible
and reading, a separate demand-driven controller downloads DB-IP Lite tables from the fixed c-ip CDN
index. It reuses a validated local cache for 30 days and has no background update timer. Hiding, pausing,
locking or sleeping cancels outstanding downloads; generation guards reject late progress/completions.
Connections remain available before geography is ready and after a download failure. The main actor
only owns UI state; bounded HTTP buffers, LZFSE decoding, hashes, disk writes and lookups run off it.
The index permits exactly the two known IPv4/IPv6 filenames, raw sizes up to 32 MiB each and compressed
sizes up to 8 MiB each. HTTPS downloads are bounded while receiving, then both compressed and raw
SHA-256/lengths are checked. Two tables are staged in one cache generation and its pointer is atomically
switched only after both succeed. Failed updates preserve old data; older owned cache generations are
removed after success. The files live in Application Support/XStats/NetworkGeography, outside backups.
Country pins aggregate counts, not precise device positions. Private/unknown locations stay in the list.
No per-IP network queries occur. Publishing fetches the official monthly CSV anew, validates ranges,
compresses using system LZFSE and uploads content-addressed objects to c-ip. Public hash readback
precedes the mutable current.json pointer and all application artifact publication. Data licensing and
attribution are in ThirdPartyNotices.md.

Only a visible, unlocked viewer renews the six-second observation lease with a read every two
seconds. Hidden/minimized windows, lock, sleep, cancellation and disconnect stop reads; the lease
expires even if the GUI crashes. The provider uses try-locks so observation contention never waits
on the flow verdict path. Without a reader the provider applies an all-network/protocol/direction
allow rule with default allow; active leases switch serially to filterData. A single active-lease deadline
and generation/revision checks prevent late callbacks or old-reader invalidation from revoking newer
leases. Every authenticated renewal advances the demand revision; successful settings are not reapplied.
Apply failure preserves the last successful state and is logged. A failed observation setting makes reads
return an error until observation succeeds, including across idle periods and reader replacement. Existing
reader polling drives recovery; after three consecutive read failures the UI stops and reports failure.
There is no background retry timer, and generation/request IDs reject stale completion results. Disabling the module serially saves `isEnabled=false`, including when an enable save was
already in flight. Explicit removal disables and removes the filter configuration before submitting
system-extension deactivation; pending reboot is reported separately from completed removal.

The system extension bundle filename must equal its Bundle ID. Only the independent component
`work.12306.xstats.networkmonitor` embeds the extension and needs System Extension installation and
Network Extension entitlements. It uses `XSTATS_COMPONENT_PROFILE`; the extension keeps
`work.12306.xstats.app.networkextension`, the content-filter-provider-systemextension entitlement and
its own `XSTATS_NETWORK_PROFILE` Developer ID profile. The mach service uses
`TeamIdentifierPrefix` for a dedicated macOS-only IPC App Group shared by the main app, component and extension.
The Mach service is `<that group>.ipc.<extension build>`; NE category validation requires this exact group prefix.
No files are stored in this group; neither the component nor extension is granted the existing Widget group.
The main app retains its Widget and IPC groups, while the component embeds no Widget or privileged helper.
The bundled LaunchAgent declares only its stable Mach service, without RunAtLoad or KeepAlive.
launchd starts the signed component executable on demand; idle RPC/SDK-free service instances exit.
Registration CLI/GUI runs outside that service, because SMAppService.unregister terminates it.
Executable CDHash plus agent-plist SHA-256 determine whether an external unregister/register refresh
is needed after upgrade. Main-app uninstall completes the extension operation, unregisters through the
still-present signed CLI, then deletes the companion bundle. A required reboot keeps the bundle intact.
Authorization/update progress use authenticated XPC callbacks, not endpoint polling. Protocol version 2
is explicit in control replies and data batches. Component GUI language follows the main application preference,
falling back to the system language. Service/registration CLI custom errors retain Chinese source keys;
GUI and main-app consumers translate them locally, so shared-service replies do not freeze a caller language.
The macOS filter description uses explicit translation in the selected application language. Main metadata discovery reads bounded Info.plist bytes
from disk rather than NSBundle's process cache. Install validation is shared by concurrent entry points;
unchanged file identity avoids repeated codesign/spctl, and each XPC message still verifies its peer.
Main-app update preparation records only viewer intent. Ordinary quit stops reading and serially
saves filter disabled before termination. Component updates own the SDK shutdown acknowledgement;
the main viewer pauses reads during handoff and resumes only its latest user demand afterward.
The component and extension share `NETWORK_EXTENSION_VERSION/BUILD`, independently from main-app
version metadata. `scripts/release_network_component.sh` signs, notarizes and packages only this product;
publication requires explicit `--publish`, uploads/reads back its versioned ZIP and identical first-install
alias before the signed `network-monitor/appcast.xml`, and never calls the main JSON release API.
Profiles must authorize the restricted network/system-extension entitlements and the selected
Developer ID certificate. The macOS-only Team ID prefixed IPC group needs no portal registration
or profile authorization; macOS verifies its signing team prefix. Distribution acceptance includes
notarization, real SDK authorization, data reads, stop/resume and independent updater handoff.
Endpoint metadata uses the public `remoteFlowEndpoint` API directly; no
legacy endpoint bridge is included.

`--snapshot <directory> --connections-only --language <language>` renders fixed synthetic metadata
without activating an extension, collecting live connections or modifying system preferences.
