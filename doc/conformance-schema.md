# The conformance wire format

*Version 1. The format of record for the Lean↔Haskell conformance boundary
(`doc/research/connection.md`, D5): what `lake exe conformance-oracle` reads
and writes, and what the frozen corpus under
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
or source text of any kind. `RawProgram` is the post-import-walk object: the
import walk, module resolution and any parser are outside this boundary entirely
(connection.md D10) — and since the Lean excision there is no parser on the Lean
side at all, which makes the boundary the *only* way a program reaches the
oracle.

## The corpus

`test/corpus/*.json`: one file per case, of the form

```json
{"name": "…", "request": <request>, "reply": <reply>, "oracleVersion": 1}
```

frozen by running the oracle once and committing its output. Tier 0 is the
Haskell side reproducing every `reply` from every `request` with **no Lean in
the loop**; regenerating the corpus is the explicit, reviewed act of changing
the specification.

## What is actually pinned: three surfaces, not one

*Recorded because every working paper in `doc/research/profunctor-design/`
listed one or two of the three, and two of them named a field that is pinned by
nothing. Counted in this checkout, over the 128 files as they stand.*

**Surface 1 — the frozen reply record, and it has exactly eight keys.** A
checked reply is `level`, `size`, `askNodes`, `codes`, `costSummary`,
`blockAsks`, `fnAsks`, `worlds`, and nothing else; the Haskell producer is
`Agentic.Observe.observeValue`, whose own docstring calls them "the five static
folds, the two ask counts, and one observation per world". Of the 128 files, 66
carry a checked reply, 40 a `refused` reply and 22 a `result` from the string
layer.

**`shapes` and `asks` are on no wire and in no file** — `grep '"shapes"'` and
`grep '"asks"'` return zero hits across all 128. The record specified in
`connection.md` §3.1 lists them and the implemented record does not; that
discrepancy is the note under "Checked" above, and its effect is to *loosen* the
constraint rather than to tighten it. `Cost.shapes` and `Cost.asks` may be
reorganised freely — as `Agentic/Core/Cost.lean`'s `shapes_eq_map_asks` and
`codes_eq_map_shapes` reorganise them — without a corpus regeneration. What is
pinned of that family is `codes`, and only `codes`.

**Surface 2 — the printed `RawProgram`.** The `request.program` of each vector
is the Lean datatype `Agentic.Core.Dsl.RawProgram` under Lean's derived JSON
encoding, so the *term's encoding* is frozen alongside its observations: a
change to a constructor name, a field name or a field order is a corpus
regeneration even when every number in every reply is unmoved. The one field
this surface does not compare is position: the corpus stores real `line`/`col`
(1,059 of 1,061 `pos` occurrences are non-zero), and `Agentic.Observe.zeroPosValue`
sets `pos` and `answerPos` to `0:0` on **both** sides of a printed-program
comparison, because the Haskell builder has no way to represent a position.
`pos` is oracle-only for a whole program in the same sense `message` and
`excerpt` are oracle-only for a refusal.

**Surface 3 — `Explain.planLines`, which is no longer pinned anywhere.**
`test/CliSmoke.lean` used to check that `agent-cat plan example/harden.wf`
printed exactly `Explain.planLines Dsl.flagshipPlan ++ Explain.revisionLines
Dsl.flagshipRaw`, string for string. The command line and that test went with
the Lean excision; `Explain.planLines` and `Explain.revisionLines` survive as
library functions with **no gate on their output**. That is a deliberate loss and
is recorded here rather than papered over: it was the strictest of the three
surfaces, because `planLines` prints things no reply record contains: `askC` and `ask` as **distinct
keywords**, the shape line, `binds #{Γ.length}`, the prompt evaluated at
`Env.probe Γ`, and for a `case` the literal arm count *in the enumeration order
of the tag type the term carries*. Three consequences worth stating once:

* any presentation that identifies `askC` with `ask` — as every free-structure
  presentation of the `pipeline` fragment does, `Denote.askC_coherent` being the
  identification — changes `planLines` output while preserving every corpus
  number;
* closing the `case` tag universe must reproduce `FinEnum.toList` order **and**
  `ts.length`, and nothing now checks that it does — `corpus-gen` would not see
  it, and the run that would have is gone;
* `binds #{Γ.length}` is a function of `Ctx` being a `List Code`. Any
  re-indexing of the term language that drops contexts has no `Γ.length` to
  print.

Two further checks are pinned and are unreachable from all three surfaces:
`Agentic/Core/Certify.lean`'s two `#guard_msgs`, of which `certify_sound`'s is
the claim that it depends on no axioms. They are build failures rather than
comments, so the discipline is self-enforcing: an additive theorem layer is safe
with respect to them exactly when it does not change the definitions of `Plan`,
`denote`, `worldOf`, `lookup`, `Q` or `El`.
