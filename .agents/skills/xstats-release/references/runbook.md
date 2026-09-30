<!-- Copyright (C) 2026 ysicing -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# XStats macOS release runbook

Use this runbook only for an actual release, resuming a partial release, or verifying one. Re-read the repository scripts first; if they disagree with this file, investigate the drift before mutating anything.

## 1. Preflight

From the XStats repository:

```bash
git status -sb
git fetch origin main
git rev-parse HEAD
git rev-parse origin/main
task test
./scripts/version.sh
```

Confirm:

- `HEAD` is the intended release source and is pushed before release metadata is prepared.
- Existing working-tree changes are understood and limited to the release task.
- The requested tag and GitHub Release do not already exist, unless this is an intentional idempotent resume.
- The top changelog section contains the intended release content. For a new release, follow `../../xstats-changelog/SKILL.md` to summarize changes since the previous tag before building; do not regenerate notes while resuming an already built release.

Check external prerequisites without exposing credentials:

```bash
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile XStats --output-format json
mc stat c-ip/oss
gh auth status
```

The signing identity must be `Developer ID Application` with its private key. Merely having a valid `Apple Development` identity or a working notary profile is insufficient.

For the one-command path, `XSTATS_RELEASE_TOKEN` must already be available through an authorized environment or credential store. `task release-all` refuses to start when the token is absent, the branch is not `main`, `HEAD` differs from `origin/main`, or the release tag already exists.

## 2. Prepare version metadata

- Use `xstats-changelog` to consolidate the release notes, then replace the first `## 未发布` heading with `## X.Y.Z · YYYY-MM-DD`.
- Update `ReleaseNotes.json` for that version: match `sourceNotes` to the Chinese summaries and prepare `translations.en` in the same item order. Generation rejects stale or incomplete English notes; changing them after the build invalidates provenance.
- Preview `python3 scripts/github_release_notes.py <version>`: GitHub Release includes the full Chinese section plus English summaries. Ensure English retains upgrade instructions and compatibility details. Publication generates the same bilingual text for both creation and reruns.
- Update the release badge in all four README files.
- Do not manually change `project.yml`; `scripts/version.sh release`, invoked by `task release`, writes the semver and increments the build number once.
- Do not commit these metadata changes yet. They are allowed inputs to the provenance preflight.

Run:

```bash
python3 scripts/release_provenance.py prepare
git diff --check
task release
```

`task release` defaults to the `XStats` notary profile. Capture both Apple submission IDs and require `Accepted` for the app and DMG.
It builds and packages without installing or launching the release on the current machine.

When the user explicitly authorizes commit, push, and all external publication, the canonical automated path is instead:

```bash
task release-all
```

It runs `task test`, performs the same release build, stages only allowed release metadata, commits and pushes it, then invokes `task publish`. After it returns, continue with the final verification section rather than repeating the manual commit or publish steps.

## 3. Verify local artifacts

Expected files:

```text
dist/XStats-X.Y.Z-AppleSilicon.dmg
dist/XStats-X.Y.Z-AppleSilicon.zip
dist/XStats-X.Y.Z-AppleSilicon.xml
dist/appcast.json
dist/xstats.rb
dist/release-provenance.json
```

The finished app remains in DerivedData. Verify that artifact directly; do not replace or launch `/Applications/XStats.app` during a release:

```bash
lipo -archs build/DerivedData-arm64/Build/Products/Release/XStats.app/Contents/MacOS/XStats
lipo -archs build/DerivedData-arm64/Build/Products/Release/XStats.app/Contents/MacOS/XStatsHelper
lipo -archs build/DerivedData-arm64/Build/Products/Release/XStats.app/Contents/PlugIns/XStatsWidget.appex/Contents/MacOS/XStatsWidget
codesign --verify --deep --strict --verbose=2 build/DerivedData-arm64/Build/Products/Release/XStats.app
spctl -a -vv build/DerivedData-arm64/Build/Products/Release/XStats.app
xcrun stapler validate dist/XStats-X.Y.Z-AppleSilicon.dmg
spctl -a -t open --context context:primary-signature -vv dist/XStats-X.Y.Z-AppleSilicon.dmg
```

All architectures must be `arm64`; both app and DMG must report notarized Developer ID acceptance. Validate the appcast JSON, artifact sizes, and SHA-256 values. Include Sparkle framework, Autoupdate, Updater and both XPC services in the arm64, same-Team, timestamp and hardened-runtime audit. Verify the signed XML and ZIP using `python3 scripts/sparkle_appcast.py dist/appcast.json dist/XStats-X.Y.Z-AppleSilicon.zip --verify`. A missing Ed25519 keychain account is a release blocker, never a reason to generate a replacement key.

For the Sparkle transition, additionally verify a signed/notarized old client upgrading to the first Sparkle client, followed by a second upgrade using Sparkle, including retry/cancel, write-permission authorization, Widget and Helper recovery. Fixture-only installation tests do not establish this public-version transition.

## 4. Commit release metadata

Stage only the intended release metadata, normally:

```text
project.yml
CHANGELOG.md
README.md
README.en.md
README.ja.md
README.ko.md
```

Include `Assets/readme/activity.svg` and `Assets/readme/activity.zh.svg` only if this release actually changed them. Verify the staged list, commit with `chore(release): 发布 X.Y.Z`, and push only when authorized.

After pushing:

```bash
python3 scripts/release_provenance.py verify dist/release-provenance.json X.Y.Z BUILD
```

The verifier must pass before uploads or tag creation.

## 5. Publish

Provide `XSTATS_RELEASE_TOKEN` through an authorized environment or credential store; never place it in a command transcript, repository file, or chat response. Then run the Task wrapper:

```bash
task publish
```

The script must use these defaults:

```text
MC_TARGET=c-ip/oss/apps/macOS/XStats
DOWNLOAD_BASE=https://c.ysicing.net/oss/apps/macOS/XStats
TAP=ysicing/homebrew-tap
```

Its required order is:

1. Verify provenance, clean worktree, and `HEAD == origin/main`.
Before uploading or publishing a Sparkle client, run `python3 scripts/publish_api.py --check-sparkle`. After the JSON manifest is published, `python3 scripts/publish_api.py --verify-sparkle dist/XStats-<version>-AppleSilicon.xml` fetches each regional XML endpoint with the reserved probe installation ID (64 zeros, not counted in statistics) and requires the bytes to match the local signed XML; `publish_release.sh` runs it automatically. Both regional fixed XML endpoints must already be deployed and reject a missing installation ID with 400 + no-store. Old JSON POST clients and publication fields remain unchanged. The API serves the current manifest's immutable signed XML without rewriting its signature or forwarding the installation ID to the CDN.

2. Verify Ed25519 signatures, then upload DMG, ZIP and versioned XML to `c-ip`.
3. Download each public `c.ysicing.net` URL and compare SHA-256.
4. Create or update `vX.Y.Z` GitHub Release, refusing to move an existing mismatched tag.
5. Publish the appcast to both regional APIs.
6. Update `Casks/xstats.rb` in `ysicing/homebrew-tap`.

If manual recovery is unavoidable, preserve this order. Do not publish an appcast that references an unavailable object.

## 6. Final verification

Prove all of the following from live state:

- `git status -sb` is clean and local `main` matches `origin/main`.
- The release tag resolves to the intended release metadata commit.
- GitHub Release is neither draft nor prerelease and contains the notarized DMG with the expected digest.
- All three public object URLs return bytes matching local DMG, ZIP and signed XML SHA-256 values; the JSON ZIP URL maps to the corresponding immutable XML.
- Both regional update-check endpoints return the released version/build and `c.ysicing.net` URLs. Reuse one fixed validation installation ID instead of creating many statistics rows.
- The remote Homebrew cask matches `dist/xstats.rb`; `brew info --cask ysicing/tap/xstats` shows the released version and arm64/macOS requirements.
- Check the release commit and any immediate release-workflow fix commits' GitHub Actions status once. Record each visible run's link and actual result; if queued, running, or not yet listed, report CI as pending or unobserved without waiting or polling. Investigate a run that has already completed with failure.
- Temporary port forwards, credential aliases, debug pods, and staging directories created by this run are removed.

Report separate evidence for signing/notarization, object storage, GitHub Release, both update APIs, Homebrew, current CI status, and Git cleanliness. Pending CI alone does not make an otherwise verified release partial; do not claim it passed. If a distribution check is missing or a completed CI failure affects the release, call the release partial rather than complete.
