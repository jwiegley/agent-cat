# The Term Algebra: What the Pre-Re-Derivation Stratum Proved

***A permanent record of the results established by `Agentic/*.lean` outside `Core/` — the `Term`
calculus, its two meanings, the `WEqR` quotient and the panel convolution algebra — written from
the live sources before their retirement under obr `acat-q1i`.***

Prepared 2026-08-20, from HEAD `b98e25f`. Every theorem statement in §2 is **transcribed from the
source**, not paraphrased; every claim carries a `file:line` as of that commit. The line numbers
die with the excision — git history is the archive, and this page is the reading of it for someone
who will never open the files.

**The excision has since happened**, on the same day and in the commit this paragraph belongs to.
Sixteen files went, and these are their sizes at `b98e25f`, which is where to look for them:
`Meaning.lean` (2,831), `Instances.lean` (1,397), `Star.lean` (1,035), `Panel.lean` (843),
`Matrix.lean` (763), `Term.lean` (535), `Semiring.lean` (510), `Keys.lean` (344), `Env.lean` (342),
`Frag.lean` (285), `Monoid.lean` (251), `Trace.lean` (221), `Gate.lean` (206), `Context.lean` (153),
`Surface.lean` (150), `Pareto.lean` (65) — **9,931 lines**. One file survives,
`Agentic/Scope.lean`, for the reason §5 gives; the monoid right action that `Agentic/Monoid.lean`
held for it moved into it, and the rest of that file — `SupMon` and the left action — went with its
consumers.

---

## 0. How to read this, and why it exists

The stratum described here was the project's first attempt at the whole problem: a graded syntax of
workflows, two meaning functions over it, a quotient by one of them, and the resource algebra
underneath. It was superseded in the 2026-08 re-derivation by `Agentic/Core/**` — a different
syntax (`Plan`), a different denotation (`Dlg`), and a certified spine that the Haskell
implementation and the 189-vector conformance corpus are held against. On 2026-08-20 the triage
established that `Agentic/Core/**` imports exactly one module from the old tree
(`Agentic/Core/Question.lean:1`: `import Agentic.Scope`), and that everything else in
`Agentic/*.lean` outside `Core/` has no consumer at all. The owner endorsed the excision.

**What is being retired is 9,931 lines of code, not a body of results.** (The `acat-q1i` ticket
text, written 2026-08-13, priced a *partial* kill at ~4,700 lines against a ~4,000-line survive
list — semirings, matrices, the Kleene star, `Keys`, the panel convolution. The 2026-08-20 triage
found that the survive list had no consumer either: the mathematics on it worth keeping had already
been re-derived inside `Core/`, so keeping the originals kept two of everything. The owner endorsed
the full no-consumer excision, and that is what §0's figure now counts.) The results are
mostly *negative* — statements of the form "the projection you wanted does not exist", "the bound
you assumed is false", "these two things you hoped were one thing are two". Negative results are
the expensive kind: each one cost a construction, an attempted proof, and a machine-checked
counterexample, and each one is a fact about the *design*, not about the code that discovered it.
Delete the code and the facts remain true; lose the record and they get rediscovered at full price.

So this is the record. §1 says what the stratum was. §2 transcribes the results. §3 states the six
theory threads that the results opened and nobody closed. §4 buries the thirty tracker items that
close with the code. §5 says which of the mathematics survived as product, so that a reader does not
mistake a retirement for a loss.

---

## 1. What the stratum was

### 1.1 The `Term` algebra — twelve constructors, graded by fragment

`Agentic/Term.lean:115` defines `Term (Op : Type → Type → Type) (G L : Type) : Frag → Type → Type
→ Type 1`, an inductive family of *written* workflows: the tree a designer composes, indexed by a
grade that the constructors compute rather than check. Three parameters keep the syntax honest:
`Op i o` is the uninterpreted leaf signature (a consultation taking an `i` and answering with an
`o`), `G` is the type of scope annotations with no structure demanded, and `L` is the type of
sharing labels, likewise unconstrained — the meaning fold compares labels *by never comparing
them*, so no `DecidableEq L` is ever required anywhere in the stratum. The twelve constructors are
`prim` (a consultation leaf), `pureT` (a plain function lifted, central by construction), `seqT`,
`parT`, `sumT` (alternatives — fallback and beam search), `choiceT` (value-dependent branching on a
decoded coproduct), `gateT` (a `Bool` permission guard), `scopeT`, `shareT` (a sharing label),
`retryT` (fueled iteration), `fanT` (data-dependent width bounded by `n`), and `bindT` (a full
value-dependent continuation). The grading rules, in one line: leaves and transforms are `static`;
`seqT`/`sumT`/`choiceT` take `⊔`; `parT` *adds* (both branches are in flight, so their widths add);
`gateT`/`scopeT`/`shareT`/`retryT` pass the grade through; `fanT n` scales by `n`; `bindT` is
`monadic` outright. The grade type is `Frag := ℕ∞` (`Agentic/Frag.lean:119`, an `abbrev`, so
Mathlib's `⊔`, `+` and `*` on the extended naturals are the arithmetic and no private order or its
laws exist), with `static = 0`, `bounded n = (n : ℕ∞)`, `monadic = ⊤`, and `Frag.scale n f = (n :
ℕ∞) * max 1 f` (`:126`, `:130`, `:135`, `:159`). Two decisions of the syntax are load-bearing
throughout: **every syntactic occurrence of `prim` is a distinct consultation site**, identity of
sites being positional; and **sharing is explicit and labeled**, `shareT` being the only override.
There is deliberately no weakening constructor (`Term.lean:92-100`).

### 1.2 `muS` — the quantitative meaning, a matrix fold

`Agentic/Meaning.lean:175` defines `muS`, the fold `⟦·⟧_S` from a term to `Scoped G (Mat S i o)` —
a *reader awaiting its scope*, delivering a resource-weighted transition matrix over a complete
commutative semiring `S`. Every clause is one row of the design's §4 table, so the
type-class-morphism equations are `rfl` and the theorems that state them (`muS_prim` `:199`,
`muS_seqT` `:214`, `muS_parT` `:227`, `muS_sumT` `:234`, …) are proofs by reflexivity rather than
inductions: `seqT` is `Mat.comp`, `parT` is `Mat.kron`, `sumT` is `Mat.matAdd`, `choiceT` is
`Mat.caseMat`, `gateT` is `Mat.gate` (refusal is the scalar `0` and annihilates), `scopeT` is
`withScope` — the scope monoid's right action, imported and not re-derived — `retryT` is
`Mat.retryTrunc` (fuel is the star's *truncation*, never the unbounded star, because the grade
calls a fueled loop `static`), `fanT` is `Mat.fanMat` with the input list truncated at `n`, and
`bindT` is `Mat.dependentSeq`. Leaves take the scope in force as an argument (`Interp Op G S := G →
{a b} → Op a b → Mat S a b`, `:121`), which is what makes scoping do work. `shareT` is
**quantitatively transparent** — the one row the fold does not pay for.

### 1.3 `muExt` — the extensional meaning, a site-keyed fold

`Agentic/Meaning.lean:832` defines `muExt`, the fold `⟦·⟧_ext` from a term to a partial function,
per sample point: `Runner Op G L → G → Key L → i ⇀ o`, where a `Runner` (`:669`) is the world
consulted and a `Key L` (`:535`) is *the consultation index a leaf reads at*. A key is either
`abs s` — the absolute path from the root, built from `Step`s (`:450`) that name which way the fold
went at each branching constructor — or `rel l s`, the path from the nearest enclosing `shareT l`.
That two-constructor key is the entire mechanism of sharing: `shareT l` **rebases** (`Key.rebase`,
`:558`), so two occurrences of one label build equal keys and therefore read equal answers, and
label equality is never tested. `retry trip` and `fan ix` carry indices, so a body run three times
is three sites — the conservative reading, because the default must never silently equate two
draws. `bindL`/`bindR` are two steps rather than one, precisely so that nested binds' continuations
cannot collide on one key. The fold is deterministic and partial: refusal is `none` and threads
through `Option`.

### 1.4 The `WEqR` quotient — workflow equality up to a relabelling of sites

`WEq` (`Agentic/Meaning.lean:1909`) is extensional equality quantified over every runner, every
scope and every key. It is the design's equality and it is *too fine to be a category's*: every
structural rearrangement moves keys, so under `WEq` the two bracketings of a pipeline are different
workflows and deleting an open gate is a semantic change. The repair is `WLe` (`:1965`) — at each
absolute base there exists a `Relabels` map `σ` on keys, chosen *after* the base and *before* the
runner, carrying one term's consultations onto the other's — and `WEqR := WLe t u ∧ WLe u t`
(`:2004`), its symmetrization, stated heterogeneously across grades because `seqT`'s index changes
by `sup_assoc`. A `Relabels` map may move absolute sites anywhere but **fixes every `rel` key**
(`:682`): a labelled site is a name, not a position. That single side condition is what buys the
laws while keeping sharing apart from duplication. `wSetoidR` (`:2477`) is the `Setoid`, `Workflow`
(`:2498`) the quotient, and on it: associativity (`:2601`), both units (`:2615`, `:2624`), gate and
scope absorption (`:2634`, `:2639`), six congruences, and `staticCategory` (`:2713`) — the static
fragment is a genuine `CategoryTheory.Category`. Three congruences are missing by construction
(`retryT`/`fanT` need an n-ary `Key.splice`; `bindT` needs a uniformly-chosen relabelling; `shareT`
is different in kind, since relabellings fix `rel` bases), so `Workflow` quotients the
`seq/par/sum/choice/gate/scope` sub-algebra only.

### 1.5 The panel convolution algebra — the monoid semiring `S⟨K⟩`

`Agentic/Panel.lean:140` defines `MSemiring S K` — a weight in `S` for every key in `K` — as the
meaning of a *panel*: send one question to several members and combine their verdicts. Combining
two independent panellists is **convolution** (`:167`): the weight of observing key `c` is the
aggregate, over every pair of keys combining to `c`, of the two weights sequenced. This is the
`liftA2` of the monoid semiring and emphatically *not* the pointwise product, which is the same
formula on the Reader and the wrong operation for panels. `delta k` (`:179`) is the member certain
to report `k`, and the derivation of §5.1 becomes a theorem: `conv_delta` (`:208`) says `δ a ⋆ δ b
= δ (a * b)`, so the point masses form a copy of `K` inside `S⟨K⟩`, and `convFold_delta` (`:815`)
extends it to a whole list — which is what makes `List.prod` *the reducer of the denotation* rather
than an unrelated list operation. The module carries the full algebra (`conv_assoc` `:294`,
`conv_one_left`/`right`, distribution over `msAdd`, `total_conv` `:496` as the multiplicative
read-out, and `instNSemiring` `:543`), and is careful that **two reorderings are two licences**:
commuting the *contributions* accumulated into one panel is free (`msAdd_comm` `:386`,
`panelOf_perm` `:612`), while commuting the *convolution factors* is the scheduler's licence and
costs a commutative key monoid (`conv_comm` `:658`, `convFold_perm` `:828`). That cost is real
rather than a formality — the default free key monoid is not commutative, and the witness is
machine-checked (`Agentic/Keys.lean:175`):

```lean
/-- The free key monoid is genuinely non-commutative, so `Panel`'s refusal to
assume `op_comm` is not idle generality: here is a panel whose verdict does
depend on the order in which its two members reported. -/
theorem list_op_not_comm : ∃ l l' : List Nat, l * l' ≠ l' * l :=
  ⟨[0], [1], by decide⟩
```

It is a survivor
against Mathlib for one stated reason (`:108`): `MonoidAlgebra R M := M →₀ R` demands finite
support, and a panel weighting in this design never has it — at possibility over the free key
monoid, "any list of findings may come back" is nonzero at infinitely many keys.

---

## 2. The results

Twenty-six theorem statements, transcribed rather than paraphrased. Each is followed by what it says
in plain words.

### 2.1 No projection from the quotient to matrices — the counting obstruction

`Agentic/Meaning.lean:2814`:

```lean
theorem one_add_one_of_muS_respects_WEq {Op : Type → Type → Type} {G L S : Type}
    [CommSemiring S] [CompleteCSemiring S] [Monoid G] (g : G) (interp : Interp Op G S)
    (h : ∀ t u : Term Op G L .static Unit Unit, WEq t u → muS interp t = muS interp u) :
    (1 : S) + 1 = 1
```

**What it means.** Suppose the quantitative meaning respected extensional equality — suppose every
two terms with one extensional meaning had one matrix. Then, because `w ⊕ w` and `w` are
extensionally equal (a duplicated alternative is invisible; the leftmost branch answers), the
carrier would have to satisfy `1 + 1 = 1`: a resource semiring in which two ways of arriving are
one way. `Prop`, `Cost` and `Prob` are such carriers and are unbothered; the expectation semiring
is not, and neither is any carrier in which the number of alternatives is part of the answer. So
**there is no `π` from `Workflow` to matrices** that does not collapse counting, which is why the
package carries two folds rather than one meaning with a cost annotation. The supporting witness is
`Agentic/Meaning.lean:2789`:

```lean
theorem WEq_sumT_pureT_self {Op : Type → Type → Type} {G L : Type} [Monoid G]
    {i o : Type} (fn : i → o) :
    WEq (Op := Op) (G := G) (L := L) (.sumT (.pureT fn) (.pureT fn)) (.pureT fn)
```

and the obstruction survives the coarsening a fortiori, because the coarser relation identifies
*more* — `Agentic/Meaning.lean:2039`:

```lean
theorem WEq.toWEqR {Op : Type → Type → Type} {G L : Type} [Monoid G] {f : Frag}
    {i o : Type} {t u : Term Op G L f i o} (h : WEq t u) : WEqR t u
```

The sanity check that `WEq` identifies *something* at all is transform fusion,
`Agentic/Meaning.lean:2778`:

```lean
theorem WEq_seqT_pureT {Op : Type → Type → Type} {G L : Type} [Monoid G]
    {i j o : Type} (f₁ : i → j) (f₂ : j → o) :
    WEq (Op := Op) (G := G) (L := L)
      (.seqT (.pureT f₁) (.pureT f₂)) (.pureT (fun a => f₂ (f₁ a)))
```

### 2.2 The other direction dies too — matrices cannot see a site

`Agentic/Meaning.lean:2769`, true by `rfl`:

```lean
theorem muS_dupPair_eq_sharedPair {Op : Type → Type → Type} {G S : Type}
    [CommSemiring S] [CompleteCSemiring S] [Monoid G] (interp : Interp Op G S) (l : Nat)
    (q : Op String Nat) :
    muS (L := Nat) interp (Term.dupPair q) = muS interp (Term.sharedPair l q) := rfl
```

against `Agentic/Meaning.lean:2436`:

```lean
theorem WEqR_dupPair_ne_sharedPair :
    ¬ WEqR (dupPair (G := LastOpt Unit) (L := Nat) AskOp.ask)
        (sharedPair (G := LastOpt Unit) (0 : Nat) AskOp.ask)
```

**What they mean together.** `dupPair q = parT (prim q) (prim q)` asks twice; `sharedPair l q =
parT (shareT l (prim q)) (shareT l (prim q))` asks once and reads the answer twice
(`Agentic/Term.lean:393`, `:405`). These two terms have **literally the same matrix**, at every
carrier and every interpretation — the equality is `rfl`, because `muS` is transparent to `shareT`
(`muS_shareT`, `Agentic/Meaning.lean:261`: `muS interp (.shareT l t) g = muS interp t g := rfl`).
And they are **still different workflows**: a relabelling may move absolute sites anywhere, but it
fixes labelled keys and it is a *function* on keys, so it can never split the one site `sharedPair`
reads twice into the two sites `dupPair` reads once each. So equality of quantitative meanings does
not imply `WEqR` either. The reason is the design's own §6a: **a matrix has no room to record a
consultation site**, so it cannot see sharing. Read with §2.1, this is the sharp form of the
statement — here are two terms one meaning cannot tell apart and the other must.

The extensional half is discharged directly at `Agentic/Meaning.lean:1270`:

```lean
theorem muExt_dupPair_ne_sharedPair :
    Term.muExt (askRunner epsSplitKey)
        (Term.dupPair (G := LastOpt Unit) (L := Nat) AskOp.ask)
      ≠ Term.muExt (askRunner epsSplitKey)
        (Term.sharedPair (G := LastOpt Unit) (0 : Nat) AskOp.ask)
```

and its exact limit at `Agentic/Meaning.lean:1284` — the distinction is real, and invisible to any
single world that does not depend on where it is asked:

```lean
theorem muExt_dupPair_eq_sharedPair_of_const {G : Type} [Monoid G] (v : Nat)
    (l : Nat) :
    Term.muExt (askRunner (G := G) (fun _ => v))
        (Term.dupPair (L := Nat) AskOp.ask)
      = Term.muExt (askRunner (G := G) (fun _ => v))
        (Term.sharedPair l AskOp.ask)
```

which is the written-term form of the stratum's founding pair, `Agentic/Env.lean:336` and `:293`:

```lean
theorem share_ne_dup : shareEx ≠ dupEx

theorem share_eq_dup_of_agree {C O W : Type} (q₁ q₂ : C) (ε : Env C O)
    (h : ε q₁ = ε q₂) :
    (askPair q₁ q₁ : Ext C O W Unit (O × O)) ε = askPair q₁ q₂ ε
```

**Why that pair matters.** Copy-naturality — the law that would let a compiler, a scheduler or a
refactoring replace "ask once and copy" by "ask twice" — holds pointwise in the answer sheet
exactly when the sheet agrees at the two indices, and fails in general. Under a measure at the edge
the failure is systematic rather than accidental: the two consultations are separate draws, so a
self-consistency ensemble that accidentally shares one index collapses to a single sample, and the
two meanings differ in their *variance* even where they agree in their support. That is why the
consultation index is part of the meaning and not an implementation detail, and it is why
duplication is the default: a default may only be the reading that cannot silently equate distinct
samples.

### 2.3 The position statement: the two meanings are incomparable

`Agentic/Meaning.lean:2726-2759` is a prose position statement rather than a theorem, and it is the
stratum's final word on the relation between its two folds. Transcribed in the load-bearing part:

> So the two equalities remain **incomparable**, and this is the honest statement in place of the
> fibration story: no projection in either direction. One direction is impossible outright —
> `one_add_one_of_muS_respects_WEq` shows a `π` from the quotient to matrices would collapse any
> carrier that counts. The other now waits on the quantitative side rather than the extensional
> one: a site-aware carrier (the free semimodule on `Key`, or a consultation-multiset fold) is what
> would let matrices see what `WEqR` sees, and that is acat-qtv's question, no longer blocked on
> this one.

**What it means.** Neither equality refines the other, so neither meaning is a quotient or a fibre
of the other, and design §3's fibration is not available. The module header says the same at
`Agentic/Meaning.lean:29-38`. Two further facts are recorded in the same passage and are worth
keeping because they are the *history* of the claim: the second obstruction once had a **bad**
witness — `gateT true` against `scopeT unit`, "same matrix, different `WEq` class" — which was an
artefact of the fine keying, and the coarsening dissolved it (both pairs are now equal on both
sides, `WEqR_gateT_true` `:2086`, `Workflow.of_gateT_true` `:2634`). What replaced it is not an
artefact at all. **What would change the verdict**, stated exactly: a site-aware carrier — the free
semimodule on `Key` — or a separate consultation-multiset fold whose value is then charged. Either
would let the quantitative fold see which sites a term consults, which is the precondition for
charging §6a's quantitative half ("share costs one, dup costs two") and therefore for a `π` in that
direction. Neither was built. Until one is, **the quantitative layer over-charges sharing by
exactly the number of extra reads** (`Agentic/Meaning.lean:71-84`).

### 2.4 The sharing defect, machine-checked

`Agentic/Meaning.lean:1306`, proved `⟨rfl, rfl⟩`:

```lean
theorem muExt_shareT_label_collision (ε : Env (Key Nat) Nat) :
    Term.muExt (askRunner ε)
        (Term.shareT (G := LastOpt Unit) (0 : Nat)
          (Term.parT (Term.prim AskOp.ask) (Term.pureT (fun s : String => s))))
        LastOpt.unset Key.root ("a", "b")
        = some (ε (.rel 0 [Step.parL]), "b")
      ∧ Term.muExt (askRunner ε)
        (Term.shareT (G := LastOpt Unit) (0 : Nat)
          (Term.parT (Term.prim AskOp.ask) (Term.pureT (fun s : String => s ++ "!"))))
        LastOpt.unset Key.root ("a", "b")
        = some (ε (.rel 0 [Step.parL]), "b!")
```

**What it means.** Two terms share the label `0`, differ in their bodies, and **both consult the
answer sheet at the single key `Key.rel 0 [parL]`** — for every `ε`. `Agentic/Term.lean:190-201`
promises sharing on same-label *and* same-body; the fold, `muExt_shareT` at
`Agentic/Meaning.lean:941`, delivers only same-label:

```lean
theorem muExt_shareT {f : Frag} {i o : Type} (l : L) (t : Term Op G L f i o)
    (g : G) (k : Key L) :
    muExt run (.shareT l t) g k = muExt run t g (Key.rebase l) := rfl
```

The rebased key is `Key.rel l []`, and it records **neither the body nor the scope**. Two
consequences, both stated at `:921-940`. *Label collision is not detected*: one label over two
different bodies silently correlates two consultations the designer wrote as distinct, and nothing
in the fold can notice, since `L` is not even required to have decidable equality. *Sharing is
scope-blind*: the same label under two different `scopeT`s rebases identically, and only the
runner's own use of its `G` argument can keep those consultations apart. **This is not a soundness
bug in the fold** — it is the cost of keying by label with no well-formedness condition tying a
label to a body. Body agreement is the designer's obligation, not a checked property. Making it
checkable is `acat-bmc`, and the options recorded there are: key by `(label, body-hash)`, demand
`DecidableEq` on a term skeleton, or restrict to let-bound sharing. **This is the one place the
syntax was still silent when the stratum was retired.**

### 2.5 The coarsening is strict

`Agentic/Meaning.lean:2456`:

```lean
theorem WEqR_strictly_coarser :
    WEqR (Op := AskOp) (G := LastOpt Unit) (L := Nat)
        (.gateT true (.prim AskOp.ask)) (.prim AskOp.ask)
      ∧ ¬ WEq (Op := AskOp) (G := LastOpt Unit) (L := Nat)
        (.gateT true (.prim AskOp.ask)) (.prim AskOp.ask)
```

**What it means.** `WEq ⊂ WEqR`, with this pair in the difference: an open gate over a consulting
leaf is `WEqR`-equal to the leaf and *not* `WEq`-equal to it, because a world that answers
differently under a `gate` step tells the two apart at a fixed key. So the coarsening is a genuine
coarsening and not a renaming — it identifies strictly more — which together with
`WEqR_dupPair_ne_sharedPair` (§2.2) fixes it from both sides: it buys the category's laws and it
still refuses to identify sharing with duplication. A coarsening that erased that would have been
the wrong coarsening, however many laws it bought.

### 2.6 Width against grade: the honest negative

`Agentic/Meaning.lean:1636`:

```lean
theorem peak_not_le_grade (q : Op String Nat) :
    ¬ ∀ {f : Frag} {i o : Type} (t : Term Op G L f i o), peak t ≤ f
```

**What it means.** The bound the grade index was assumed to deliver is **false**. `peak`
(`Agentic/Meaning.lean:1436`) counts *consultation sites in flight* — `prim` is one, `pureT` is
none, `seqT`/`sumT`/`choiceT` take the larger of their children, `parT` adds, `fanT n` multiplies
by `n`, a shut gate is `0`, annotations change nothing, `bindT` is `⊤` — and both directions of
comparison with the grade fail. The counterexamples are the package's own memorialized pair, at
`:1617`, `:1624` and `:1606`:

```lean
theorem peak_dupPair (q : Op String Nat) : peak (dupPair (G := G) (L := L) q) = 2

theorem grade_dupPair (q : Op String Nat) : grade (dupPair (G := G) (L := L) q) = 0 := rfl

theorem peak_lt_grade_fanT_pureT :
    peak (Op := Op) (G := G) (L := L) (.fanT 7 (.pureT (fun s : String => s)))
      < grade (Op := Op) (G := G) (L := L)
        (.fanT 7 (.pureT (fun s : String => s)))
```

Two consultations in flight at grade `static`; zero consultations at a claimed width of seven. The
finding is not that a fold is wrong: **a grade measures data-dependent width — copies of a written
shape — and a count of consultations is not below it in either direction.** What the grade *does*
bound is one factor of the count, `Agentic/Meaning.lean:1502`:

```lean
theorem peak_le_writtenSites_mul_copies :
    ∀ {f : Frag} {i o : Type} (t : Term Op G L f i o),
      peak t ≤ writtenSites t * Frag.copies f
```

— consultations in flight is at most consultations *written* times the copies the grade admits —
and it is **tight at both refuting witnesses** and strict at a sequence (`:1645`, `:1654`), so the
inequality cannot be improved to an equality. Read at the fragments, this is the discipline the
grade was supposed to deliver, and it does deliver it once restated: `:1569`
`peak_le_writtenSites_of_static : peak t ≤ writtenSites t`, and `:1578` `peak_le_of_bounded : peak
t ≤ writtenSites t * ((max 1 n : Nat) : ℕ∞)`.

What makes `peak` *semantic* rather than a second arithmetic on syntax is `:1704`:

```lean
theorem muExt_indep_of_peak_eq_zero [Monoid G] (run run' : Runner Op G L) :
    ∀ {f : Frag} {i o : Type} (t : Term Op G L f i o), peak t = 0 →
      ∀ (g : G) (k : Key L), muExt run t g k = muExt run' t g k
```

— a term of peak zero means the same thing in every world — and the grade conspicuously lacks the
property, `:1796`:

```lean
theorem grade_zero_not_indep :
    Term.grade (Term.prim (Op := AskOp) (G := LastOpt Unit) (L := Nat) AskOp.ask) = 0
      ∧ Term.muExt (askRunner (G := LastOpt Unit) (L := Nat) (fun _ => 0))
            (Term.prim AskOp.ask) LastOpt.unset Key.root ""
          ≠ Term.muExt (askRunner (G := LastOpt Unit) (L := Nat) (fun _ => 1))
            (Term.prim AskOp.ask) LastOpt.unset Key.root ""
```

A number that is `0` on a term that consults is not measuring consultations. **The anchor is
partial and was known to be**: it discharges the `peak = 0` case only, and `parT` concurrent /
`seqT` sequential / `retryT` sequential-across-trips remain *postulated readings* of concurrency
rather than derived ones, because nothing in the stratum has a notion of a run — `muExt` is a
partial function, not a trace (`acat-ti2`).

### 2.7 One fault, two views: sharing's over-charge

`Agentic/Meaning.lean:1673`:

```lean
theorem peak_sharedPair (l : L) (q : Op String Nat) :
    peak (sharedPair (G := G) l q) = 2
```

against `:1809` and `:1817`:

```lean
theorem muExt_sharedPair_one_key (ε : Env (Key Nat) Nat) (a b : String) :
    Term.muExt (askRunner ε) (Term.sharedPair (G := LastOpt Unit) (0 : Nat) AskOp.ask)
        LastOpt.unset Key.root (a, b)
      = some (ε (.rel 0 []), ε (.rel 0 [])) := rfl

theorem muExt_dupPair_two_keys (ε : Env (Key Nat) Nat) (a b : String) :
    Term.muExt (askRunner ε) (Term.dupPair (G := LastOpt Unit) (L := Nat) AskOp.ask)
        LastOpt.unset Key.root (a, b)
      = some (ε (.abs [Step.parL]), ε (.abs [Step.parR])) := rfl
```

**What it means.** The labelled pair peaks at two exactly as the duplicated one does, because `peak`
counts *occurrences* in flight and both occurrences are in flight — yet the run of the shared pair
touches **one** key and the duplicated pair touches **two**. On the reading of §6a where "share
costs one", `peak` over-counts the shared pair by exactly the number of extra reads, which is the
same over-charge `muS` makes at `shareT` (§2.2), reached from the other side. **One fault, two
views.** The count is left at occurrences *deliberately*: merging sites means comparing labels, and
nothing in the package requires `DecidableEq L`, so a distinct-key width needs either that
hypothesis or a set-valued fold — a different fold with a different meaning, not a different
computation of the same one.

### 2.8 The `sumT` bias: symmetric quantitatively, leftmost extensionally

`Agentic/Meaning.lean:234` against `:898`:

```lean
theorem muS_sumT {f g' : Frag} {i o : Type}
    (t : Term Op G L f i o) (u : Term Op G L g' i o) (g : G) :
    muS interp (.sumT t u) g = Mat.matAdd (muS interp t g) (muS interp u g) := rfl

theorem muExt_sumT {f g' : Frag} {i o : Type}
    (t : Term Op G L f i o) (u : Term Op G L g' i o) (g : G) (k : Key L) (a : i) :
    muExt run (.sumT t u) g k a
      = (muExt run t g (k.push .sumL) a).orElse
          (fun _ => muExt run u g (k.push .sumR) a) := rfl
```

**What it means.** Alternation is **symmetric** in the quantitative meaning — `Mat.matAdd` is
commutative (`Agentic/Matrix.lean:427`, `matAdd_comm`) — and **leftmost-defined** in the extensional
one, since `Option.orElse` takes the first branch that answers. One constructor, two folds, two
incompatible readings of what an alternative *is*: a weighted sum of ways to arrive, or a
prioritized fallback. The consequence is visible in §2.1, where the leftmost bias is exactly what
makes `w ⊕ w` extensionally equal to `w` and thereby forces `1 + 1 = 1` on any carrier that
respects extensional equality — so the bias is not cosmetic, it is the mechanism of the counting
obstruction. `acat-frb` asks for the honest reconciliation and names three candidates: a relational
extensional layer, a choice function, or priority written into the syntax. None was chosen.

### 2.9 The `muExt_parT` left-short-circuit obstruction

`Agentic/Meaning.lean:890-895`:

```lean
theorem muExt_parT {f g' : Frag} {i j k' l : Type}
    (t : Term Op G L f i j) (u : Term Op G L g' k' l) (g : G) (k : Key L)
    (p : i × k') :
    muExt run (.parT t u) g k p
      = (muExt run t g (k.push .parL) p.1).bind fun b =>
          (muExt run u g (k.push .parR) p.2).map fun d => (b, d) := rfl
```

with the docstring's own statement of the defect (`:883-889`):

> `Mat.kron` is symmetric in the weight it assigns the two branches: neither factor can prevent the
> other from contributing. The `Option`-bind here cannot be, because a deterministic partial fold
> has to sequence two effects and the design supplies no way to run them independently — so when
> the left branch refuses, the right branch's consultation does not happen at all, and the two folds
> disagree about which sites a refusing tensor visits. This is one of the recorded obstructions to a
> `π` relating the two meanings (acat-qtv).

**What it means.** The tensor is supposed to be a *juxtaposition* — both branches run, neither
governs the other. Quantitatively it is, because `Mat.kron` is symmetric. Extensionally it is not:
`Option`'s bind sequences, so a refusing left branch **erases the right branch's consultation
entirely**, and the two meanings then disagree about which sites a refusing tensor visits. This is a
latent obstruction rather than an outright one — it does not have its own separating theorem — and
it was recorded to be stated when the `π` was attempted, which never happened.

### 2.10 Other recorded obstructions and deliberate deferrals

Gathered from the module docstrings, since each is a decision a reader would otherwise have to
reconstruct.

- **The syntax realizes eight of the design's thirteen rows; five rows have no constructor**
  (`Agentic/Meaning.lean:155-171`). *Identity*: there is no `idT`, so the Category row's unit is
  never taken — `Mat.pointMat_id` proves `pointMat id = idMat` and nothing in the fold connects to
  it. *The additive zero*: `sumT` adds, but there is no `zeroT` denoting `Mat.zeroMat`, so the
  additive monoid's unit is missing from the syntax (`acat-1xo` — the cheapest gap in the stratum).
  *Panel and convolution*: `parT` is binary juxtaposition only; §5.1's n-ary panel with its reducer
  monoid and convolution fan-in has no constructor (`acat-x9v`), so §1.5's algebra was never
  reachable from a written term. *Comonad / fork*: no `pinT` or `forkT`, so `Env.pin` and
  `Trace.deriv` are semantics with no syntax above them (`acat-vgz`). *The lax-monoidal
  inequality*: §4's `⟦f ⊗ g⟧ ≤ ⟦f⟧ ⊗ ⟦g⟧` is an ordering statement and the fold has no order on it
  at all — `muS_parT` is an equality, so the lax structure map is not witnessed here, it is absent.
- **`shareT` under `retryT`/`fanT` is deliberately conservative and deliberately unresolved**
  (`Agentic/Meaning.lean:430-438`). The site key carries a trip index and a fan index, so a
  labelled body run three times is three sites: sharing means *the same site across two written
  occurrences*, not *ask once across trips*. Whether a labelled body should instead be asked once
  across trips is "left open deliberately and is acat-0vv's decision to make".
- **There is deliberately no `share` step in the path alphabet** (`:440-444`): `shareT` replaces the
  base rather than extending the path, so a step for it would be dead syntax no key could contain.
- **`bindL`/`bindR` are two steps on purpose** (`:445-449`): with one step, the two continuations of
  `bindT (bindT w k₁) k₂` would collide on one key — two distinct consultations reading one answer,
  the exact silent correlation the design refuses.
- **`shareT` nesting is unspecified** (`acat-d1t`). `shareT l (shareT l' t)` has no stated rule.
  `Agentic/Scope.lean` sets the precedent — innermost-wins is *proved*, not interpreted — and the
  analogue was owed at the fold and never paid.
- **No weakening constructor, and the substitute violates its own rationale**
  (`Agentic/Term.lean:92-100`, `:288-298`). `sub : f ≤ g → Term f i o → Term g i o` is refused on
  principle: grades are exact by construction, and a weakening constructor would put a second term
  with the same meaning into the syntax and make every fold prove it respects the relabelling.
  `Term.toMonadic` exists as a derived stand-in for heterogeneous planners — and the review found
  that it relabels via an opaque `bindT`, so it is inexact, `PUnit`-only, and blinds every fold. The
  honest replacement is a structural `≤` fold or a grade-existential continuation (`acat-ejy`).
- **The grade's `ℕ∞` collapse cost exactly one thing, written down** (`Agentic/Term.lean:431-443`).
  On *literal* grades — every written workflow — the indices still reduce by `rfl`. On a *variable*
  grade, `static + f = f` is `zero_add` and `static ⊔ f = f` is `bot_sup_eq`: propositional, not
  definitional, so one smoke example carries an explicit `castGrade` and one quotient law carries
  one extra `▸`. That is the whole of the price paid for deleting a private arithmetic, a private
  order, and the laws of both.
- **`fanT` fusion holds only laxly** (`acat-pjg`): `scale n (scale 0 f) = bounded n` while `scale
  (n*0) f = bounded 0`, so any future fusion or normalization rule holds as `scale (n*m) f ≤ scale n
  (scale m f)` and **not** as an equality. Recorded before a normalization pass could assume it.
- **The panel's algebra claims exactly what it proves, and no more** (`Agentic/Panel.lean:44-49`).
  `conv_delta_idem` — a certain member convolved with itself is that member — needs
  `Std.IdempotentOp` at the key monoid's `*`; `msAdd_idem` needs `IdemSemiring S`. **No general
  `conv f f = f` is claimed, because none is true.** Likewise the converse of `conv_comm` is shown
  at one carrier only; the generic statement needs a nontriviality fence and delta injectivity
  (`acat-ab7`).
- **`Env.cachedAt` is a tautology and was known to be** (`Agentic/Env.lean:252`): `cachedAt := f`,
  so `cached_eq : cachedAt f = f` is `rfl` — a true statement about the identity function and not
  about caching. The non-vacuous statement would be a first-consult/replay construction proved equal
  to `f`, connecting to `share_eq_dup_of_agree` (`acat-bf8`).
- **The `Context` stratum's interior operator sits on a lawless `LE`** (`acat-npb`): `Interior.id`
  must take reflexivity as an argument, `Interior` is never applied to `Ctx`, and the design's third
  collapse consequence — finite-dimensionality in the prompt — was silently replaced rather than
  proved.
- **Six survivor claims, across five modules, were audited against Mathlib and stated exactly**, which is why the
  mathematics could be re-derived rather than re-invented. `Agentic/Semiring.lean:87`: Mathlib has
  no class for a semiring with an arbitrary-index sum — `tsum` is a topological limit, `iSup` forces
  an idempotent `+`. `Agentic/Semiring.lean:317`: Mathlib's only star-with-laws on a semiring is
  `KleeneAlgebra`, which demands an idempotent `+`, and the expectation semiring has a star and does
  not have one. `Agentic/Matrix.lean:29`: Mathlib's `Matrix m n α` *is* this type on the nose — what
  is missing is the multiplication, which needs `Fintype m` and sums with `Finset.sum`, and these
  matrices are over arbitrary index types. `Agentic/Panel.lean:108`: `MonoidAlgebra` demands finite
  support, which a panel weighting never has. `Agentic/Monoid.lean:56`: Mathlib has the join, its
  unit and the unbundled laws, but nowhere a `Monoid` whose `*` is `⊔`. `Agentic/Scope.lean:59` (line 74 in the post-excision tree — Scope survives and grew):
  Mathlib has `WithOne` but no right-zero semigroup to feed it, so the last-wins monoid has no
  Mathlib route. Each closes with the same sentence: should Mathlib gain the construction, the
  module **becomes a transport**.

---

## 3. The six theory threads

Each is a direction the results opened. Two sentences each: what it would take, and what it would
buy.

**1. Site identity — what a label *is*.** It would take a well-formedness condition tying a label to
a body (a body hash, a `DecidableEq` on a term skeleton, or a let-bound restriction), a stated rule
for nested labels, and a decision on whether a label under iteration shares across trips or per
trip. It would buy the elimination of the one silent-correlation hazard the stratum could not close
(§2.4) — the difference between a sharing discipline a designer must respect and one the elaborator
enforces — and it is the prerequisite for every other thread that names a site, including footprints
and pinning.

**2. The two meanings — a `π` in one direction.** It would take a site-aware quantitative carrier —
the free semimodule on `Key`, or a separate consultation-multiset fold mirroring `muExt`'s control
flow, whose value is then charged — plus the resolution of the `parT` short-circuit (§2.9) and the
`sumT` bias (§2.8). It would buy the fibration design §3 wanted: one meaning over the other rather
than two beside each other, the quantitative charge for sharing that §6a demands, and the end of the
over-charge that `muS` and `peak` both make from opposite sides.

**3. Syntax catching up with semantics.** It would take five constructors the fold already has rows
for or the algebra already has laws for — `zeroT` (the additive unit), `panelT` (n-ary, carrying its
reducer monoid and stating its own site-identity rule, since a panel of `n` members has `n` sites),
`caseT` (k-ary verdict branching, not nested binary `Sum`s), `pinT`/`forkT` (above `Env.pin` and the
Brzozowski derivative), and `raceT` (first-past-the-post over idempotent reducers) — together with
a grant-lattice `gateT` in place of the hard-wired `Bool`. It would buy the rest of the design's §4
table becoming *reachable from a written term*, which is the difference between a semantics that
models the domain and a language that expresses it.

**4. Atkey context-indexing.** It would take re-indexing the syntax as `Term k k' f i o`, composing
when the indices meet, with compaction as a morphism in the index category — an interior operator
whose loss is visible in exactly one factor. It would buy the removal of the design's most
consequential omission-by-default: the current syntax hard-codes the collapse `κ = const ε` (fresh
context per turn) *by having no context index at all*, and that single unstated choice is what makes
the parameterised monad ordinary, each leaf's matrix history-free, and content-addressed caching
sound — the absence of first-class multi-turn context and the soundness of caching are one decision,
currently taken silently.

**5. Ordered carriers and leastness.** It would take a resource-semiring class with monotone `+`,
`*` and `csum` — an ordered carrier stated once rather than per-carrier — and then the leastness
statements the star currently makes only at `Cost`. It would buy `starTrunc ≤ star` and every fuel
bound stated once per ordered carrier instead of once per carrier that happens to have an order, and
it would make leastness at expectation *statable at all*: the squared-zero construction has a star
and no order, so at present the claim cannot even be written down.

**6. Mathlib adoption as policy, not accident.** It would take declaring the instances the stratum
proved but withheld (a commutative semiring on the monoid semiring under a commutative key monoid; an
idempotent-addition instance; the semimodule laws for scalar action on panels), each as a deliberate
second-structure-on-one-carrier decision rather than a drive-by, plus the classical Kleene identities
that `KleeneStar` makes theorems rather than assumptions. It would buy the transport clause at the
bottom of every survivor docstring turning from a promise into an action — each in-tree construction
retired the moment Mathlib carries it — which is the only discipline that keeps a formalization from
slowly becoming a private library.

---

## 4. The ticket graveyard

Thirty tracker items closed by the excision. Each names what it asked and why it dies with the
stratum. None is refuted; each is *unreachable* — its subject is the retired code.

| Ticket | What it asked | Why it closes |
|---|---|---|
| `acat-qtv` | A `π` relating `muS` and `muExt` over the coarsened quotient; needs the edge measure and the `parT` short-circuit recorded as a latent obstruction. | Both folds retired. The obstruction is preserved in §2.1–2.3, §2.9. |
| `acat-bmc` | Fix `shareT`'s label collision across unequal bodies: key by leaf datum, demand syntactically equal bodies, or accept designer-declared identity. | `shareT` and `Key.rebase` retired. The defect is machine-checked in §2.4 and survives as thread 1. |
| `acat-0vv` | Decide `shareT` under `retryT`/`fanT`: fold the trip and fan indices into the key, or declare ask-once-reuse the intended combinator. | The site key and its `retry`/`fan` steps are retired; the open decision is recorded in §2.10. |
| `acat-ti2` | Generalize the `peak` semantic anchor beyond `peak = 0`; a per-run trace of consulted sites with `|in flight| ≤ peak` is the real anchor. | `peak` retired. The partiality of the anchor and the postulated concurrency readings are recorded in §2.6. |
| `acat-frb` | Reconcile `sumT`'s symmetric quantitative meaning with its leftmost-defined extensional one: relational layer, choice function, or priority in the syntax. | `sumT` retired. The fault and the three candidate repairs are recorded in §2.8. |
| `acat-41c` | Atkey-parameterise `Term` with the context index; `Term` hard-codes the `const ε` collapse by omission. | `Term` retired. The diagnosis becomes thread 4. |
| `acat-vgz` | `pinT`/`forkT`: syntax above `Env.pin` and the Brzozowski derivative, naming sites with the same `L` rather than a fresh scheme. | The syntax it would extend and the semantics it would sit above are both retired. |
| `acat-x9v` | `panelT`: the n-ary panel as a primitive carrying the reducer key monoid, with fan-in as the augmentation homomorphism, stating its own `n`-sites rule. | `Term` and `Panel`'s convolution both retired; §1.5 records the algebra that had no syntax. |
| `acat-w7l` | Footprints on `Op` or `parT` plus disjointness-licensed exchange, feeding the Mazurkiewicz independence relation, so the lax-monoidal row's equality half is statable. | `parT`, `Trace` and the independence relation all retired; `Trace.ind` never had a producer. |
| `acat-3tu` | Extend `WEqR` congruence beyond the 6-of-12 sub-algebra: n-ary `Key.splice` for `retryT`/`fanT`, a uniform relabelling for `bindT`, a labelled-base layer for `shareT`. | The quotient is retired; §1.4 records exactly how far it got and why the remaining three are each a different problem. |
| `acat-jmm` | An ordered-carrier class: resource semiring with monotone `+`, `*`, `csum`, so fuel bounds and `truncation ≤ star` are stated once. | Its consumers (`Mat.CostBounded`, `starTrunc_le_star`) retire with the matrix and star layers. Becomes thread 5. |
| `acat-yad` | `Pareto`: n-ary axes, strict dominance, the frontier, and a tie to `Cost`; currently binary and disconnected. | `Pareto.lean` retires with no consumer; the promised frontier was never defined. |
| `acat-3ov` | Leastness at expectation: the squared-zero star has no order, and the derived idempotent-addition instance may make leastness provable. | Blocked on `acat-jmm`, whose carrier retires. Becomes thread 5. |
| `acat-od5` | The weighted convolution fold: a general `List (MSemiring S K) → MSemiring S K` reducer with permutation invariance, plus §5.1's necessity claims formalized. | `convFold` handles certain members only, and the syntax it was prerequisite for (`acat-x9v`) retires too. |
| `acat-nka` | `msSmul` semimodule laws, so panels compose with gating. | Only `total_msSmul` existed; `MSemiring` and `Gate` both retire. |
| `acat-gl8` | Declare the commutative-semiring and idempotent-addition instances on `MSemiring`, deliberately — a second semiring structure on one carrier. | The carrier retires. The deliberate-diamond question becomes thread 6. |
| `acat-135` | Drop `Session`'s unused complete-semiring constraint; add the trace-monoid product (convolution at `K := Trace ind`). | Both `Session` and `Trace` retire. |
| `acat-ab7` | The `conv_comm` converse: needs a nontriviality fence and delta injectivity, then `conv_comm ↔ CommMonoid K`. | `conv` retires. The scope of what *is* proved is recorded in §2.10. |
| `acat-80z` | Record the finite-index aggregation law (`csum` over `Fin n` / lists) as derivable from `csum_pair` and `csum_zero`, before it is rediscovered. | Wanted only by a future n-ary-panel-equals-fold theorem, which retires with the panel. |
| `acat-ejy` | A weakening fold `Term f → Term g` for `f ≤ g`, and the deletion of `toMonadic`, which violates the no-weakening rationale it sits under. | `Term` retires. The rationale and the finding against `toMonadic` are recorded in §2.10. |
| `acat-qx8` | `caseT`: k-ary verdict branching over a finite type, plus §5.1's lens-by-backend grid, in place of nested binary `Sum`s. | `choiceT` retires; the shape survives as thread 3. |
| `acat-ylz` | `raceT`/`unamb`: first-past-the-post over reducers monotone in the information order. | Unblocked only by the idempotent-reducer witness in `Keys`, which retires. |
| `acat-755` | Generalize `gateT` from `Bool` to a grant lattice acting through `{0,1}`, with nested grants intersecting in the lattice. | `gateT` retires. `scopeT` was already parameterised; the asymmetry dies with both. |
| `acat-1xo` | `zeroT`: the additive unit, with `⟦0⟧ = 0`; `sumT` has no unit and refusal is expressible only as `gateT false t`. | The cheapest gap in the stratum, never taken. Recorded in §2.10 as one of the five unrealized §4 rows. |
| `acat-npb` | `Context` repair: a `Preorder` class, connect `Interior` to `Ctx`, restore the design's third collapse consequence. | `Context.lean` retires with no consumer. The unfixed lawlessness is recorded in §2.10; the ambition becomes thread 4. |
| `acat-bf8` | Give `cachedAt` content: a first-consult/replay construction proved equal to `f`, in place of a tautology about the identity function. | `Env`'s `Ext` stratum retires. The vacuity is recorded in §2.10. |
| `acat-d1t` | Prove the `shareT` nesting rule — innermost, outermost, or compose — as a theorem, following `Scope`'s precedent. | `shareT` retires. Recorded in §2.10; the question becomes part of thread 1. |
| `acat-n8m` | Prove the classical Kleene identities — sliding, denesting, `(a+b)*` — now that the star class makes them theorems rather than assumptions. | Narrowed at the 2026-08-20 triage: most siblings are already free from Mathlib's Kleene algebra, three are genuinely unproved, and none has a consumer. Becomes thread 6. |
| `acat-5ly` | Two residues: prune unconsumed `deriving DecidableEq` clauses, and re-home `Cost.add_mono`. | The deriving half was already done by the migration; the one live line's right home was `acat-jmm`, which also retires. |
| `acat-pjg` | Record that `fanT` fusion holds only laxly after the zero-fan repair, before a normalization pass assumes equality. | `fanT` and `Frag.scale` retire. The lax inequality is recorded in §2.10. |

---

## 5. Where the living descendants are

A reader should not mistake this retirement for a loss of capability. The mathematics that earned its
place was re-derived into `Agentic/Core/**`, and it is *product* there — certified, exercised by the
Haskell implementation, and held byte-identical by 189 conformance vectors.

**The initial algebra, spent rather than stated.** The `Term` stratum's twelve-constructor
inductions were twelve separate structural recursions, each justified by its own induction. The
descendant is `Agentic/Core/Alg.lean`: `Plan`'s five formers are a signature, `PlanAlg` is that
signature's algebra, `PlanAlg.fold` is the induced homomorphism, and `PlanAlg.fold_unique` is
initiality — the fold is the *only* homomorphism. **Eleven of the twelve structural recursions in
the package now *are* `PlanAlg.fold` at an algebra, by definition and not up to a proved equation**:
substitution, `under`, grafting, `denote`, `level`, `codes`, `shapes`, `asks`, `size`, `askNodes`,
`explain`. Each keeps its five defining equations as named theorems proved by `rfl`, so every proof
that used to unfold a recursion still says exactly what it said; what has gone is eleven recursions
and eleven inductions. The twelfth, `Cost.costM`, does not fit and is documented as not fitting —
its signature absorbs the level bound, and an algebra carrier may not mention the term. **This is
the abstraction the `Term` stratum's twelve-constructor folds were groping toward and never found.**

**The verdict monoid — the panel, delivered.** §1.5's convolution algebra never had a syntax to
denote. Its descendant is smaller, total, and shipping: `Verdict := WithZero (FreeMonoid Objection)`
(`Agentic/Core/Question.lean:112`) — the free monoid on objections with an absorbing element for
refusal, carrying Mathlib's `MonoidWithZero` rather than a private structure. Refusal annihilates
(`declined_mul`, `mul_declined`), approval is the unit `1` (`approve_mul`, `mul_approve`), and
`Approved` is a monoid morphism to conjunction — `approved_mul` at `:201` and `approved_prod` at
`:213`, whose docstring names the point exactly: conjunction is commutative where the verdict monoid
is not, **and that gap is the whole of the licence a scheduler has**. `Plan.panel`
(`Agentic/Core/Plan.lean:979`) is then a fold with that monoid — `panel [] = .ret (fun _ => 1)` and
`panel (p :: ps) = zipWith (· * ·) p (panel ps)`, `panel_nil` and `panel_cons`, both `rfl` at `:983`
and `:986` — so a panel of
verdicts reduces with the monoid the type already
has, and what survives reordering is exactly what the morphism says survives.

**The Haskell operational twin.** `haskell/src/Agentic/Plan.hs` carries the same monoid as ordinary
code — `verdictApprove`, `verdictDeclined`, `verdictObject`, `verdictMul` at `:243`, each citing its
Lean site — and `panel` at `:722` is `foldr (zipWithP verdictMul) (PRet (exprConst
verdictApprove))`: the Lean fold, transliterated. `panelText` at `:750` does the same for text
parts. The DSL admits panels as first-class surface syntax with their rung computed by the same fold
(`Agentic/Core/Dsl.lean:95`, `:105`: a panel is at the join of its members' rungs, proved by
induction over the fold). So the panel that §1.5 could only denote and §2.10 records as having no
constructor **exists as a language construct, a certified fold, and running code** — just not as
convolution over an arbitrary key monoid, because nothing the product does needs that generality.

**And the one import.** `Agentic/Core/Question.lean:1` imports `Agentic.Scope` — the last-wins
scope monoid, with innermost-wins as a proved theorem rather than an interpreter rule. It is the
single line of the old tree that the certified spine still reads, and it is exactly the piece the
old tree's own survivor audit had flagged as something Mathlib does not carry.
