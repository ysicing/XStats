#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

"""把发布清单提交给 XStats API。"""

import json
import os
import sys
import urllib.request
from pathlib import Path


DEFAULT_ENDPOINT = "https://getopenstats.com/api/v1/releases/current"


def publish(appcast: Path, endpoint: str, token: str) -> None:
    if not token:
        raise ValueError("XSTATS_RELEASE_TOKEN 不能为空")
    body = appcast.read_bytes()
    manifest = json.loads(body)
    if not isinstance(manifest, dict) or not manifest.get("version"):
        raise ValueError(f"{appcast} 不是有效的版本清单")
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
            raise RuntimeError(f"发布接口返回 {response.status}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"用法：{sys.argv[0]} <appcast.json>")
    endpoint = os.environ.get("XSTATS_API_URL", DEFAULT_ENDPOINT)
    token = os.environ.get("XSTATS_RELEASE_TOKEN", "")
    try:
        publish(Path(sys.argv[1]), endpoint, token)
    except Exception as error:
        raise SystemExit(f"发布版本到 API 失败：{error}") from error
    print(f"✅ 版本清单已发布到 {endpoint}")


if __name__ == "__main__":
    main()
