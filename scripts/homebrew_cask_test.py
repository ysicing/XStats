#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""用真实 Homebrew DSL 验证两份发布 Cask；不安装、退出应用或删除用户数据。"""
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release_capture as capture

ROOT = Path(__file__).resolve().parents[1]
BREW = shutil.which("brew")


@unittest.skipUnless(BREW, "需要 Homebrew 来验证 Cask DSL 和 livecheck 策略")
class HomebrewCaskTests(unittest.TestCase):
    def test_generated_casks_keep_product_versions_and_uninstall_boundaries(self):
        with tempfile.TemporaryDirectory(prefix="xstats-cask-test-") as temporary:
            work = Path(temporary)
            # 执行实际 heredoc，覆盖 Shell 转义，不运行构建、公证和上传。
            source = (ROOT / "scripts/release.sh").read_text()
            template = source.split('cat > "$DIST/xstats.rb" <<CASK\n', 1)[1].split('\nCASK', 1)[0]
            env = dict(os.environ, DIST=str(work), VERSION="1.4.2", SHA_ARM="a" * 64,
                       DOWNLOAD_BASE="https://example.test/xstats")
            subprocess.run(["bash", "-eu", "-c", 'cat > "$DIST/xstats.rb" <<CASK\n' + template + '\nCASK\n'],
                           env=env, check=True)

            name = "XStats-Capture-0.1.1-AppleSilicon"
            for suffix in ("dmg", "zip", "xml"):
                (work / f"{name}.{suffix}").write_text("fixture")
            notes = work / "notes.json"
            notes.write_text("{}")
            identity = "A" * 40
            with patch.object(capture, "DIST", work), patch.object(capture, "NOTES", notes), \
                    patch.object(capture, "clean_head", return_value="fixture"), \
                    patch.object(capture, "object_hash", return_value=None), \
                    patch.object(capture, "run", return_value=f'{identity} "Developer ID Application: Fixture (TEAM123456)"'), \
                    patch.object(capture, "verify_bundle"), patch.object(capture, "archive"), \
                    patch.object(capture, "backup", return_value="fixture"), \
                    patch.object(capture, "make_manifest", return_value={}), \
                    patch.dict(os.environ, SIGN_ID=identity), redirect_stdout(io.StringIO()):
                capture.build_release("0.1.1", "2", name, {})

            # 加载发布输出本身；真实策略处理混排标签、标题、预发布和草稿。
            check = r'''
require "cask/cask_loader"
require "livecheck/strategy/json"
require "livecheck/strategy/github_releases"
require "json"

releases = [
  { "tag_name" => "v1.4.2", "name" => "capture-v99.0.0" },
  { "tag_name" => "capture-v0.1.1", "name" => "v99.0.0" },
  { "tag_name" => "network-v99.0.0" },
  { "tag_name" => "v2.0.0", "draft" => true },
  { "tag_name" => "capture-v2.0.0", "draft" => true },
  { "tag_name" => "v3.0.0", "prerelease" => true },
  { "tag_name" => "capture-v3.0.0", "prerelease" => true },
  { "tag_name" => "v4.0.0-rc.1" },
  { "tag_name" => "capture-v4.0.0-rc.1" },
]

ARGV.each do |path|
  cask = Cask::CaskLoader::FromContentLoader.new(File.read(path)).load(config: nil)
  main = cask.token == "xstats"
  expected = main ? "1.4.2" : "0.1.1"
  bundle = main ? "work.12306.xstats.app" : "work.12306.xstats.capture"
  raise "wrong version" unless cask.version.to_s == expected
  raise "wrong livecheck strategy" unless cask.livecheck.strategy == :github_releases
  result = Homebrew::Livecheck::Strategy::GithubReleases.find_versions(
    url: cask.homepage, regex: cask.livecheck.regex, content: JSON.generate(releases)
  )
  raise "mixed release versions: #{result[:matches].keys}" unless result[:matches].keys == [expected]
  uninstall = cask.artifacts.find { |a| a.is_a?(Cask::Artifact::Uninstall) }
  raise "wrong quit target" unless uninstall&.to_h&.fetch(:quit) == bundle
  raise "unsafe uninstall directive" unless (uninstall.to_h.keys - [:quit, :signal]).empty?
  raise "uninstall must not force-quit" unless Array(uninstall.to_h[:signal]).empty?
  zap = cask.artifacts.find { |a| a.is_a?(Cask::Artifact::Zap) }
  trash = Array(zap.to_h.fetch(:trash))
  raise "zap paths must follow Cask style" unless trash == trash.sort_by(&:downcase)
  raise "missing preferences" unless trash.include?("~/Library/Preferences/#{bundle}.plist")
  raise "shared Capture cache must survive" if trash.any? { |p| p.include?("XStatsCapture") }
  raise "uninstall must not affect the other product" if trash.any? { |p| main ? p.include?(".capture") : p.include?("/XStats/") }
  raise "unsafe zap path" if trash.any? { |p| !p.start_with?("~/Library/") || p.include?("*") || p.include?("Group Containers") }
  if main
    raise "missing private app data" unless trash.include?("~/Library/Application Support/XStats")
    raise "missing private app cache" unless trash.include?("~/Library/Caches/XStats")
  end
end
'''
            result = subprocess.run([BREW, "ruby", "-e", check, str(work / "xstats.rb"),
                                     str(work / "xstats-capture.rb")], text=True, capture_output=True,
                                    env=dict(os.environ, HOMEBREW_NO_AUTO_UPDATE="1"))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
