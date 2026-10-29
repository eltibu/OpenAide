"""Builds the app's translations from Open WebUI's.

    python3 tool/i18n/build_catalogs.py <open-webui>/src/lib/i18n/locales

Writes assets/i18n/:
- strings.json: every phrase the app shows (in T('...'), tr('...') and
  _say(context, '...')).
- <code>.json: the phrases Open WebUI already translates for that language.
- languages.json: the languages the web lists.

Phrases the web doesn't have are translated on the phone by a model on the
user's server (Settings > General > Language). Run tool/i18n/wrap_text.py
first after adding screens.
"""

import json
import os
import re
import sys

LIT = r"""'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*\""""
CALL = re.compile(
    r"\b(?:(?:T|tr)\(|_?say\(\s*\w+,)\s*((?:(?:" + LIT + r")\s*)+)[,)]"
)
ONE = re.compile(LIT)


def unquote(lit):
    body = lit[1:-1]
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), body)


def app_words():
    words = set()
    for d, _, fs in os.walk("lib"):
        for f in fs:
            if not f.endswith(".dart"):
                continue
            src = open(os.path.join(d, f)).read()
            for m in CALL.finditer(src):
                parts = ONE.findall(m.group(1))
                if any("$" in p for p in parts):
                    continue
                words.add("".join(unquote(p) for p in parts))
    return sorted(w for w in words if w.strip())


def main():
    locales = sys.argv[1]
    out = "assets/i18n"
    os.makedirs(out, exist_ok=True)
    words = app_words()
    json.dump(words, open(f"{out}/strings.json", "w"), ensure_ascii=False, indent=0)
    langs = json.load(open(f"{locales}/languages.json"))
    json.dump(langs, open(f"{out}/languages.json", "w"), ensure_ascii=False, indent=0)
    for name in sorted(os.listdir(locales)):
        path = f"{locales}/{name}/translation.json"
        if not os.path.exists(path) or name.startswith("en-"):
            continue
        web = json.load(open(path))
        mine = {w: web[w] for w in words if web.get(w)}
        json.dump(mine, open(f"{out}/{name}.json", "w"), ensure_ascii=False, indent=0, sort_keys=True)
    print(f"{len(words)} phrases, {len(langs)} languages")


if __name__ == "__main__":
    main()
