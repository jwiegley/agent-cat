---
status: FOUNDATIONAL
owner-ruling: goal mtafl3rl-yomsmb, 2026-08-26
issue: acat-cvx
supersedes: acat-2ls semantic-placement decision
---

# Request intent as an executable Plan annotation

## Objective

This document corrects the placement of `consult | observe | effect` after the
owner accepted the preceding denotational audit with the exact ruling: **“I
concur with the above. Make it so.”** (`/goal`, `mtafl3rl-yomsmb`, 2026-08-26).
The accepted identity result is that two workflows asking the same *authored*
questions in the same order and receiving the same answers have the same
principal meaning when they differ only in execution intent. A route-selected
or failover target is not the authored question.

Intent remains valuable. It belongs to the typed executable representation,
where it governs reuse, ordering, permission, completion discipline, rendering,
and operational evidence. It does not index the answer sheet.

| Law | This document supplies |
|---|---|
| I1 | Principal answer identity is `(c, Q c)`. |
| I2 | The five-form `Plan` may carry intent without moving meaning. |
| I3 | Denotation forgets intent compositionally. |
| I4 | Annotated execution trace forgets to semantic trace. |
| I5 | Runtime policies interpret intent only below denotation. |
| I6 | Representation lockstep has an explicit evidence ceiling. |

This document does not supply state-transformer semantics for physical effects,
a sixth `Plan` constructor, a new authoring language, or proof of external I/O.

## K1 — principal mathematical object

The answer sheet is indexed by questions:

```lean
Ω = (c : Code) → Q c → El c
```

A dialogue is the free monad over question-and-answer interaction:

```lean
Dlg A = A + Σ (c : Code), Q c × (El c → Dlg A)
```

Its two observations are the result and the exact semantic transcript:

```lean
Event = Σ (c : Code), Q c × El c
Trace = List Event
```

Question identity includes addressee, scope, prompt, and draw. Intent is absent.
Two equal questions receive one answer in every world. Two authored occurrences
remain two transcript events whether execution reuses an answer or not.

## K2 — fundamental operations

The principal object retains the established operations:

- `pure` / `done`;
- monadic bind on `Dlg`;
- one question generator `ask`;
- result and trace folds;
- counterfactual `pin` on a question; and
- free-monoid concatenation of traces.

`consult`, `observe`, and `effect` are not additional K2 operations. They are
annotations on one representation of `ask`.

## K3 — fundamental theorems and non-theorems

### Theorems

1. `run` and `trace` are monad morphism observations of `Dlg`.
2. Equal questions have equal answers in a world.
3. Duplicating an ask produces two semantic events; sharing one answer produces
   one.
4. Pins at distinct question keys commute.
5. `billFresh` is a monoid morphism from semantic trace.

### Non-theorems

1. Intent does not alter question answer identity.
2. `effect` does not denote a physical state transition.
3. `observe` does not prove an argv is read-only or an observation faithful.
4. Permission, lane selection, retry, timeout, routing, and memo policy are not
   semantic operations.
5. Operational memo billing is not required to be a monoid morphism or invariant
   under semantic equality.
6. Intent-aware v3 lockstep does not establish K1 identity or physical effect
   success.
7. A completed adapter turn is not proof that an external change occurred.

## K4 — representation tower

```text
RawProgram / Haskell authoring
        │ check / build
        ▼
Annotated five-form Plan
  Request c = Q c × Intent c
        │ denote = erase intent
        ▼
Question dialogue Dlg
        │ run / trace
        ▼
Ω and semantic Trace
```

The Haskell `Plan` is a peer realization of the annotated Lean `Plan`. It is not
a second meaning.

Execution descends separately:

```text
Annotated Plan
        │ execute
        ▼
Annotated execution trace
        │ forgetEvent
        ▼
Semantic Trace
```

No new AST is required. The current five-form `Plan` is already the appropriate
intermediate representation, just as `case` and `dyn` are representation forms
with equal denotational clauses but different analysis properties.

### Equality by level

| Level | Equality |
|---|---|
| Principal `Dlg` / `Ω` | Bare-question result and semantic trace equality |
| Annotated `Plan` | Kernel of the erasing denotation for semantic equality; structural equality only for representation checks |
| Annotated execution trace | Exact annotated event equality for operational lockstep |
| Runtime / adapters | Empirical comparison under a pinned execution policy |

## K5 — definitions forced at each representation

### Erasure

```lean
forgetRequest : Request c → Q c
forgetRequest r = r.question
```

### Denotation

Closed request:

```lean
denote (askC c r k) γ =
  Dlg.ask c r.question (fun x => denote k (x :: γ))
```

Open request:

```lean
denote (ask c s e k) γ =
  Dlg.ask c (s.question.withPrompt (e γ))
    (fun x => denote k (x :: γ))
```

Changing only intent therefore leaves denotation unchanged.

### Annotated execution events

```lean
inductive AnswerSource (c : Code)
  | reused
  | asked (dispatched : Q c)

ExecEvent = Σ (c : Code),
  { authored : Request c, source : AnswerSource c, answer : El c }

forgetEvent ⟨c, e⟩ = ⟨c, e.authored.question, e.answer⟩
```

Every execution event retains the authored request. `source` says whether its
answer was reused or which operationally relabelled question was actually sent.

### Operational interpretations

```text
reuse(consult) = reusable
reuse(observe) = reusable
reuse(effect)  = per occurrence

permission(effect) = grant
permission(_)      = cancel

effectLane(effect) = ordered
```

Reusable memo identity is bare `(c, Q c)`. The memo stores a typed answer, not an
authored event annotation. Every Plan occurrence constructs its own `ExecEvent`
from the current authored `Request`, answer source, and cached or fresh answer;
thus `consult q` followed by `observe q` calls the underlying service once while
its annotated trace still says `consult`, then `observe`.

Effect occurrences neither read nor populate reusable memo state; every effect
is dispatched. Because `effect` is restricted to `.ack`, its semantic answer is
`Unit`, while physical execution count remains an empirical obligation.

Failover preserves the authored request and selects an operational dispatched
question. Backend/model attribution remains below denotation; only
`authored.question` survives `forgetEvent`.

### Cost placement

`billFresh` remains a semantic trace interpretation. Effect-aware memo billing
is an interpretation of annotated execution trace and is named and documented as
operational. It may depend on intent and need not respect semantic equality.

## K6 — pure commuting theorem statements

The following statements are kernel obligations; their proofs are checker-owned.

### Generator equations

```lean
forgetRequest (s.withPrompt words) =
  s.question.withPrompt words
```

```lean
forgetRequest (σ.onRequest r) =
  σ.onQ (forgetRequest r)
```

### Denotation equality

```lean
denote (askC c r k) γ =
  Dlg.ask c (forgetRequest r) (fun x => denote k (x :: γ))
```

```lean
denote (ask c s e k) γ =
  Dlg.ask c (s.question.withPrompt (e γ))
    (fun x => denote k (x :: γ))
```

### Actual pure K5 executor

```text
Extends ω t →
  let r = execAnnotated ω p γ t
  r.value = run ω (denote p γ)
  ∧ Extends ω r.table
  ∧ map forgetEvent r.trace = trace ω (denote p γ)
```

The independent structural `execTrace` fold also satisfies the same erasure
equation; `execAnnotated_correct` establishes it for the executor that performs
bare-Q memo hits and effect bypass.

### Relabelling

```text
forgetRequest(relabel r) = relabel(forgetRequest r)
```

```text
forgetEvent(relabel e) = relabel(forgetEvent e)
```

## Empirical realization contracts

`IO` execution is not a K6 proof obligation. Each successful run is captured
under a pinned oracle/policy tuple and checked against the bare-Q world exhibited
by its resulting answer table or certificate: result agrees with semantic `run`;
annotated trace erases to semantic trace using authored questions; failover
attribution remains only in `AnswerSource.asked`; and every effect occurrence is
put once. These are empirical sampled squares with the evidence ceilings below.

## Rejected alternatives

### Request-indexed principal worlds

Rejected. It makes an answer depend on execution annotation without a domain
observer requiring that dependence. It was motivated by memoization and
permission defects, reversing the denotational direction.

### Intent only in semantic trace, with bare-question worlds

Coherent but unnecessary under the owner identity ruling. This alternative
remains the correct choice if authored speech-act force is later declared a
principal user observation.

### Stateful or algebraic physical-effect meaning

Rejected for this correction. It would be a genuine K1 redesign of world,
adequacy, pinning, and cost. A label returning `Unit` is not such a semantics.

### Sixth effect constructor

Rejected. The five-form `Plan` already carries generator annotations, and the
erasing denotation is a direct `PlanAlg` fold.

### A second executable AST

Rejected absent obstruction. Current `Plan` is already the typed intermediate
representation required.

## Migration invariants

1. Preserve all five `Plan` constructors.
2. Preserve Haskell production authoring and runtime.
3. Preserve Raw v2 syntax and all 190 frozen bytes.
4. Preserve source lowering: ordinary value ask → consult; value `toolExec` →
   observe; statement act → effect.
5. Preserve effect execution multiplicity, permission, ordering, completion, and
   failover behavior.
6. Restore bare-Q semantic world, dialogue, event, table, key, and price.
7. Make reusable memo identity bare Q in Lean and Haskell.
8. Memoize typed answers only; construct one annotated event per current Plan
   occurrence, retaining its own intent on a cache hit.
9. Preserve authored questions across routing and failover; record dispatched
   targets and backend attribution only in operational answer-source metadata.
10. Preserve proof axiom ceilings.
11. Treat v3 intent comparison as representation fidelity and add trace erasure.
12. Do not add physical read-only claims or state-transition semantics.

## Evidence ceilings

| Evidence | Establishes | Does not establish |
|---|---|---|
| Lean proofs | Pure erasure and commuting statements | Correct K1 choice or physical execution |
| Frozen v2 corpus | Historical semantic compatibility | Intent placement |
| v3 lockstep | Lean/Haskell annotation agreement | Semantic inequality of intents |
| Policy probes | Memo, scheduling, and permission behavior | Physical effect success |
| ACP/deck gates | Adapter behavior under tested protocols | Provider, OS, or external-service fidelity |
| Bisimulation | Agreement at declared comparison surfaces | Truth beyond the oracle's evidence ceiling |

## Migration order

1. Restore bare-Q K1 carriers and define annotated trace erasure.
2. Change `denote` to erase intent and prove generator equations.
3. Split semantic and operational key/price/bill uses.
4. Align Lean execution and Haskell memo identity with bare Q.
5. Reclassify v3 and add erasure comparisons.
6. Correct current documentation and supersede the former placement decision.
7. Run all proof, corpus, runtime, adapter, and adversarial-review gates.

No later step may weaken an earlier invariant to obtain a passing build.
