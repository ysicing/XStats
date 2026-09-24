---
name: xstats-changelog
description: Prepare or review XStats macOS app release notes in CHANGELOG.md from verified changes since the previous release. Use when drafting a new app version or before xstats-release; do not use for a raw commit list or XStats Server releases.
---

<!-- Copyright (C) 2026 ysicing -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# XStats Changelog

Write a short, user-facing summary for the next macOS app release. `CHANGELOG.md` is the source for both the README release summary and GitHub Release notes; it is not a copy of `git log`.

## Establish the evidence

- Check `git status` and the current changelog first. Preserve existing draft entries and unrelated working-tree changes.
- Find the previous published `vX.Y.Z` tag and verify that it is an ancestor of the intended release commit. Review both `git log <tag>..HEAD` and `git diff <tag>..HEAD`, then inspect relevant behavior or tests when commit titles alone are ambiguous. Include in-scope uncommitted changes only when they are intended for this release; do not silently treat every dirty file as a release feature.
- If the baseline tag, target version, or intended release scope is unclear, resolve that before writing a formal version heading. Do not infer a release solely from the latest commit title.

## Write the summary

- Summarize externally visible outcomes, not implementation steps or every commit. Group by `### 新增`, `### 改进`, `### 修复`, and `### 移除` as applicable; omit empty groups. Use `移除` only for an actual removed capability, not a renamed or temporarily unavailable one.
- Keep each item concise and factual. Merge related commits into one benefit or behavior change; retain important compatibility, data-handling, and user-action changes. Exclude internal-only refactors, CI, build, and release mechanics unless they directly affect users.
- Draft under `## 未发布` during development. For an authorized release with a determined version, make the first `##` heading `## X.Y.Z · YYYY-MM-DD` and keep older versions unchanged. Do not leave `## 未发布` above the formal heading: release scripts parse the first level-two heading as the version.
- Review the result against the diff and the existing draft for omissions, duplication, or unsupported claims. Do not rewrite already published history as part of preparing a new release.

## Validate and hand off

- Run `python3 scripts/sync_changelog.py` so README summaries stay in sync; inspect generated-file diffs before keeping them.
- Run `python3 scripts/sync_changelog_test.py`, `./scripts/version.sh` when the heading is formal, and `git diff --check`. Check that the first heading, version, and date match the intended release.
- Report the summary and any uncertain changes for human review before building. This skill only edits release-note metadata; it does not authorize a build, commit, push, tag, or publication.
