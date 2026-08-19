# D3 + D4 — the revising redesign

*Implementation design for `doc/research/isaac-workflows.md` §6 D3 and D4, as the
owner ruled them, which is past what §6 recommends. D3 changes `revising` itself
so that the unsettled ending carries the candidate, accepting the corpus
refreeze; D4 adds `revisingOn` as a variant now, with a three-way exit. Together
they are the largest single piece of wave 3's one regeneration event.*

**The contract this document must satisfy is P9's.** On 2026-08-18 the fusion of
`revising` with its consuming `case` was implemented to measure, the corpus was
regenerated to scratch, and the audit found `askNodes` had moved 16→13 on
battery-112, semantic-001 and semantic-004 (`size` 31→22, `paths` 8→5). The
fusion was refused — not because the numbers were wrong, but because *the
invariance table had not predicted them*, and a movement in `askNodes` is a
change to the enumerable question tree, which is a semantics decision and not a
re-pinning decision (`doc/research/profunctor-design.md`, row P9 and §4.2). So
this document predicts every field of every affected entry **before** anything is
regenerated, derives the arithmetic it predicts from, and names the unpinned
renderings that move too. A regeneration that produces a number not in §2.6
below is a refusal, not a re-pin.

---

## 0. The two decisions in one paragraph each

**D3.** `Plan.revising` stops returning `Option (El c)` and returns `El c × Bool`
— *the candidate always, and whether it settled*. The `Option` was throwing away
the very artefact G5 asks for: on exhaustion the loop holds the last candidate
in its hand and discards it. With the pair, `finishCont` binds the candidate into
**both** arms, `Raw`'s `caseResult` gains one field (`unsettledName`), and the
Haskell `Outcome` gains a payload on `Unsettled`. **Every observable the corpus
pins is invariant** — `size`, `askNodes`, `blockAsks`, `costSummary`, `level`,
`codes`, every trace and every bill — because not one term node moves: a `caseB`
stays a `caseB`, a `ret` stays a `ret`, and the only difference is which
environment the unsettled arm is read in. What moves is the *request* JSON of 27
corpus entries (one new key), the authored `known here` of exactly one entry
(battery-128), and two renderings nothing pins.

**D4.** `revisingOn` is a second loop beside `revising` whose round branches
three ways on the review's verdict tag rather than two ways on approval:
`approve` settles, `object` amends (or, at the last round, exhausts), `declined`
**abandons**. Its exit is a three-armed `case` over a new closed `Ending` tag, and
its consuming block form is `case x { settled p {…} unsettled p {…} abandoned p
{…} }`. It is a new `RawSource` constructor and a new `RawBlock` constructor, so
**no existing corpus entry moves at all** — new fixtures only. Its price is one
new `Tag` constructor (the first since the tag universe was closed at two), a
second unroll to prove level-bounded and denotation-correct, and a tail replicated
`2n+1` times instead of `n+1`.

---

## 1. The state of the mechanism today, stated once

Three files hold the whole of it, and the numbers below are derived from them
rather than read off a comment.

**`Agentic/Core/Plan.lean:956`** — `Plan.revising check revise n : Cont Γ (El c)
(Option (El c))`, `Nat.rec` in the metalanguage. Round `n` (the base clause) is
one `ret` carrying `if approvedB v then some a else none`; each round above it is
`caseB approvedB` whose true arm is `ret (some a)` and whose false arm is the
amendment grafted onto the next round. **So the unrolled loop has exactly `n+1`
`ret` leaves**: one per approved exit at rounds `0 … n-1`, plus the base clause's.

**`Agentic/Core/Dsl/Check.lean:505`** — `finishCont acc exh` is grafted onto every
one of those leaves, and is a `caseB (final).isSome` whose settled arm reads the
artefact through `(final δ).getD default` and whose unsettled arm is
`Plan.sub exh σ`, i.e. the arm elaborated one scope *out*. That `default` is a
value no run ever sees, and `Explain.planLines`' legend has to apologise for it in
prose (`Explain.lean:418–420`).

**`haskell/src/Agentic/Workflow.hs:644–659`** — the `Step (Loop c' s')` instance
already forks: it runs the rest of the block **twice**, once with
`Settled (V x VHere)` at scope `An c ': s` and once with `Unsettled` — *also at
scope `An c ': s`*, because a Haskell `case` has one type — and then
`unsettledArm` (`Workflow.hs:975`) undoes that weakening by closing the unused
slot with `defaultEl`. The comment there is the whole argument for D3 in
miniature: "the second run simply had no `Settled` handle to bind".

The consequence worth stating before the design: **on the Haskell side D3 is
almost entirely a deletion.** The fork already builds both arms at the settled
arm's scope; D3 makes that scope honest and `unsettledArm` — the subtlest
function in `Workflow.hs`, deliberately unexported with a paragraph defending it —
ceases to have a reason to exist.

### 1.1 The four arithmetic laws, derived and checked

Everything in §2.6 and §3.3 is these four, so they are derived here and validated
against two frozen entries.

Write `r` for the review clause's ask count, `a` for the amendment's, `n` for the
bound, and for the two exit arms `α, υ` (ask counts), `A, U` (path counts),
`σ_st, σ_un` (`Plan.size`).

* **Leaves.** The unroll has `n+1` `ret` leaves. The graft replicates the exit
  once per leaf.
* **Asks** (`Guards.hs:153`, `blockAsks`, verbatim from Lean):
  `(n+1)·r + n·a + (n+1)·(α+υ)`.
* **Paths** (`Cost.costM`: `ret ↦ {1}`, `ask ↦ map`, `case ↦ bind over
  Tag.values`): `(n+1)·(A+U)`.
* **Size** (`Plan.size`: `ret ↦ 1`, `ask ↦ 1+k`, `case ↦ 1+Σarms`):
  with `G = 1 + σ_st + σ_un` for the grafted exit,
  `S₀ = r + G` and `S_{k+1} = r + 1 + G + a + S_k`, hence
  **`S_n = (n+1)·r + n·a + n + (n+1)·G`**.

*Validation, `vector-002` (nested loops, `blockAsks 39`, `size 92`, `paths 27`,
`2..14`).* Inner loop `n=3, r=a=1`, arms `act` (1 ask, size 2, 1 path) and `stop`
(0 asks, size 1, 1 path): asks `4+3+4·1 = 11`; paths `4·2 = 8`; `G = 4`, size
`4·1+3·1+3+4·4 = 26`. Outer `n=2, r=a=1`, settled arm = the inner block, unsettled
= `stop`: asks `3+2+3·11 = 38`, plus the leading `d <- ask` = **39** ✓; paths
`3·(8+1) = 27` ✓; `G = 1+26+1 = 28`, size `3+2+2+3·28 = 91`, plus the leading ask
= **92** ✓. Cheapest path is the leading ask, round 0's review, then the *unsettled*
arm of the exit at that leaf — a path `isSome` decides against and `costM` counts
anyway — **2** ✓; dearest is 1 + (3 reviews + 2 amends) + (4 reviews + 3 amends) +
act = **14** ✓.

*Validation, `example-000` (the flagship, `askNodes 19`, `size 36`, `paths 9`,
`5..15`).* `n=2`, review is a panel of 3 (`r=3`, and a `k`-member panel elaborates
to a chain of size `k+1`), `a=1`; settled arm is `ok <- ask` then `if` (asks 2,
size 5, paths 2), unsettled is `stop` (0, 1, 1). Asks `3·3+2·1+3·2 = 17`, plus
`guide` and `draft` = **19** ✓; paths `3·(2+1) = 9` ✓ (which is DslFlagship's "three
ways out of the revision loop times three ways through the tail"); `G = 7`, size
`9+2+2+21 = 34`, plus two = **36** ✓; min `1+1+3 = 5` ✓; max `1+1+(9+2)+2 = 15` ✓.

Both entries reproduce exactly. The laws are the ones to reason with.

---

## 2. D3 — the unsettled ending carries the candidate

### 2.1 The semantic change: `Option (El c)` dies

```lean
-- Agentic/Core/Plan.lean
def revising {Γ : Ctx} {c : Code}
    (check : Cont Γ (El c) Verdict)
    (revise : Cont Γ (El c × Verdict) (El c)) :
    Nat → Cont Γ (El c) (El c × Bool)
  | 0 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        .ret (fun θ => (a (τ θ), Verdict.approvedB (v θ)))
  | n + 1 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        caseB (fun θ => Verdict.approvedB (v θ))
          (.ret (fun θ => (a (τ θ), true)))
          (graft (revise _ (Sub.comp σ τ) (fun θ => (a (τ θ), v θ))) fun _ ρ a' =>
            revising check revise n _ (Sub.comp (Sub.comp σ τ) ρ) a')
```

Constructor for constructor this is the term that is there today. The `some`/`none`
of the result expression becomes a pair; nothing else in the clause moves. **The
`Inhabited (El c)` requirement disappears** — there is no longer a slot to fill
with `default` — which is the wart `Explain.planLines`' legend documents.

`Option` dies outright. It has exactly three mentions to retire: the return type
here, `finishCont`'s argument type, and `Denote.lean`'s `reviseLoop`. It is
replaced by `El c × Bool` rather than by a bespoke sum because `Plan Γ A` is
polymorphic in a `Type` (`A` is `PlanF`'s parameter, not an index), so a product of
an answer and a tag costs nothing structurally, and `Bool` is already a `Tag`.

Why the *candidate*, and which one: on exhaustion the loop is holding the artefact
the `n`-th amendment produced and the `n+1`-th review objected to. That is exactly
Isaac's yield — "the tree keeps every edit the capped trips made, and the last
summary is what the panel reads" — and not, notably, the candidate that *would
have been* produced by amending in response to the final objection, which was
never asked for and must not be invented.

### 2.2 The exit continuation, generalised over the tag

D3 and D4 want the same continuation at two different tags, so it is written once
now and instantiated twice:

```lean
-- Agentic/Core/Dsl/Check.lean  (replaces finishCont)
def exitCont {Γ : Ctx} {c : Code} (t : Tag)
    (arms : t.El → Plan (c :: Γ) Unit) : Plan.Cont Γ (El c × t.El) Unit :=
  fun _ σ final =>
    Plan.case t (fun δ => (final δ).2)
      (fun x => Plan.sub (arms x) (fun δ => Env.cons (final δ).1 (σ δ)))
```

`finishCont acc exh` is `exitCont .bool (fun b => cond b acc exh)`, and
`Plan.caseB e t f = .case .bool e (fun b => cond b t f)` — so **the emitted node,
its tag, and its arm order are literally unchanged**. `Tag.values .bool = [false,
true]`, so `arm 0` is still the unsettled arm and `arm 1` still the settled one,
which is what keeps `Explain.planLines`' arm numbering fixed.

The one real difference: **both** arms are now `Plan (c :: Γ) Unit` and both are
substituted with `Env.cons (final δ).1`, where the unsettled arm used to be
`Plan.sub exh σ` at `Γ`.

### 2.3 The `Raw` delta — minimal, and where it goes

**`RawSource.revising` is unchanged.** It describes the loop; the binder belongs to
the arm that binds it, exactly as `settledName` does today.

**`RawBlock.caseResult` gains one field**, immediately after `settledName`:

```lean
  /-- `case x { settled p {…} unsettled q {…} }`: the two outcomes of a bounded
  revision, the settled artefact bound as `p` and the last candidate — the one the
  final review objected to — bound as `q`. Legal only immediately after
  `x <- revising …`. -/
  | caseResult (x : String) (settledName unsettledName : String)
      (settled unsettled : RawBlock) (pos : Pos)
```

JSON delta, in `haskell/src/Agentic/Raw.hs:513` (encoder) and `:549` (decoder), and
in the Lean codec: one key inside the `caseResult` object.

```diff
   "caseResult": {
     "x": "result",
     "settledName": "patch",
+    "unsettledName": "patch",
     "settled": { … },
     "unsettled": { … },
     "pos": { … }
   }
```

**The two names may coincide**, because they bind in disjoint arms — and the
authoring surface will always make them coincide, since both arms are built at
the same depth and `genName live` is a function of the depth. So for every
W-authored entry the new key's value equals `settledName`, which makes the corpus
diff trivially reviewable: 27 files, one added line each, and the line's value is
the line above it. The flagship's is `"patch"` twice, which is the same joke the
carrier and the settled binder already make (`tier1/Cases.hs:812`: "reuses one
name for the carrier and the settled binder").

**Twenty-seven, not twenty-eight and not twenty-six.** Twenty-eight entries
contain the word `revising`; `battery-091` and `battery-097` contain a `revising`
with no consuming `caseResult` at all (they are the "nothing consumes it" and
"a `stop` while a result is pending" refusals) and their requests are untouched;
and `battery-099` contains a `caseResult` with **no** `revising` — it is the
"a settled case on a name that is not a result" refusal — and *does* gain the key
even though it has no loop. That last one is the entry a mechanical `grep
revising` over the corpus misses, and missing it would leave one request the
codec cannot decode after step 5 of §4.5.

Rejected alternative: putting `unsettledName` on `RawSource.revising`. It reads
worse (the loop does not bind it, the `case` does), it puts the field on the
constructor that D4 duplicates, and it makes the `Pend`-to-`caseResult` handoff
carry a name the consuming form then has to agree with.

### 2.4 The elaboration delta

`Check.lean:527`, `Pend` becomes tag-indexed so that D4 can share it:

```lean
structure Pend (Γ : Ctx) where
  name : String
  code : Code
  tag  : Tag                          -- `.bool` for `revising`, `.ending` for `revisingOn`
  plan : Plan Γ (El code × tag.El)
```

`Check.lean:611`, the `revising` bind clause, changes in one place: the pending
plan it hands forward is `⟨x, b.code, .bool, Plan.revising … n Γ Sub.id b.val⟩`.
Everything above it — the `maxRevisions` pre-check, the annotation refusal, the
three `freshName`s, the subject lookup, `Swith`, the two `rhsPlan`s — is untouched.

`Check.lean:702`, the `caseResult` clause, is where the work is:

```lean
  | Γ, S, some pd, .caseResult x sname uname settled unsettled pos =>
    if x != pd.name then .error … else
    match freshName S pos sname with | .error e => .error e | .ok _ =>
    match freshName S pos uname with | .error e => .error e | .ok _ =>   -- NEW
    match checkBlock fns (pd.code :: Γ) (Bindings.push sname pd.code S) none settled with
    | .error e => .error e
    | .ok settledP =>
    match checkBlock fns (pd.code :: Γ) (Bindings.push uname pd.code S) none unsettled with
    | .error e => .error e                       -- was: … Γ S none unsettled
    | .ok unsettledP =>
      .ok (Plan.graft pd.plan (exitCont .bool (fun b => cond b settledP unsettledP)))
```

Three consequences, each of which is a refusal that must exist and a fixture that
must pin it:

1. **The unsettled binder is checked for freshness against the enclosing scope**,
   on the same rule and with the same message as the settled one. This is what
   keeps kind inference sound: `useKindB` is "structural, first-match, and
   deliberately ignorant of shadowing" (`Check.lean:191`) precisely because
   `freshName` refuses shadowing before any inferred kind is acted on, and adding
   a binder without adding its check would open that hole in the unsettled arm.
2. **`useKindB`'s `caseResult` clause is unchanged** (`Check.lean:260`): it still
   scans settled then unsettled for the first ground use of an *outer* name, and
   the new binder cannot capture one because (1) refuses the collision.
3. **The share from the loop's result to the settled binder is still not followed**
   for kind inference (`Check.lean:197`), and the same holds for the unsettled
   binder for the same reason: a program whose kind is discoverable only through it
   writes one annotation.

`Explain.lean:395`'s `RawBlock.revisionBounds` clause for `caseResult` gains one
ignored argument and nothing else.

### 2.5 The `W` surface

**`Outcome` becomes symmetric.**

```haskell
data Outcome (c :: Code) (s :: Scope)
  = -- | the loop settled, and this is what it settled on
    Settled (V (An c ': s) c)
  | -- | the bound ran out, and this is the candidate it ran out holding
    Unsettled (V (An c ': s) c)
```

**`Step (Loop c' s')`** (`Workflow.hs:652`) changes by two characters of intent:

```haskell
  step mn live lp k =
    loopRun lp live (fromMaybe (resultName live) mn)
      (Arms x (k (Settled   (V x VHere)) (x : live))
              (k (Unsettled (V x VHere)) (x : live)))     -- was: k Unsettled live
    where x = genName live
```

`Arms` is unchanged — it already declares both arms at `Blk (An c ': s)`.

**`unsettledArm` is deleted** (`Workflow.hs:957–977`), together with the paragraph
defending it and the `KnownCode c` constraint it forced onto the call site. The
weakening it undid no longer happens: the arm is genuinely built one scope in.
`revising`'s body loses its `(unsettledArm @c unsettled)` wrapper.

`B.revisingCaseI` gains one `Text` (the unsettled binder's printed name) and its
last argument's type changes from `Blk s` to `Blk ('(nu, c) ': s)`; the typed
`revisingCase` gains `KnownSymbol unsettled`, `Fresh unsettled s`, and a settled-shaped
arm function. `Builder.finishCont` (`Builder.hs:1081`) becomes the `exitCont`
port, losing its `KnownCode c` and its `defaultEl`. `Plan.revising`
(`Plan.hs:677`) returns `Cont g (El c) (El c, Bool)`.

`Agentic/Gen.hs:713` — the random-program generator that feeds the live
differential — passes the new name; simplest is to pass the settled name twice,
which is what the surface does and keeps generated programs in the shape the
corpus is in.

**What the author writes** becomes, in `Example/Harden.hs:198` and each of Isaac's
seven loops, `Unsettled _ -> stop` where it said `Unsettled -> stop`. That is the
whole authoring diff for the programs that do not want to yield — and see §4.4 for
the deliberate decision *not* to change the ones that do, in this commit.

### 2.6 The predicted per-field movement table

Every corpus entry containing a `revising`, with the fields as frozen today and as
predicted after D3. **`→` means predicted new value.** The rule column names why.

Rule **[I]** — *invariant by node-for-node identity*: the elaborated `Plan` has the
same constructors in the same order; `Plan.sub` is `subAlg.fold`, which rebuilds
constructor for constructor (`Plan.lean:580`), so `size`, `askNodes` and `costM`
cannot see it. Rule **[R]** — *request JSON gains `unsettledName`*. Rule **[S]** —
*the authored source must change or the entry flips*. Rule **[X]** — *refused
entry; classification unchanged (`Conformance.classify` reads a message prefix, and
none of the five prefixes is reachable from a binder name)*.

| entry | level | size | askNodes / blockAsks | costSummary (min,max,paths) | codes | rules |
|---|---|---|---|---|---|---|
| battery-075 a revising subject nothing binds | refused → refused | — | — | — | — | [R][X] |
| battery-084 a review annotated off verdict | refused → refused | — | — | — | — | [R][X] |
| battery-085 a review annotated at verdict | branch → branch | 11 → **11** | 4 → **4** | (2,4,4) → **(2,4,4)** | null | [R][I] |
| battery-089 a revising result with an annotation | refused → refused | — | — | — | — | [R][X] |
| battery-090 a loop nested in a settled arm | branch → branch | 33 → **33** | 14 → **14** | (2,8,10) → **(2,8,10)** | null | [R][I] |
| battery-091 a revising result nothing consumes | refused → refused | — | — | — | — | [X] *(no `caseResult`; request untouched)* |
| battery-092 a binding while a result is pending | refused → refused | — | — | — | — | [R][X] |
| battery-093 an act while a result is pending | refused → refused | — | — | — | — | [R][X] |
| battery-096 a known here while a result is pending | refused → refused | — | — | — | — | [R][X] |
| battery-097 a stop while a result is pending | refused → refused | — | — | — | — | [X] *(no `caseResult`)* |
| battery-098 a case on the wrong pending name | refused → refused | — | — | — | — | [R][X] |
| battery-099 a settled case on a name that is not a result *(a `caseResult` with no `revising`)* | refused → refused | — | — | — | — | [R][X] |
| battery-102 the settled binder may shadow nothing live | refused → refused | — | — | — | — | [R][X] |
| battery-110 an amendment bound above the limit | refused (`revisionBound`) → same | — | — | — | — | [R][X] |
| battery-112 a loop that settles at round two of four | branch → branch | 31 → **31** | 16 → **16** | (3,9,8) → **(3,9,8)** | null | [R][I] |
| battery-114 a revising subject of kind verdict | branch → branch | 23 → **23** | 10 → **10** | (2,5,8) → **(2,5,8)** | null | [R][I] |
| battery-120 a revision bounded at zero amendments | branch → branch | 7 → **7** | 4 → **4** | (3,3,2) → **(3,3,2)** | null | [R][I] |
| battery-121 a bounded revision whose candidate is not text | branch → branch | 26 → **26** | 9 → **9** | (2,7,9) → **(2,7,9)** | null | [R][I] |
| **battery-128 the scope at a loop's two exits asserted** | branch → branch | 13 → **13** | 6 → **6** | (2,5,4) → **(2,5,4)** | null | [R][I]**[S]** |
| battery-129 a kind fixed on the far side of a known here and a graft | branch → branch | 14 → **14** | 7 → **7** | (3,6,4) → **(3,6,4)** | null | [R][I] |
| battery-130 kind inference that only the amend clause grounds | branch → branch | 21 → **21** | 10 → **10** | (3,8,6) → **(3,8,6)** | null | [R][I] |
| battery-135 a panel in the amend position | refused → refused | — | — | — | — | [R][X] |
| battery-141 a numeral abutting the next token | branch → branch | 20 → **20** | 9 → **9** | (2,7,6) → **(2,7,6)** | null | [R][I] |
| battery-165 a review answering the wrong kind through a call | refused → refused | — | — | — | — | [R][X] |
| **example-000 the flagship, single file** | branch → branch | 36 → **36** | 19 → **19** | (5,15,9) → **(5,15,9)** | null | [R][I] |
| example-002 the flagship written against a library | branch → branch | 49 → **49** | 23 → **23** | (5,15,15) → **(5,15,15)** | null | [R][I] |
| semantic-001 a loop that settles at round two | branch → branch | 31 → **31** | 16 → **16** | (3,9,8) → **(3,9,8)** | null | [R][I] |
| semantic-004 a loop that truly settles at round two | branch → branch | 31 → **31** | 16 → **16** | (3,9,8) → **(3,9,8)** | null | [R][I] |
| **vector-002 blockAsks graft at depth** | branch → branch | 92 → **92** | 39 → **39** | (2,14,27) → **(2,14,27)** | null | [R][I] |

**Sixteen accepted entries, and not one number moves.** The two the brief asked
to be predicted exactly:

* **`vector-002`**: `level branch`, `size 92`, `askNodes 39`, `blockAsks 39`,
  `costSummary {minFold 2, maxFold 14, paths 27}`, `codes null`, `fnAsks []`. Its
  request gains two `unsettledName` keys — `"x"` on the outer `caseResult` and
  `"y"` on the inner — matching its two `settledName`s.
* **`example-000`**: `level branch`, `size 36`, `askNodes 19`, `blockAsks 19`,
  `costSummary {minFold 5, maxFold 15, paths 9}`, `codes null`, `fnAsks []`, and
  its four world replies (bills 6 / 7 / 13 / 13) unchanged. Its request gains one
  key, `"unsettledName": "patch"`.

**Why nothing moves, argued rather than asserted.** The four laws of §1.1 read
only three things off the term: how many `ret` leaves the unroll has (`n+1`,
unchanged — the base clause is still one `ret` and each round above it still
contributes exactly one), how wide the exit `case` is (two arms at `Tag.bool`,
unchanged), and how many asks and nodes each arm holds (unchanged — the arms'
`Raw` is the same tree and `checkBlock` emits one `Plan` node per `Raw`
construct regardless of the context it is checked in). The only structural
difference is the *context* the unsettled arm is elaborated in, and every fold in
the analysis layer is context-blind: `size`, `askNodes` and `costM` never inspect
`Γ`.

### 2.7 What must **not** move, and why it does not

* **Traces and bills.** `Plan.trace ω p γ` is a list of `Event`s, one per ask
  reached, carrying the question actually put. D3 changes no ask, no prompt and no
  branch condition — `(final δ).2` is the same `Bool` `isSome` computed, on the
  same verdict — so the executed path is the same path and the events are the same
  events. Every `worlds` block in every entry is byte-identical, and so are
  `billFresh`/`billMemo`. **The four `Plan.trace flagshipPlan = Plan.trace
  Harden.demo` agreements in `DslFlagship.lean:324–346` survive as stated**;
  they must be re-elaborated (six minutes) but not re-derived.
* **`level`.** `finishCont`'s `caseB` becomes `exitCont .bool`'s `case .bool`,
  which is the same former. Every revising program was `branch` and stays
  `branch`; nothing approaches `dyn`.
* **`codes`.** `Conformance` emits `codes` only below the branch rung, and a
  `revising` always emits a `case`, so `codes` is `null` on all 28 entries today
  and stays `null`. (Confirmed empirically: every revising entry's `codes` is
  `null`.)
* **Refusal classifications.** `Conformance.classify` (`Conformance.lean:201`)
  matches five message substrings — the empty panel, `at most 64 amendments`,
  `elaborates to`, `` `served by` names the model ``, and the duplicate function
  table. None is reachable by adding a binder name, so all twelve refused entries
  keep their `guard` and their `n`. Their oracle-only `pos`/`excerpt`/`message`
  are also unchanged, because every one of those refusals fires strictly before
  the new `freshName` call.

### 2.8 Two observations that **do** move and nothing pins — the P9 clause

P9 was refused because a rendering moved that the table had not listed. These two
are listed.

1. **`Explain.planLines`' legend, on every program.** Its closing bullet
   (`Explain.lean:418–420`) explains the probe rendering by naming
   `Plan.revising`'s own `(final δ).getD default`. That expression ceases to
   exist, so the sentence must be rewritten — and `planLines` prints its legend
   unconditionally, so **the Lean `plan` rendering changes for every program in
   the repository, revising or not**. Nothing pins it: `CliSmoke.lean` went with
   the Lean excision and there is no consumer of `planLines` in the tree today
   (`grep` finds only its own module and one prose reference in
   `HardenPatch.lean:323`). Replacement text should say what is now true: a probe
   environment does not know which arm it is inside, so a splice under either arm
   shows the probe's candidate and not a candidate any run produced.
2. **`binds #d` inside unsettled arms, +1.** `Plan.explainAlg` prints
   `binds #{Γ.length}` at each ask (`Explain.lean:290/293`). The unsettled arm now
   sits one context deeper, so every ask inside one prints a `binds` count one
   higher. Four frozen entries have an ask in an unsettled arm — **battery-112,
   battery-120, semantic-001, semantic-004**, each an `act` — and all four are
   also the entries P9 moved, which is not a coincidence: they are the corpus's
   only exercise of the unsettled arm as anything but `stop`. Again unpinned, and
   again correct rather than merely tolerable: the arm really does bind one more
   thing.

Neither is a corpus field. Both are recorded so that a reviewer who runs a Lean
`plan` after the regeneration and sees a diff knows it was predicted.

### 2.9 The authored-source edits, spelled

Exactly one frozen entry's *request* must be edited beyond the mechanical key
addition, and it is the entry that exists to catch this:

**`battery-128-the-scope-at-a-loop-s-two-exits-asserted.json`.** Its settled arm
asserts `known here: x, d` and its unsettled arm asserts `known here: d`. Under D3
the unsettled arm binds the candidate too, so the second assertion becomes false
and `checkBlock` refuses it — the entry would flip from accepted to `.other`.
The edit is one array:

```diff
   "caseResult": {
     "x": "r",
     "settledName": "x",
+    "unsettledName": "x",
     "settled":   { … "knownHere": { "names": ["x", "d"], … } … },
-    "unsettled": { … "knownHere": { "names": ["d"],      … } … },
+    "unsettled": { … "knownHere": { "names": ["x", "d"], … } … },
```

and the entry's meaning sharpens rather than weakens: it now asserts that a loop's
two exits bind *the same scope*, which is D3's whole content, in a form that
cannot rot. Its reply does not move — `known here` elaborates to nothing at all
(`tier1/Cases.hs:368`: "size 4, not 5").

**Two new fixtures are owed**, both refusals, both parallel to battery-102:

* *the unsettled binder may shadow nothing live* — `unsettledName` equal to a live
  outer name, refused by the new `freshName`, classified `.other`;
* *the two exit binders may be the same name* — an accepted entry with
  `settledName == unsettledName` and a hole in **each** arm resolving to its own
  arm's binder, which pins that the two are binders in disjoint scopes and not one
  binder. (The flagship exercises the same-name case but only reads it in the
  settled arm.)

A third is worth having and is cheap: *the unsettled arm reads the candidate* — the
smallest program in which the unsettled arm holes `{q}` and therefore actually
pays for D3. Without it the corpus records the new binder's existence and never
its use.

---

## 3. D4 — `revisingOn`, the three-way exit

### 3.1 What it is

`revising` tests one predicate, `Verdict.approvedB`, so `object` and `declined`
are the same thing to it: both buy another trip. `revisingOn` branches on the
verdict's *tag* — the finite classifier `VTag` that `caseVerdict` already uses —
and maps its three values onto three fates:

| verdict tag | in a round below the last | at the last round |
|---|---|---|
| `approve` | **settle** — exit with the candidate | **settle** |
| `object` | **amend** — one more trip | **unsettled** — the bound ran out |
| `declined` | **abandon** — exit now, no more trips | **abandon** |

This is §4 G6's near-miss made exact: `caseVerdict`'s three arms are Isaac's
`WORK COMPLETE` / `WORK REMAINS` / protocol-violation, and today the review
clause's verdict is consumed by the loop so the three cannot be told apart —
`WORK BLOCKED` buys a trip it should end, and a missing status line spends fuel
it should not.

### 3.2 The unroll, and the exit tag

```lean
/-- `[[Ending]]` = how a three-way bounded revision left off. -/
inductive Ending where
  | settled     -- a review approved
  | unsettled   -- the bound ran out with an objection outstanding
  | abandoned   -- a review declined: no answer
  deriving DecidableEq, Repr, Inhabited

def Ending.ofVTag : VTag → Ending
  | .approve => .settled | .object => .unsettled | .declined => .abandoned

-- Tag gains its third constructor, its El, its values, and the three instances.
def Tag.values : (t : Tag) → List t.El
  | .bool   => [false, true]
  | .vtag   => [.approve, .object, .declined]
  | .ending => [.settled, .unsettled, .abandoned]

def revisingOn {Γ : Ctx} {c : Code}
    (check : Cont Γ (El c) Verdict)
    (revise : Cont Γ (El c × Verdict) (El c)) :
    Nat → Cont Γ (El c) (El c × Ending)
  | 0 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        .ret (fun θ => (a (τ θ), Ending.ofVTag (v θ).tag))
  | n + 1 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        caseV v (fun t => match t with
          | .approve  => .ret (fun θ => (a (τ θ), .settled))
          | .declined => .ret (fun θ => (a (τ θ), .abandoned))
          | .object   =>
              graft (revise _ (Sub.comp σ τ) (fun θ => (a (τ θ), v θ))) fun _ ρ a' =>
                revisingOn check revise n _ (Sub.comp (Sub.comp σ τ) ρ) a')
```

Note the base clause needs **no** `case`: the ending is a pure function of the
verdict, so round `n` is one `ret`, exactly as `revising`'s is. That is what keeps
the leaf count odd and the formula clean.

The exit is `exitCont .ending`, the same continuation §2.2 introduced:

```lean
Plan.graft pd.plan (exitCont .ending (fun e => match e with
  | .settled => settledP | .unsettled => unsettledP | .abandoned => abandonedP))
```

**The extra exit edge per round, counted.** Leaves `L(0) = 1`, `L(k+1) = L(k) + 2`
— the approve-`ret` and the declined-`ret` — so **`L(n) = 2n+1`**, against
`revising`'s `n+1`. The exit is replicated once per leaf, as before.

### 3.3 The cost fold, derived

With `r`, `a`, `n` as in §1.1 and the three arms' ask counts `α, υ, β`, path counts
`A, U, B`, sizes `σ_st, σ_un, σ_ab`, and `G₃ = 1 + σ_st + σ_un + σ_ab`:

* **`blockAsks`** — the new `Guards.hs`/`Check.lean` clause, in the shape the
  existing one has (the `revisingOn`-followed-by-`caseEnding` clause must precede
  the general one, exactly as today's pair does, `Guards.hs:140`):

  ```
  loop  = (n+1)·r + n·a
  total = loop + (2n+1)·(α + υ + β)
  ```

* **`costSummary.paths`** = **`(2n+1)·(A + U + B)`**. Derivation: `costM` at a
  `case` is `Finset.univ.val.bind` over the tag's values, i.e. the *sum* over arms;
  the unroll's `caseV` contributes `1 + 1 + (recursion)` leaves per round and the
  base clause one; each leaf is grafted with a three-armed `case` contributing
  `A+U+B`.

* **`Plan.size`** — `S'₀ = r + G₃`, `S'_{k+1} = r + 1 + 2·G₃ + a + S'_k`, hence
  **`S'_n = (n+1)·r + n·a + n + (2n+1)·G₃`**. (Compare `revising`:
  `(n+1)·r + n·a + n + (n+1)·G₂`. The loop's own contribution is identical; only
  the multiplier on the exit and the exit's own width differ.)

* **`minFold`** = `r + min(cost_min st, cost_min un, cost_min ab)` — the cheapest
  path is round 0's review followed by the cheapest arm, and as with `revising`
  that path may be one no run can take (`abandoned` reached with `approve`'s
  leaf's arm), which is `costM`'s stated behaviour and not a defect.
  **`maxFold`** = `(n+1)·r + n·a + max(cost_max st, cost_max un, cost_max ab)`.

*Worked, for the fixture §3.7 asks for:* `n = 2`, review one ask, amend one ask,
arms `act`/`stop`/`stop`. Leaves `5`; `blockAsks = 3+2+5·(1+0+0) = 10`;
`paths = 5·3 = 15`; `G₃ = 1+2+1+1 = 5`, `size = 3+2+2+5·5 = 32`;
`minFold = 1+0 = 1`, `maxFold = 3+2+1 = 6`.

**The affordability guard bites sooner.** `maxQuestions := 4096` is checked against
`blockAsks`, and `(2n+1)` grows twice as fast as `(n+1)`, so a `revisingOn` with a
wide tail reaches the budget refusal at roughly half the bound a `revising` does.
That is a fact to state in `revisingOn`'s haddock, not a thing to change.

### 3.4 The `Raw` spelling — a new source form, and a new block form

```lean
inductive RawSource where
  | rhs (r : RawRhs)
  | revising   (subject carrier : String) (bound : Nat)
      (reviewName : String) (reviewAnn : Option Code) (review amend : RawRhs) (pos : Pos)
  /-- `revising on s as c, at most n amendments { v <- review  amend c { source } }`:
  the same loop, whose fork reads the review's verdict three ways — approval
  settles, an objection amends, a refusal abandons. -/
  | revisingOn (subject carrier : String) (bound : Nat)
      (reviewName : String) (reviewAnn : Option Code) (review amend : RawRhs) (pos : Pos)
```

The payload is identical to `revising`'s; only the constructor differs. That is
deliberate: **the difference is in how the loop reads its verdict, which is a
property of the loop and not of its clauses**, and keeping the payloads identical
means the checker's long prologue (bound pre-check, annotation refusal, three
`freshName`s, subject lookup, `Swith`, the two `rhsPlan`s) is shared verbatim
between the two clauses rather than transcribed.

```lean
  /-- `case x { settled p {…} unsettled q {…} abandoned t {…} }`: the three
  outcomes of a three-way bounded revision, each binding the candidate in hand.
  Legal only immediately after `x <- revising on …`. -/
  | caseEnding (x : String) (settledName unsettledName abandonedName : String)
      (settled unsettled abandoned : RawBlock) (pos : Pos)
```

**No existing entry moves.** The JSON codecs tag by constructor name, so a
`"revising"` object stays a `"revising"` object and a `"caseResult"` stays a
`"caseResult"`; `revisingOn` and `caseEnding` are new tags nothing frozen carries.
D4's whole corpus cost is *new fixtures*.

The adjacency rule pairs by tag: a `.revising` pend is consumed only by
`.caseResult` and a `.revisingOn` pend only by `.caseEnding`. Since `Pend` now
carries its `Tag`, the mismatch refusals write themselves — `case x { settled …
unsettled … }` after a `revising on` gets "this result has three endings, and the
third is `abandoned`", and the converse gets its mirror. Both are owed fixtures.

### 3.5 The `W` surface

A three-arm fork, `Outcome`-shaped rather than `caseVerdict`-shaped. The
distinction matters: `caseVerdict` in the surface (`Workflow.hs:895–904`) takes
its three blocks as explicit arguments, because it branches on a handle that is
already bound; `revisingOn`, like `revising`, must *fuse* its exit into the bind,
because `Ctx` has no code for an ending and the pair is one node.

```haskell
data Ending (c :: Code) (s :: Scope)
  = Settled   (V (An c ': s) c)
  | Unsettled (V (An c ': s) c)
  | Abandoned (V (An c ': s) c)

data Arms3 (c :: Code) (s :: Scope)
  = Arms3 Text Text Text (Blk (An c ': s)) (Blk (An c ': s)) (Blk (An c ': s))

instance ( s' ~ s, c' ~ c, j ~ 'Open (An c ': s), a ~ Ending c s ) =>
         Step (LoopOn c' s') ('Open s) j a where
  step mn live lp k =
    loopOnRun lp live (fromMaybe (resultName live) mn)
      (Arms3 x x x (k (Settled   (V x VHere)) (x : live))
                   (k (Unsettled (V x VHere)) (x : live))
                   (k (Abandoned (V x VHere)) (x : live)))
    where x = genName live
```

written by the author as

```haskell
result <- revisingOn draft (atMost 3) \patch -> W.do
  verdict <- panel [ … ]
  amend (ask (model "author") …)
case result of
  Settled   patch -> W.do …
  Unsettled patch -> W.do …          -- yield: the tree keeps the capped trips' edits
  Abandoned patch -> stop            -- the reviewer would not answer
```

Two prices, both real and both worth stating in the haddock:

* **the rest of the block is built three times at the Haskell level**, and the
  `Blk` it produces is replicated `2n+1` times in the plan. A `revisingOn` with a
  long tail is a compile-time cost and a term-size cost that a `revising` is not,
  and the answer when it bites is D1: put the tail in a `function` and call it
  once per arm.
* **`stop` in an arm is still an arm the author must write.** The dissent recorded
  against G5 — that the forced `Unsettled -> stop` *is* `completionGate` for free —
  applies three times over here, and the reply is the same: the `case` is total, so
  the author writes the arm; only the data is added.

### 3.6 The `BLOCKED` fourth ending

The mechanism is open at the exit and closed at the classifier, and the two should
be said apart.

**The exit extends for free.** A fourth `Ending` constructor, a fourth entry in
`Tag.values .ending`, a fourth arm in `caseEnding`, a fourth `Ending` constructor
in the `W` surface, and a fourth run of the continuation. `Tag`'s universe is a
closed inductive precisely so that adding a value is a local, total, kernel-checked
edit; `Level`, `Cost` and `Explain` all fold over `Tag.values` generically and need
no clause. Path arithmetic generalises to `L(n)·Σ arms`. No frozen entry moves,
because no frozen entry mentions `.ending`.

**The classifier does not.** What populates the fourth ending is the question of
*what says BLOCKED*, and `VTag` has exactly three values — a fourth would change
`caseVerdict`'s arm count and therefore `costM` and `planLines` on **every** frozen
entry that writes a verdict `case`, which is a blast radius an order of magnitude
past D3's. So the fourth ending arrives, if it arrives, through **D7's decider
vocabulary**: `lastNonEmptyLineIs "WORK BLOCKED"` applied to the review's answer,
yielding a fourth tag beside the verdict's three. **Record it as: D4 builds the
door; D7 is the key.** Nothing in D4 should be shaped to anticipate it beyond
leaving `Ending` an ordinary inductive with an `ofVTag` that is total today.

Recorded and refused: **the cheaper D4 that reuses `VTag` as the exit tag.**
Carry `El c × Verdict` out of the loop and `caseV` on it at the exit — settled ⇔
the last verdict approved, abandoned ⇔ it declined, unsettled ⇔ it objected. This
needs *no new `Tag` constructor at all*, no `Ending` type, no change to
`Plan.hs`'s `Tag` GADT or `tagValues`, and it hands the arms the objections for
free. It is genuinely cheaper today and it is refused because it welds the exit
arity to `VTag`'s three, which is exactly the door the previous paragraph is
opening. Worth reopening only if the fourth ending is decided against.

### 3.7 What D4 moves

**Nothing frozen.** Two new constructors nothing frozen carries; two new checker
clauses reached only from them; one new `Tag` value that no existing term names;
one new `Plan.revisingOn` beside the existing `Plan.revising`. Adding a
constructor to an inductive does not change any existing inhabitant of it.

Owed proof work, which is the honest bulk of D4:

* `Dsl.lean:105` gains `level_revisingOn_le` beside `level_revising_le`;
* `Dsl.lean:278` `checkBlock_level_le` gains two clauses;
* `Dsl.lean:615` `overRevised_sound` gains a `revisingOn` clause, and
  `Explain.lean:391` `revisionBounds` likewise (a `revising on` is a bounded
  revision and must be refused above `maxRevisions` and printed by
  `revisionLines`);
* `Denote.lean:731/755` gains `reviseLoopOn` and `denotes_revisingOn` — a second
  morphism equation between an unrolled plan and a semantic loop, which is the
  single largest item on the D4 list;
* `Dsl.lean:733` `checkBlock_caseVerdict_arms` gains a sibling
  `checkBlock_caseEnding_arms`, so that a permuted arm list stops type-checking
  silently in the new form as it does in the old.

Owed fixtures (all new files, no refreeze): the accepted three-way loop worked in
§3.3 (`size 32`, `askNodes 10`, `paths 15`, `1..6`); a `revisingOn` at bound 0
(one review, three endings, `2n+1 = 1` leaf); the two adjacency mismatches
(`caseResult` after `revising on`, `caseEnding` after `revising`); a `known here`
in each of the three arms, asserting that all three bind the candidate; and one
`abandoned`-reaching world in a `semantic-*` entry, since a run that never
declines never exercises the third exit.

---

## 4. The refreeze procedure

### 4.1 The order, and the one irreversible step

The regeneration is a **single event** and everything before it is Lean-only.

1. **Lean kernel changes land and `lake build` is green** (§5 steps 1–8). At this
   point `test/corpus/` is still the old corpus and `lake exe corpus-gen` would
   fail to *parse* it — the requests lack `unsettledName`. So a decoder that
   defaults a missing `unsettledName` to `settledName` is written **first**, used
   for exactly one run, and deleted in the same commit series. Rationale: a
   defaulted decoder makes the mechanical half of the refreeze a machine's job
   rather than a hand-edit of 27 files, and a decoder that silently accepts an
   incomplete `Raw` after the event would be a hole in the conformance boundary.
   The alternative — a `jq` pass over the 27 files adding
   `unsettledName = settledName` at every `caseResult` before regenerating — is
   equally acceptable and avoids touching the codec at all; **prefer the `jq`
   pass**, and require the codec to demand the field from the first commit. Drive
   the pass off the presence of a `caseResult` node, never off the word
   `revising`, or `battery-099` is missed and step 3 fails to parse.
2. **`battery-128`'s unsettled `known here` is hand-edited** (§2.9) *before* the
   regeneration, or the regeneration will record a refusal.
3. **`lake exe corpus-gen`** — the regeneration event. `git diff --stat
   test/corpus` must show exactly 27 files with one added `unsettledName` line
   each, plus battery-128's one changed array, **and no change to any `reply`
   block at all**. A `reply` diff is a refusal: it means §2.6 was wrong and the
   change has moved a semantics the design predicted it would not.
4. **Re-run `corpus-gen` a second time.** It must now be a no-op — that is the
   standing gate (`test/CorpusGen.lean`'s header) and it re-establishes it.
5. **New fixtures** (§2.9's three, §3.7's six) are added as requests and
   regenerated; their replies are whatever `observe` prints, and the two whose
   numbers §3.3 predicts must match.

### 4.2 `DslFlagship` — the re-pin list, and it is empty

`flagshipRaw` (`DslFlagship.lean:110`) is written out by hand, so it gains one
string:

```diff
         (RawBlock.caseResult
           "result"
           "patch"
+          "patch"
           (RawBlock.bind "ok" …)
           (RawBlock.empty …)
           { line := 49, col := 3 })
```

**Not one proved number moves.** Concretely, and this is the list the brief asked
for:

| theorem | today | after D3 |
|---|---|---|
| `flagshipRaw_accepted` | `true` | `true` |
| `level_flagshipPlan` | `branch` | `branch` |
| `card_leaves_flagship` | `9` | **`9`** |
| `minFold_flagship` | `5` | **`5`** |
| `maxFold_flagship` | `15` | **`15`** |
| `trace_flagship_{refuse,apply,stubborn,echo}` | `= Harden.demo`'s | **unchanged** |
| the four bills | `6 / 7 / 13 / 13` | **unchanged** |
| `flagshipUpTo` | inhabits at `15` | **`15`** |

`size` is not proved in `DslFlagship`; it is pinned by the corpus entry (36) and by
`ci/examples.sh` (36), and §2.6 predicts it invariant.

The cost is elaboration time, not re-derivation: all 28 theorems in that module
re-run through the kernel on the changed term, which is the six minutes and several
gigabytes the lakefile warns about. **Never elaborate it twice concurrently.**

`Agentic/Core/HardenPatch.lean` is the item the brief's input list does not name
and it is the second-largest Lean edit after the checker. It holds the *hand-written*
demo plan and its `Dlg`-level denotation, all typed at `Option (El .text)`:

* `loopD : Nat → El .text → Dlg (Option (El .text))` → `Dlg (El .text × Bool)`;
* `finishD : Option (El .text) → Dlg Unit` → `El .text × Bool → Dlg Unit`, with the
  unsettled branch still doing nothing (the flagship's arm is `stop`), which is
  why the denotation and therefore the four trace agreements are unchanged;
* `patchOf (o) = o.getD ""` → `Prod.fst`, or deleted;
* `finishK : Cont Γ (Option (El .text)) Unit` → `Cont Γ (El .text × Bool) Unit`;
* `denotes_finishK`'s proof: `cases o with | none | some` becomes `cases b`, and
  the `Option.getD_some` rewrites go away.

Its docstring at `:318` — "`finishK` sits at `Option (El .text)`, which is **not an
answer type at all**" — keeps its point and changes its noun.

### 4.3 tier1's two authored pins

`haskell/tier1/Cases.hs` rebuilds each corpus case from `Agentic.Builder`
combinators and compares the whole reply. Two of its 21 cases have their program
written elsewhere: `example-000`/`harden` and `example-001`/`hello`, both from
`Example.Harden` (`tier1/Main.hs`'s `$examples` note). `hello` has no `revising`
and is untouched. `harden` is `Example/Harden.hs:162–198` and needs one pattern
change, `Unsettled -> stop` → `Unsettled _ -> stop`.

Every other tier1 case that builds a loop calls `Builder.revisingCase` or
`revisingCaseI` and gains the unsettled name argument: by the module's own list
that is `semantic001`, `vector002`, `battery121`, `battery120`, `battery090`, plus
`battery085`, `battery112`, `battery114`, `battery128`, `battery129`, `battery130`,
`battery141` where present. In each the new argument is the settled name repeated,
which is what the corpus will hold. **`battery128`'s rebuilt `knownHere` must also
be updated** to the two-name list, and it is the tier1 case most likely to be
missed because its diff is in a string list and not in a type.

The pins to check after: `ci/tier1.sh` green at 21/21, `ci/tier0.sh` at 128/128
(now more, with the new fixtures), and the bisim differential.

### 4.4 `ci/examples.sh` — and the deliberate decision not to move it

Every one of the seven pinned rows stays exactly as written:

```
pin harden            branch      36   19    5   15     9     7    7
pin plan-feature      pipeline    14   13   13   13     1    13   13
pin review-lite       branch      13   10    8    9     2     9    9
pin ship-feature-lite branch     149   78    4   24    36    12   12
pin grind-tests       branch     144   73    9   27    36    15   15
pin stack-prs         branch     155   70    4   24    43    16   15
```

— **provided the seven `Unsettled -> stop` arms in `Example/Isaac.hs` and
`Example/Harden.hs` become `Unsettled _ -> stop` and nothing more.** A pattern
binding a handle nobody reads elaborates to the same `Raw` and the same plan.

**Do not, in this commit, rewrite `shipFeatureLiteProgram`'s unsettled arm to
yield.** It is the program D3 exists for — `Isaac.hs:1282` carries the apology in
a comment — and rewriting it will move `size`, `askNodes`, `costSummary` and both
bills on the `ship-feature-lite` row, and probably on `grind-tests` and
`stack-prs` too. Landing the mechanism and changing the program in one commit
would make the examples table's movement unattributable, which is the exact failure
P9 records. So: **a follow-up commit**, one program at a time, each with the new
numbers derived from §1.1 before they are run and pinned after. `isaac-workflows`
§3's table and each program's haddock move with them, and G5's entry in §4 gets
its "adopted" line.

### 4.5 The Haskell re-port order

The Haskell is a transliteration of the Lean, so it is ported after the Lean is
green, bottom-up, in the order the dependency graph forces:

1. `Plan.hs:677` `revising` — return `Cont g (El c) (El c, Bool)`; two clause
   bodies, no structure change. **Add `revisingOn` here too** if D4 lands in the
   same wave.
2. `Plan.hs` `Tag`/`tagValues` — the `TEnding` row, and the `Tag.finEnum_toList`
   counterpart discipline (`tagValues` is hand-written to reproduce Lean's
   enumeration order and is checked against it).
3. `Builder.hs:1081` `finishCont` → `exitCont`; loses `KnownCode c` and
   `defaultEl`.
4. `Builder.hs:1190` `revisingCaseI` — one more `Text`, the last argument's type
   change, the `RawCaseResult` gaining its field. Then `Builder.hs:1130`
   `revisingCase`'s constraints.
5. `Raw.hs:482/513/549` — the `RawCaseResult` field, encoder, decoder. **And the
   decoder must demand it**, per §4.1.
6. `Guards.hs:147` `blockAsks`, `:207` `blockGuard`, `:227` `overRevised` — the
   `caseResult` clauses gain an ignored argument; the D4 clauses are new.
7. `Workflow.hs` — `Outcome`, the `Step (Loop …)` instance, the deletion of
   `unsettledArm`, `revising`'s body.
8. `Gen.hs:713` — the generator passes the new name.
9. `Example/Harden.hs`, `Example/Isaac.hs` — the seven patterns.
10. `tier1/Cases.hs` — the rebuild calls and battery128's name list.

Gate: `ci/tier0.sh` (replay the frozen corpus), `ci/tier1.sh` (rebuild it from the
builder), the bisim differential against `conformance-oracle`, then
`ci/examples.sh`.

---

## 5. Implementation checklist, Lean-first

The single regeneration event is step 12. Everything before it leaves
`test/corpus/` untouched; everything after it is downstream of a corpus that has
already moved.

**D3, Lean**

1. `Plan.lean:956` — `revising` returns `El c × Bool`. Drop the `Inhabited (El c)`
   need at the call sites it had one.
2. `Dsl.lean:105` — `level_revising_le` re-typed (proof body unchanged in shape).
3. `Check.lean:505` — `finishCont` → `exitCont t arms`, generalised over `Tag`.
4. `Check.lean:527` — `Pend` gains its `tag` field.
5. `Check.lean:611` — the `revising` bind clause hands forward `.bool`.
6. `Check.lean:702` — the `caseResult` clause: the new `freshName`, the unsettled
   arm checked at `pd.code :: Γ`, the `exitCont .bool` graft.
7. `Syntax.lean:284` — `RawBlock.caseResult` gains `unsettledName`; its docstring
   states what the binder is (the candidate the final review objected to).
8. `Syntax.lean` / `Conformance.lean` codecs — the JSON key.
9. `Explain.lean:395` — `revisionBounds`' `caseResult` clause arity.
10. `Explain.lean:418–420` — the legend bullet rewritten (§2.8).
11. `HardenPatch.lean:201–274` — `loopD`, `finishD`, `patchOf`, `finishK`,
    `denotes_finishK`; `Denote.lean:731/755/853` — `reviseLoop`, `denotes_revising`,
    `upToTwice`. `DslFlagship.lean:110` — the one added `"patch"`.
    `lake build` green, including the six-minute flagship module.

12. ### ▶ **THE REGENERATION EVENT** ◀
    `jq` pass adding `unsettledName = settledName` to 26 requests →
    battery-128's `known here` hand-edit → `lake exe corpus-gen` →
    **check the diff against §2.6: every `reply` block unchanged** →
    `lake exe corpus-gen` again, must be a no-op.

**D3, Haskell** — steps 1–10 of §4.5.

**D3, fixtures** — the three new entries of §2.9, added and regenerated.

**D4, Lean** (may land in the same wave; it touches nothing D3 froze)

13. `Plan.lean` — `Ending`, `Ending.ofVTag`, `Tag.ending` with its `El`, `values`,
    three instances, and the `Tag.finEnum_toList` case; `Plan.revisingOn`.
14. `Syntax.lean` — `RawSource.revisingOn`, `RawBlock.caseEnding`, codecs.
15. `Check.lean` — the `revisingOn` bind clause (sharing the prologue with
    `revising`), the `caseEnding` clause, the two adjacency-mismatch refusals,
    `useKindB`'s and `revisionBounds`' new clauses.
16. `Dsl.lean` — `level_revisingOn_le`, two `checkBlock_level_le` clauses,
    `overRevised_sound`'s clause, `checkBlock_caseEnding_arms`.
17. `Denote.lean` — `reviseLoopOn` and `denotes_revisingOn`.
18. `Guards.hs`/`Check.lean` — the `blockAsks` clause with the `(2n+1)` multiplier,
    ordered before the general `revisingOn` clause.
19. **D4, Haskell** — `Plan.hs` (`revisingOn`, `TEnding`, `tagValues`),
    `Builder.hs` (`revisingOnCase`/`…I`), `Raw.hs`, `Guards.hs`, `Workflow.hs`
    (`Ending`, `Arms3`, `LoopOn`, the `Step` instance), `Gen.hs`.
20. **D4, fixtures** — the six of §3.7, added and regenerated; the two whose
    numbers §3.3 derives must match on the nose.

**Close-out**

21. `Certify.lean`'s empty-axiom claim re-checked (both changes are ordinary data
    and ordinary recursion; no `native_decide`, no `Quot`).
22. `ci/tier0.sh`, `ci/tier1.sh`, bisim, `ci/examples.sh` — all green with the
    tables of §4.3 and §4.4 unmoved.
23. `isaac-workflows.md` §4 G5 and G6 gain their "adopted" lines, and §6's D3/D4
    entries record that the owner ruled past the recommendation and what it cost.
24. **Separately, after**: `shipFeatureLiteProgram`'s yielding arm, with the new
    `ci/examples.sh` numbers derived before they are run (§4.4).

---

## 6. Interaction points with the sibling designs

Named only, per the brief's scope.

* **D1 (`function`/`callStmt`/`callV` in the surface).** The natural answer to
  D4's three-times-built tail: an arm becomes one `callStmt` rather than a copy.
  `blockAsks`' `callAsks` already prices it, so the `(2n+1)` multiplier applies to
  a call's cost exactly as to a statement's — nothing in §3.3 changes. D1 landing
  after D4 is fine; D1 landing first would let D4's fixtures be smaller.
* **D8 (program inputs).** No interaction. A loop's subject is a handle either way.
* **D2 (`panelText`).** A `panelText` is an `Rhs`, so it may stand as a
  `revising`'s or `revisingOn`'s review clause; the review's `r` in §1.1 becomes
  the fan-out's member count. The two designs meet only in `rhsAsks`.
* **D5 (tool argv, runner-authored receipt).** May appear in any arm. The
  unsettled arm now having a handle is what makes "run the gate against the
  candidate the loop gave up on" writable at all.
* **D6 (failure vocabulary).** `revisingOn`'s `abandoned` ending and `TurnGap`'s
  `TurnEmpty` are adjacent but not the same thing: `declined` is an answer the
  addressee gave, `TurnEmpty` is an answer it failed to give. Keep them apart in
  the vocabulary or the distinction G6 is buying will be spent immediately.
* **D7 (closed decider vocabulary).** The key to D4's fourth (`BLOCKED`) ending,
  per §3.6. D4 should ship without anticipating it.
