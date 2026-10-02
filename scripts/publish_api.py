#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

"""把发布清单提交给 XStats API。"""

import json
import os
import sys
import urllib.request
import urllib.error
from urllib.parse import urlsplit, urlunsplit
from collections.abc import Mapping
from pathlib import Path


DEFAULT_ENDPOINTS = (
    "https://apps.12306.work/api/v1/apps/xstats/releases/current",
    "https://apps-api.xiai.me/api/v1/apps/xstats/releases/current",
    "https://apps.china.12306.work/api/v1/apps/xstats/releases/current",
)


# 与服务端 releaseProbeInstallationID 一致：核验更新源但不计入安装统计。
RELEASE_PROBE_INSTALLATION_ID = "0" * 64
MAXIMUM_FEED_BYTES = 256 * 1024


def sparkle_feed_url(endpoint: str, query: str = "") -> str:
    parts = urlsplit(endpoint)
    if parts.path != "/api/v1/apps/xstats/releases/current":
        raise ValueError(f"无法推导 Sparkle 更新源：{endpoint}")
    return urlunsplit((parts.scheme, parts.netloc, "/api/v1/apps/xstats/update/appcast.xml", query, ""))


def check_sparkle_endpoints(endpoints: list[str]) -> None:
    """不携带安装标识的探测必须返回 400，防止先发布客户端而服务端仍是旧版。"""
    if not endpoints:
        raise ValueError("至少需要一个版本发布接口")
    for endpoint in endpoints:
        url = sparkle_feed_url(endpoint)
        request = urllib.request.Request(url, headers={"User-Agent": "XStats-Release"})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raise RuntimeError(f"{url} 未拒绝缺少安装标识的请求：{response.status}")
        except urllib.error.HTTPError as error:
            with error:
                # 代理可能合并缓存指令，按 token 判断而不是整串比较。
                directives = {item.strip().lower() for item in (error.headers.get("Cache-Control") or "").split(",")}
                if error.code != 400 or "no-store" not in directives:
                    raise RuntimeError(f"请先部署支持 Sparkle 的 API：{url} 返回 {error.code}") from error


def verify_sparkle_feeds(feed: Path, endpoints: list[str]) -> None:
    """发布 JSON 后逐区域取回 Sparkle 清单，必须与本地已签名 XML 逐字节一致。"""
    if not endpoints:
        raise ValueError("至少需要一个版本发布接口")
    expected = feed.read_bytes()
    query = f"current_version=release-probe&installation_id={RELEASE_PROBE_INSTALLATION_ID}"
    for endpoint in endpoints:
        url = sparkle_feed_url(endpoint, query)
        request = urllib.request.Request(url, headers={"User-Agent": "XStats-Release"})
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status != 200 or response.read(MAXIMUM_FEED_BYTES + 1) != expected:
                raise RuntimeError(f"{url} 返回的 Sparkle 清单与 {feed.name} 不一致")
        print(f"✅ Sparkle 更新源已生效：{urlsplit(url).netloc}")


def publish(appcast: Path, endpoints: list[str], token: str) -> None:
    if not token:
        raise ValueError("XSTATS_RELEASE_TOKEN 不能为空")
    if not endpoints:
        raise ValueError("至少需要一个版本发布接口")
    # 先校验全部发布路径，避免后续地址配置错误时已切换部分区域的版本。
    for endpoint in endpoints:
        sparkle_feed_url(endpoint)
    body = appcast.read_bytes()
    manifest = json.loads(body)
    if not isinstance(manifest, dict) or not manifest.get("version"):
        raise ValueError(f"{appcast} 不是有效的版本清单")
    for endpoint in endpoints:
        request = urllib.request.Request(
            endpoint,
            data=body,
            method="PUT",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "User-Agent": "XStats-Release",
            },
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status != 204:
                raise RuntimeError(f"{endpoint} 返回 {response.status}")
        print(f"✅ 版本清单已发布到 {endpoint}")


def configured_endpoints(environment: Mapping[str, str]) -> list[str]:
    configured = environment.get("XSTATS_API_URLS", "")
    if configured:
        return [item.strip() for item in configured.split(",") if item.strip()]
    if endpoint := environment.get("XSTATS_API_URL"):
        return [endpoint]
    return list(DEFAULT_ENDPOINTS)


def main() -> None:
    usage = f"用法：{sys.argv[0]} <appcast.json> | --check-sparkle | --verify-sparkle <feed.xml>"
    arguments = sys.argv[1:]
    if len(arguments) not in (1, 2) or (len(arguments) == 2) != (arguments[0] == "--verify-sparkle"):
        raise SystemExit(usage)
    endpoints = configured_endpoints(os.environ)
    token = os.environ.get("XSTATS_RELEASE_TOKEN", "")
    try:
        if arguments[0] == "--check-sparkle":
            check_sparkle_endpoints(endpoints)
        elif arguments[0] == "--verify-sparkle":
            verify_sparkle_feeds(Path(arguments[1]), endpoints)
        else:
            publish(Path(arguments[0]), endpoints, token)
    except Exception as error:
        raise SystemExit(f"发布版本到 API 失败：{error}") from error


if __name__ == "__main__":
    main()
