#!/usr/bin/env python3
"""Derive public children and class instances from GHCi and check the manual."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANUAL = ROOT / "doc/agent-cat.texi"
LEDGER = ROOT / "doc/haskell-member-coverage.texi"
HASKELL = ROOT
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("manual_coverage", ROOT / "doc/check-manual-coverage.py")
coverage = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(coverage)


def wildcard_parents() -> set[str]:
    result: set[str] = set()
    for module, path in coverage.MODULES.items():
        for item in coverage.split_exports(coverage.export_body(path.read_text(), module)):
            match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_']*)\s*\(\.\.\)", item)
            if match:
                result.add(f"{module}.{match.group(1)}")
    return result


def exported_class_parents(api: dict[str, str]) -> set[str]:
    class_names: set[str] = set()
    for path in (ROOT / "dsl/src").rglob("*.hs"):
        for match in re.finditer(r"(?m)^class\s+(?:\([^\n]*\)\s*=>\s*)?([A-Z][A-Za-z0-9_']*)\b", path.read_text()):
            class_names.add(match.group(1))
    return {name for name in api if name.rsplit(".", 1)[-1] in class_names}


def ghci_info(parents: list[str]) -> dict[str, str]:
    commands = [
        ':set prompt ""',
        ':set prompt-cont ""',
        ':module + Agentic.Builder Agentic.Cli Agentic.DSL Agentic.DSL.Plan Agentic.Planning Agentic.Runtime.Facts Agentic.Schema Agentic.Schema.Json Agentic.Schema.TH Agentic.WF Agentic.Workflow Agentic.Workflow.Do',
    ]
    for index, parent in enumerate(parents):
        commands.extend(
            [
                f":! echo __ACAT_BEGIN_{index}__",
                f":info! {parent}",
                f":! echo __ACAT_END_{index}__",
            ]
        )
    commands.append(":quit")
    result = subprocess.run(
        ["cabal", "repl", "agentic-cli:lib:agentic-cli", "-v0"],
        cwd=HASKELL,
        input="\n".join(commands) + "\n",
        text=True,
        capture_output=True,
        check=False,
        timeout=300,
    )
    if result.returncode != 0:
        raise SystemExit(f"GHCi inventory failed:\n{result.stdout}\n{result.stderr}")
    blocks: dict[str, str] = {}
    for index, parent in enumerate(parents):
        match = re.search(
            rf"(?s)__ACAT_BEGIN_{index}__\n(.*?)__ACAT_END_{index}__",
            result.stdout,
        )
        if not match:
            raise SystemExit(f"GHCi returned no inspectable block for {parent}")
        blocks[parent] = match.group(1)
    return blocks


def members(block: str) -> set[str]:
    result: set[str] = set()
    # Constructors in ordinary data declarations.
    for match in re.finditer(r"(?:=|\|)\s+(?:[A-Za-z0-9_.]+\.)?([A-Z][A-Za-z0-9_']*)\b", block):
        result.add(match.group(1))
    # GADT constructors and class methods.
    for match in re.finditer(r"(?m)^\s{2}(?:[A-Za-z0-9_.]+\.)?([A-Za-z_][A-Za-z0-9_']*)\s+::", block):
        result.add(match.group(1))
    # Record fields may begin immediately after an opening brace or on later lines.
    for match in re.finditer(r"[\{,]\s*(?:[A-Za-z0-9_.]+\.)?([a-z][A-Za-z0-9_']*)\s+::", block):
        result.add(match.group(1))
    # Associated type families declared by a class.
    for match in re.finditer(r"(?m)^\s{2}type (?:family )?(?:[A-Za-z0-9_.]+\.)?([A-Z][A-Za-z0-9_']*)\b", block):
        result.add(match.group(1))
    return result


def normalize_instance(header: str) -> str:
    header = re.sub(r"[A-Za-z0-9_.-]+-\d+(?:\.\d+)*:", "", header)
    return " ".join(header.split())


def instances(block: str) -> set[str]:
    result: set[str] = set()
    for match in re.finditer(r"(?ms)^instance\s+(.*?)(?=\s*-- Defined (?:at|in))", block):
        header = normalize_instance("instance " + match.group(1))
        result.add(header)
    return result


def instance_id(parent: str, header: str) -> str:
    digest = hashlib.sha256(header.encode()).hexdigest()[:16]
    return f"{parent}.instance:{digest}"


def texinfo(text: str) -> str:
    return text.replace("@", "@@").replace("{", "@{").replace("}", "@}")


def expected_ledger(check_manual: bool = True) -> tuple[str, int, int]:
    api = coverage.api_inventory()
    wildcards = wildcard_parents()
    parents = sorted(wildcards | exported_class_parents(api))
    blocks = ghci_info(parents)
    member_rows: list[tuple[str, str, str]] = []
    instance_rows: list[tuple[str, str, str, str]] = []
    manual = MANUAL.read_text()
    for parent in parents:
        classification = api[parent]
        for name in sorted(members(blocks[parent]) if parent in wildcards else set()):
            member_rows.append((parent, name, classification))
            if check_manual and name not in manual:
                raise SystemExit(f"manual does not mention compiler-exported child: {parent}.{name}")
        for header in sorted(instances(blocks[parent])):
            ident = instance_id(parent, header)
            instance_rows.append((parent, header, ident, classification))
            if check_manual and parent.rsplit(".", 1)[-1] not in manual:
                raise SystemExit(f"manual does not discuss exported class: {parent}")

    lines = [
        "@c Compiler-derived public children and exported-class instances.",
        "@c Regenerate with: make -C doc update-haskell-inventory",
        "",
        "@section Compiler-derived public members and instances",
        "",
        "This matrix is generated from GHCi @code{:info!} output for the current",
        "package.  Every row names its public parent and maps to that parent entry",
        "later in this chapter; the comments beside the rows carry the classifications",
        "checked by the documentation gates.",
        "",
        "@subsection Wildcard-exported constructors, fields, and methods",
        "",
        "@multitable @columnfractions .42 .25 .33",
        "@headitem Public parent @tab Exported member @tab Documentation entry",
    ]
    for parent, name, classification in member_rows:
        lines.append(f"@c MEMBER {parent}.member:{name} {classification}")
        lines.append(f"@hsindex {parent}.{name}")
        lines.append(
            f"@item @code{{{texinfo(parent)}}} @tab @code{{{texinfo(name)}}} "
            f"@tab @code{{{texinfo(parent)}}}"
        )
    lines.extend(
        [
            "@end multitable",
            "",
            "@subsection Exported-class instances",
            "",
            "@table @asis",
        ]
    )
    for parent, header, ident, classification in instance_rows:
        lines.append(f"@c INSTANCE {ident} {classification}")
        lines.append(f"@c INSTANCE-TEXT {ident} {header}")
        lines.append(f"@item @code{{{texinfo(parent)}}}")
        lines.append(f"@code{{{texinfo(header)}}}")
    lines.extend(["@end table", ""])
    return "\n".join(lines), len(member_rows), len(instance_rows)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="rewrite the compiler-derived ledger")
    args = parser.parse_args()
    expected, member_count, instance_count = expected_ledger(check_manual=not args.write)
    if args.write:
        LEDGER.write_text(expected)
        print(f"wrote {LEDGER.relative_to(ROOT)}")
        return 0
    actual = LEDGER.read_text()
    if actual != expected:
        raise SystemExit(
            "compiler-derived member ledger is stale; run `make -C doc update-haskell-inventory`"
        )
    print(
        f"manual members: {member_count} compiler-exported children and "
        f"{instance_count} exported-class instances verified"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
