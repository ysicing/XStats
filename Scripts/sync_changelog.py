#!/usr/bin/env python3
"""Puts CHANGELOG.md where people look, and draws the commit calendar.

    python3 Scripts/sync_changelog.py

Rewrites, from CHANGELOG.md and `git log`:

- the "recent updates" block in README.md (Chinese) and README.en.md, between
  <!-- changelog:start --> and <!-- changelog:end -->;
- the same block, as HTML, in web/index.html;
- Assets/readme/activity.svg and activity.zh.svg, 26 weeks of commits.

Run it after every CHANGELOG edit. Standard library only, so it runs on a
stock Mac and in CI. Adapted from QuotaBar's script of the same name.
"""

import argparse
import datetime
import html
import math
import pathlib
import re
import subprocess
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent.parent
RECENT_DAYS = 3
WEEKS = 26

KIND_EN = {"新增": "Added", "样式": "Style", "调整": "Changed", "修复": "Fixed"}
WEB_ITEMS_PER_DAY = 8


# ── CHANGELOG.md ──────────────────────────────────────────────────────────

def parse(text):
    """Releases, newest first: each with its days, each day with its groups.

    "## 未发布" holds "### YYYY-MM-DD" days; "## 0.1.0 · 2026-09-20" holds its
    groups directly, which count as one day on the release date.
    """
    releases, release, day, group = [], None, None, None
    for line in text.splitlines():
        heading = re.match(r"^## (.+)$", line)
        dated = re.match(r"^### (\d{4}-\d{2}-\d{2})\s*$", line)
        kind = re.match(r"^#### (.+)$", line)
        if heading:
            title = heading.group(1).strip()
            version = re.match(r"^v?([\d.]+)\s*·\s*(\d{4}-\d{2}-\d{2})$", title)
            release = {
                "version": version.group(1) if version else None,
                "date": version.group(2) if version else None,
                "days": [],
            }
            releases.append(release)
            day = {"date": release["date"], "groups": []} if version else None
            if day:
                release["days"].append(day)
            group = None
        elif dated and release is not None:
            # A release that kept its dated days: drop the empty day that
            # stood in for the release date.
            if release["days"] and not release["days"][-1]["groups"]:
                release["days"].pop()
            day = {"date": dated.group(1), "groups": []}
            release["days"].append(day)
            group = None
        elif kind and day is not None:
            group = {"kind": kind.group(1).strip(), "items": []}
            day["groups"].append(group)
        elif line.startswith("- ") and group is not None:
            group["items"].append(line[2:].strip())
        elif line.startswith("  ") and line.strip() and group is not None and group["items"]:
            text = line.strip()
            # 缩进的 “- ” 是子条目，保留成嵌套列表；其余是折行，直接接上（中文折行不加空格）
            group["items"][-1] += f"\n  - {text[2:].strip()}" if text.startswith("- ") else text
    for release in releases:
        release["days"] = [d for d in release["days"] if any(g["items"] for g in d["groups"])]
    return [r for r in releases if r["days"]]


def day_entries(releases):
    """Every day, newest first, with the release it belongs to."""
    days = [(release, day) for release in releases for day in release["days"]]
    days.sort(key=lambda pair: pair[1]["date"] or "", reverse=True)
    return days


def item_count(day):
    return sum(len(g["items"]) for g in day["groups"])


def counts(day, en):
    parts = []
    for g in day["groups"]:
        n = len(g["items"])
        if en:
            parts.append(f"{n} {KIND_EN.get(g['kind'], g['kind']).lower()}")
        else:
            parts.append(f"{g['kind']} {n}")
    return " · ".join(parts)


def latest_release(releases):
    return next((r for r in releases if r["version"]), None)


def unreleased(releases):
    return next((r for r in releases if not r["version"]), None)


# ── README ────────────────────────────────────────────────────────────────

def readme_block(releases, en):
    latest = latest_release(releases)
    pending = unreleased(releases)
    pending_count = sum(item_count(d) for d in pending["days"]) if pending else 0
    lines = ["<!-- changelog:start -->"]
    lines.append("<!-- Generated from CHANGELOG.md by Scripts/sync_changelog.py. Do not edit by hand. -->"
                 if en else "<!-- 由 Scripts/sync_changelog.py 从 CHANGELOG.md 生成，请勿手改。 -->")
    head = []
    if latest:
        head.append(f"Latest release **{latest['version']}** ({latest['date']})" if en
                    else f"最新版本 **{latest['version']}**（{latest['date']}）")
    elif en:
        head.append("Not released yet")
    else:
        head.append("尚未发布正式版本")
    if pending_count:
        head.append(f"**{pending_count}** changes in development" if en
                    else f"开发中 **{pending_count}** 项改动尚未发布")
    head.append("[full changelog](CHANGELOG.md) (kept in Chinese)" if en else "[完整更新日志](CHANGELOG.md)")
    lines += ["", " · ".join(head), ""]
    # 英文 README 只生成英文摘要；完整条目仍以中文 CHANGELOG 为准，避免混入大段中文。
    if en:
        lines.append("<!-- changelog:end -->")
        return "\n".join(lines)
    for index, (release, day) in enumerate(day_entries(releases)[:RECENT_DAYS]):
        label = release["version"] or ("Unreleased" if en else "未发布")
        opened = " open" if index == 0 else ""
        lines.append(f"<details{opened}>")
        lines.append(f"<summary><b>{day['date']}</b> · {label} · {counts(day, en)}</summary>")
        lines.append("")
        for g in day["groups"]:
            lines.append(f"**{KIND_EN.get(g['kind'], g['kind']) if en else g['kind']}**")
            lines.append("")
            lines += [f"- {item}" for item in g["items"]]
            lines.append("")
        lines.append("</details>")
        lines.append("")
    lines.append("<!-- changelog:end -->")
    return "\n".join(lines)


def replace_block(path, block, start="<!-- changelog:start -->", end="<!-- changelog:end -->"):
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.S)
    if not pattern.search(text):
        raise SystemExit(f"{path.relative_to(ROOT)}: no {start} … {end} markers")
    updated = pattern.sub(lambda _: block, text, count=1)
    if updated != text:
        path.write_text(updated, encoding="utf-8")
        return True
    return False


# ── Website ───────────────────────────────────────────────────────────────

def inline_html(text):
    """Escape an item and keep its `code`, **bold** and [links](url)."""
    out = html.escape(text, quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", out)
    out = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', out)
    return out


def item_html(item):
    """条目正文，子条目画成嵌套列表。"""
    head, *subs = item.split("\n  - ")
    out = inline_html(head)
    if subs:
        out += '<ul class="log__sub">' + "".join(f"<li>{inline_html(sub)}</li>" for sub in subs) + "</ul>"
    return out


def web_day(release, day, lines):
    items = [(g["kind"], item) for g in day["groups"] for item in g["items"]]
    lines.append('  <article class="log__day">')
    lines.append(f'    <div class="log__head"><time datetime="{day["date"]}">{day["date"]}</time>'
                 f'<span class="log__tag">{html.escape(release["version"])}</span></div>')
    lines.append(f'    <p class="log__counts">{html.escape(counts(day, False))}</p>')

    def item_lines(chunk, indent):
        return [f'{indent}<li><span class="log__kind">{html.escape(kind)}</span>{item_html(item)}</li>'
                for kind, item in chunk]

    lines.append('    <ul class="log__list">')
    lines += item_lines(items[:WEB_ITEMS_PER_DAY], "      ")
    lines.append("    </ul>")
    rest = items[WEB_ITEMS_PER_DAY:]
    if rest:
        # 仓库是私有的，完整条目直接折叠在官网上，不链接到 GitHub
        lines.append('    <details class="log__rest">')
        lines.append(f'      <summary>还有 {len(rest)} 项</summary>')
        lines.append('      <ul class="log__list">')
        lines += item_lines(rest, "        ")
        lines.append("      </ul>")
        lines.append("    </details>")
    lines.append("  </article>")


def web_block(releases, indent="      "):
    """官网只展示已发布的版本：最近几天直接显示，更早的折叠。"""
    released = [r for r in releases if r["version"]]
    entries = day_entries(released)
    lines = ["<!-- changelog:start -->",
             "<!-- 由 Scripts/sync_changelog.py 从 CHANGELOG.md 生成，请勿手改。 -->",
             '<div class="log">']
    for release, day in entries[:RECENT_DAYS]:
        web_day(release, day, lines)
    older = entries[RECENT_DAYS:]
    if older:
        lines.append('  <details class="log__older">')
        lines.append(f'    <summary>更早的更新（{len(older)} 天）</summary>')
        for release, day in older:
            web_day(release, day, lines)
        lines.append("  </details>")
    lines.append("</div>")
    lines.append("<!-- changelog:end -->")
    return "\n".join(lines[:1] + [indent + line for line in lines[1:]])


# ── Commit calendar ───────────────────────────────────────────────────────

def commit_days():
    dates = subprocess.run(
        ["git", "log", "--format=%ad", "--date=short"],
        cwd=ROOT, capture_output=True, text=True, check=True).stdout.split()
    return Counter(dates)


def activity_svg(per_day, today, en):
    cell, gap, left, top = 11, 3, 30, 18
    step = cell + gap
    # Columns are weeks starting Sunday, the last one holding today.
    end = today + datetime.timedelta(days=(5 - today.weekday()) % 7)  # the Saturday ending this week
    start = end - datetime.timedelta(days=WEEKS * 7 - 1)
    days = [start + datetime.timedelta(days=i) for i in range(WEEKS * 7)]
    window = {d: per_day.get(d.isoformat(), 0) for d in days if d <= today}
    total = sum(window.values())
    peak = max(window.values(), default=0)
    palette = ["rgba(139,148,158,0.18)", "#9be9a8", "#40c463", "#30a14e", "#216e39"]

    def level(n):
        return 0 if n == 0 or peak == 0 else max(1, min(4, math.ceil(4 * n / peak)))

    width = left + WEEKS * step
    height = top + 7 * step + 40
    font = 'font-family="-apple-system,BlinkMacSystemFont,Segoe UI,Helvetica,Arial,PingFang SC,sans-serif"'
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" role="img">']
    title = (f"{total} commits in the last {WEEKS} weeks" if en else f"近 {WEEKS} 周共 {total} 次提交")
    parts.append(f"<title>{title}</title>")
    parts.append(f'<g {font} font-size="9" fill="#8b949e">')
    months_en = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    last_month = None
    for w in range(WEEKS):
        first = days[w * 7]
        if first.month != last_month and first.day <= 7:
            label = months_en[first.month - 1] if en else f"{first.month}月"
            parts.append(f'<text x="{left + w * step}" y="{top - 6}">{label}</text>')
            last_month = first.month
        elif last_month is None:
            last_month = first.month
    for row, label in ((1, "Mon" if en else "一"), (3, "Wed" if en else "三"), (5, "Fri" if en else "五")):
        parts.append(f'<text x="0" y="{top + row * step + cell - 2}">{label}</text>')
    parts.append("</g>")
    for i, d in enumerate(days):
        if d > today:
            continue
        n = window[d]
        x, y = left + (i // 7) * step, top + (i % 7) * step
        tip = f"{n} commits on {d.isoformat()}" if en else f"{d.isoformat()}：{n} 次提交"
        parts.append(f'<rect x="{x}" y="{y}" width="{cell}" height="{cell}" rx="2" fill="{palette[level(n)]}"><title>{tip}</title></rect>')
    # The legend under the grid on the right, the caption on its own line
    # below: side by side they collide in English.
    base = top + 7 * step + 14
    caption = (f"{total} commits in the last {WEEKS} weeks · through {today.isoformat()}" if en
               else f"近 {WEEKS} 周共 {total} 次提交 · 截至 {today.isoformat()}")
    parts.append(f'<g {font} font-size="10" fill="#8b949e">')
    parts.append(f'<text x="{left}" y="{base + 16}">{caption}</text>')
    legend_x = width - 5 * step - 34
    parts.append(f'<text x="{legend_x - 4}" y="{base}" text-anchor="end">{"Less" if en else "少"}</text>')
    for k in range(5):
        parts.append(f'<rect x="{legend_x + k * step}" y="{base - cell + 1}" width="{cell}" height="{cell}" rx="2" fill="{palette[k]}"/>')
    parts.append(f'<text x="{legend_x + 5 * step + 2}" y="{base}">{"More" if en else "多"}</text>')
    parts.append("</g></svg>")
    return "\n".join(parts) + "\n"


def write_if_changed(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return False
    path.write_text(content, encoding="utf-8")
    return True


def main():
    parser = argparse.ArgumentParser(description="Sync CHANGELOG.md into the READMEs and the activity chart.")
    parser.add_argument("--changelog", default=str(ROOT / "CHANGELOG.md"),
                        help="read this file instead, e.g. the committed copy while other edits are pending")
    parser.add_argument("--through-today", action="store_true",
                        help="include today's commits in the calendar (default stops at yesterday)")
    args = parser.parse_args()
    releases = parse(pathlib.Path(args.changelog).read_text(encoding="utf-8"))
    changed = []
    if replace_block(ROOT / "README.md", readme_block(releases, en=False)):
        changed.append("README.md")
    if replace_block(ROOT / "README.en.md", readme_block(releases, en=True)):
        changed.append("README.en.md")
    if replace_block(ROOT / "web" / "index.html", web_block(releases)):
        changed.append("web/index.html")
    # The calendar runs through yesterday by default: a finished day does not
    # change, so running this again after today's commits leaves the chart
    # alone rather than redrawing it with every commit that records the redraw.
    today = datetime.date.today()
    if not args.through_today:
        today -= datetime.timedelta(days=1)
    per_day = commit_days()
    for name, en in (("activity.svg", True), ("activity.zh.svg", False)):
        if write_if_changed(ROOT / "Assets" / "readme" / name, activity_svg(per_day, today, en)):
            changed.append(f"Assets/readme/{name}")
    print("已更新：" + "、".join(changed) if changed else "已是最新")


if __name__ == "__main__":
    main()
