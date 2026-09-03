#!/usr/bin/env python3
"""Check that the Texinfo manual accounts for the public authoring surface."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANUAL = ROOT / "doc" / "agent-cat.texi"
MODULES = {
    "Agentic.Cli": ROOT / "cli/src/Agentic/Cli.hs",
    "Agentic.Runtime.Facts": ROOT / "runtime/src/Agentic/Runtime/Facts.hs",
    "Agentic.Workflow": ROOT / "dsl/src/Agentic/Workflow.hs",
    "Agentic.Workflow.Do": ROOT / "dsl/src/Agentic/Workflow/Do.hs",
    "Agentic.WF": ROOT / "dsl/src/Agentic/WF.hs",
    "Agentic.Schema": ROOT / "dsl/src/Agentic/Schema.hs",
    "Agentic.Schema.Json": ROOT / "dsl/src/Agentic/Schema/Json.hs",
    "Agentic.Schema.TH": ROOT / "dsl/src/Agentic/Schema/TH.hs",
}
CLI_SOURCE = ROOT / "cli/src/Agentic/Cli.hs"
HASKELL_INDEX = ROOT / "doc/haskell-api-index.texi"
CLI_INDEX = ROOT / "doc/runner-index.texi"
MARKER = re.compile(r"^@c COVER (API|CLI) (\S+) (author|support|machinery)$", re.MULTILINE)

AUTHOR_WORKFLOW = {
    ":>",
    "Answer",
    "Decider",
    "Ending",
    "Gives",
    "Outcome",
    "act",
    "amend",
    "annotated",
    "answer",
    "answering",
    "ask",
    "ask_",
    "atMost",
    "call",
    "call_",
    "caseVerdict",
    "confirm",
    "decide",
    "defining",
    "done",
    "drawing",
    "fallingBackTo",
    "function",
    "input",
    "knownHere",
    "model",
    "named",
    "noArgs",
    "noInputs",
    "noParams",
    "panel",
    "panelText",
    "person",
    "revising",
    "revisingOn",
    "running",
    "schemaArray",
    "schemaBoolean",
    "schemaInteger",
    "schemaNull",
    "schemaNumber",
    "schemaObject",
    "schemaProperty",
    "schemaString",
    "servedBy",
    "stop",
    "structured",
    "takes",
    "taking",
    "tool",
    "unless",
    "wf",
    "wft",
    "when",
    "workflow",
}
AUTHOR_API = (
    {f"Agentic.Workflow.{name}" for name in AUTHOR_WORKFLOW}
    | {"Agentic.WF.wf", "Agentic.WF.wft"}
    | {"Agentic.Schema.Json.decodeAs", "Agentic.Schema.Json.encodeAs", "Agentic.Schema.Json.renderAs"}
    | {"Agentic.Schema.TH.deriveSchema", "Agentic.Cli.cliMain"}
)
MACHINERY_WORKFLOW = {
    "Amendment",
    "An",
    "Ann",
    "Arms",
    "Arms3",
    "Blk",
    "Calling",
    "Clauses",
    "Curries",
    "Entry",
    "Live",
    "Loop",
    "LoopOn",
    "Nm",
    "NoFollow",
    "Res",
    "Rhs",
    "Scope",
    "Stage",
    "Step",
    "Term",
    "W",
    "bindW",
    "genName",
    "ifThenElse",
    "resultName",
    "runBody",
    "runRev",
    "runW",
    "thenW",
}
MACHINERY_API = (
    {f"Agentic.Workflow.{name}" for name in MACHINERY_WORKFLOW}
    | {"Agentic.Workflow.Do.>>", "Agentic.Workflow.Do.>>="}
    | {"Agentic.WF.KnownIx", "Agentic.WF.Scopeless"}
    | {
        "Agentic.Schema.FreshProperty",
        "Agentic.Schema.ObjectTail",
        "Agentic.Schema.SCode",
        "Agentic.Schema.SSchema",
    }
)


def export_body(source: str, module: str) -> str:
    clean = re.sub(r"--.*", "", source)
    start = clean.index(f"module {module}")
    opening = clean.index("(", start)
    depth = 0
    for index in range(opening, len(clean)):
        char = clean[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return clean[opening + 1 : index]
    raise ValueError(f"unterminated export list in {module}")


def split_exports(body: str) -> list[str]:
    items: list[str] = []
    start = 0
    depth = 0
    for index, char in enumerate(body):
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            items.append(body[start:index])
            start = index + 1
    items.append(body[start:])
    return [" ".join(item.split()) for item in items if item.strip()]


def normalize_export(module: str, item: str) -> set[str]:
    if item.startswith("pattern "):
        item = item.removeprefix("pattern ").strip()
    if item.startswith("(") and item.endswith(")"):
        return {f"{module}.{item[1:-1]}"}
    match = re.match(r"([A-Za-z_][A-Za-z0-9_']*)", item)
    if not match:
        raise ValueError(f"cannot read export {item!r} from {module}")
    names = {f"{module}.{match.group(1)}"}
    children = re.search(r"\(([^()]*)\)\s*$", item)
    if children and children.group(1).strip() != "..":
        for child in children.group(1).split(","):
            name = child.strip()
            if name:
                names.add(f"{module}.{name}")
    return names


def api_inventory() -> dict[str, str]:
    result: set[str] = set()
    for module, path in MODULES.items():
        body = export_body(path.read_text(), module)
        for item in split_exports(body):
            result.update(normalize_export(module, item))
    return {name: classification(name) for name in result}


def classification(name: str) -> str:
    if name in AUTHOR_API:
        return "author"
    if name in MACHINERY_API:
        return "machinery"
    return "support"


def cli_inventory() -> dict[str, str]:
    source = CLI_SOURCE.read_text()
    parser = source[source.index("parseCommand ::") : source.index("usage ::")]
    options = set(re.findall(r'"(--[a-z][a-z0-9-]*)', parser))
    verbs: set[str] = set()
    for line in parser.splitlines():
        match = re.match(r'\s*(?:\[|\()"([a-z][a-z0-9-]*)"', line)
        if match:
            verbs.add(f"verb:{match.group(1)}")
    return {name: "author" for name in options | verbs}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--list", action="store_true", help="print the source-derived inventory")
    parser.add_argument("--manual", type=Path, default=MANUAL)
    args = parser.parse_args()

    inventory = {"API": api_inventory(), "CLI": cli_inventory()}
    if args.list:
        for kind in ("API", "CLI"):
            for name, expected_classification in sorted(inventory[kind].items()):
                print(kind, name, expected_classification)
        return 0

    text = args.manual.read_text()
    covered = {"API": {}, "CLI": {}}
    for kind, name, actual_classification in MARKER.findall(text):
        covered[kind][name] = actual_classification
    indexed = {
        "API": set(re.findall(r"^@hsindex (\S+)$", HASKELL_INDEX.read_text(), re.MULTILINE)),
        "CLI": set(re.findall(r"^@clindex (\S+)$", CLI_INDEX.read_text(), re.MULTILINE)),
    }

    missing = {
        kind: sorted(set(items) - set(covered[kind]))
        for kind, items in inventory.items()
        if set(items) - set(covered[kind])
    }
    extra = {
        kind: sorted(set(covered[kind]) - set(items))
        for kind, items in inventory.items()
        if set(covered[kind]) - set(items)
    }
    misclassified = {
        kind: sorted(
            name
            for name in set(items) & set(covered[kind])
            if covered[kind][name] != items[name]
        )
        for kind, items in inventory.items()
    }
    misclassified = {kind: names for kind, names in misclassified.items() if names}
    for heading, groups in (("missing", missing), ("stale", extra)):
        for kind, names in groups.items():
            for name in names:
                print(f"{heading} {kind} coverage: {name}")
    for kind, names in misclassified.items():
        for name in names:
            print(
                f"classification mismatch for {kind} {name}: "
                f"expected {inventory[kind][name]}, found {covered[kind][name]}"
            )
    index_missing = {
        kind: sorted(set(items) - indexed[kind])
        for kind, items in inventory.items()
        if set(items) - indexed[kind]
    }
    index_extra = {
        kind: sorted(indexed[kind] - set(items))
        for kind, items in inventory.items()
        if indexed[kind] - set(items)
    }
    for heading, groups in (("missing", index_missing), ("stale", index_extra)):
        for kind, names in groups.items():
            for name in names:
                print(f"{heading} {kind} index: {name}")
    if missing or extra or misclassified or index_missing or index_extra:
        return 1
    total = sum(map(len, inventory.values()))
    print(f"manual coverage: {total} source items accounted for, classified, and indexed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
