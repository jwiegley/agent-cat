# Attack: Adequacy to the Domain

*Attack lens — write the domain's real workflows in each proposed kernel and see what breaks.
Not a review of the derivations' internal reasoning; a test of whether the objects they name can
carry the work.*

**Thesis.** All four re-derivations agree that the world is a function of *questions* — that is
right and forced. All four then reach for the ladder `Applicative ⊂ Selective ⊂ Monad`, and that
is wrong for this domain, because in this domain **every prompt after the first is a function of
an earlier answer**, and a free applicative's question list is fixed before any answer exists.
Consequently, in three of the four kernels, *all six* workloads in the brief — including the
sharing example the kernels cite as their motive — land at grade `mon`, where the kernel itself
says no static cost exists. In the fourth (the `Dlg` kernel) the levels are semantic predicates on
a single carrier that does not record which class was used, so the analyses cannot be written at
all. The level the domain actually inhabits — *shape known, content flowing, finite-tag branching*
— is the **arrow** level (`Op i o ≅ i → Q o`, `choiceT` as `|||`), which is a recognized standard
class in the doctrine's own Step 6 list, which one derivation names ("Pipeline") and then fails to
carry, and which all four propose to delete. The owner's cost-factorization requirement is
satisfied by none of the four on any workflow in the brief, and is satisfied by the incumbent on
the flagship one.

---

## 0. Method

Six workloads, from the brief:

| | workload | what it stresses |
|---|---|---|
| (a) | hardenPatch: draft under deep model; 3 reviewers, 2 sharing one style-guide reading; revise ≤2; ask human; apply on yes | sharing, scoping, bounded loop, human, terminal act |
| (b) | best-of-5 resampling of one prompt, with a judge | q1 (identity of repeated questions) |
| (c) | review over N files, N runtime-known and bounded | data-dependent width |
| (d) | planner whose answer chooses which of two sub-workflows runs | branching vs. genuine monad |
| (e) | race two models for one artifact, first acceptable wins | alternation, early exit |
| (f) | offline costing: exact at static, tree where branching | the owner's directive (1) |

Four kernels:

- **K1 — `Dlg`** (`rederive-meaning-first.md`): `Dlg A = A + Σ(c:Code). Q c × (El c → Dlg A)`, the
  free monad on a question signature, HOAS continuations, single carrier; levels
  `Batch ⊂ Pipeline ⊂ Branching ⊂ Dynamic` as *semantic predicates on traces*.
- **K2 — polymorphic oracle** (`rederive-algebra-first.md`): `⟦W g A⟧ = ∀F ∈ Class(g), ((q:Q) → F (R q)) → F A`;
  inductive family with five generators `pure/ask/ap/select/bind`; grade `ap ≤ sel ≤ mon`; cost
  carrier `Finset Q` (idempotent), `bill` derived.
- **K3 — weighted free classes** (`rederive-decontaminate.md`): three carriers
  `WApp/WSel/WMon` free over one generator `ask`; meaning `den : Oracle → V A` with `V` a weighting
  monad (`VS S A = A → S`); `Alternative` for failure and alternation; cost *is* the meaning at
  another semiring.
- **K4 — ledger proposal** (`contamination-ledger.md` §4): `Q : Type → Type`,
  `World = History → ∀α, Q α → α`, `Ap ⊂ Sel ⊂ Free`, two meanings retained (`[[·]]_S` matrices,
  `[[·]]_ext`), `traverse` for fan, star for retry.

Baseline: **the incumbent**, `agent-cat`'s `Term` — kept in view not as authority (directive (2)
forbids that) but because it is the only artefact in the comparison that has actually been made to
express workload (a) and read a cost off it. Where I end up agreeing with a shape it has, I give
the argument from the meaning; where the argument is only "agent-functor did it", I say the
convergence is unjustified.

---

## 1. The pivot: what a consultation is a function of

Every finding below is a corollary of one observation, so it goes first.

In this domain a consultation's *prompt* is built from earlier answers. The draft goes into the
review prompt. The style guide's text goes into two reviewers' prompts. The objections go into the
revision prompt. The five candidates go into the judge's prompt. The file list goes into the
per-file prompts. There is no interesting workflow in which the second question is a constant.

Two ways to model a consultation:

```
  as a value:     ask : Q c → W (El c)              -- the question is fixed at construction
  as a morphism:  leaf : Op i o                     -- ≅ i → Q o; the question is a function of a wire
```

The free applicative on the first has normal form `Σ (qs : List Q), (Answers qs → α)` — K4 states
it in §4.1 — and the list `qs` is **closed**: no answer can appear anywhere in it. So under the
value presentation, "build the next prompt from the last answer" is not applicative, and it is not
selective either: `select : f (a ⊕ b) → f (a → b) → f b` lets a payload `a` reach the handler's
*pure combination*, never the handler's *questions*, which are fixed in the term. Hence it is
`bind`, and grade `mon`, and — by each kernel's own theorems — no static cost.

Under the morphism presentation the same workflow is a composite of leaves whose *shape* is fixed
and whose *content* flows along wires. The question set is not statically known; the question
*count* is, and so is the cost whenever the price of a leaf does not depend on the text flowing
through it. That is exactly the analysis the owner asked for.

Elliott's Step 6 lists both rows: `A → B ⇒ reader Functor/Applicative/Monad` **and** `a space of
arrows ⇒ Category/Cartesian/Cocartesian/CartesianClosed`. The arrow row is a recognized standard
class, not a bespoke invention, and the domain selects it. The convergence with `agent-functor`'s
`Flow` is therefore forced by the meaning; the *point-free notation* that came with `Flow` is a
separate decision and is deletable (§7.3).

K1 sees this and says so — §5 q4 calls the Pipeline level "the derivation's sharpest result" and
names the free static arrow as its witness. It then builds a kernel with one carrier in which that
level cannot be represented. K2, K3 and K4 do not see it: each answers the sharing question with an
example in which the shared answer feeds only *pure* functions (K2 §7 q2's Sharing theorem is
stated for `f, g` pure; K3 q2's `share x = (fun a => (a,a)) <$> x`; K1 §5 q2 is the honest one and
uses `do`). The domain's sharing feeds another *question*. The theorem all three offer does not
cover the case they offer it for.

---

## 2. Workload (a): hardenPatch

### 2.1 K1 (`Dlg`) — the best surface, and three defects in the flagship

K1 §10 is twelve readable lines and I would happily write them. Three things are wrong with it.

**Defect A1 — the loop does not implement its own English.** `loop : Nat → (S → W (Step S A)) → S → W (Option A)`
with `loop 0 _ _ = pure none` runs the body `n` times. The body is *review-then-maybe-revise*. So
`loop 2` performs review, revise, review, revise, give up: **two reviews, two revisions, and the
second revision is paid for and discarded unreviewed.** "Revise up to twice" wants three reviews and
two revisions. The correct recursion checks first and revises in the recursive call; the natural
spelling of the combinator gets it backwards. K2 §6.2 and K3 q5 have the same shape
(`retry (n+1) b x = b x >>= Sum.elim pure (retry n b)`, body = review-and-revise) and the same
waste. This is a small thing that matters, because it is the shape of the one combinator every real
workflow uses, and three independent derivations wrote it wrong the same way.

**Defect A2 — the worked cost is wrong, and the way it is wrong is diagnostic.** §8.3 gives
`1 + 1 + (3 ⊗ (approve ⊕ (1 + 3 ⊗ (approve ⊕ (1 + 3))))) + 1` ⇒ "min 7, max 15". The formula
describes three review rounds and two revisions (the intended English), while the code (`loop 2`)
gives two rounds. Evaluating the formula itself in the spend semiring gives min 6 and max 14, not
7 and 15: the extra unit is `cost (pure a) = 1` (§7.4) read as one dollar, when in the spend
semiring `⊗` is `+` and the multiplicative unit is `0`. The demonstration that "cost is read off
the meaning, no profiling, no execution" contains an off-by-one from confusing a semiring unit with
the number one, and a shape error from the loop. Also: on the give-up path the human is never
asked, so the maximum-spend branch is not the branch §8.3 describes.

**Defect A3 — by K1's own criterion the workflow is `Dynamic`, so none of the cost machinery
applies.** K1 §5 q4: "a `bind` is finitely branching exactly when its answer type is finite."
The loop binds on `Step Patch Patch` and the panel binds on `List Objection`; both are infinite.
So `hardenPatch : Dynamic`, and by §8.2(3) its cost is only the uncomputable function
`λ w. costOf (trace w p)`. The criterion is too coarse: what matters is that the continuation's
*shape* depends only on a finite classifier of the answer while the *payload* flows on. K1 has a
name for payload-flow (Pipeline) and a name for finite branching (Branching) and never combines
them, and its Branching witness (free `Selective`) cannot express the combination. So the
`Batch ⊂ Pipeline ⊂ Branching ⊂ Dynamic` chain of semantic predicates and the
`FreeAp ⊂ StaticArrow ⊂ FreeSel ⊂ FreeMonad` chain of witnesses **are not the same chain**: the
revise loop satisfies `Branching` (finitely many trace shapes) and is not expressible in free
`Selective`. The table in §5 q4 Part B is unsound at the Branching row.

**Defect A4 — the level is not recorded in the value, so no analysis can read it.** This is the
deepest one. `panel` is `traverse` at `Dlg`'s `Applicative`, and `Dlg`'s `Applicative` is derived
from its `Monad`; the value produced is a left-nested chain of `ask` nodes with function
continuations, *identical in form* to a genuine `bind` chain. Given `p : Dlg A` you cannot recover
whether `<*>` or `>>=` built it. Therefore:

- §5 q6's scheduling-freedom theorem ("for `p` built with `⊛` only …") has a hypothesis that is not
  a property of `p`. The runtime cannot check it, so it cannot run the panel concurrently.
- §7.4's cost equations distinguish `cost (mf <*> mx) = cost mf ∥ cost mx` (exact) from
  `cost (p >>= k) ≤ …` (lax), but `mf <*> mx` and the corresponding `p >>= k` are the same `Dlg`
  value, so `cost` is not well defined by those clauses.
- §8.4's graded budget subtype `{p : Dlg A // cost p ≤ γ}` needs `cost p`, which at a bind node is
  `⊕ a. cost (k a)` — a supremum over an infinite `El c` computed from an opaque Lean function.
  Not computable. Budgets-as-types, K1's most attractive feature, is unavailable.

K1's own §5 q9 argues *against* first-order syntax on the grounds that it would need α-equivalence,
substitution and a `Quot`. That argument is answered by intrinsically-typed de Bruijn syntax
(`Term Γ A`), standard in Lean, where α-equivalence does not exist as a concept and no quotient is
needed. K1 traded the only structure its analyses can consume for a problem that a standard
technique does not have.

**Verdict on K1 for (a):** natural to write, impossible to analyse. It is an author surface, not a
kernel.

### 2.2 K2 / K3 / K4 — grade `mon` at line two

```lean
-- K2, and the shape is the same in K3 and K4
def harden (task : Spec) : W .mon (Option Patch) :=
  bind (ask (readQ "STYLE.md"))          fun guide =>   -- ⟵ grade becomes .mon HERE
  bind (ask (draftQ deepModel task))     fun p₀    =>
  bind (loop 2 (fun p =>
        bind (panel [correctQ guide p, secureQ guide p, simpleQ p]) fun vs =>
        match fold vs with
        | .approve => pure (.stop p)
        | .revise objs => (.again) <$> ask (reviseQ p objs)))  fun final =>
  ...
```

`guide` is a `String` that must appear inside `correctQ`'s and `secureQ`'s prompts. Building those
questions from `guide` is `bind`. Nothing weaker will do it: the free applicative's question list is
closed, and `select`'s handler has fixed questions. So:

- **K2**: grade `.mon`. `asks : W .mon A → (Ω → S)`. There is no `bill`, no `costTree`, no
  `asksOver`/`asksUnder`. §5.4's factorization table returns "arbitrary support; no static
  computation". The exact-cost theorem's domain (`Const S` at grade `ap`) contains no workflow in
  the brief.
- **K3**: `WMon`. Its own §5 table: "dynamic — nothing finite — no structural fold exists." The
  meaning at min-plus is still *defined* (an infinite sum in a complete semiring) which is more than
  K2 offers, but it is not computed by recursion on syntax, so offline costing has no algorithm.
- **K4**: `Free Q`. Its §4.4 item 2 asks to prove that the analysis homomorphism
  `[[·]]_M : Ap Q α → M` "exists for `Ap` and `Sel` and **does not** for `Free`" — i.e. K4's own
  planned theorem says workload (a) has no cost analysis.

The irony deserves naming: **the sharing scenario is what destroys the grade.** All four documents
delete `shareT`'s labels on the ground that sharing is host binding; host binding of an answer into
a later prompt is `bind`; `bind` is grade `mon`; grade `mon` has no bill. Labels bought static
costing of a shared read. That trade is not identified in any of the four.

### 2.3 The incumbent, for calibration

`agent-cat/example/HardenPatch.lean` is 60 lines including comments, and its last two lines are

```lean
example (c : Bool) : Term.grade (harden c) = .static := rfl
example (c : Bool) : Term.widthT (harden c) = some 0 := rfl
```

`harden` is `.static`: the whole of (a) — deep-model scoping, a three-member panel with a shared
guide, `loop 2`, the consent gate, the terminal act — sits in the fragment where the cost fold is
exact, and the grade is checked by `rfl`. The mechanism is exactly §1's pivot:

```lean
| correct : PatchOp (Guide × Patch) Findings     -- the guide and the patch are INPUTS
def attempt := under deepModel (ask .draft) >>> keep review >>> fn decodeVerdict
def harden (consent : Bool) := loop 2 attempt >>> gate consent (ask .applyP)
```

The guide flows into the reviewers on a wire, not into a closure. `keep w = fn (fun a => (a,a)) >>> parT (fn id) w`
is the arrow's copy, and it shares a *value* between two consumers with no label at all.

Two corrections to the incumbent that this exercise surfaces, both in its favour:

1. **`shareT` is redundant even inside the arrow.** `guided sg .style .correct` uses a label only
   because the panel's members are written as independent closed terms. Hoisting the guide —
   `keep (ask .style) >>> panel [fn id >>> ask .correct, …]` — shares it structurally, `.static`,
   label-free. So the ledger's row 2 conclusion (delete labels) survives; its *argument* (therefore
   go applicative and use host binding) does not, and dragging the applicative rewrite along with
   it is what costs the grade.
2. **The example does not thread the objections** — `decodeVerdict (p, .revise) = Sum.inr p` feeds
   the patch back, discarding what the reviewers said, and typechecks only because
   `Spec = Patch = String`. Threading them is free in the arrow (`revise : Op (Patch × Objections) Patch`,
   the loop carrying `Patch × Objections`) and stays `.static`. That the *arrow* can thread
   objections while remaining statically costed, and the applicative cannot thread them at all, is
   the cleanest single demonstration of §1.

---

## 3. Workload (b): best-of-5 with a judge

```lean
-- K1: Pipeline (trace length is always 6, in every world) — correctly classified
do let cs ← (List.range 5).traverse (fun i => ask { q with draw := i })
   ask (judgeQ cs)

-- K2 / K3 / K4: applicative until the judge, then bind
bind ((List.range 5).traverse (fun i => ask { q with draw := .Nth i })) fun cs =>
  ask (judgeQ cs)                              -- ⟵ .mon

-- arrow: fn (List.replicate 5) >>> fanT 5 (ask q) >>> ask judge   -- .bounded 5, cost 6, exact
```

**The tell.** K2 §7 q1 and K3 q1 both give `bestOf` with a *pure* scorer — `argmax score` — and
both call it applicative with exact bill `n`. The brief says "with a judge". A model judge is a
question containing the five candidates, so the grade goes to `mon` and the exact bill evaporates.
The example that certifies the design was chosen to avoid the domain's version of the case.

**Resampling identity.** K1 and K2 put `draw : Nat` in the question; K3 makes two occurrences of
`ask q` two independent draws by the tensor of the weighting monad, so it needs no `draw` field.
K3 is the cleanest here and pays for it elsewhere: because the two draws have no separate identity,
**`pin` cannot fix an individual draw**. "Replay this run but with candidate #3 replaced" —
fixtures, resumption, counterfactual debugging, all of which the domain does — is inexpressible in
K3, while it is `Function.update` in K1/K2/K4 and in the incumbent. K3's §6 keeps `pin` in its
survivor list without noticing that its own q1 answer removed the index `pin` needs.

**Verdict:** natural in all four *as a shape*; costed in none of them once the judge is a model;
K3 loses replay.

---

## 4. Workload (c): review over N files, N runtime-known and bounded

```lean
-- K1 / K2 / K4
do let fs ← ask listFilesQ
   fs.traverse (fun f => ask (reviewQ f))

-- K3 (its own Part 4 table)
traverse f (as.take n)

-- incumbent
def perFile : Wf (.bounded 8) (List Patch) (List Findings) := Term.fanT 8 (ask .simple)
```

- **K1** has *no account of width at all*. `fs` is an answer, `fs.traverse` is inside a bind, the
  cost is `⊕` over every possible file list, and nothing anywhere in the kernel can say "at most
  eight". The bound is inexpressible.
- **K2** admits this in §11.4: "§§1–10 have no account of data-dependent width … a complete kernel
  plausibly wants the product `Grade × Frag`". Honest, and it means the kernel as derived does not
  cover the workload.
- **K3** writes `traverse f (as.take n)` — reproducing exactly the truncating meaning that the
  ledger condemns in `fanT` (nine files given to an eight-wide fan denotes eight reviews). K3
  inherits the defect it was written to remove.
- **K4** says cost is "a function of `xs`, which is the truth", and that a number is obtained by
  bounding the *type* (`Vector i n`). Correct, and left as a slogan: the list comes from an answer,
  so bounding the type means the *answer type* must be length-indexed, and nothing in K4 supplies
  that.

**The repair nobody proposed, and it is three characters of type.** Put the bound where the domain
puts it — in the answer:

```lean
El listCode := Σ n, PLift (n ≤ 8) × Vec File n        -- or   Vec File 8 ⊕ TooMany
```

The boundary parser that already has to turn a tool's stdout into a typed answer (K1 §11.4's "one
function per answer code") is exactly the place where "more than eight files" becomes a *value* the
workflow branches on. Then `traverse` over a length-indexed vector has statically known width, the
cost is exact, **and no meaning truncates anything**. This closes the ledger's row 5 objection to
`fanT` without deleting the width bound and without a `take`. It is available to every kernel here,
and it is the correct application of K1 §5 q8's own principle ("partiality that matters is in the
answer type where the domain put it") to width instead of failure.

---

## 5. Workload (d): a planner whose answer picks one of two sub-workflows

This is the case the owner names as "genuine monad", and all four derivations correctly refine the
owner's framing: choosing between *known* alternatives is below `Monad`. I endorse the refinement.
The refinement is then spent on the wrong object.

```lean
-- K2: .sel  — but ONLY if wA and wB consult constant questions
ifS ((· == .planA) <$> ask plannerQ) wA wB

-- in practice wA and wB are about the artefact:
bind (ask plannerQ) fun plan => match plan with
  | .planA => deepReview artefact | .planB => quickCheck artefact      -- ⟵ .mon

-- arrow: the artefact rides the wire into whichever branch is taken
fn classify >>> choiceT (deepReview) (quickCheck)                      -- .static, 2-leaf tree
```

`choiceT : Term f i o → Term g j o → Term (f ⊔ g) (i ⊕ j) o` is `|||` of `ArrowChoice`. The tag
selects the branch; the payload enters the chosen branch's leaves as input. Cost is a genuine
two-leaf tree with both arms present and enumerable — precisely "a tree structure where branching
happens", which is what the owner asked for. `Selective` gives the tree only when the arms are
closed; `ArrowChoice`-without-`ArrowApply` gives it when the arms are open in the payload, which is
the domain's case.

**Genuinely monadic residue.** A planner that *emits a plan* to be interpreted (an unbounded list of
steps) is genuine `bind` in every kernel, and all four are honest that no static tree exists there.
Two observations:

- The domain still wants a *bound* there ("this run may cost at most $2"). The only mechanism that
  produces an a-priori bound in the presence of value-determined shape is a syntactic fuel/width
  index. All four kernels delete the incumbent's (`retryT n`, `fanT n`) and replace them with
  suprema over infinite answer types. That is a computable over-approximation traded for an
  uncomputable exact value — a regression against directive (1), not a simplification.
- The right form of the index is a *sound over-approximation in one direction* of a quantity the
  meaning defines (`#asks`, or peak width), not an equality. `peak_not_le_grade` shows `Frag`
  measures fan-copies rather than asks and so bounds nothing; the diagnosis is "the index measures
  the wrong quantity", not "indices are decoration". An index folding into `(ℕ, +)` with `⊔` at
  choice, `+` at tensor, `n·` at fan and `⊤` at unfueled bind bounds `#asks` soundly and is
  computable.

---

## 6. Workload (e): racing two models

The one workload where the applicative-first kernels are at their best.

```lean
-- K2: exactly the shape select was invented for; qB does not depend on qA's answer
select ((fun a => if ok a then .inr a else .inl a) <$> ask qA) ((fun b _ => b) <$> ask qB)
--   asksUnder = {qA}   asksOver = {qA, qB}   — tight, attained, exact tree

-- K3: additionally weighted alternation / beam search
(ask qA) <|> (ask qB)          -- at a lexicographic ("First") semiring for left bias

-- K1: no alternation operator; the sequential form is a bind on a Bool
do let a ← ask qA; if ok a then pure a else ask qB
```

- **K2/K3 natural and exactly costed** — provided acceptability is decided by a *pure* predicate.
  If "acceptable" is judged by a model, the judge's prompt contains the artefact and the workflow
  is `mon` again.
- **K1 loses weighted alternation entirely** and says so (§14.4). "Try two and take the better" is
  `bestOf`, which is weaker: no zero, no annihilation, no beam search, no `sumT`. For a product that
  wants fallback chains with preference weights this is a real hole.
- **The parallel form** ("run both, take the first acceptable, cancel the loser") needs cost with
  two operators — `+` on spend, `max` on latency. K1 §8.1's `⊗ / ∥ / ⊕` table is the best statement
  of this in the four documents and I endorse it; it just cannot be applied, because `∥` is only
  defined at `<*>`, and §2.1's Defect A4 says `<*>` is not recoverable from a `Dlg`.

---

## 7. The cost-factorization audit (directive (1)), verdict by verdict

The owner asked for two things: *exact cost when monad is not necessary*, and *a tree when it is*.
Three distinct failure modes appear, and each kernel has at least one.

**F1 — the level is not recorded in the carrier.** (K1.) `Dlg` is one type; `<*>`, `select` and
`>>=` all produce the same shape of value. Every level-indexed statement — exact cost, the finite
tree, the concurrency licence, the graded budget — has a hypothesis that cannot be decided from the
value it is about. The analyses are not merely uncomputable; they are not well defined.
K2 §4.2 contains the argument K1 needed and lacks, and it is the best single passage in the four
documents: `ap` and `select` must be *generators* because `Const S` is `Applicative`-not-`Monad`
and `Over S`/`Under S` are `Selective`-not-`Monad`, so the cost morphisms have no domain unless the
term records which class built it. That argument refutes K1 outright.

**F2 — the ladder's rungs are empty in this domain.** (K2, K3, K4.) The analyses are well defined
at `ap` and `sel`; no workload in the brief lives there, because prompts are built from answers.
Formally: for each kernel, the set of terms with a static bill is the set whose question values are
closed, and the domain's workflows have at most one such question (the first).

**F3 — the analysis is a supremum or sum over an infinite answer type.** (All four, at bind.)
`cost (p >>= k) ≤ cost p ⊗ (⊕ a. cost (k a))` (K1 §7.4) and `[[t >>= k]]_S = Σ_b …` (K3, K4,
and the incumbent's `muS_bindT`) quantify over every possible answer. The sums exist mathematically
and are not computable from an opaque continuation.

The missing hypothesis that would fix F3, stated in none of the four (K1 §8.2's caveat states it
for `μ` and then §8.3 ignores it):

> **If `price : Q c → C` factors through a finite quotient of the question space — through the
> addressee, model, mode and a size class, and not through the prompt text — then the cost fold is
> computable at a bind node whose continuation branches on a finite classifier, and is exact.**

This is true of the domain's actual pricing (per-call and per-latency pricing factor through the
shape; per-token pricing does not, and for per-token pricing the honest output is an interval keyed
to a token bound carried in the answer type). It is the theorem the kernel should be built to
support, and it is precisely a statement about the arrow level: a leaf is `i → Q o` and its price
is a function of the leaf, not of `i`.

### The matrix

| | K1 `Dlg` | K2 oracle | K3 weighted | K4 ledger | incumbent (arrow) |
|---|---|---|---|---|---|
| (a) hardenPatch | Dynamic by own criterion; cost sup over infinite type; worked number wrong; loop wrong | `.mon` at line 2 — no bill | `WMon` — "no structural fold exists" | `Free` — own §4.4 says no `[[·]]_M` | **`.static`, checked by `rfl`** |
| (b) best-of-5 + model judge | Pipeline (right class, no carrier) | `.mon` | `WMon` | `Free` | `.bounded 5`, exact 6 |
| (c) N files, N ≤ 8 | width inexpressible | admitted absent (§11.4) | `take n` truncates the meaning | slogan only | `.bounded 8` (with truncation defect) |
| (d) two known sub-workflows | Branching predicate, no witness | `.sel` iff arms closed — they aren't | as K2 | as K2 | `.static` 2-leaf tree |
| (e) race, pure acceptance test | bind on Bool; tree | **`.sel`, tight bounds — best** | **`<|>`, weighted — best** | `.sel` | `.static` |
| (e) race, model judge | Dynamic | `.mon` | `WMon` | `Free` | `.static` |
| (f) offline costing | **not well defined** (F1) | defined, domain empty (F2) | defined, no algorithm (F2/F3) | defined, domain empty (F2) | computable fold; exact where price factors |
| budgets as types | uncomputable (§8.4) | absent | absent | absent | fuel/width index (sound if re-cut) |

**Verdict: the owner's cost-factorization requirement is claimed by all four and satisfied by
none of them on any workflow in the brief.** It is satisfied by the incumbent on (a), (b), (d) and
(e), and by the incumbent-with-answer-typed-width on (c).

---

## 8. What is inexpressible, ugly, and natural — per kernel

### K1 — `Dlg`

- **Natural:** everything, to *write*. Do-notation, host binding, `traverse`, host recursion,
  human as an addressee, refusal as an answer. The best author surface of the four, and the surface
  the owner sketched (ask/askHuman/model/panel/revising) falls out of it directly. The transcript
  is *in the meaning* (`trace`), which is the only kernel that models what the product actually
  shows a user — run graphs, resumption, provenance — and the Forcing Lemma is the right theorem
  about it.
- **Ugly:** nothing, at the surface. That is the problem: everything is equally easy, so nothing is
  distinguished.
- **Inexpressible:** every static analysis (F1); independence, hence the concurrency licence;
  weighted alternation and beam search (admitted §14.4); data-dependent width bounds; budgets as
  types; acts (deferred to §12, with an honest price list).

### K2 — polymorphic oracle

- **Natural:** (e) with a pure acceptance test — `select` with tight, attained `Over`/`Under`
  bounds is genuinely the right object for fallback among fixed alternatives. `Finset Q` as an
  idempotent cost carrier is a real derivation (Attempt D in §9), and it is the only kernel whose
  cost carrier makes "a correct runtime consults each distinct question once" a *statement* rather
  than an assumption.
- **Ugly:** grade coercions at every mixed-grade join; no `Monad` instance except at `W .mon`, so
  `do` is unavailable exactly where the analysis is; the discipline "reach for `<*>` and `ifS`
  before `>>=`" (§8.2) is the same point-free plumbing the ledger condemns in the arrow, relocated.
- **Inexpressible:** content-dependent prompts below `mon` (§1); width (admitted); alternation and
  weights (no `<|>`, no zero); acts; a trace in the meaning; free `Selective` over a *dependent*
  `R : Q → Type` is flagged as an open question in §11.5 and is not in Mathlib.

### K3 — weighted free classes

- **Natural:** failure, refusal, gating and alternation, all as one algebra (`0`, `+`, scalar
  action) — the best answer in the four to q8, and it repairs both of the incumbent's documented
  contradictions (`Option` bias at `parT`/`sumT`, the missing `zeroT`). Resampling needs no `draw`
  field. `cost_is_meaning` — cost is the meaning at another semiring — is the most elegant
  statement of the cost story anywhere in the dossier, and it is the only one that survives
  content-dependence *in principle*, because the sum is defined at `WMon` even when no fold is.
- **Ugly:** `Scoped G A = G → W A` puts a reader around every workflow, so the author threads `G`;
  `VS S A = A → S` over `A = String` needs a complete semiring and will be felt in Lean; writing at
  App/Sel level costs do-notation (admitted, §8 strain 5).
- **Inexpressible:** `pin` of an individual draw, hence replay and fixtures for any resampled
  workflow (§3 above) — and K3's survivor list keeps `pin` without noticing; a transcript (the
  meaning is a measure, so "what did it ask" exists only in the T1 Boolean tier); a computable cost
  at `WMon`; width without the `take`-truncation it condemns.

### K4 — ledger proposal

- **Natural:** the diagnosis. §2.C on `Frag`, §2.G on labels, §2.E on `Runner`-versus-`Env` are all
  correct and evidenced, and the recommendation to keep `Matrix`/`Semiring`/`Star`/`Gate`/
  `Instances`/`Context`/`LastOpt` is right.
- **Ugly:** it retains *two* meanings (`[[·]]_S` and `[[·]]_ext`), which is the defect the other
  three identify as the incumbent's root problem; §4.4 item 4 then asks for a projection π between
  them.
- **Inexpressible / self-defeating:** `World = History → ∀α, Q α → α`. History-indexing forces
  `[[f <*> x]]_ext` to thread the history left-to-right — K4 says so in §4.2 — which is exactly
  K2 §9's rejected **Attempt B**: an ordering silently gained, a tape in the model, and with it the
  loss of commutativity, the panel's unorderedness and the parallel licence. Two dossier documents
  contradict each other here and K2 is right. Also, putting a measure on a function space of
  functions is *worse* measure-theoretically than on `Q → Ans`, so §4.4's promised π is not
  obviously recovered by the change made for its sake.
- The ledger's row 9 ("`Op : Type → Type → Type` INHERITED; alternative `Q : Type → Type`") is,
  per §1, the single change that destroys the level the domain inhabits — and rows 1 and 9 are the
  same decision, ranked first and ninth.

---

## 9. What survives every workload

Stated separately because the attack should not obscure it. These held up under all six workloads
in all four kernels, and I would keep them under any rebuild:

1. **The world is a function of questions, not of syntactic positions.** Every workload confirms
   it; nothing in six workloads wanted a path. This is the dossier's real result and it is forced.
2. **Model, tool and human are one effect with an addressee field.** No workload distinguishes
   them; the differences are cost coordinates.
3. **Randomness at the edge**: one measure on worlds, no distribution threaded through any operator.
4. **Refusal, timeout and malformed output are answers, not exceptions** — and, generalizing
   (§4 above), so is "too many files". Put in the answer type what the domain puts in the answer.
5. **Scope is part of the question; the bulk operator is a monoid action.** `LastOpt` and per-axis
   innermost-wins survive verbatim.
6. **`pin = Function.update`** on the oracle — required by replay, fixtures and counterfactual
   debugging, and it needs the resample index that K3 removes.
7. **Deleting `shareT`'s labels** — but by the arrow's copy (`keep`/`&&&`), not by going
   applicative (§2.3).
8. **Branching is below monad.** The owner's directive (1) is refined correctly by all four; the
   refinement should be kept and applied to `ArrowChoice` rather than to `Selective`.

---

## 10. What the workloads say the kernel should be

Not a design decree; the shape the six workloads select, with the argument from the meaning in each
case.

- **A consultation is a morphism `i → Q o`, not a value `Q o`.** Forced by the domain fact that
  prompts are functions of earlier answers, together with the requirement to know the bill first.
  Elliott's Step 6 names the class (`Category`/`Cartesian`/`Cocartesian`). The convergence with
  `agent-functor`'s `Flow i o` is a consequence, not a reason.
- **The ladder has four rungs, not three**, and its middle two are arrow-shaped:
  `free Applicative` (questions closed) ⊂ `static arrow` (shape fixed, content flows)
  ⊂ `ArrowChoice` (finite-tag branching, content flows into arms; cost = finite tree)
  ⊂ `ArrowApply`/`Monad` (answer determines shape). K1 named rung 2 and could not carry it; nobody
  named rung 3, and rung 3 is where retry, panels-over-drafts, planners-over-two-plans and
  race-with-judge all live.
- **A first-order, intrinsically-typed syntax with variables** (`Term Γ A`, de Bruijn) rather than
  either HOAS or point-free composition. It gives the author `let`, gives the analyser a term to
  fold over, and — contra K1 §5 q9 — needs no α-equivalence and no `Quot`. This dissolves the
  false dilemma running through all four documents ("point-free plumbing *or* host binding"); the
  third option is to own the binder.
- **One meaning, carrying the transcript**: `[[w]] : Oracle → V (A × Trace)` (K3's carrier, K1's
  insight). Cost is a fold of the trace, so a shared read is one event and a duplicated one is two
  *in the object that decides equality* — which closes `acat-qtv` with neither labels nor a second
  meaning, and gives the product the provenance it displays.
- **Width and fuel indices retained, re-cut to bound `#asks`**, and proved to be sound
  over-approximations in one direction. `peak_not_le_grade` is a report that `Frag` measured
  fan-copies; it is not an argument against indices.
- **The costing theorem to aim at:** *if `price` factors through the question's shape, the cost
  fold is exact at rungs 1–2, a finite tree at rung 3, and a fueled over-approximation at rung 4.*
  That sentence is directive (1), and it is provable only in a kernel that has rungs 2 and 3.
