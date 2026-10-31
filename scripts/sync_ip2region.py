#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""同步固定版本 ip2region XDB，经 LZFSE 压缩、回读校验后发布到 c-ip。"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import sync_network_geography as common

VERSION = "6a276cc7c4f9f2d7ff1d8ace14b91af59752f943"
ASSETS = (
    {"family": 4, "bytes": 11_122_714,
     "sha256": "46249ad1b33bcaa4cc37475b93746cec2b00acffc3316cc4f56167ac821ea2ad"},
    {"family": 6, "bytes": 37_277_813,
     "sha256": "939f6b46bd2b8bec3cf7c5ceb8ba782266ae9b1f35b5ba7916700dec0b7506ed"},
)
MAX_BYTES = 64 * 1024 * 1024
MC_TARGET = f"{common.MC_TARGET}/ip2region/{VERSION}"
DOWNLOAD_BASE = f"{common.DOWNLOAD_BASE}/ip2region/{VERSION}"


def prepare(output: Path) -> dict:
    """先核对固定原库与 XDB 头，再压缩；失败不覆盖上一份本地清单。"""
    output.mkdir(parents=True, exist_ok=True)
    manifest = {"schemaVersion": 1, "version": VERSION,
                "attribution": "ip2region", "attributionURL": "https://github.com/lionsoul2014/ip2region",
                "license": "Apache-2.0", "files": []}
    with tempfile.TemporaryDirectory(prefix=".prepare-", dir=output) as directory:
        staging = Path(directory)
        for expected in ASSETS:
            family = expected["family"]
            name = f"ip2region_v{family}.xdb"
            source_url = f"https://raw.githubusercontent.com/lionsoul2014/ip2region/{VERSION}/data/{name}"
            raw = common.download_bytes(source_url, expected["bytes"])
            if len(raw) != expected["bytes"] or hashlib.sha256(raw).hexdigest() != expected["sha256"]:
                raise ValueError(f"IPv{family} 原库长度或 SHA-256 不匹配")
            if (len(raw) < 256 or int.from_bytes(raw[0:2], "little") != 3
                    or int.from_bytes(raw[16:18], "little") != family
                    or int.from_bytes(raw[18:20], "little") != 4):
                raise ValueError(f"IPv{family} XDB 头部无效")
            raw_path = staging / name
            raw_path.write_bytes(raw)
            del raw
            compressed = staging / (name + ".lzfse")
            common.compress_lzfse(raw_path, compressed)
            payload = compressed.read_bytes()
            if not 0 < len(payload) <= MAX_BYTES:
                raise ValueError(f"IPv{family} 压缩文件大小无效")
            digest = hashlib.sha256(payload).hexdigest()
            filename = name.replace(".xdb", "-") + digest + ".lzfse"
            compressed.rename(staging / filename)
            manifest["files"].append({
                "name": name, "file": filename, "bytes": expected["bytes"],
                "sha256": expected["sha256"], "sourceURL": source_url,
                "compressedBytes": len(payload), "compressedSHA256": digest,
            })
        manifest_path = staging / "current.json"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        for path in staging.iterdir():
            if path.name != "current.json":
                path.replace(output / path.name)
        manifest_path.replace(output / "current.json")
    return manifest


def publish(output: Path, manifest: dict) -> None:
    # 与国家库共享上传、CDN 完整回读和清单最后提交的流程，使用独立版本目录。
    common.publish(output, manifest, target=MC_TARGET, download_base=DOWNLOAD_BASE, maximum=MAX_BYTES)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=common.ROOT / "dist/network-geography/ip2region" / VERSION)
    parser.add_argument("--publish", action="store_true", help="上传 c-ip 并完整回读校验；默认仅准备本地数据")
    args = parser.parse_args()
    try:
        manifest = prepare(args.output)
        for item in manifest["files"]:
            print(f"{item['name']}: {item['bytes']} bytes -> {item['compressedBytes']} bytes")
        if args.publish:
            publish(args.output, manifest)
            print(f"已发布并验证：{DOWNLOAD_BASE}/current.json")
        else:
            print(f"已准备：{args.output / 'current.json'}（未上传）")
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"ip2region 同步失败：{error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
