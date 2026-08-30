#!/usr/bin/env python3
"""Verify that marked Haskell examples are verbatim excerpts of live source."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANUAL = ROOT / "doc" / "agent-cat.texi"
BLOCK = re.compile(
    r"^@c SOURCE (\S+)\n@(example|verbatim)\n(.*?)\n@end \2\n@c END SOURCE$",
    re.MULTILINE | re.DOTALL,
)


def unescape_texinfo(text: str) -> str:
    return text.replace("@@", "@").replace("@{", "{").replace("@}", "}")


def main() -> int:
    manual = MANUAL.read_text()
    failures: list[str] = []
    count = 0
    for match in BLOCK.finditer(manual):
        count += 1
        relative = Path(match.group(1))
        source_path = (ROOT / relative).resolve()
        if ROOT not in source_path.parents or not source_path.is_file():
            failures.append(f"invalid source path: {relative}")
            continue
        excerpt = match.group(3) if match.group(2) == "verbatim" else unescape_texinfo(match.group(3))
        if excerpt not in source_path.read_text():
            failures.append(f"manual excerpt is not verbatim: {relative}")
    includes = set(re.findall(r"^@verbatiminclude (examples/\S+\.hs)$", manual, re.MULTILINE))
    expected_includes = {"examples/Hello.hs", "examples/Registry.hs"}
    if includes != expected_includes:
        failures.append(f"Haskell includes differ: {sorted(includes)}")
    for relative in includes:
        include_path = (MANUAL.parent / relative).resolve()
        if ROOT not in include_path.parents or not include_path.is_file():
            failures.append(f"invalid Haskell include: {relative}")
    if count == 0:
        failures.append("manual contains no source-backed Haskell examples")
    for failure in failures:
        print(failure)
    if failures:
        return 1
    print(f"manual examples: {count} source excerpts and {len(includes)} complete Haskell files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
