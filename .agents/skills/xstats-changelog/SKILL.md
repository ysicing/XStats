---
name: xstats-changelog
description: Prepare XStats macOS release notes and curate What's New highlights from verified changes. Use for app release drafts, the highlights page, or before xstats-release.
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

- Summarize externally visible outcomes. Use `### 新增`, `### 改进`, `### 修复`, `### 废弃`, and `### 移除` for nonempty categories. Use `废弃` for a capability still available but discouraged and `移除` when it has been removed.
- Keep each item concise and factual. Merge related commits into one benefit or behavior change; retain important compatibility, data-handling, and user-action changes. Exclude internal-only refactors, CI, build, and release mechanics unless they directly affect users.
- Draft under `## 未发布` during development. For an authorized release with a determined version, make the first `##` heading `## X.Y.Z · YYYY-MM-DD` and keep older versions unchanged. Do not leave `## 未发布` above the formal heading: release scripts parse the first level-two heading as the version.
- For a new release, update `docs/ReleaseNotes.json` with the same version and generated Chinese `sourceNotes`, then write matching English summaries in `translations.en`. Both Chinese app languages show the Chinese source; all other languages show English. Translate only the current release; keep the same item order and count, and do not use live machine translation in the client. Verify wording against the Chinese source.
- GitHub Release bodies contain both Chinese and English: keep the full Chinese section and reuse `translations.en` for English. Include user-action and compatibility details in the English notes, even when the Chinese source summary was shortened. Preview with `python3 scripts/github_release_notes.py <version>`; do not rewrite historical releases without authorization.
- Review the result against the diff and the existing draft for omissions, duplication, or unsupported claims. Do not rewrite already published history as part of preparing a new release.

## Curate What's New

- Before building each new main-app release, add its version to [the bundled highlights catalog](../../../Packages/XStatsKit/Sources/XStatsUI/Resources/ReleaseHighlights.json), using the verified changes above. Every formal release needs an entry, with `features: []` when no changes qualify. When resuming publication of an existing build, reuse its selections.
- Choose up to five new capabilities or substantial expansions, in priority order. Write a short feature name and one sentence about what people can now do. Qualify experimental or opt-in behavior. Keep ordinary fixes in the full changelog.
- Reuse the feature `id` for later expansions. Use `experimental: true` for experimental features and `retiredFeatureIDs` for highlights that no longer apply. Higher `priority` wins when the page is full, and catalog order breaks ties within a release. Write each feature's `title` and `detail` in the catalog's `zh` and `en` entries. Both Chinese app languages use `zh`; all others use `en`. Page controls use the app's normal localization.
- Preview both upgrade paths. For one intervening formal app release, use `XStats <version> 新版亮点` and omit per-feature versions. For multiple releases, use `XStats 最近版本亮点` and label each item with its contributing version. Count releases strictly after the last seen version through the target, including releases with zero highlights. Limit that window to the newest five formal app releases before selecting features.
- Merge repeated features within that window, keeping the newest applicable description and version. Select at most five items overall by user impact, then display by descending version and within-version priority. Drop features unavailable in the target. Skip the page when the selection is empty.
- Run the `ReleaseHighlightsTests` targeted suite when changing the catalog. See [ReleaseHighlights.md](../../../docs/ReleaseHighlights.md) for the client behavior and migration baseline.

## Validate and hand off

- Run `python3 scripts/sync_changelog.py` so README summaries stay in sync; inspect generated-file diffs before keeping them.
- Run `python3 scripts/sync_changelog_test.py`, `./scripts/version.sh` when the heading is formal, and `git diff --check`. Check that the first heading, version, and date match the intended release.
- Report the summary and any uncertain changes for human review before building. This skill only edits release-note metadata; it does not authorize a build, commit, push, tag, or publication.
