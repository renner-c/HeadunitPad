#!/usr/bin/env python3
"""Fail the build if the app uses an SF Symbol that does not exist on iOS 14.3.

`UIImage(systemName:)` returns nil for a symbol newer than the running OS, so an
iOS 15+ symbol silently renders as nothing on the target iPad (iPadOS 14.3).

What is scanned (HeadunitPad/**/*.swift, comments ignored):
  * `systemImageName: "x"` and `systemName: "x"`      -> a single symbol
  * `systemImageNames: ["a", "b", ...]`               -> an ordered fallback list
    (the first name that resolves wins at runtime, see HeadunitButton)

Rule:
  * A single symbol must exist and have an iOS release <= --max-ios (default 14.3).
  * A name in a fallback list may be newer than --max-ios ONLY IF the same list
    also contains at least one symbol with an iOS release <= --max-ios.
  * A name that is not in the symbol database at all is always an error (typo).
  * Non-literal arguments (variables, interpolation) cannot be checked and are skipped.

The database is macOS's CoreGlyphs bundle (present on the CI macOS runners):
  /System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist
  `symbols` maps name -> release key ("2020.1"); `year_to_release` maps a release
  key -> {"iOS": "14.2", ...}.

Usage: check_sf_symbols.py [--root DIR] [--plist PATH] [--max-ios 14.3]
Exit status: 0 ok, 1 violations found, 2 usage / database problems.
"""

import argparse
import os
import plistlib
import re
import sys
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

DEFAULT_PLIST = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
DEFAULT_MAX_IOS = "14.3"

STRING_LITERAL = r'"((?:[^"\\\n]|\\.)*)"'
SINGLE_RE = re.compile(r'\b(?:systemImageName|systemName)\s*:\s*' + STRING_LITERAL)
# Only literal-only lists are checked; declarations like `systemImageNames: [String] = []` and
# computed arguments don't match.
LIST_RE = re.compile(
    r'\bsystemImageNames\s*:\s*\[(\s*(?:' + STRING_LITERAL + r'\s*,\s*)*(?:' + STRING_LITERAL + r'\s*,?\s*)?)\]'
)
LITERAL_RE = re.compile(STRING_LITERAL)


@dataclass(frozen=True)
class Use:
    path: str
    line: int
    names: Tuple[str, ...]
    is_fallback_list: bool


def parse_version(text: str) -> Tuple[int, ...]:
    return tuple(int(part) for part in text.split("."))


def strip_comments(source: str) -> str:
    """Blank out // and /* */ comments (keeping newlines) but leave string literals intact."""
    out: List[str] = []
    i, n = 0, len(source)
    while i < n:
        ch = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if ch == '"':
            j = i + 1
            while j < n and source[j] != '"' and source[j] != "\n":
                j += 2 if source[j] == "\\" else 1
            out.append(source[i:j + 1])
            i = j + 1
        elif ch == "/" and nxt == "/":
            while i < n and source[i] != "\n":
                i += 1
        elif ch == "/" and nxt == "*":
            end = source.find("*/", i + 2)
            end = n if end == -1 else end + 2
            out.append("".join(c if c == "\n" else " " for c in source[i:end]))
            i = end
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def extract_uses(source: str, path: str = "<memory>") -> List[Use]:
    code = strip_comments(source)
    uses: List[Use] = []
    for m in SINGLE_RE.finditer(code):
        uses.append(Use(path, code.count("\n", 0, m.start()) + 1, (m.group(1),), False))
    for m in LIST_RE.finditer(code):
        names = tuple(LITERAL_RE.findall(m.group(1)))
        uses.append(Use(path, code.count("\n", 0, m.start()) + 1, names, True))
    return sorted(uses, key=lambda u: u.line)


def load_availability(plist_path: str) -> Dict[str, Optional[Tuple[int, ...]]]:
    """Map symbol name -> iOS release as a version tuple (None if it has no iOS release)."""
    with open(plist_path, "rb") as handle:
        data = plistlib.load(handle)
    releases = data["year_to_release"]
    result: Dict[str, Optional[Tuple[int, ...]]] = {}
    for name, key in data["symbols"].items():
        ios = releases.get(key, {}).get("iOS")
        result[name] = parse_version(ios) if ios else None
    return result


def check_uses(
    uses: List[Use],
    availability: Dict[str, Optional[Tuple[int, ...]]],
    max_ios: Tuple[int, ...],
) -> List[str]:
    """Return one human-readable message per violation."""
    problems: List[str] = []

    def too_new(name: str) -> bool:
        release = availability[name]
        return release is None or release > max_ios

    max_text = ".".join(str(p) for p in max_ios)
    for use in uses:
        where = f"{use.path}:{use.line}"
        unknown = [n for n in use.names if n not in availability]
        for name in unknown:
            problems.append(f"{where}: unknown SF Symbol '{name}' (typo?)")
        known = [n for n in use.names if n in availability]
        has_safe = any(not too_new(n) for n in known)
        for name in known:
            if not too_new(name):
                continue
            release = availability[name]
            version = ".".join(str(p) for p in release) if release else "n/a"
            if not use.is_fallback_list:
                problems.append(
                    f"{where}: SF Symbol '{name}' needs iOS {version} (> {max_text}); "
                    f"use a fallback list via systemImageNames: with an older symbol"
                )
            elif not has_safe:
                problems.append(
                    f"{where}: SF Symbol '{name}' needs iOS {version} (> {max_text}) and the "
                    f"fallback list has no symbol available on iOS {max_text}"
                )
        if use.is_fallback_list and not use.names:
            problems.append(f"{where}: empty systemImageNames list")
    return problems


def swift_files(root: str) -> List[str]:
    found: List[str] = []
    for directory, _dirs, files in os.walk(root):
        found.extend(os.path.join(directory, f) for f in files if f.endswith(".swift"))
    return sorted(found)


def scan(root: str) -> List[Use]:
    uses: List[Use] = []
    for path in swift_files(root):
        with open(path, encoding="utf-8") as handle:
            uses.extend(extract_uses(handle.read(), os.path.relpath(path)))
    return uses


def main(argv: Optional[List[str]] = None) -> int:
    repo = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=os.path.join(repo, "HeadunitPad"))
    parser.add_argument("--plist", default=DEFAULT_PLIST)
    parser.add_argument("--max-ios", default=DEFAULT_MAX_IOS)
    args = parser.parse_args(argv)

    if not os.path.isfile(args.plist):
        print(f"error: SF Symbols database not found: {args.plist}", file=sys.stderr)
        return 2
    availability = load_availability(args.plist)
    uses = scan(args.root)
    problems = check_uses(uses, availability, parse_version(args.max_ios))

    symbols = sorted({n for u in uses for n in u.names})
    print(f"Checked {len(uses)} SF Symbol use(s), {len(symbols)} distinct name(s) against iOS {args.max_ios}.")
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
