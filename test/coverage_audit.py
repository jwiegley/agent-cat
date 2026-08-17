#!/usr/bin/env python3
"""Refusal-site coverage audit for the DSL.

Every `.error` site in Agentic/Core/Dsl/{Parse,Check}.lean must be exercised by
the smoke test: this script extracts the message fragment of each site and
requires it to appear among the diagnoses the smoke test asserts. A new refusal
added without a test fails this audit, which is the point.

The asserted diagnoses live in *two* files, and both must be read. The case
tables moved to test/DslCases.lean so that `corpus-gen` could import them
without importing an executable's `main`; test/DslSmoke.lean kept the
assertions written inline beside the checks that use them. Reading only one of
the two makes this audit fail vacuously.

Two classes of site are exempt, each for a stated reason:
  * messages beginning "internal:" — the six fuel branches, unreachable by the
    budget invariant (every recursion is seeded with the input's length and
    every step consumes at least one item; documented, not proved, in
    Agentic/Core/DslFlagship.lean's "What is not proved");
  * sites listed in ALLOW, with the reason beside each.

Run from the repository root:  python3 test/coverage_audit.py
"""

import re
import sys

SOURCES = [
    "Agentic/Core/Dsl/Parse.lean",
    "Agentic/Core/Dsl/Check.lean",
]
SMOKE = [
    "test/DslCases.lean",
    "test/DslSmoke.lean",
]

ALLOW = {
    # `unexpected` builds "expected {what}" from a caller-supplied phrase; the
    # generic wrappers themselves carry no message. Their call sites do, and
    # those are audited through the phrases below.
    'expected {what}, but the source ended': "the EOF shape of `unexpected`; hit "
        "by 'the source ends inside the workflow' via its {what}",
    'expected {what}': "the generic shape of `unexpected`; every call site's "
        "{what} phrase is audited individually",
    '`{String.ofList [c]}`': "expectPunct's {what} is the mark itself; the "
        "battery exercises `]` `,` `=` `:` `{` and `}` expectations by source",
    # parsePrimer returns only at the end of its token list — any token that
    # does not begin a priming statement is refused inside it, with a position
    # — so the callers' trailing-junk arms below are defensive totality code
    # that no source text reaches.
    'expected the end of the library': "parsePrimer never returns a nonempty "
        "rest; the offending token is diagnosed inside it",
    'a file is a program (`workflow { … }`) or a library (its priming, then '
    'the end of the file); expected `workflow`, or the end of the library':
        "parsePrimer never returns a nonempty rest; the offending token is "
        "diagnosed inside it",
    # parseModuleSrc returns a workflow, a primer, or an error, so the
    # program front end's neither-arm cannot fire.
    'a program has a `workflow` block': "parseModuleSrc with qual=none returns "
        "a workflow or a primer, or errors; the neither-arm is unreachable",
}


def fragments(path):
    """The distinguishing string fragment of every `.error` site in a file."""
    text = open(path).read()
    out = []
    # A site is `.error ⟨pos, "message …", excerpt⟩` or `.error (unexpected ts "what")`,
    # possibly with `s!` interpolation and line-continuation backslashes.
    for m in re.finditer(r'\.error\s*[⟨(]', text):
        rest = text[m.end():]
        q = rest.find('"')
        if q < 0 or q > 200:
            continue
        # Read the string literal, honouring \-escapes and line continuations.
        i = q + 1
        buf = []
        while i < len(rest):
            c = rest[i]
            if c == '\\':
                nxt = rest[i + 1]
                if nxt == '\n':  # Lean line continuation: skip the newline and indent
                    i += 2
                    while i < len(rest) and rest[i] in ' \t':
                        i += 1
                    continue
                buf.append({'n': '\n', 't': '\t', '\\': '\\', '"': '"',
                            '{': '{', '}': '}'}.get(nxt, nxt))
                i += 2
                continue
            if c == '"':
                break
            buf.append(c)
            i += 1
        msg = ''.join(buf)
        # Interpolations make the literal a template, and escapes differ between
        # the source spelling and the smoke test's expected strings, so the
        # audited fragment is the longest run free of braces and backslashes —
        # with interpolation *contents* removed first, because `{codeName x}`
        # is Lean code that never appears in a rendered diagnosis.
        parts = re.split(r'[\x00{}\\]', re.sub(r'\{[^{}]*\}', '\x00', msg))
        frag = max(parts, key=len).strip()
        if len(frag) >= 8:  # too-short fragments match everything
            out.append((path, msg, frag))
    return out


def main():
    # The smoke test spells expected strings with Lean escapes; comparison is
    # over backslash-free text on both sides.
    smoke = "".join(open(p).read() for p in SMOKE).replace("\\", "")
    missing = []
    total = exempt = 0
    for path in SOURCES:
        for path, msg, frag in fragments(path):
            total += 1
            if msg.startswith("internal:"):
                exempt += 1
                continue
            if msg in ALLOW:
                exempt += 1
                continue
            if frag not in smoke:
                missing.append((path, msg))
    print(f"coverage audit: {total} refusal sites, {exempt} exempt "
          f"({total - exempt} audited)")
    if missing:
        print("REFUSAL SITES WITH NO TEST:", file=sys.stderr)
        for path, msg in missing:
            print(f"  {path}: {msg[:100]}", file=sys.stderr)
        sys.exit(1)
    print("coverage audit: every audited refusal site is exercised by "
          + " + ".join(SMOKE))


if __name__ == "__main__":
    main()
