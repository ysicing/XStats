---
name: xstats-release
description: Execute, resume, or verify the XStats macOS client release workflow, including semver metadata, arm64 Developer ID signing, Apple notarization, c-ip object storage, regional update APIs, GitHub Release, Homebrew tap, and CI. Use for an actual XStats app release or a partial-release recovery; do not use for XStats Server development or server-image delivery.
---

<!-- Copyright (C) 2026 ysicing -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# XStats Release

Release the XStats macOS client without letting its binary, Git tag, object-storage artifacts, update manifests, or Homebrew cask drift apart.

Before acting, read the repository `AGENTS.md`, the release section of `DEVELOPMENT.md`, `Taskfile.yml`, and `Scripts/release.sh` / `Scripts/publish_release.sh`. Treat the repository scripts as the current implementation; use [references/runbook.md](references/runbook.md) for the operational sequence and recovery checks.

## Boundaries

- Work in the repository containing this skill. Confirm it is the intended XStats checkout rather than assuming a fixed absolute path.
- This skill covers the macOS app release only. Do not change the separate XStats Server repository, server image workflow, Cloudflare policy, Kubernetes workloads, or storage topology merely because a release touches their endpoints.
- A request to inspect or prepare a release does not authorize commit, push, tag creation, uploads, API writes, Homebrew changes, or other external mutation. Require the user's explicit release or delivery instruction before those actions.
- Do not create a PR unless the user explicitly requests one.
- Never print, commit, persist in project files, or repeat signing credentials, storage keys, or `XSTATS_RELEASE_TOKEN`. Read secrets from an already authorized environment or credential store.

## Release invariants

- Public versions are semver from the first formal `CHANGELOG.md` heading; date-style versions are historical test data.
- Release artifacts contain only arm64 binaries.
- Public distribution uses `Developer ID Application`, hardened runtime, secure timestamps, notarization, stapling, and Gatekeeper acceptance. `Apple Development` and `SKIP_NOTARIZE=1` are not public-release substitutes.
- The notarization keychain profile is `XStats` unless the user explicitly selects another valid profile.
- Upload through the MinIO alias `c-ip` to `c-ip/oss/apps/macOS/XStats`; public downloads use `https://c.ysicing.net/oss/apps/macOS/XStats/`.
- Publish the same appcast to the global and China release APIs. The manifest must remain last: packages first, then GitHub Release, then update APIs.
- The Homebrew target is `ysicing/homebrew-tap`, installed as `ysicing/tap/xstats`.
- `dist/release-provenance.json` binds artifacts to the build-time commit, version, build number, and version-file hashes. Do not bypass it or rebuild provenance manually.
- A release builds and verifies artifacts without quitting, replacing, or launching the XStats installed on the current machine. Do not run `install_local.sh` as part of `task release` or `task release-all`; local installation is a separate, explicit request.

## Execution shape

1. Establish a clean, current source baseline and pass repository tests/CI.
2. Prepare only release metadata, then let `task release` advance `project.yml`, build, sign, notarize, staple, and generate `dist/`.
3. Verify the built app in `build/DerivedData-arm64/Build/Products/Release/XStats.app` and generated artifacts before committing release metadata; leave `/Applications/XStats.app` untouched.
4. Commit and push only the allowed metadata, then run the provenance verifier.
5. Run the idempotent publish script and verify every external destination independently.

When the user explicitly authorizes the complete release, `task release-all` is the canonical one-command entry and includes commit, push, and every external publication. Use `task release` for build-only work and `task publish` to resume an already built and pushed release.

Stop rather than weakening a safety check when the source changed after the build, the tag points elsewhere, notarization is not accepted, public hashes differ, an API returns anything other than its expected success, or a credential is unavailable.

## Partial-release handling

- Determine the last proven stage before retrying. Object uploads, GitHub Release updates, API publication, and tap updates are separate facts.
- Run `task publish` only after confirming the same provenance record and release commit; it invokes the idempotent publisher without rebuilding.
- A Cloudflare response with `cf-mitigated: challenge` is an edge failure, not an application authentication failure. Use an already authorized clean egress when available; do not solve the challenge interactively or broadly disable protections.
- If object upload fails, confirm the target is `c-ip`. Do not silently substitute `c`, `cos`, `home`, `ggy`, another bucket, or GitHub assets.
- Never report completion from a successful build, upload, or tag alone. Completion requires the final verification checklist in the runbook.
