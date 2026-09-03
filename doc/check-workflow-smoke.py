#!/usr/bin/env python3
"""Check the retained full workflow smoke result against the checked-in script."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "doc/workflows/agent-cat-manual.js"
RECORD = ROOT / "doc/workflow-smoke.json"
VERIFICATION = ROOT / "doc/verification.md"
WORK_IDS = ["purpose-architecture", "mathematics", "operations", "user-guide", "reference"]
REVIEW_IDS = ["facts", "completeness", "examples", "texinfo", "prose"]


def main() -> int:
    script = SCRIPT.read_bytes()
    record = json.loads(RECORD.read_text())
    digest = hashlib.sha256(script).hexdigest()
    if record["scriptSha256"] != digest:
        raise SystemExit("workflow smoke result does not describe the checked-in script")
    phases = re.findall(r'\{ title: "([^"]+)" \}', script.decode())
    if phases != ["Inventory", "Draft", "Synthesize", "Review", "Revise", "Validate"]:
        raise SystemExit(f"workflow phase contract changed: {phases}")
    status = record["status"]
    if status != {
        "state": "completed",
        "phase": "Validate",
        "totalAgents": 14,
        "doneAgents": 14,
        "errorAgents": 0,
        "skippedAgents": 0,
    }:
        raise SystemExit(f"workflow smoke status is incomplete: {status}")

    result = record["result"]
    if result["complete"] is not True or result["gaps"] != []:
        raise SystemExit("workflow smoke result is not complete")
    if record["args"].get("smoke") is not True:
        raise SystemExit("retained run is not the bounded smoke mode")

    inventory = result["inventory"]
    if not inventory["sourceMap"] or not inventory["requiredTopics"] or inventory["gaps"] != []:
        raise SystemExit("workflow smoke does not retain a complete source inventory")

    drafts = result["draftLedger"]
    if [entry["id"] for entry in drafts] != WORK_IDS:
        raise SystemExit("workflow smoke draft identities changed")
    for entry in drafts:
        draft = entry["result"]
        if entry["status"] != "complete" or draft is None:
            raise SystemExit(f"workflow smoke draft failed: {entry['id']}")
        if not draft["evidence"] or not draft["coveredTopics"] or draft["gaps"] != []:
            raise SystemExit(f"workflow smoke draft evidence is incomplete: {entry['id']}")
        if entry["id"] != "user-guide" and not draft["texinfo"].strip():
            raise SystemExit(f"workflow smoke draft text is empty: {entry['id']}")

    synthesis = result["synthesis"]
    if synthesis["coveredIds"] != WORK_IDS or synthesis["missingIds"] != []:
        raise SystemExit("workflow synthesis coverage is incomplete")
    if not synthesis["texinfo"].strip() or not synthesis["evidence"] or synthesis["gaps"] != []:
        raise SystemExit("workflow synthesis evidence or gap ledger is incomplete")

    reviews = result["reviewLedger"]
    if [entry["id"] for entry in reviews] != REVIEW_IDS:
        raise SystemExit("workflow smoke review identities changed")
    finding_ids: list[str] = []
    for entry in reviews:
        review = entry["result"]
        if entry["status"] != "complete" or review is None or not review["checked"]:
            raise SystemExit(f"workflow smoke review failed: {entry['id']}")
        if review["gaps"] != []:
            raise SystemExit(f"workflow smoke review retained a gap: {entry['id']}")
        for finding in review["findings"]:
            for field in ["id", "severity", "location", "problem", "evidence", "correction"]:
                if not finding[field]:
                    raise SystemExit(f"workflow review finding lacks {field}: {entry['id']}")
            finding_ids.append(finding["id"])

    revision = result["revision"]
    dispositions = revision["appliedFindings"] + revision["deferredFindings"]
    if sorted(dispositions) != sorted(finding_ids) or len(dispositions) != len(set(dispositions)):
        raise SystemExit("workflow review finding dispositions are incomplete or duplicated")
    if revision["deferredFindings"] != [] or revision["gaps"] != []:
        raise SystemExit("workflow revision retained a deferred finding or gap")
    if not revision["texinfo"].strip() or not revision["validationEvidence"]:
        raise SystemExit("workflow revision text or evidence is missing")

    validation = result["validation"]
    if validation["passed"] is not True or not validation["commands"] or not validation["outputs"]:
        raise SystemExit("workflow Validate phase did not retain command evidence")
    if validation["gaps"] != []:
        raise SystemExit("workflow Validate phase retained a gap")

    verification = VERIFICATION.read_text()
    required = [
        record["runId"],
        "nix develop path:. -c make -C doc check",
        "make -C doc check-haskell",
        "./bisim/ci/tier0.sh",
        "./cli/ci/examples.sh",
        "./engine/acp/ci/acp.sh",
        "./engine/agent-deck/ci/deck.sh",
        "python3 doc/check-prose.py",
    ]
    missing = [entry for entry in required if entry not in verification]
    if missing:
        raise SystemExit(f"verification record lacks required evidence: {missing}")

    leftovers = list((ROOT / "doc").glob("revision.*")) + list((ROOT / "doc").glob(".validation-output.*"))
    if leftovers:
        raise SystemExit(f"workflow validation artifacts remain: {leftovers}")
    print(
        f"workflow smoke: {record['runId']}, full inventory/drafts/reviews/revision retained, "
        "all findings applied, validation passed"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
