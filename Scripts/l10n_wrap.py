#!/usr/bin/env python3
"""把 Swift 源码里的中文字符串字面量包进 tr(...)，并输出需要翻译的文案模板。

    Scripts/l10n_wrap.py --apply            # 改写源码
    Scripts/l10n_wrap.py --list > keys.txt  # 只列出模板（插值写成 {}）

跳过注释、多行字符串、原始字符串、日志调用（Logger 需要字面量）、case 模式与 enum 原始值，
以及已经包在 tr(...) 里的字面量。插值里嵌套的中文字面量也会各自包起来。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "Packages/XStatsKit/Sources"
MODULES = ["XStatsUI", "Metrics", "Cleaner", "HelperShared", "Updates", "SMC"]
CJK = re.compile(r"[一-鿿　-〿＀-￯]")
LOG_CALL = re.compile(r"(\bLog\.\w+|\blog|\blogger)\.(notice|error|info|debug|warning|fault|trace|critical)\($")
CASE_PATTERN = re.compile(r"^\s*case\s*$|^\s*case\s+\w+\s*=\s*$|,\s*$(?<=case\s)")

keys = set()


def parse_interpolation(s, i):
    """s[i] 是 '\\(' 之后的第一个字符，返回 (内部代码, 结束位置 ')' 的下标)"""
    depth = 1
    j = i
    while j < len(s):
        c = s[j]
        if c == '"':
            _, j = parse_string(s, j, transform=False)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return s[i:j], j
        j += 1
    raise ValueError("unterminated interpolation")


def parse_string(s, i, transform=True):
    """s[i] == '"'，返回 (改写后的字面量, 下一个位置)；同时算出不含插值的文字与模板"""
    j = i + 1
    out = ['"']
    text = []
    template = []
    while j < len(s):
        c = s[j]
        if c == "\\":
            if s[j + 1] == "(":
                inner, end = parse_interpolation(s, j + 2)
                out.append("\\(" + (transform_code(inner) if transform else inner) + ")")
                template.append("{}")
                j = end + 1
                continue
            out.append(s[j:j + 2])
            template.append(s[j:j + 2].replace('\\"', '"').replace("\\n", "\\n"))
            j += 2
            continue
        if c == '"':
            out.append('"')
            return ("".join(out), "".join(text), "".join(template)), j + 1
        if c == "\n":
            raise ValueError("newline in string")
        out.append(c)
        text.append(c)
        template.append(c)
        j += 1
    raise ValueError("unterminated string")


def transform_code(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        if s.startswith("//", i):
            end = s.find("\n", i)
            end = n if end < 0 else end
            out.append(s[i:end])
            i = end
        elif s.startswith("/*", i):
            end = s.find("*/", i + 2)
            end = n if end < 0 else end + 2
            out.append(s[i:end])
            i = end
        elif s.startswith('"""', i):
            end = s.find('"""', i + 3)
            end = n if end < 0 else end + 3
            out.append(s[i:end])
            i = end
        elif s.startswith('#"', i):
            end = s.find('"#', i + 2)
            end = n if end < 0 else end + 2
            out.append(s[i:end])
            i = end
        elif s[i] == '"':
            prefix = "".join(out)
            line = prefix[prefix.rfind("\n") + 1:]
            stripped = prefix.rstrip()
            skip = bool(LOG_CALL.search(line.rstrip())) or bool(re.search(r"^\s*case\s*$|^\s*case\s+\w+\s*=\s*$", line)) \
                or stripped.endswith("tr(")
            (literal, text, template), end = parse_string(s, i, transform=not skip)
            if skip:
                out.append(s[i:end])
            elif CJK.search(text):
                keys.add(template)
                out.append("tr(" + literal + ")")
            else:
                out.append(literal)
            i = end
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def add_import(source):
    if re.search(r"^import Localization$", source, re.M):
        return source
    imports = list(re.finditer(r"^import [\w.]+\n", source, re.M))
    if not imports:
        return "import Localization\n" + source
    last = imports[-1]
    return source[:last.end()] + "import Localization\n" + source[last.end():] if False else \
        source[:imports[0].start()] + "".join(sorted(set([m.group(0) for m in imports] + ["import Localization\n"]))) + source[last.end():]


def main():
    apply = "--apply" in sys.argv
    for module in MODULES:
        for path in sorted((ROOT / module).rglob("*.swift")):
            source = path.read_text(encoding="utf-8")
            updated = transform_code(source)
            if apply and updated != source:
                path.write_text(add_import(updated), encoding="utf-8")
    if "--list" in sys.argv:
        for key in sorted(keys):
            print(key)
    print(f"{len(keys)} 条文案", file=sys.stderr)


if __name__ == "__main__":
    main()
