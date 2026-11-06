---
title: "重复启动转发后必须真正退出临时进程"
author: Ysicing
date: 2026-11-06
branch: main
id: l-b45ab5fe
scope: repo
status: active
src: agent
touches:
  - Apps/XStats/Widget/TimeZoneWidget.swift
  - Packages/XStatsKit/Sources/WidgetData/ClockTimeZone.swift
  - Packages/XStatsKit/Sources/XStatsUI/AppKit/AppController.swift
  - Packages/XStatsKit/Sources/XStatsUI/Rest/TimerTimeZoneContent.swift
  - Packages/XStatsKit/Tests/XStatsUITests/TimerPopoverTimeZoneTests.swift
  - docs/DEVELOPMENT.md
---

## Decided
Acquire the per-user flock before AppModel, preference writes or menu-bar initialization because a duplicate must not start sampling or create status items. Register the receiver before taking the lock and queue bounded requests because a second launch can arrive before the owner finishes initialization. Relay startup events through a lightweight AppKit delegate, then terminate the duplicate.

## Tried and ruled out
Calling NSApplication.stop inside applicationDidFinishLaunching failed because the native duplicate remained in app.run. A native two-process fixture timed out waiting for that duplicate to exit. Replacing stop with terminate passed reopen, background, CLI and URL forwarding, restart after SIGKILL, and three simultaneous-launch pairs. Same-process lock and notification tests had passed before this failure, so they cannot prove actual process exit.

## Watch out
Never unlink the lock file because contenders could then lock different inodes. CLOEXEC prevents subprocesses from prolonging the owner's lock lifetime. Route snapshot, read-only diagnostic and cleaner-directory worker modes before resident-instance exclusion because these intentionally share the executable. Login/service/background relaunches must remain backgrounded; explicit presentation arguments and URLs belong to the lock owner.

In the code:
- Packages/XStatsKit/Sources/XStatsUI/AppKit/ApplicationInstance.swift
- Packages/XStatsKit/Sources/XStatsUI/AppKit/AppController.swift: XStatsApplication.main
- Packages/XStatsKit/Tests/XStatsUITests/ApplicationInstanceTests.swift
- The isolated native fixture never launched or terminated the installed XStats app.
