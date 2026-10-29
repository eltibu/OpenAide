"""Turns the app's own words into translatable ones.

    python3 tool/i18n/wrap_text.py [files...]

Text('Plain words') becomes T('Plain words'), and the file gets the import.
Only literal text is touched: anything built with $ stays a Text. Run it
again after adding screens; it leaves T() alone. Then run
tool/i18n/build_catalogs.py so the new words get translations.
"""

import os
import re
import sys

LIT = r"""(?:'(?:[^'\\$\n]|\\[^$])*'|"(?:[^"\\$\n]|\\[^$])*")"""
TEXT = re.compile(r"\bText\((\s*" + LIT + r"(?:\s*" + LIT + r")*\s*[,)])")
IMPORT = "core/i18n/app_strings.dart"


def rel_import(path):
    here = os.path.dirname(os.path.relpath(path, "lib"))
    target = os.path.relpath(os.path.join("", IMPORT), here or ".")
    return target.replace(os.sep, "/")


def add_import(src, path):
    if "app_strings.dart'" in src:
        return src
    line = f"import '{rel_import(path)}';\n"
    imports = list(re.finditer(r"^import [^\n]+;\n", src, re.M))
    if not imports:
        return line + src
    # After the last package import, before relative ones, keeps the
    # file's grouping close enough for dart format.
    last = imports[-1]
    return src[: last.end()] + line + src[last.end() :]


def wrap(path):
    src = open(path).read()
    out = TEXT.sub(lambda m: "T(" + m.group(1), src)
    if out != src:
        out = add_import(out, path)
        open(path, "w").write(out)
        return True
    return False


def main():
    files = sys.argv[1:] or [
        os.path.join(d, f)
        for d, _, fs in os.walk("lib")
        for f in fs
        if f.endswith(".dart")
    ]
    changed = [f for f in files if "core/i18n/" not in f and wrap(f)]
    print(f"{len(changed)} files changed")


if __name__ == "__main__":
    main()
