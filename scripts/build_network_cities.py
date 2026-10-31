#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Build a small WGS84 representative-point table from GeoNames CN.zip (CC BY 4.0)."""

import argparse
import json
import re
import zipfile

PROVINCES = dict(zip(
    "01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 18 19 20 21 22 23 24 25 26 28 29 30 31 32 33".split(),
    "安徽 浙江 江西 江苏 吉林 青海 福建 黑龙江 河南 河北 湖南 湖北 新疆 西藏 甘肃 广西 贵州 辽宁 内蒙古 宁夏 北京 上海 山西 山东 陕西 天津 云南 广东 海南 四川 重庆".split(),
))


def build(source):
    points = {}
    priorities = {}
    with zipfile.ZipFile(source) as archive, archive.open("CN.txt") as rows:
        for row in rows:
            fields = row.decode("utf-8").rstrip("\n").split("\t")
            feature, province = fields[7], PROVINCES.get(fields[10])
            if not province or feature not in ("ADM1", "ADM2", "PPLA", "PPLA2", "PPLC"):
                continue
            coordinate = [float(fields[5]), float(fields[4])]
            priority = {"ADM1": 0, "ADM2": 1, "PPLA": 2, "PPLA2": 2, "PPLC": 2}[feature]
            names = {""} if feature == "ADM1" else set(fields[3].split(","))
            for name in names:
                if name and not re.fullmatch(r"[\u4e00-\u9fff]+", name):
                    continue
                if name.endswith("市"):
                    name = name[:-1]
                key = province + "|" + name
                if priority > priorities.get(key, -1):
                    points[key] = coordinate
                    priorities[key] = priority
    return dict(sorted(points.items()))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", help="GeoNames CN.zip")
    parser.add_argument("output")
    args = parser.parse_args()
    with open(args.output, "w", encoding="utf-8") as destination:
        json.dump(build(args.source), destination, ensure_ascii=False, separators=(",", ":"))
        destination.write("\n")
