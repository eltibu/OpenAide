"""Drops `const` where a translated phrase (tr()) now sits inside it.

    python3 tool/i18n/unconst.py   # reads `flutter analyze` errors

Run after wrapping phrases in tr(); repeat until analyze is clean.
"""

import re
import subprocess
import sys

OPEN = {"(": ")", "[": "]", "{": "}"}


def close_of(src, start):
    """Index of the bracket closing the first one at or after start."""
    i = start
    while src[i] not in OPEN:
        i += 1
    depth, quote = 0, None
    while i < len(src):
        c = src[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = None
        elif c in "'\"":
            quote = c
        elif c in OPEN:
            depth += 1
        elif c in OPEN.values():
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return len(src)


def fix(path, spots):
    src = open(path).read()
    lines = src.split("\n")
    offsets = sorted(
        (sum(len(l) + 1 for l in lines[: ln - 1]) + col - 1 for ln, col in spots),
        reverse=True,
    )
    for off in offsets:
        for m in reversed(list(re.finditer(r"\bconst\s+", src[:off]))):
            if close_of(src, m.end()) >= off:
                src = src[: m.start()] + src[m.end() :]
                break
    open(path, "w").write(src)


def main():
    out = subprocess.run(
        ["flutter", "analyze"], capture_output=True, text=True
    ).stdout
    spots = {}
    for m in re.finditer(
        r"error • .* • (\S+\.dart):(\d+):(\d+) • (const_\w+|non_constant\w*|invalid_constant)",
        out,
    ):
        spots.setdefault(m.group(1), set()).add((int(m.group(2)), int(m.group(3))))
    for path, s in spots.items():
        fix(path, s)
    print(sum(len(s) for s in spots.values()))
    return 1 if spots else 0


if __name__ == "__main__":
    sys.exit(main())
