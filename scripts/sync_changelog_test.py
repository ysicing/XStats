#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

import unittest

import sync_changelog


class SyncChangelogTest(unittest.TestCase):
    def test_readme_summary_uses_latest_release_with_mixed_heading_styles(self) -> None:
        releases = sync_changelog.parse("""\
## 0.9.0 · 2026-09-24
### 新增
- 新的额度视图。
## 0.8.0 · 2026-09-23
### 2026-09-23
#### 修复
- 修复旧问题。
""")

        self.assertEqual([release["version"] for release in releases], ["0.9.0", "0.8.0"])
        for en in (False, True):
            block = sync_changelog.readme_block(releases, en)
            self.assertIn("0.9.0", block)
            self.assertNotIn("0.8.0", block)
            self.assertNotIn("<details", block)
            self.assertIn("CHANGELOG.md", block)


if __name__ == "__main__":
    unittest.main()
