#!/usr/bin/env python3
"""Run the deterministic CLI examples and compare their documented facts."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANUAL = (ROOT / "doc/agent-cat.texi").read_text()
EXPECTED_NAMES = {
    "harden",
    "hello",
    "structured",
    "structured-result",
    "plan-feature",
    "review-lite",
    "ship-feature-lite",
    "grind-tests",
    "stack-prs",
}


def run(runner: str, *args: str, code: int = 0) -> subprocess.CompletedProcess[str]:
    result = subprocess.run([runner, *args], text=True, capture_output=True, check=False)
    if result.returncode != code:
        raise SystemExit(
            f"{' '.join(args) or '<no arguments>'}: expected exit {code}, got {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result


def require_in_both(text: str, lines: list[str]) -> None:
    for line in lines:
        if line not in text:
            raise SystemExit(f"fresh CLI output lacks documented line: {line}")
        if line not in MANUAL:
            raise SystemExit(f"manual lacks fresh CLI line: {line}")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: check-manual-cli.py PATH-TO-AGENTIC-RUN")
    runner = sys.argv[1]

    rows = json.loads(run(runner, "list", "--json").stdout)
    names = {row["name"] for row in rows}
    if names != EXPECTED_NAMES:
        raise SystemExit(f"registered names differ: {sorted(names)}")
    for name in names:
        if f"@code{{{name}}}" not in MANUAL:
            raise SystemExit(f"manual does not name registered example: {name}")

    plan = run(runner, "plan", "hello").stdout
    require_in_both(
        plan,
        [
            "level     pipeline",
            "size      4",
            "askNodes  3",
            "codes     text, text, receipt",
            "cost      minFold 3, maxFold 3, over 1 path",
        ],
    )
    cost = run(runner, "cost", "hello").stdout
    require_in_both(
        cost,
        [
            "costSummary   minFold 3, maxFold 3, over 1 path",
            "every path consults 3 times",
            "the fold, path by path (1 in all):",
        ],
    )
    scripted = run(runner, "run", "hello", "--scripted").stdout
    for line in ["billFresh   3", "billMemo    3"]:
        if line not in scripted:
            raise SystemExit(f"scripted hello lacks {line}")

    run(runner, "--help")
    run(runner, code=1)

    acp = (ROOT / "engine/acp/src/Agentic/Acp.hs").read_text()
    deck = (ROOT / "engine/agent-deck/src/Agentic/AgentDeck.hs").read_text()
    defaults = {
        "ACP timeout": re.search(r"acpTurnTimeoutMs = (\d+)", acp).group(1),
        "deck poll": re.search(r"deckPollMs = (\d+)", deck).group(1),
        "deck timeout": re.search(r"deckTimeoutMs = (\d+)", deck).group(1),
    }
    for label, value in defaults.items():
        if value not in MANUAL:
            raise SystemExit(f"manual lacks current {label} default {value}")

    print("manual CLI: registry, help, plan, cost, scripted run, exits, and defaults verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
