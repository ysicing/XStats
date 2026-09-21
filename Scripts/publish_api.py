#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

"""把发布清单提交给 XStats API。"""

import json
import os
import sys
import urllib.request
from collections.abc import Mapping
from pathlib import Path


DEFAULT_ENDPOINTS = (
    "https://xstats-apps.12306.work/api/v1/releases/current",
    "https://x-stats.china.12306.work/api/v1/releases/current",
)


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
        publish(Path(sys.argv[1]), endpoints, token)
    except Exception as error:
        raise SystemExit(f"发布版本到 API 失败：{error}") from error


if __name__ == "__main__":
    main()
