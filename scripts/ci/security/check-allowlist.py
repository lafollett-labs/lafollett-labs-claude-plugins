#!/usr/bin/env python3
"""Refuse a gitleaks config broader than this repo allows. Usage: check-allowlist.py <config.toml>

The config is parsed as TOML, so every spelling of a key (inline tables, dotted or quoted keys,
spaced headers) is checked as the same structure gitleaks reads. Allowed, and nothing else:
  [extend]          exactly useDefault = true (no second config, no disabledRules)
  [[allowlists]]    description, condition = "AND", one paths entry, one regexes entry, and an
                    optional regexTarget of "secret" or "line"
  paths             ^, literal path characters (\\. for a dot), $: one exact file
  regexes           ^, 8+ literal characters or backslash-escaped punctuation, $: one exact value
No [[rules]] (a rule reusing a default id replaces that rule), no stopwords, no legacy [allowlist].
Keys are matched exactly; gitleaks folds key case, so any other casing is refused too.
Prints one problem per line. Exit 0 clean, 1 problems, 2 unreadable, not TOML, or no tomllib.
"""
import re
import sys

try:
    import tomllib
except ImportError:
    print("check-allowlist: needs Python 3.11+ (tomllib)")
    sys.exit(2)

LITERAL = r"[A-Za-z0-9_=:/ ,@%&~#\"<>!;-]"
ESCAPED = r"\\[.\[\](){}*+?|^$/\\-]"
VALUE = re.compile(rf"\^(?:{LITERAL}|{ESCAPED}){{8,}}\$")
PATH = re.compile(r"\^(?:[A-Za-z0-9_/-]|\\\.)+\$")
ENTRY_KEYS = {"description", "condition", "paths", "regexes", "regexTarget"}


def one(value, pattern):
    return isinstance(value, list) and len(value) == 1 and isinstance(value[0], str) and pattern.fullmatch(value[0])


def problems(cfg):
    out = []
    extra = sorted(set(cfg) - {"extend", "allowlists"})
    if extra:
        out.append("only [extend] and [[allowlists]] are allowed at the top level, not: " + ", ".join(extra))
    if cfg.get("extend") != {"useDefault": True}:
        out.append("[extend] must be exactly useDefault = true")
    entries = cfg.get("allowlists", [])
    if not isinstance(entries, list):
        return out + ["allowlists must be an array of tables ([[allowlists]])"]
    for n, entry in enumerate(entries, 1):
        where = f"[[allowlists]] #{n}"
        if not isinstance(entry, dict):
            out.append(f"{where}: not a table")
            continue
        extra = sorted(set(entry) - ENTRY_KEYS)
        if extra:
            out.append(f"{where}: keys not allowed: " + ", ".join(extra))
        if not (isinstance(entry.get("description"), str) and entry["description"].strip()):
            out.append(f"{where}: needs a description of why the value is safe")
        if entry.get("condition") != "AND":
            out.append(f'{where}: condition must be "AND"')
        if not one(entry.get("paths"), PATH):
            out.append(f"{where}: paths must be one exact file: ^, literal characters (\\. for a dot), $")
        if not one(entry.get("regexes"), VALUE):
            out.append(f"{where}: regexes must be one exact value: ^, 8+ literal characters (escape punctuation), $")
        if entry.get("regexTarget", "secret") not in ("secret", "line"):
            out.append(f'{where}: regexTarget must be "secret" or "line"')
    return out


def main(argv):
    if len(argv) != 2:
        print("usage: check-allowlist.py <config.toml>")
        return 2
    try:
        with open(argv[1], "rb") as f:
            cfg = tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"check-allowlist: cannot read {argv[1]}: {e}")
        return 2
    found = problems(cfg)
    for p in found:
        print(p)
    return 1 if found else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # anything unexpected refuses the config rather than passing it
        print(f"check-allowlist: {type(e).__name__}: {e}")
        sys.exit(2)
