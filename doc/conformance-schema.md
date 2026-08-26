# The conformance wire format

*Version 3. Program requests accept `"version": 2 | 3`; omission means 2.
Version 2 remains byte-identical semantic observation. Version 3 compares
intent-bearing Plan events and includes `semanticTrace`, their bare-question
erasure. Its occurrence-sensitive memo bill is operational evidence, not K1.*

The oracle speaks line-delimited JSON on stdin/stdout: one request per line,
one reply per line, `id` echoed verbatim when the request carries one. EOF on
stdin is the clean shutdown.

Every request may carry `"budgetMs"` (default 30000). On expiry the reply is
`{"timeout": {"ms": n}}` — **an observation, not an error** (connection.md
D13): the two implementations genuinely differ in asymptotics, and an
asymmetry must be recordable as an asymmetry.

## Request 1 — observe a program

```json
{"id": …, "version": 2|3, "program": <RawProgram>, "worlds": [<WorldSpec>, …], "budgetMs": …}
```

`RawProgram` is the Lean datatype `Agentic.Core.Dsl.RawProgram` under Lean's
derived JSON encoding (constructors as single-key objects, structures as field
objects — the corpus files are the normative examples). `worlds` defaults to
`[{}]`, the echo world. A world may add exact structured answers as
`"schema": [{"schema": <Schema>, "value": <SchemaValue>}, …]`. Each entry
is validated while the request is decoded; malformed fixtures are rejected
rather than silently defaulted. A world missing any schema the checked plan may
query is rejected before evaluation; schemas the plan never asks for may be omitted.

Three constructor-level changes landed together in the D-slate regeneration, and
because Surface 2 below freezes the *term's encoding*, each moved requests whose
replies did not move at all:

* **`caseResult` gained `unsettledName`** (D3), immediately after `settledName`.
  A bounded revision's two exits now both bind the candidate — the settled
  artefact, and the last one the final review objected to — so the unsettled arm
  has a binder where it had none. The two names may coincide, and for every
  surface-authored program they do, because both arms are built at the same
  depth. Twenty-seven requests gained the key; one of them, `battery-099`, has no
  `revising` at all and gained it anyway, because the key belongs to the
  `caseResult` node and not to the loop.
* **`revisingOn` and `caseEnding` are new constructors** (D4) — a loop that
  branches on the review's verdict tag three ways, and the three-armed `case`
  that consumes it. The codecs tag by constructor name, so nothing frozen
  carries either and **no existing entry moved for D4**.
* **`RawAsk.model` became an object** (D6): `"deep"` is now
  `{"primary": "deep", "alternates": []}`. `null` is unchanged and still means
  unpinned. Exactly five requests carry a `served by` and so exactly five moved.
  The *reply* side is untouched — a trace event's `scope.model` is still the bare
  string of the model that answered, because a pure `World` is total and never
  fails over.

The reply is one of three shapes:

### Refused

```json
{"refused": {
  "guard": "panelEmpty" | "revisionBound" | "questionBudget"
         | "servedBy" | "dupFunction" | "deciderEmpty"
         | "other",                                 // COMPARED
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
theorems. `other` covers every refusal outside the six term-level guards;
those are diagnostics, not comparands.

`deciderEmpty` (D7) covers both degeneracies of a decider — no needle at all,
and a needle that says nothing — because they are one mistake: a test that is
constantly false, or constantly true, with nothing in the source to show it.
`panelEmpty` covers an empty `panel` **and** an empty `panelText` (D2), because
it means "a fan with no members" whichever monoid the fan folds into. A text
panel's *label* refusals (an invalid character, two members answering to one
name) are `CheckError`s and classify as `other`: guards are the program-budget
family and these are well-formedness.

### Checked

```json
{"level": "batch" | "pipeline" | "branch" | "dynamic",
 "size": <Nat>, "askNodes": <Nat>,
 "codes": [<Code>, …] | null,             // null on any branching program
 "costSummary": {"minFold": <Nat>|null, "maxFold": <Nat>|null, "paths": <Nat>},
 "blockAsks": <Nat>,
 "fnAsks": [["name", <Nat>], …],
 "worlds": [
   {"world": <WorldSpec>,
    "trace": [<SemanticEventV2>|<ExecEventV3>, …],
    "semanticTrace": [<SemanticEventV2>, …],     // version 3 only
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
* Version 2 `trace` contains semantic bare-question events. Version 3 `trace`
  contains annotated execution events and `semanticTrace` contains the same
  occurrences after intent erasure. Both are data, never renderings:

```json
{"code": <Code>,
 "intent": "consult" | "observe" | "effect",        // v3 trace only
 "addressee": {"model"|"tool"|"person": {"id": "…"}}
            | {"toolExec": {"id": "…", "cmd": "…", "args": ["…", …]}},
 "scope": {"model": "…"|null, "mode": "…"|null},
 "prompt": "…", "draw": <Nat>,
 "answer": <string>                          // text
         | {"tag": "approve"}                // verdict
         | {"tag": "declined"}
         | {"tag": "object", "objections": ["…", …]}
         | <bool>                            // flag
         | null                              // receipt
         | <SchemaValue>}                    // schema-indexed value, encoded exactly
```

`<Code>` is one of the four existing strings or the structured family:

```json
"text" | "verdict" | "flag" | "receipt"
| {"json": {"schema": <Schema>}}
```

`json` is a wire tag only; the semantic constructor is `Code.structured` /
`CodeStructured`, and diagnostics call it `structured`.

`<Schema>` is the algebraic wire form: the five primitive strings (`null`,
`boolean`, `integer`, `number`, `string`), `{"array":{"items":<Schema>}}`,
`"object"`, or
`{"property":{"name":"…","schema":<Schema>,"rest":<Schema>}}`.

The semantic answer is **not JSON**: Lean's `Schema.El` and Haskell's
`SchemaEl` interpret primitives as ordinary values, arrays as lists, and records
as nested products. `<SchemaValue>` is a total exact boundary representation:
unit/null, booleans, integers and strings use their direct JSON forms; lists and
records recurse; exact rationals use
`{"numerator": <Int>, "denominator": <Nat>}`. This is not the user-facing
JSON codec, and no two semantic values collapse here. The user-facing JSON
representation rejects duplicate object members (including escape-equivalent
keys) and exponents whose magnitude exceeds 4096 before numeric expansion.

Both traces are compared **in order, unnormalized**. Semantic event identity is
code plus complete `Q`; version-3 intent is representation annotation. Routes,
retries, timeouts and selected backends remain execution metadata and do not
rewrite the authored question in `semanticTrace`.

`toolExec` remains the addressee carrying a program-authored argv. Source
position supplies intent: value-position commands are observations;
statement-position acts are effects. Two different commands remain different
questions. Version 2 deduplicates bare questions, preserving historical billing
(`battery-220` has `billMemo = 1`). Version 3 operational billing shares consult
and observe answers by bare `Q` while retaining every effect occurrence. The pure
oracle executes nothing. Passing v3 establishes Lean/Haskell annotation and
erasure parity; it does not establish semantic inequality or physical success.

## Request 2 — the string layer

```json
{"id": …, "string": {"op": …, "text": "…", …}}
```

| `op` | extra request fields | `result` |
| --- | --- | --- |
| `norm` | — | string |
| `words` | — | array of strings |
| `decodeVerdict` | — | verdict object |
| `decode` | `code` | `{"answer": …\|null}` |
| `say` | `code` | string |
| `bare` | — | string |
| `fields` | — | array of strings |
| `headerPaths` | — | array of strings |
| `matchGlob` | `pattern` | bool |
| `decide` | `decider`, `needles` | bool |
| `fence` | `name` | string |

Reply: `{"result": …}`. The extension is **additive**: `{"op", "code"?, "text"}`
still means exactly what it meant, and an old oracle meeting a new request
answers `{"error": "unknown string op `…`"}`, which is a loud failure and not a
silent one.

`decider` is one of `lastNonEmptyLineIs`, `containsLine`, `anyLineStartsWith`,
`anyPathMatches` — the closed vocabulary of D7, spelled by the same camel-case
names the `RawRhs.decide` constructor's `decider` field carries, with
`deciderName`/`deciderOfName` a machine-checked retraction so that the
authoring keyword, the diagnosis and the corpus field are one table.

The four low-level ops (`bare`, `fields`, `headerPaths`, `matchGlob`) exist so
that a divergence is **localizable**: a `decide` mismatch with all four green is
a composition bug, and with one of them red is that function's bug. The same
reason `norm` and `words` are pinned apart from `decode`.

This request kind exists because it is the highest-ranked divergence risk and
the only coverage it can get: on a program-in/world-out boundary nothing ever
calls `Decode`. The known hazard the vectors freeze: `Exec.norm` lowercases
**ASCII only** (`"HeLLo İstanbul" → "hello İstanbul"`, the `İ` surviving),
where a naive Haskell `toLower` is Unicode. Every predicate added for D2 and D7
is ASCII-only on the same rule, and the vectors freeze the places the two
implementations could otherwise drift: the CRLF marker line, `**WORK
COMPLETE**`, whitespace-only input, `İ` through a needle, `"✗"` against `"✗ "`,
`*.hs` against `x.lhs` / `b/src/Bar.hs` / `.hs` / `/dev/null`, a two-star glob,
an indented `diff --git` header, a bare markdown rule, and a fenced body that
closes its own tag or a sibling's.

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
nothing. Counted in this checkout, over the 190 files as they stand.*

**Surface 1 — the frozen reply record, and it has exactly eight keys.** A
checked reply is `level`, `size`, `askNodes`, `codes`, `costSummary`,
`blockAsks`, `fnAsks`, `worlds`, and nothing else; the Haskell producer is
`Agentic.Observe.observeValue`, whose own docstring calls them "the five static
folds, the two ask counts, and one observation per world". Of the 190 files, 94
carry a checked reply, 52 a `refused` reply and 44 a `result` from the string
layer.

**`shapes` and `asks` are on no wire and in no file** — `grep '"shapes"'` and
`grep '"asks"'` return zero hits across all 190. The record specified in
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
(1,455 of 1,457 `pos` occurrences are non-zero), and `Agentic.Observe.zeroPosValue`
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
