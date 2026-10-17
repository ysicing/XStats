#!/usr/bin/env python3
# Copyright (C) 2026 ysicing
# SPDX-License-Identifier: AGPL-3.0-or-later

"""运行现有真实硬件资源测试；成功后更新唯一的受版本控制摘要。"""

import datetime
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
REPORT = Path("docs/PERFORMANCE.md")
GROUPS = (
    ("monitoring", "监控反复开关", "XSTATS_MONITORING_RESOURCE_REPORT", 5),
    ("battery", "电池页面与能耗采样", "XSTATS_BATTERY_POWER_RESOURCE_REPORT", 9),
    ("information", "关闭监控后的基础信息页面", "XSTATS_BASIC_INFORMATION_RESOURCE_REPORT", 8),
)
METRICS = {
    "cpuSeconds": "CPU 时间（秒）",
    "wallSeconds": "实际时长（秒）",
    "snapshots": "快照数",
    "cpuSamples": "CPU 样本",
    "batterySamples": "电池样本",
    "powerSamples": "功耗样本",
    "appEnergySamples": "App 能耗样本",
    "firstEnergySeconds": "首个能耗样本延迟（秒）",
}


def load_reports(directory):
    reports = {}
    for name, _, _, count in GROUPS:
        data = json.loads((directory / f"{name}.json").read_text())
        if name == "monitoring" and isinstance(data, list):
            rows = {row["name"]: {k: v for k, v in row.items() if k != "name"} for row in data}
        elif name != "monitoring" and isinstance(data, dict):
            rows = data
        else:
            raise ValueError(f"{name}: 报告结构错误")
        if len(rows) != count:
            raise ValueError(f"{name}: 阶段数量错误（应为 {count}）")
        required = {"cpuSeconds", "snapshots"}
        required |= {"cpuSamples"} if name == "monitoring" else set()
        if name == "battery":
            required |= {"wallSeconds", "batterySamples", "powerSamples", "appEnergySamples"}
        for phase, values in rows.items():
            if not isinstance(phase, str) or not isinstance(values, dict) or not required <= values.keys():
                raise ValueError(f"{name}: 阶段指标不完整")
            for key, value in values.items():
                if key not in METRICS or type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                    raise ValueError(f"{name}/{phase}: 无效指标 {key}")
        reports[name] = rows
    return reports


def render_report(metadata, reports):
    lines = [
        "<!-- Copyright (C) 2026 ysicing",
        "SPDX-License-Identifier: AGPL-3.0-or-later -->",
        "", "# 本地性能报告", "",
        "由 `task perf` 生成；每次成功运行更新此文件，通过 Git 历史查看变化。", "",
        f"- 测量时间：{metadata['time']}",
        f"- 测量起点 HEAD：`{metadata['commit']}`",
        f"- 工作区：{'包含未提交改动' if metadata['dirty'] else '干净'}（不计本报告）",
        f"- 硬件：{metadata['chip']}；{metadata['memoryGiB']} GiB 内存；{metadata['arch']}",
        f"- 系统：macOS {metadata['macOS']}",
        f"- Xcode：{metadata['xcode']}",
        f"- Swift：{metadata['swift']}",
        "- 配置：Release（启用 testable imports）；三组测试串行、各运行一次；构建时间不计入阶段指标",
        "- 结果：三组测试通过，全部阶段报告完整", "",
        "## 统计口径", "",
        "CPU 时间来自测试进程的用户态与内核态累计时间差，不是 CPU 百分比，"
        "不包含子进程 CPU 时间，也不是已安装 XStats 的整机能耗。"
        "本报告不测内存峰值、唤醒次数或耗电量。", "",
        "这是短时资源生命周期走查，未预热或重复取中位数。"
        "小幅耗时变化可能来自系统负载、温度或调度；比较时应使用同一机器、"
        "相同工具链和相近负载。缺失指标显示为 —，不表示零。", "",
        "HEAD 指运行开始时的代码基点，不是包含本报告的提交；"
        "若工作区有改动，测量包含当时的本地改动。"
        "原始 JSON、环境信息和日志保存在本次 `build/performance/` 子目录，不入库。",
    ]
    for name, title, _, _ in GROUPS:
        rows = reports[name]
        keys = [key for key in METRICS if any(key in values for values in rows.values())]
        lines += ["", f"## {title}", "",
                  "| 阶段 | " + " | ".join(METRICS[key] for key in keys) + " |",
                  "| --- | " + " | ".join("---:" for _ in keys) + " |"]
        for phase, values in sorted(rows.items()):
            cells = []
            for key in keys:
                value = values.get(key)
                cells.append("—" if value is None else f"{value:.6f}" if key.endswith("Seconds") else f"{value:g}")
            lines.append(f"| {phase} | " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n"


def run_performance(root):
    output = root / "build/performance"
    output.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    directory = Path(tempfile.mkdtemp(prefix=stamp + "-", dir=output))
    print(f"原始报告与日志：{directory}", flush=True)

    def capture(*args):
        return subprocess.check_output(args, cwd=root, text=True).strip()

    metadata = {
        "time": stamp,
        "commit": capture("git", "rev-parse", "HEAD"),
        "dirty": bool(capture("git", "status", "--porcelain", "--", ".", f":(exclude){REPORT}")),
        "chip": capture("sysctl", "-n", "machdep.cpu.brand_string"),
        "memoryGiB": int(capture("sysctl", "-n", "hw.memsize")) // (1024 ** 3),
        "arch": capture("uname", "-m"),
        "macOS": capture("sw_vers", "-productVersion"),
        "xcode": capture("xcodebuild", "-version").replace("\n", "; "),
        "swift": capture("swift", "--version").splitlines()[0],
        "status": "running",
    }
    package = root / "Packages/XStatsKit"
    env = os.environ.copy()
    env.update({variable: str(directory / f"{name}.json") for name, _, variable, _ in GROUPS})
    try:
        print("step 1/3：构建 Release 测试程序（详见 build.log）", flush=True)
        with (directory / "build.log").open("w") as log:
            # Release 默认不导出 @testable 所需符号；保留优化，同时显式启用测试访问。
            subprocess.run(["swift", "build", "-c", "release", "--build-tests", "-Xswiftc", "-enable-testing"],
                           cwd=package, stdout=log, stderr=subprocess.STDOUT, check=True)
        print("step 2/3：串行运行三组资源测试（详见 tests.log）", flush=True)
        with (directory / "tests.log").open("w") as log:
            subprocess.run(["swift", "test", "-c", "release", "--skip-build", "--no-parallel",
                            "-Xswiftc", "-enable-testing",
                            "--filter", r"^XStatsUITests\.MonitoringResourceTests/"],
                           cwd=package, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        print("step 3/3：校验数据并更新摘要", flush=True)
        reports = load_reports(directory)
        summary = render_report(metadata, reports)
        (directory / "summary.md").write_text(summary)
        # 失败不能覆盖上一份成功报告；同目录替换避免写到一半留下残缺摘要。
        target = root / REPORT
        temporary = target.with_suffix(".md.tmp")
        temporary.write_text(summary)
        temporary.replace(target)
        metadata["status"] = "passed"
        print(f"已更新：{target}", flush=True)
    except Exception:
        metadata["status"] = "failed"
        raise
    finally:
        (directory / "environment.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    try:
        run_performance(ROOT)
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"性能测试失败，未更新成功报告；请查看本次日志。{error}") from error
