---
title: Shrink the main installer without pruning app content
author: Ysicing
date: 2026-11-07
branch: main
id: l-00da02f4
scope: repo
status: active
src: agent
touches:
  - docs/DEVELOPMENT.md
  - scripts/release.sh
---

## Decided
For the main app DMG, use explicit APFS, ULMO compression and udif-chunk-size=8192 (4 MiB). This changes packaging only; preserve every app binary, image, template and language. Keep the existing ZIP update contract and use DEFLATE level 9.

## Tried and ruled out
Using the signed 1.6.0 (172) app after Finder resource pruning: baseline ZIP 13,710,418 bytes and DMG 14,440,845 bytes. ZIP level 9 only reached 13,685,063 bytes. Default-chunk ULMO reached about 10.07-10.12 MB; HFS+ ULMO increased to 11.35 MB. Explicit APFS plus 4 MiB chunks produced a Developer ID signed DMG of 9,390,411 bytes. Do not claim the ZIP also meets the decimal 10 MB goal.

## Watch out
The experiment was not notarized; verify final size after notarization and stapling at release. Size is not a permanent guarantee as app content grows. Mounted candidate matched all 505 regular files, 6 symlinks and executable permissions against the baseline ZIP; all 21 language tables and 9 declared languages remained. ZIP AppleDouble entries encode metadata, not extra ordinary files on the mounted volume. Do not package an installed app with custom Finder icon metadata.

In the code: scripts/release.sh uses -fs APFS -format ULMO -imagekey udif-chunk-size=8192 before the existing DMG signing/notarization steps. docs/DEVELOPMENT.md records the format choice. The main binary contributes about 7.40 MB to ZIP, main images 2.42 MB and Widget 1.44 MB. Remaining identical content is only about 0.52 MB compressed, mostly Widget localization; deleting it cannot bridge the 3.69 MB ZIP gap and can break language loading.
