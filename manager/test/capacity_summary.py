#!/usr/bin/env python3
"""Compare the WM-041 capacity ceilings with their document and measurements.

The ceilings subcommand compares manager/test/capacity-ceilings.json with
the ceiling tables of manager/CAPACITY.md. Each table whose header is
"| Key | Ceiling | Unit | Basis |" contributes its rows. The key sets must
be equal, and each row must show the unit of its key and the ceiling that
the JSON states, in the form that render() gives.

The summary subcommand reads the ceilings and one or more measurement
files. A measurement file is one JSON object whose members map a ceiling
key to a number, a string or a boolean. The command prints one PASS or
FAIL line for each key with a measurement and one MISSING line for each
key without one, in key order, and an UNCHECKED line for each measured key
that names no ceiling. It writes its counts to standard error. It exits 1
when a key fails or is missing, and 2 when an input is not valid.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

UNITS = {"bytes", "ms", "count", "code", "status", "flag"}
COMPARATORS = {"max", "min", "range", "equals"}
HEADER = ["Key", "Ceiling", "Unit", "Basis"]
KEY = re.compile(r"^`([a-z0-9][a-z0-9.-]*)`$")


class InputError(Exception):
    """An input file that does not have the documented form."""


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise InputError(f"duplicate JSON member {key!r}")
        value[key] = item
    return value


def read_json(path: str):
    try:
        with open(path, "rb") as handle:
            return json.loads(handle.read().decode("utf-8"), object_pairs_hook=unique_object)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as failure:
        raise InputError(f"{path}: {failure}") from failure


def is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def is_scalar(value) -> bool:
    return isinstance(value, (str, bool)) or is_number(value)


def load_ceilings(path: str) -> dict:
    document = read_json(path)
    if not isinstance(document, dict) or document.get("version") != 1 or not isinstance(document.get("ceilings"), dict):
        raise InputError(f"{path}: expected an object with version 1 and a ceilings object")
    ceilings = document["ceilings"]
    for key, ceiling in ceilings.items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", key):
            raise InputError(f"{path}: key {key!r} has characters outside a-z, 0-9, '.' and '-'")
        if not isinstance(ceiling, dict) or ceiling.get("unit") not in UNITS:
            raise InputError(f"{path}: ceiling {key} has no unit of {sorted(UNITS)}")
        comparators = set(ceiling) - {"unit"}
        if len(comparators) != 1 or not comparators <= COMPARATORS:
            raise InputError(f"{path}: ceiling {key} needs exactly one of {sorted(COMPARATORS)}")
        (comparator,) = comparators
        bound = ceiling[comparator]
        if comparator in ("max", "min") and not is_number(bound):
            raise InputError(f"{path}: ceiling {key} {comparator} is not a number")
        if comparator == "range" and not (isinstance(bound, list) and len(bound) == 2
                                          and all(is_number(item) for item in bound) and bound[0] <= bound[1]):
            raise InputError(f"{path}: ceiling {key} range is not [low, high] with low <= high")
        if comparator == "equals" and not is_scalar(bound):
            raise InputError(f"{path}: ceiling {key} equals is not a number, string or boolean")
    return ceilings


def show(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return value
    return json.dumps(value)


def render(ceiling: dict) -> str:
    """The text of the Ceiling column of CAPACITY.md for this ceiling."""
    if "max" in ceiling:
        return f"at most {show(ceiling['max'])}"
    if "min" in ceiling:
        return f"at least {show(ceiling['min'])}"
    if "range" in ceiling:
        low, high = ceiling["range"]
        return f"{show(low)} to {show(high)}"
    return f"equals `{show(ceiling['equals'])}`"


def cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def document_rows(path: str) -> list[tuple[int, str, str, str]]:
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as failure:
        raise InputError(f"{path}: {failure}") from failure
    rows = []
    index = 0
    while index < len(lines):
        if lines[index].startswith("|") and cells(lines[index]) == HEADER:
            index += 2
            while index < len(lines) and lines[index].startswith("|"):
                row = cells(lines[index])
                match = KEY.match(row[0]) if len(row) == 4 else None
                if match is None:
                    raise InputError(f"{path}:{index + 1}: a ceiling row needs four cells and a key in backquotes")
                rows.append((index + 1, match.group(1), row[1], row[2]))
                index += 1
        else:
            index += 1
    return rows


def ceilings_command(arguments) -> int:
    ceilings = load_ceilings(arguments.ceilings)
    rows = document_rows(arguments.document)
    failures = []
    seen = {}
    for line, key, ceiling, unit in rows:
        if key in seen:
            failures.append(f"DUPLICATE {key} at lines {seen[key]} and {line} of {arguments.document}")
            continue
        seen[key] = line
        if key not in ceilings:
            failures.append(f"ONLY-IN-DOCUMENT {key} at line {line}")
            continue
        expected = render(ceilings[key])
        if ceiling != expected:
            failures.append(f"DIFFERENT {key} at line {line}: the document says {ceiling!r} and the JSON says {expected!r}")
        if unit != ceilings[key]["unit"]:
            failures.append(f"DIFFERENT {key} at line {line}: the document unit is {unit!r} and the JSON unit is {ceilings[key]['unit']!r}")
    for key in sorted(set(ceilings) - set(seen)):
        failures.append(f"ONLY-IN-JSON {key}")
    for failure in failures:
        print(failure)
    if failures:
        return 1
    print(f"ceilings: the {len(ceilings)} keys of {arguments.ceilings} and {arguments.document} agree in key, ceiling and unit")
    return 0


def holds(ceiling: dict, value) -> bool:
    if "equals" in ceiling:
        expected = ceiling["equals"]
        if isinstance(expected, bool) or isinstance(value, bool):
            return isinstance(value, bool) and isinstance(expected, bool) and value == expected
        if isinstance(expected, str) or isinstance(value, str):
            return isinstance(value, str) and isinstance(expected, str) and value == expected
        return value == expected
    if not is_number(value):
        return False
    if "max" in ceiling:
        return value <= ceiling["max"]
    if "min" in ceiling:
        return value >= ceiling["min"]
    low, high = ceiling["range"]
    return low <= value <= high


def summary_command(arguments) -> int:
    ceilings = load_ceilings(arguments.ceilings)
    measured = {}
    for path in arguments.measurements:
        values = read_json(path)
        if not isinstance(values, dict):
            raise InputError(f"{path}: a measurement file is one JSON object")
        for key, value in values.items():
            if not is_scalar(value):
                raise InputError(f"{path}: measurement {key} is not a number, string or boolean")
            if key in measured and measured[key][0] != value:
                raise InputError(f"{path}: measurement {key} is {value!r} here and {measured[key][0]!r} in {measured[key][1]}")
            measured[key] = (value, path)
    counts = {"PASS": 0, "FAIL": 0, "MISSING": 0}
    for key in sorted(ceilings):
        ceiling = ceilings[key]
        if key not in measured:
            verdict = "MISSING"
            print(f"MISSING {key} ceiling={render(ceiling)} unit={ceiling['unit']}")
        else:
            value = measured[key][0]
            verdict = "PASS" if holds(ceiling, value) else "FAIL"
            print(f"{verdict} {key} measured={json.dumps(value)} ceiling={render(ceiling)} unit={ceiling['unit']}")
        counts[verdict] += 1
    for key in sorted(set(measured) - set(ceilings)):
        print(f"UNCHECKED {key} measured={json.dumps(measured[key][0])}")
    print(f"summary: {counts['PASS']} PASS, {counts['FAIL']} FAIL, {counts['MISSING']} MISSING", file=sys.stderr)
    return 1 if counts["FAIL"] or counts["MISSING"] else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    ceilings = commands.add_parser("ceilings", help="compare the JSON ceilings with the tables of CAPACITY.md")
    ceilings.add_argument("ceilings")
    ceilings.add_argument("document")
    ceilings.set_defaults(action=ceilings_command)
    summary = commands.add_parser("summary", help="compare measurement files with the ceilings")
    summary.add_argument("ceilings")
    summary.add_argument("measurements", nargs="+")
    summary.set_defaults(action=summary_command)
    arguments = parser.parse_args()
    try:
        return arguments.action(arguments)
    except InputError as failure:
        print(f"capacity_summary: {failure}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
