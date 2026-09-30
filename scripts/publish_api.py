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
    "https://xstats-apps.12306.work/api/v1/releases/current",
    "https://x-stats.china.12306.work/api/v1/releases/current",
)


def check_sparkle_endpoints(endpoints: list[str]) -> None:
    """不携带安装标识的探测必须返回 400，防止先发布客户端而服务端仍是旧版。"""
    if not endpoints:
        raise ValueError("至少需要一个版本发布接口")
    for endpoint in endpoints:
        parts = urlsplit(endpoint)
        if not parts.path.endswith("/api/v1/releases/current"):
            raise ValueError(f"无法推导 Sparkle 更新源：{endpoint}")
        url = urlunsplit((parts.scheme, parts.netloc, parts.path.removesuffix("releases/current") + "update/appcast.xml", "", ""))
        request = urllib.request.Request(url, headers={"User-Agent": "XStats-Release"})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                raise RuntimeError(f"{url} 未拒绝缺少安装标识的请求：{response.status}")
        except urllib.error.HTTPError as error:
            with error:
                if error.code != 400 or error.headers.get("Cache-Control") != "no-store":
                    raise RuntimeError(f"请先部署支持 Sparkle 的 API：{url} 返回 {error.code}") from error


def publish(appcast: Path, endpoints: list[str], token: str) -> None:
    if not token:
        raise ValueError("XSTATS_RELEASE_TOKEN 不能为空")
    if not endpoints:
        raise ValueError("至少需要一个版本发布接口")
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
    if len(sys.argv) != 2:
        raise SystemExit(f"用法：{sys.argv[0]} <appcast.json>")
    endpoints = configured_endpoints(os.environ)
    token = os.environ.get("XSTATS_RELEASE_TOKEN", "")
    try:
        if sys.argv[1] == "--check-sparkle":
            check_sparkle_endpoints(endpoints)
        else:
            publish(Path(sys.argv[1]), endpoints, token)
    except Exception as error:
        raise SystemExit(f"发布版本到 API 失败：{error}") from error


if __name__ == "__main__":
    main()
