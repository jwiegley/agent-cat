# Manual verification record

This record covers the working tree on branch `manual`, based on
`5540d80e43895498da4e0ec0e58dcc26c4e5431f` and the uncommitted manual changes
present on 2026-08-28. No command below used a live model, network-backed
adapter, production service, or external account.

## Workflow smoke run

The checked-in script `workflows/agent-cat-manual.js` had SHA-256
`10f66aa25cf654376ce436c1b1e0c354b2f0697962f45668e7ab8ce19e2c2654`.
It was passed verbatim to the Pi `workflow` tool with these arguments:

```json
{
  "mode": "update",
  "smoke": true,
  "scope": "One two-sentence Texinfo paragraph explaining that a Haskell Program pairs RawProgram with a typed Plan and that Lean is used for conformance testing rather than production execution.",
  "requirements": "Exercise all fourteen calls and six phases. Keep every result strictly bounded. The Validate phase must run actual makeinfo Info and HTML commands against a temporary wrapped candidate and return exact outcomes. Every review finding must receive an applied or deferred stable-ID disposition, and every intermediate gaps array must be empty for complete=true."
}
```

Run `agent-cat-manual-mtc8ywaw-oqxenx` completed with fourteen agents done,
zero errors, zero skipped agents, and the final phase `Validate`. The runtime's
full persisted `result` is retained in `doc/workflow-smoke.json`: the eight-entry
source map, all five draft Texinfo values and evidence arrays, synthesis and its
empty gap ledger, all five review reports and their complete findings, the
revised Texinfo, stable-ID dispositions (`texinfo:1` and `prose:1` applied; none
deferred), validation evidence, and final `gaps: []` / `complete: true`.

The validation agent ran these exact render commands:

```sh
makeinfo --no-split --output=/tmp/agent-cat-revision.1cdAn8/revision.info doc/revision.texinfo
makeinfo --html --no-split --output=/tmp/agent-cat-revision.1cdAn8/revision.html doc/revision.texinfo
```

Both exited 0 with empty standard output and standard error, producing nonempty
Info and HTML files. The candidate, captures, and rendered files were removed,
and the cleanup assertion exited 0. `doc/check-workflow-smoke.py` binds this
full result to the current script hash and verifies every inventory, draft,
synthesis, review, disposition, revision, validation, and final-gap field.

## Documentation and examples

| Command | Outcome |
| --- | --- |
| `nix flake check --no-build` | Passed for `aarch64-darwin`; incompatible systems were reported as omitted. |
| `nix develop -c make -C doc check` | Passed. Info and HTML emitted no diagnostics; six source excerpts, two complete Haskell files, 214 top-level API/CLI entries, three indexes, and the retained workflow smoke record passed their checks. |
| `make -C doc check-haskell` | Passed. Cabal was up to date; the complete `Hello` and `Registry` modules compiled and linked in a temporary directory; the one-row executable listed and ran `hello --scripted`; deterministic CLI transcripts and defaults matched; GHCi derived and verified 117 wildcard-exported children and 103 exported-class instances. |
| `make -C doc clean all` | Passed. Retained outputs were `doc/build/agent-cat.info` and `doc/build/agent-cat.html`; `doc/build/` is ignored. |
| `python3 doc/check-prose.py` | Passed with exact output `manual prose: prohibited patterns absent; no three-sentence staccato run`. |

The compiler-derived ledger is regenerated with
`make -C doc update-haskell-inventory`. Its checker obtains wildcard-exported
constructors, fields, associated types, and methods from GHCi `:info!`, discovers
exported classes from current source, and records all instances reported by
GHCi. The checked ledger is `doc/haskell-member-coverage.texi`; it is no longer
a hand-maintained constructor or instance inventory. Its compiler-derived
member and instance rows render as a reader-visible matrix in the Haskell
reference and map each row to its documented parent entry.

## Haskell and conformance gates

| Command | Outcome |
| --- | --- |
| `cd haskell && nix develop -c bash -c 'set -e; ./ci/tier0.sh; ./ci/policies.sh; ./ci/citations.sh'` | Passed. Tier 0: 190/190; curated Tier 1: 30/30; all policy probes passed; 208 Lean citations resolved across 41 files. |
| `cd haskell && nix develop -c ./ci/examples.sh` | Passed. Eight registered programs were pinned with zero failures; both help spellings and their commands ran; input-dependent folds stayed fixed while printed programs changed. |
| `cd haskell && ./ci/acp.sh` | Passed. Sixteen scenarios, zero failures, including permission denial/grant, exit statuses 1/2/3, two routed adapters, fail-over, and narration separation. |
| `cd haskell && ./ci/deck.sh` | Passed. Eight scenarios, zero failures, including memo reuse, decode abandonment, stopped/hung/stale sessions, missing binary, and two routed panes. |

`haskell/ci/acp.sh` now captures process standard output and standard error
separately before combining them for content assertions, preventing concurrent
scheduler output from splitting a diagnostic line. `haskell/ci/examples.sh`
reuses an existing Nix development shell when one is supplied, avoiding a new
Nix evaluation for every CLI call while retaining direct-invocation behavior.

An earlier aggregate invocation exceeded the harness time limit while unrelated
Nix, GHC, and Haddock work was active. Each unfinished gate was subsequently run
as the exact separate command shown above and passed.

## Workflow syntax and prose

The workflow source was parsed with Acorn using ECMAScript module syntax plus the
runtime's allowed top-level await and return settings; parsing succeeded. The
manual prose check searched for the prohibited stock phrases, contractions,
marketing terms, clipped `Constructor:` and `Default:` lead-ins, and the
unexplained terms identified by independent review; no match remained. A
sentence scan found no run of three prose sentences of six words or fewer.

Three independent read-only reviewers audited factual claims, completeness, and
prose. Their supported findings were applied: cost-tree extrema were separated
from attained world extrema; the checker contract and hazards were made
explicit; complete copyable module and registry examples were added; registration
exports were covered; constructor and instance inventory became compiler-derived;
build dependencies and CLI transcript checks were added; and the cited prose
faults were corrected. The claim that `doc/design.html` and
`doc/walkthrough.html` were absent was rejected after direct file inspection.

## Repository state

`git diff --cached --check` passed. `git ls-files --error-unmatch` confirmed that
`doc/agent-cat.texi`, `doc/Makefile`, `doc/verification.md`, and
`workflows/agent-cat-manual.js` are tracked. `git status --short test/corpus` was
empty, no `.hi`, `.o`, or `__pycache__` artifact remained under `doc/`, and obr
reported its database and `doc/PLAN.org` in sync. All goal changes are staged;
the goal-created `.pi/` runtime state remains untracked. No commit was created
because the user did not request one.

A full `lake build` was not run because no Lean source changed. The Lean-facing
claims were checked against current declarations, the 190 frozen observations,
the 30 curated comparisons, and the citation gate. Live ACP adapters and real
agent-deck sessions were excluded by the goal boundary; their deterministic
fixture doubles passed as recorded above.
