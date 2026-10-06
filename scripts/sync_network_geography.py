#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""每次重新获取 DB-IP Lite 并准备动态地图库；只有 --publish 才上传对象存储。"""
import argparse
from datetime import datetime, timedelta, timezone
import gzip
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid

from build_network_geography import MAX_BINARY_BYTES, convert_country_csv

ROOT = Path(__file__).resolve().parents[1]
MAX_SOURCE_BYTES = 16 * 1024 * 1024
MAX_CSV_BYTES = 64 * 1024 * 1024
MAX_COMPRESSED_BYTES = 8 * 1024 * 1024
MC_TARGET = "c-ip/oss/apps/macOS/XStats/network-geography"
DOWNLOAD_BASE = "https://c.ysicing.net/oss/apps/macOS/XStats/network-geography"


def download_bytes(url: str, limit: int) -> bytes:
    """同时限制声明长度和实际读取长度，防止源或 CDN 超量响应。"""
    request = urllib.request.Request(url, headers={"User-Agent": "XStats-network-geography/1", "Accept-Encoding": "identity"})
    with urllib.request.urlopen(request, timeout=120) as response:
        length = response.headers.get("Content-Length") if hasattr(response, "headers") else None
        if length is not None and int(length) > limit:
            raise ValueError(f"响应超过 {limit} 字节上限：{url}")
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"响应超过 {limit} 字节上限：{url}")
    return data


def inflate_source(data: bytes) -> bytes:
    if len(data) > MAX_SOURCE_BYTES:
        raise ValueError("源 gzip 超过大小上限")
    with gzip.GzipFile(fileobj=io.BytesIO(data)) as source:
        csv_data = source.read(MAX_CSV_BYTES + 1)
    if len(csv_data) > MAX_CSV_BYTES:
        raise ValueError("解压 CSV 超过大小上限")
    return csv_data


def compress_lzfse(raw: Path, compressed: Path) -> None:
    subprocess.run(["xcrun", "swift", str(ROOT / "scripts/compress_network_geography.swift"),
                    str(raw), str(compressed)], check=True, timeout=180)


def prepare(output: Path, source_url: str) -> dict:
    """重新下载和校验全部源数据；本地清单最后原子替换，失败保留旧清单。"""
    source_data = download_bytes(source_url, MAX_SOURCE_BYTES)
    source_sha = hashlib.sha256(source_data).hexdigest()
    binaries = convert_country_csv(inflate_source(source_data))
    generated = datetime.now(timezone.utc)
    manifest = {"attribution": "IP Geolocation by DB-IP", "attributionURL": "https://db-ip.com/",
                "license": "CC BY 4.0", "licenseURL": "https://creativecommons.org/licenses/by/4.0/",
                "schemaVersion": 1, "version": generated.strftime("%Y-%m-%d") + "-" + source_sha[:16],
                "sourceURL": source_url, "sourceSHA256": source_sha,
                "generatedAt": generated.isoformat(timespec="seconds").replace("+00:00", "Z"), "files": []}
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".prepare-", dir=output) as temporary:
        staging = Path(temporary)
        for family in (4, 6):
            binary = binaries[family]
            digest = hashlib.sha256(binary).hexdigest()
            raw_name = f"country-ipv{family}.bin"
            raw, compressed = staging / raw_name, staging / f"country-ipv{family}.lzfse"
            raw.write_bytes(binary)
            compress_lzfse(raw, compressed)
            compressed_bytes = compressed.read_bytes()
            if not 0 < len(compressed_bytes) <= MAX_COMPRESSED_BYTES:
                raise ValueError(f"IPv{family} 压缩数据为空或超过大小上限")
            # 对象名由实际上传字节决定，系统压缩器输出变化也不会覆盖既有 immutable 对象。
            compressed_digest = hashlib.sha256(compressed_bytes).hexdigest()
            compressed_name = f"country-ipv{family}-{compressed_digest}.lzfse"
            compressed.rename(staging / compressed_name)
            manifest["files"].append({"name": raw_name, "file": compressed_name, "bytes": len(binary),
                                      "sha256": digest, "compressedBytes": len(compressed_bytes),
                                      "compressedSHA256": compressed_digest})
        (staging / "source.csv.gz").write_bytes(source_data)
        manifest_path = staging / "current.json"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        for path in staging.iterdir():
            if path.name != "current.json":
                path.replace(output / path.name)
        manifest_path.replace(output / "current.json")
    return manifest


def monthly_source_urls(now: datetime) -> list[str]:
    """DB-IP 月初可能尚未发布当月文件；当月优先，上月作为唯一回退。"""
    previous = now.replace(day=1) - timedelta(days=1)
    return [f"https://download.db-ip.com/free/dbip-country-lite-{month:%Y-%m}.csv.gz" for month in (now, previous)]


def prepare_latest(output: Path, source_urls: list[str]) -> dict:
    """仅在 404 时尝试下一个源；其他网络或校验错误照常中止，不掩盖真实故障。"""
    for index, source_url in enumerate(source_urls):
        try:
            return prepare(output, source_url)
        except urllib.error.HTTPError as error:
            if error.code != 404 or index == len(source_urls) - 1:
                raise
            print(f"源尚未发布，改用上月数据：{source_url}", file=sys.stderr)
    raise ValueError("没有可用的数据源")


def publish(output: Path, manifest: dict) -> None:
    """只有已验证的不可变对象全部就位后，才发布可变入口清单。"""
    manifest_data = (output / "current.json").read_bytes()
    if json.loads(manifest_data) != manifest:
        raise ValueError("本地清单已变化，停止发布")
    for item in manifest["files"]:
        path = output / item["file"]
        data = path.read_bytes()
        if len(data) != item["compressedBytes"] or hashlib.sha256(data).hexdigest() != item["compressedSHA256"]:
            raise ValueError(f"本地压缩文件校验失败：{path.name}")
        subprocess.run(["mc", "cp", "--quiet", "--attr", "Cache-Control=public,max-age=31536000,immutable",
                        str(path), f"{MC_TARGET}/{path.name}"], check=True, timeout=300)
        online = download_bytes(f"{DOWNLOAD_BASE}/{path.name}", MAX_COMPRESSED_BYTES)
        if len(online) != item["compressedBytes"] or hashlib.sha256(online).hexdigest() != item["compressedSHA256"]:
            raise ValueError(f"CDN 压缩文件校验失败：{path.name}")
    subprocess.run(["mc", "cp", "--quiet", "--attr", "Cache-Control=max-age=300",
                    str(output / "current.json"), f"{MC_TARGET}/current.json"], check=True, timeout=300)
    # 可变清单已有五分钟 CDN 缓存；本次回读使用唯一查询，避免把旧缓存误判为上传失败。
    online_manifest = download_bytes(f"{DOWNLOAD_BASE}/current.json?verify={uuid.uuid4().hex}", 64 * 1024)
    if online_manifest != manifest_data:
        raise ValueError("CDN current.json 与本地清单不一致")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/network-geography")
    parser.add_argument("--source-url", help="默认使用 DB-IP 当月文件，未发布时回退上月")
    parser.add_argument("--publish", action="store_true", help="上传 c-ip 对象存储并验证 CDN；默认仅准备本地数据")
    args = parser.parse_args()
    source_urls = [args.source_url] if args.source_url else monthly_source_urls(datetime.now(timezone.utc))
    try:
        manifest = prepare_latest(args.output, source_urls)
        for item in manifest["files"]:
            print(f"IPv{4 if item['name'] == 'country-ipv4.bin' else 6}: {item['bytes']} bytes -> {item['compressedBytes']} bytes")
        if args.publish:
            publish(args.output, manifest)
            print(f"已发布并验证：{DOWNLOAD_BASE}/current.json")
        else:
            print(f"已准备：{args.output / 'current.json'}（未上传）")
    except (ValueError, OSError, EOFError, subprocess.SubprocessError) as error:
        print(f"地图库同步失败：{error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
