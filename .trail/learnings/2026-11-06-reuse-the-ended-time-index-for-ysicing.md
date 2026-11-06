---
title: Reuse the ended-time index for live connection queries
author: Ysicing
date: 2026-11-06
branch: main
id: l-0bf1fef2
scope: repo
status: active
src: agent
touches:
  - Packages/XStatsKit/Sources/Metrics/SpeedTestProbe.swift
  - Packages/XStatsKit/Sources/XStatsUI/NetworkObservation/NetworkHistoryStore.swift
  - Packages/XStatsKit/Tests/MetricsTests/SpeedTestTests.swift
  - Packages/XStatsKit/Tests/XStatsUITests/NetworkHistoryStoreTests.swift
---

## Decided
Expand activeOnly into distinct SQL predicates and use COALESCE(closed_at,retired_at) IS NULL because it matches the existing connections_ended expression index and is equivalent to both columns being NULL. Remove geography joins from non-region counts and groups because those expressions never read geography.

## Tried and ruled out
A new partial active-connection index made pagination slightly faster, but the existing index already bounded live counts and region aggregation to unended connections. Reuse it because it avoids extra storage and index maintenance during ingestion. Do not restrict every sidebar aggregate to live connections because historical groups with zero current connections must remain selectable.

## Watch out
App/process/domain sidebar groups still scan retained history for that zero-count behavior. Synthetic SQL timings exclude points, pruning, disk I/O and Swift decoding; they are not whole-view, CPU or energy measurements.

In the code: Packages/XStatsKit/Sources/XStatsUI/NetworkObservation/NetworkHistoryStore.swift, view and connections_ended; NetworkHistoryStoreTests.liveQueriesPreserveHistoryAndRespectSelection. On 2026-11-06, system SQLite 3.54.0 with 100000 synthetic records and 512 active connections returned identical count/page/groups/regions results; sums of five-run medians were approximately 161ms before and 70ms after.
