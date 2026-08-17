# The conformance wire format

*Version 1. The format of record for the Lean↔Haskell conformance boundary
(`doc/research/dsl-redesign/connection.md`, D5): what `lake exe
conformance-oracle` reads and writes, and what the frozen corpus under
`test/corpus/` contains. The Haskell side's generators and comparison read this
page; a change here is a version bump and a corpus regeneration, in one
commit.*

The oracle speaks line-delimited JSON on stdin/stdout: one request per line,
one reply per line, `id` echoed verbatim when the request carries one. EOF on
stdin is the clean shutdown.

Every request may carry `"budgetMs"` (default 30000). On expiry the reply is
`{"timeout": {"ms": n}}` — **an observation, not an error** (connection.md
D13): the two implementations genuinely differ in asymptotics, and an
asymmetry must be recordable as an asymmetry.

## Request 1 — observe a program

```json
{"id": …, "program": <RawProgram>, "worlds": [<WorldSpec>, …], "budgetMs": …}
```

`RawProgram` is the Lean datatype `Agentic.Core.Dsl.RawProgram` under Lean's
derived JSON encoding (constructors as single-key objects, structures as field
objects — the corpus files are the normative examples). `worlds` defaults to
`[{}]`, the echo world.

The reply is one of three shapes:

### Refused

```json
{"refused": {
  "guard": "panelEmpty" | "revisionBound" | "questionBudget"
         | "servedBy" | "dupFunction" | "other",   // COMPARED
  "n": <Nat> | null,                                // COMPARED (questionBudget only)
  "pos": {"line": …, "col": …},                     // oracle-only
  "excerpt": "…",                                   // oracle-only
  "message": "…"                                    // oracle-only
}}
```

The **compared/oracle-only split** is connection.md §3.6's: the guard identity
and, for the question budget, the computed `n` are facts both sides produce;
`pos`, `excerpt` and `message` are functions of written characters and of the
checker's wording, which the Haskell side never has. The guard is a
classification **assigned in the oracle** by total match on the message text —
`CheckError` carries no code, and adding one would edit literals pinned inside
theorems. `other` covers every refusal outside the five term-level guards;
those are diagnostics, not comparands.

### Checked

```json
{"level": "batch" | "pipeline" | "branch" | "dynamic",
 "size": <Nat>, "askNodes": <Nat>,
 "codes": ["text", …] | null,          // null on any branching program
 "costSummary": {"minFold": <Nat>|null, "maxFold": <Nat>|null, "paths": <Nat>},
 "blockAsks": <Nat>,
 "fnAsks": [["name", <Nat>], …],
 "worlds": [
   {"world": <WorldSpec>,
    "trace": [<Event>, …],
    "billFresh": <Nat>, "billMemo": <Nat>}, …]}
```

* `codes` is nullable and **usually null**: it is a pipeline-only comparand
  (`Cost.codes` returns `none` at `case`), present so pipeline programs pin
  their question sequence. `shapes`/`asks` are deferred to a later version for
  the same reason they are usually null.
* `costSummary` is `Explain.costSummary`: min/max bills over the cost tree and
  the leaf count. `minFold`/`maxFold` are null only at the empty tree edge.
* `blockAsks`/`fnAsks` are the Raw-level ask counts — the week-one comparands,
  computable on both sides with no `Plan`.
* An `Event` is data, never a rendering:

```json
{"code": "text"|"verdict"|"flag"|"receipt",
 "addressee": {"model"|"tool"|"person": {"id": "…"}},
 "scope": {"model": "…"|null, "mode": "…"|null},
 "prompt": "…", "draw": <Nat>,
 "answer": <string>                          // text
         | {"tag": "approve"}                // verdict
         | {"tag": "declined"}
         | {"tag": "object", "objections": ["…", …]}
         | <bool>                            // flag
         | null}                             // receipt
```

Traces are compared **in order, unnormalized**: a trace is a free monoid and
its order is the observation.

## Request 2 — the string layer

```json
{"id": …, "string": {"op": "norm"|"words"|"decodeVerdict"|"decode"|"say",
                     "code": "text"|"verdict"|"flag"|"receipt",  // decode/say only
                     "text": "…"}}
```

Reply: `{"result": …}` — a string for `norm`/`say`, a string list for `words`,
a verdict object for `decodeVerdict`, `{"answer": …|null}` for `decode`.

This request kind exists because it is the highest-ranked divergence risk and
the only coverage it can get: on a program-in/world-out boundary nothing ever
calls `Decode`. The known hazard the vectors freeze: `Exec.norm` lowercases
**ASCII only** (`"HeLLo İstanbul" → "hello İstanbul"`, the `İ` surviving),
where a naive Haskell `toLower` is Unicode.

## Request 3 — liveness

```json
{"id": …, "ping": true}   →   {"id": …, "pong": true}
```

## What is never on the wire

A `Plan`, a `Dlg`, an `Ω` as a function, a `Table` holding anything but data,
or `.wf` text. `RawProgram` is the post-import-walk object: the import walk,
module resolution and the parser are outside this boundary entirely
(connection.md D10).

## The corpus

`test/corpus/*.json`: one file per case, of the form

```json
{"name": "…", "request": <request>, "reply": <reply>, "oracleVersion": 1}
```

frozen by running the oracle once and committing its output. Tier 0 is the
Haskell side reproducing every `reply` from every `request` with **no Lean in
the loop**; regenerating the corpus is the explicit, reviewed act of changing
the specification.
