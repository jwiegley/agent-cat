#!/usr/bin/env python3
"""Enforce the manual's explicit plain-English prose constraints."""

from __future__ import annotations

import re
from pathlib import Path

MANUAL = Path(__file__).with_name("agent-cat.texi")
BANNED = re.compile(
    r"not (only|just)|not .* but |isn't|doesn't|can't|won't|it's|there's|"
    r"In today's|leverage|empower|unlock|seamless|robust|best-in-class|powerful|"
    r"Constructor:|Default:|free question|convolution|initial-algebra|free-monoid",
    re.IGNORECASE,
)


def main() -> int:
    text = MANUAL.read_text()
    hits = [(number, line) for number, line in enumerate(text.splitlines(), 1) if BANNED.search(line)]
    if hits:
        for number, line in hits:
            print(f"prohibited prose at {number}: {line}")
        return 1

    plain = re.sub(r"@(?:code|file|command|samp|dfn|ref)\{([^{}]*)\}", r"\1", text)
    plain = re.sub(r"(?ms)^@(example|verbatim|smallexample).*?^@end \1$", "", plain)
    sentences = [sentence.strip() for sentence in re.split(r"(?<=[.!?])\s+", plain) if sentence.strip()]
    short = [len(re.findall(r"[A-Za-z][A-Za-z'-]*", sentence)) <= 6 for sentence in sentences]
    for index in range(len(short) - 2):
        if all(short[index : index + 3]):
            print("three-sentence staccato run begins with:")
            for sentence in sentences[index : index + 3]:
                print(sentence)
            return 1

    print("manual prose: prohibited patterns absent; no three-sentence staccato run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
