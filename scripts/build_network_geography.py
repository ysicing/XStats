#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""转换官方 DB-IP Lite 混合 IPv4/IPv6 CSV；不将 IP 数据写入源码资源。"""
import argparse
import csv
import io
import ipaddress
import json
from pathlib import Path
import re

MAX_BINARY_BYTES = 32 * 1024 * 1024


def convert_country_csv(data: bytes, max_bytes: int = MAX_BINARY_BYTES) -> dict[int, bytes]:
    """严格校验每个地址族的递增不重叠范围，并合并相邻同国家记录。"""
    outputs = {4: bytearray(), 6: bytearray()}
    pending = {}
    try:
        text = data.decode("utf-8")
        for line, row in enumerate(csv.reader(io.StringIO(text), strict=True), 1):
            if len(row) != 3:
                raise ValueError(f"CSV 第 {line} 行必须有 3 列")
            first, last, country = row
            start, end = ipaddress.ip_address(first), ipaddress.ip_address(last)
            if start.version != end.version or int(start) > int(end):
                raise ValueError(f"CSV 第 {line} 行地址族或范围顺序无效")
            if not re.fullmatch(r"[A-Z]{2}", country):
                raise ValueError(f"CSV 第 {line} 行国家代码无效")
            family = start.version
            a, b = int(start), int(end)
            previous = pending.get(family)
            if previous:
                if previous[1] >= a:
                    raise ValueError(f"CSV 第 {line} 行范围重叠或未递增")
                if previous[1] + 1 == a and previous[2] == country:
                    pending[family] = (previous[0], b, country)
                    continue
                width = 4 if family == 4 else 16
                outputs[family].extend(previous[0].to_bytes(width, "big") + previous[1].to_bytes(width, "big") + previous[2].encode("ascii"))
            record_bytes = 10 if family == 4 else 34
            if len(outputs[family]) + record_bytes > max_bytes:
                raise ValueError(f"IPv{family} 二进制数据超过大小上限")
            pending[family] = (a, b, country)
    except (UnicodeError, csv.Error) as error:
        raise ValueError("CSV 编码或格式无效") from error
    if set(pending) != {4, 6}:
        raise ValueError("CSV 必须同时包含 IPv4 和 IPv6 数据")
    for family, (a, b, country) in pending.items():
        width = 4 if family == 4 else 16
        outputs[family].extend(a.to_bytes(width, "big") + b.to_bytes(width, "big") + country.encode("ascii"))
    return {family: bytes(value) for family, value in outputs.items()}


def convert_world_geojson(source: Path, destination: Path) -> None:
    """保留 Natural Earth 地图轮廓的离线转换；与动态 IP 数据独立。"""
    countries = []
    for feature in json.loads(source.read_text())["features"]:
        properties = feature["properties"]
        code = properties["ISO_A2_EH"]
        if code == "-99":
            continue
        geometry = feature["geometry"]
        polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
        countries.append(dict(code=code, longitude=properties["LABEL_X"], latitude=properties["LABEL_Y"],
                              rings=[[[round(x, 2), round(y, 2)] for x, y in polygon[0]] for polygon in polygons]))
    destination.write_text(json.dumps(countries, separators=(",", ":")))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path, nargs="?", help="官方混合 IPv4/IPv6 CSV")
    parser.add_argument("--output", type=Path, default=Path("dist/network-geography"))
    parser.add_argument("--world", type=Path, help="单独生成 Natural Earth 世界轮廓")
    args = parser.parse_args()
    if not args.csv and not args.world:
        parser.error("需要 CSV 或 --world")
    args.output.mkdir(parents=True, exist_ok=True)
    if args.csv:
        for family, data in convert_country_csv(args.csv.read_bytes()).items():
            (args.output / f"country-ipv{family}.bin").write_bytes(data)
    if args.world:
        convert_world_geojson(args.world, args.output / "world-countries.json")


if __name__ == "__main__":
    main()
