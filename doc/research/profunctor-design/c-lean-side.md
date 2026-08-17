# C — The Lean side: what profunctors buy the formalization

**Scope.** What a profunctor-flavoured layer would buy `Agentic/Core/*.lean`,
priced against Mathlib as it actually exists at `leanprover/lean4:v4.30.0` /
`mathlib4 @ v4.30.0` (the pin in `lean-toolchain` and `lake-manifest.json`).
Every Mathlib namespace named below was read from
`.lake/packages/mathlib/Mathlib/…` in this checkout, not from memory.

**Method note, and the reason to trust the numbers.** Everything in §6 and §7
marked ✅ was elaborated against the built package with
`lake env lean <probe>.lean` (warm `.lake/build`, 1.2 GB of oleans). The probe
source is in `c-lean-side-probes.lean` beside this page — 421 lines, 30
declarations, warning-free — and it imports nothing that `Agentic/Core/` does
not already import. Claims I did *not* compile are marked ⚠️ and say so. Nothing
in the package was modified: the probe file sits in `doc/`, which is in no
`lean_lib` glob and no `srcDir`, so `lake build` cannot see it.

**Bottom line, up front.**

| | verdict |
|---|---|
| **Light version** — `Plan` as a lawful bifunctor, the analyses as one algebra + fusion, `Dlg` as a lax monoidal functor, all in the package's own vocabulary | **Do it.** ~490 lines net new, of which the 30 declarations in `c-lean-side-probes.lean` already elaborate, warning-free. It collapses 11 of the 12 structural recursions over `Plan` into one fold, retires six five-case inductions outright (two ✅ compiled: `run_panel`, `trace_panel`; four argued: `codes_isSome_of_le_pipeline`, `codes_eq_of_le_pipeline`, `level_sub`, `level_under`), reorganises the 29 `level ≤ …` theorems as corollaries of six structural ones, and deletes 10 `Plan.Denotes` hypothesis occurrences plus the flagship's four hand-written discharges. Corpus-safe if done additively. Real cost is the 6-minute `DslFlagship` feedback loop, not the proofs. |
| **Full version** — monoids in `Prof`, Tambara modules, the four rungs as free monoids in four monoidal categories, one meta-theorem | **Don't.** Mathlib has `Profunctor` but explicitly *not* its composition; profunctor composition is a coend and Mathlib's coend in `Type` is `Quot`, i.e. built from exactly the material `Plan.case`'s `FinEnum` note refuses. And the tower is a statement about four hypothetical term languages, not about the one inductive `Plan` — making it bite requires the graded-index design the package already compiled and refuted (`D_graded_index_fails.lean`). 3,000–6,000 lines, 3–6 months, zero theorems gained. |
| **Two most valuable new theorems** | (1) the **`Cont`–Yoneda equivalence** — `Plan (c :: Γ) B ≅ {k : Cont Γ (El c) B // Natural k}`, which deletes the higher-rank `Cont` from every author-facing signature, repairs `Morphism.sub_graft_not_natural`, and turns `Plan.Denotes` from a hypothesis into a lemma; (2) the **fold-fusion law** for `Expr`-blind and projection-composed algebras, which gives `codes = Shape.code <$> shapes`, `shapes = Key.shape <$> asks`, `leaves ∘ costTree = costMultiset`, and the four missing `sub`/`under`-invariance lemmas, from one induction. Both skeletons compile. |

---

## 1. Inventory: what is already there

### 1.1 The two functorial actions of `Plan`

`Plan.lean` says, in a section header, "`Plan` is a presheaf on contexts". That
is true but the orientation deserves nailing down, because the seed brief and
the docstring point opposite ways and a CT reader will stop on it.

Define two categories:

- **E** — objects `Ctx`, `Hom_E Γ Δ := Env Γ → Env Δ`. *Environment maps.*
- **C** := **E**ᵒᵖ — objects `Ctx`, `Hom_C Γ Δ := Sub Γ Δ = Env Δ → Env Γ`
  (`Plan.lean:169`), identity `Sub.id`, composition `Sub.comp`.

`Sub` is *already* the opposite. `Sub.id_comp`, `Sub.comp_id` (`:194`, `:197`)
and `Sub.comp_assoc` (`:200`) are all `rfl`, so **C** is a Mathlib
`Category.{0,0}` verbatim — 10 lines, every law `rfl` (✅ probe `ctxCat`). And
`Plan.sub_comp : sub (sub p σ) τ = sub p (Sub.comp σ τ)` (`:328`) is
`F(σ ≫ τ) = F(τ) ∘ F(σ)`, so:

> `Plan (−) A : C ⥤ Type 1` is a **covariant** functor on C = presheaf on E.

In Mathlib's own convention — `Profunctor.{w} C D := C ⥤ Dᵒᵖ ⥤ Type w`
(`Mathlib/CategoryTheory/Profunctor/Basic.lean:54`) — `Plan` is a
`Profunctor.{1} (Type 0) E`: covariant in the answer type, contravariant in the
environment. Seed observation 3's "`Ctxᵒᵖ × Type → Type`, `Sub` is the
contravariant action" is right **once you say the base is E, not C**; said of C
it is exactly backwards, since `sub` is C-covariant.

One structural consequence worth recording, because it deletes a whole class of
hoped-for payoff: `Env : C → Typeᵒᵖ` is full and faithful *by definition* (the
Hom-sets are literally the same type), so **C is the full image of `Env` in
`Typeᵒᵖ`**. There is no syntactic site of contexts-and-renamings here. That is
what makes `sub_id`/`sub_comp` cheap, and it is also why there is no
normalisation-by-evaluation, no Yoneda-on-renamings, and no
"presheaf-model-of-syntax" story to import: weakening, exchange, contraction and
arbitrary semantic reindexing are one operation and the package already says so
(`Plan.lean:161–168`).

The covariant leg is the gap. `mapP` (`:432`) is derived from `graft`, and its
functor laws are stated **only up to `≈ᵖ`**, through the denotation:
`Morphism.mapP_id` (`:587`), `Morphism.mapP_comp` (`:593`). They hold *on the
nose*:

```lean
example (p : Plan Γ A) : Plan.mapP id p = p := Morphism.graft_pure p          -- ✅
example : Plan.mapP g (Plan.mapP f p) = Plan.mapP (g ∘ f) p := by            -- ✅
  rw [Plan.mapP, Plan.mapP, Morphism.graft_assoc]; rfl
```

The first is literally `graft_pure`; the second is `graft_assoc` plus `rfl`.
So the syntax already *is* a functor in `A` and the package proves something
weaker than it has. (Not a defect — nobody needed it — but it is the first
thing the bifunctor framing hands back.)

The bifunctor coherence square, `sub (mapP f p) σ = mapP f (sub p σ)`, is
**not** stated anywhere and does not follow from anything present; it follows
from the naturality repair in §1.2 (✅ `sub_mapP`, one line from
`sub_graft_of_natural`).

### 1.2 `Cont`, `graft`, and the one square that fails

`Cont Γ A B := ∀ Δ, Sub Γ Δ → Expr Δ A → Plan Δ B` (`:410`), `Type 1`,
higher-rank. `graft` (`:421`) is substitution into `ret` leaves; the three monad
laws hold **at the syntax, unconditionally** — `Morphism.graft_ret` (`:201`,
`rfl`), `graft_pure` (`:206`), `graft_assoc` (`:227`) — which
`Morphism.lean:218–226` correctly reads as "`Plan`'s sequencing is a genuine
monad structure **relative to `Expr`**".

That phrase has a precise referent the package does not cite: Altenkirch,
Chapman and Uustalu's **relative monads**. `Plan` is a monad relative to
`Expr : C ⥤ Type`, with unit `ret : Expr Γ A → Plan Γ A` and Kleisli extension
`graft`. This is the correct home for `graft` and it is *not* the profunctor
tower.

The fourth expected law fails, and the package compiles the counterexample:
`Morphism.sub_graft_not_natural` (`:324`) exhibits `wobbly : Cont [] Unit Unit`
(`:310`) — a family that asks once per binding in scope — for which
`sub (graft p k) σ ≠ graft (sub p σ) (k ∘ σ)`, distinguishable by transcript
length. `Morphism.lean:294–305` draws the right conclusion ("a `Cont` carries a
coherence obligation") but then discharges it *semantically*: `Plan.Denotes`
(`Denote.lean:212`) is a condition on `denote ∘ k`, not on `k`.

**This is the load-bearing gap.** The obligation is naturality of a
`Type`-valued family, and it can be stated syntactically:

```lean
def Cont.Natural (k : Cont Γ A B) : Prop :=
  ∀ Δ Ξ (τ : Sub Γ Δ) (e : Expr Δ A) (ρ : Sub Δ Ξ),
    Plan.sub (k Δ τ e) ρ = k Ξ (Sub.comp τ ρ) (fun ξ => e (ρ ξ))
```

— which is exactly naturality of `Δ ↦ (Sub Γ Δ × Expr Δ A → Plan Δ B)` in the
C-variable. With it, the failed square closes (✅ `sub_graft_of_natural`, §6.1),
and `Denotes` becomes derivable rather than assumed (§6.1, §7.1).

`Plan.Denotes` currently appears as a hypothesis of **seven theorems**, ten
occurrences: `Denote.denote_graft` (`:230`), `Denote.denotes_revising`
(`:496–497`, two), `Morphism.denote_graft` (`:255`),
`Morphism.denote_graft_assoc` (`:265`, two), `Morphism.run_graft` (`:276`),
`Morphism.trace_graft` (`:287`), `Morphism.denote_revising` (`:463`, two); plus
`Denote.Equiv.graft_congr` (`:695`) which inlines the same condition twice.
And it is *discharged by hand* four times in the 991-line, 75-second flagship
module `HardenPatch.lean` — `denotes_review` (`:295`), `denotes_redraft`
(`:304`), `denotes_finishK` (`:327`), `denotes_bodyK` (`:350`).

### 1.3 The `Level` fold and every theorem with a level hypothesis

`level` (`Level.lean:120`) is a five-clause fold; the five equations are `rfl`.
Four elimination lemmas consume a bound (`level_le_of_askC`, `le_of_ask`,
`le_of_case`, `not_le_of_dyn`, `:151–174`). Two invariance theorems
(`level_sub :190`, `level_under :207`) — `level_sub` is correctly labelled a
naturality statement in its docstring. Then the derived-form bounds:
`level_graft_le :230`, `level_graft_of_batch :259`, `level_mapP :277`,
`level_zipWith_le :283`, `level_seq_le :292`, `level_panel_le :299`,
`level_bindP_ret :311`.

Theorems (and one definition, and one type) carrying a `level p ≤ ℓ`
hypothesis, exhaustively:

| where | count | names |
|---|---|---|
| `Cost.lean` | 19 + 1 def + 1 type | `asks_isSome_of_le_pipeline`, `codes_isSome_of_le_pipeline`, `shapes_isSome_of_le_pipeline`, `asks_eq_of_le_batch`, `asked_multiset_eq_of_le_batch`, `bill_exact_batch`, `codes_eq_of_le_pipeline`, `length_trace_eq_of_le_pipeline`, `shapes_eq_trace_of_le_pipeline`, `shapes_eq_of_le_pipeline`, `bill_indep_of_le_pipeline`, `asks_eq_default`, `bill_exact_pipeline`, `bill_mem_leaves`, `minFold_le_bill`, `bill_le_maxFold`, `exists_min_bill`, `exists_max_bill`, `PlanUpTo.bill_le`; **def** `costTree :668`; **type** `PlanUpTo :996` |
| `Morphism.lean` | 6 | `level_sound_batch`, `level_sound_pipeline`, `level_sound_pipeline_count`, `level_sound_pipeline_shape`, `level_sound_branch`, `level_sound_dynamic` |
| `Explain.lean` | 2 + 2 defs | `Plan.length_trace_eq_askNodes`, `Plan.size_eq_askNodes_succ`; `costSummary`, `leafBills` take `h` |
| `Dsl.lean` | ~14 | a *different* kind: upper bounds on elaborator output (`checkBlock_level_le`, `checkProgram_level_le`, `parseAndCheck_level_le`, …) — "the language cannot write a `dyn`", not analysis availability |

**The boilerplate, counted.** Of the twelve structural recursions over `Plan` in
the package (`sub`, `under`, `graft`, `denote`, `level`, `codes`, `shapes`,
`asks`, `costTree`, `size`, `askNodes`, `explain`), ten are analysis folds, and
their soundness proofs repeat the same two closing moves:
`absurd (le_of_case h).1 (by decide)` — **11 occurrences** — and
`absurd h (by simp only [level_dyn]; decide)` — **11 occurrences**. There are 25
five-case splits over `Plan` across `Plan.lean`, `Denote.lean`, `Level.lean`,
`Cost.lean`, `Explain.lean`, `Morphism.lean`. That is the number the algebra
layer attacks.

### 1.4 The `Cost` analyses, by rung

| analysis | type | `batch` | `pipeline` | `branch` | `dynamic` |
|---|---|---|---|---|---|
| `codes :304` | `→ Option (List Code)` | `some` | `some` | `none` | `none` |
| `shapes :321` | `→ Option (List Shape)` | `some` | `some` | `none` | `none` |
| `asks :336` | `→ Env Γ → Option (List Key)` | `some`, env-free | `some`, env-dependent words | `none` | `none` |
| `asksBill :349` | `→ Option S` | exact, **no price hypothesis** | exact under `PricesByShape` | `none` | `none` |
| `costTree :668` | takes `level p ≤ branch` | `leaf` chain | `leaf` chain | finite tree | *undefined by signature* |
| `billFresh :166` | `Trace → S` | monoid morphism (`billFresh_append :202`) | ″ | ″ | ″ |
| `billMemo :176` | `Trace → S` | **not** a morphism (`billMemo_not_monoid_hom :276`) | ″ | ″ | ″ |

The three targets in play are exactly three algebraic strengths, and this is
where the graded story is genuinely informative — and where the seed brief's
one-line summary is wrong:

- `batch`/`pipeline`: target is `Const M` for a **monoid** `M`
  (`List Code`, `List Shape`, `List Key`, `S`). What breaks at `case` is *not*
  monoidality — `Const M` is perfectly monoidal — it is that `Const M` has no
  way to answer a *choice*: `left'`/`branch` for `Const M` would need one `m`
  for a sum and the honest answer is a bag of them.
- `branch`: the target moves from the monoid `M` to the **monoid semiring**
  `Multiset M` (`·` pointwise, `+` = `Multiset.add`, unit `{1}`). `CostTree S`
  (`:610`) is an intermediate data structure whose *only* observable is
  `leaves : CostTree S → Multiset S` (`:631`); `minFold`, `maxFold` and
  `Multiset.card leaves` are all the report ever asks for
  (`Explain.lean:445–461`). See §7.2.
- `dynamic`: even the semiring target fails, and the reason is *finiteness*, not
  algebra — `no_finite_bill_set_at_dyn` (`:908`) is a **witness**, not a
  parametricity argument. Nothing categorical replaces it. See §2.1.

So the seed's "Const/Forget is monoidal but not compositional, hence cost dies
at dyn" is two errors in one sentence: cost does not die at `dyn`, it dies at
`case` (and is *rescued* by changing the target); and what kills it at `dyn` is
cardinality, not composition.

### 1.5 `Morphism.lean` — what morphism structure is already formalized

Read in full. It is an *audit* module: every operation restated as a commuting
square in `pure`/`>>=`/`<$>`/`<*>` vocabulary, plus three compiled refutations.
Already present, in categorical terms:

- **Five leaf laws** (`denote_ret … denote_dyn`, `:93–122`), all `rfl` —
  `denote` is *defined* as the solved form of the specification.
- **`denote` is a presheaf map**: `denote_sub` (`:138`), i.e. the natural
  transformation `Plan (−) A ⟹ [Env (−), Dlg A]`.
- **`under` is a monoid action on the syntax and on the meaning**:
  `Plan.under_idSig`, `under_under` (`Plan.lean:354, 365`), `denote_under`,
  `run_under`, `trace_under`, `level_under` (`:148–186`). `under_sub`
  (`Plan.lean:390`) is the commutation of the two actions.
- **`denote` is a relative-monad morphism**: `graft_ret` / `graft_pure` /
  `graft_assoc` at the syntax, `denote_graft` / `denote_graft_assoc` at the
  meaning, `run_graft` / `trace_graft` into `Id` and the free monoid.
- **Panels**: `denote_panel` (`:385`) as a `foldr` of the applicative product,
  `run_panel` / `trace_panel` as its two projections, plus the *honest order
  fact* `trace_panel_not_perm_invariant` (`:425`).
- **Congruence for free**, four instances (`under_congr`, `mapP_congr`,
  `zipWith_congr`, `panel_congr`, `:561–582`) — the kernel of a compositional
  meaning.
- **Three refutations**: `sub_graft_not_natural` (`:324`),
  `level_not_equiv_invariant` (`:646`), `plan_not_forcing` (`:688`).

`Morphism.lean` is therefore already the "categorical layer", written by hand in
the package's own vocabulary. What it lacks is not statements but **structure**:
each square is proved separately, nothing is an instance of anything, and the
one square that fails is repaired by a semantic side condition rather than by
the naturality that is actually missing.

### 1.6 The map onto the profunctor story

| existing declaration | categorical statement | already an instance of something? |
|---|---|---|
| `Sub.id_comp`, `comp_id`, `comp_assoc` | **C** is a category | no — would become `instance : Category Ctx`, all laws `rfl` (✅) |
| `Sub.lift_id`, `lift_comp`, `wk_lift` | `c :: (−)` is an endofunctor on C; `wk` is a natural transformation `c :: (−) ⟹ id` | no |
| `Plan.sub_id`, `sub_comp` | `Plan (−) A : C ⥤ Type 1` | no — would become `Functor` |
| `Morphism.mapP_id`, `mapP_comp` (stated ≈ᵖ) | `Plan Γ (−) : Type ⥤ Type 1` | **holds on the nose** — ✅ §1.1; the ≈ᵖ versions are strictly weaker |
| *(missing)* `sub_mapP` | bifunctor coherence | ✅ from `sub_graft_of_natural` |
| `Plan.Denotes` | naturality of `denote ∘ k` | **replaceable**: `Cont.Natural` + `Cont.denotes_ofPlan` (✅ §6.1) |
| `sub_graft_not_natural` | the square fails for non-natural families | ✅ repaired: `sub_graft_of_natural` |
| `graft_ret`/`graft_pure`/`graft_assoc` | `Plan` is a **relative monad** over `Expr` | cite Altenkirch–Chapman–Uustalu; *not* the profunctor tower |
| `level`, `codes`, `shapes`, `asks`, `size`, `askNodes`, `denote`, `sub`, `under`, `explain` | ten algebra homomorphisms out of the initial algebra | ✅ `PlanAlg.fold` + `fold_unique` (§6.2) |
| `level_sub`, `level_under` | `Expr`/`Q`-blind folds are `sub`- and `under`-invariant | ✅ subsumed; four siblings currently *missing* (§7.2) |
| `codes` vs `shapes` vs `asks` | three fusions of one fold | ✅ `codes = Shape.code <$> shapes`, `shapes = Key.shape <$> asks`, both unconditional (§6.3) |
| `billFresh_nil/cons/append` | `billFresh` is `FreeMonoid Event →* S` | would become `MonoidHom`; `map_one`/`map_mul` replace three lemmas |
| `denote_panel`, `run_panel`, `trace_panel`, `flatten_perm` | `Dlg` is lax monoidal; `run ω`, `trace ω` are monoid homs; `panel = List.prod` | ✅ `map_list_prod` replaces two inductions (§6.4) |
| `CostTree` + `leaves` + `minFold`/`maxFold` | a fold into the monoid semiring `Multiset S` | ✅ reasoning; ⚠️ not compiled (§7.2) |
| `no_finite_bill_set_at_dyn`, `no_cost_tree_at_dyn`, `no_static_bill_at_branch` | non-existence witnesses | **irreducible** — no categorical schema replaces these (§2.1) |

---

## 2. Which seed observations survive

### 2.1 Seed 1 — the level lattice *is* the idiom/arrow/monad hierarchy

**Largely correct as a reading; wrong as a proof strategy.**

Correct, and worth writing into the docs because it names the design's ancestry:

- `batch` — only `askC` and `ret`. A batch plan is a fixed sequence of *closed*
  questions and a pure function of all the answers, i.e. exactly a normal form
  of the **free applicative** over the question functor
  `F X = Σ c, Q c × (El c → X)` (McBride–Paterson; Capriotti–Kaposi).
  `level_askC` returning `level k` unchanged (`Level.lean:131`) is the statement
  that the applicative rung is free.
- `pipeline` — `ask` lets the *words* depend on earlier answers while the
  addressee, scope and draw stay term-level data. That is precisely a **free
  arrow / free Freyd category** over the effect signature: the growing context
  is `first`, `Sub.lift` is the strength, and the number and shape of steps are
  fixed. Atkey's "What is a categorical model of arrows?" and
  Jacobs–Heunen–Hasuo are the right references; Asada's "Arrows are strong
  monads" is the profunctor-side reading.
- `branch` — `case` at a `FinEnum` tag is `Selective.branch` restricted to
  *finite* tag types, which is what makes the cost object a finite tree. Mokhov
  et al., *Selective Applicative Functors*, is the exact citation and places the
  class between `Applicative` and `Monad`.
- `dynamic` — `dyn` is `ArrowApply`, and `ArrowApply ≅ Monad` is Hughes 2000.
- The whole grading is the same discovery as **Build systems à la carte**
  (Mokhov–Mitchell–Peyton Jones): applicative dependencies are static and
  monadic ones are not. That paper should be in the bibliography.

Wrong as a proof strategy, and this is the part to refute:

> "The analysis-availability theorems become one schema: an interpretation into
> target `p` exists iff `p` carries the rung's algebraic structure … free
> theorems from a class-polymorphic interpreter, replacing bespoke proofs."

Three problems.

1. **The `⇐` half is real but is not a profunctor theorem.** "Given a target
   with the structure, the interpretation exists" is *a fold*. `PlanAlg.fold`
   (§6.2) delivers it in 6 lines, universe-polymorphically, with `fold_unique`
   as the uniqueness half. You do not need `Prof` for it, and you do not need
   `Strong`/`Choice` classes either: the algebra's five fields *are* the
   structure, spelled in the package's own vocabulary.

2. **The `⇒` half cannot be a schema.** Lean has no parametricity, so nothing is
   free. But the deeper point is that it would not be free in Haskell either:
   "no analysis at `dyn`" is `no_finite_bill_set_at_dyn` (`Cost.lean:908`), a
   *cardinality* argument about one exhibited plan, and the module says so at
   length (`:892–907`: "Read the quantifier carefully. This is a theorem about
   *one* `dyn` plan"). No free theorem produces a witness. The package's
   existing witness-based negatives — three of them, plus
   `minFold_not_attained` (`:839`) and `no_static_bill_at_branch` (`:974`) — are
   the right form and stay.

3. **The rungs are not four types.** `Plan` is one inductive; `level` is a fold
   on it. "batch ≅ free applicative" is a statement about the *image* of a
   predicate, not about a type. To make the free-monoid tower load-bearing you
   would have to split `Plan` into four indexed families — which is exactly
   `attack-realizability-lean/D_graded_index_fails.lean`, compiled and refuted
   ("Dependent elimination failed", quoted at `Level.lean:14–21`). The
   grade-as-fold repair is not a workaround; it is the reason the tower cannot
   be the organising principle.

**Amendment to the seed's rung/structure table**, from §1.4: the target moves
`monoid → monoid semiring → nothing`, and the break points are `case`
(algebra: no choice) and `dyn` (cardinality: not finite). "Const dies at dyn" is
the wrong break point.

### 2.2 Seed 2 — `revising` is a lens; panels are Day convolution

**The lens is decorative. Refute it.**

`review : c → Verdict` as `get` and `amend : (c, Verdict) → c` as `put` has the
right *shapes*. All three lens laws fail, and each failure is the point of the
combinator:

| law | reading here | holds? |
|---|---|---|
| `put (s, get s) = s` | amending an artefact against its own verdict returns it unchanged | **no** — that is what an amendment *is not* |
| `get (put (s, a)) = a` | re-reviewing an amended artefact returns the old verdict | **no** — the loop exists because it might not |
| `put (put (s,a), a') = put (s, a')` | amendments do not accumulate | **no** — `revise` receives the artefact *and* the verdict (`Plan.lean:620`) precisely so that they do |

A "lens" with no lens laws is a pair of functions with suggestive names, and
the profunctor-optics machinery (Pickering–Gibbons–Wu; Boisseau–Gibbons; Riley;
Clarke et al.) buys exactly nothing without the laws. Both maps are also
*effectful* — `check : Cont Γ (El c) Verdict` is a consultation, not a function —
so even the shape is only right in a Kleisli category. Hedges-style open games
have the correct forward/backward silhouette but supply best-response and
equilibrium structure that has no counterpart here; nothing transfers.

**What `revising` actually is**, and the package half-says it already
(`Plan.lean:616–619`): the `n`-th approximant of the least fixed point of the
endofunctor
`Φ(X) = check >>= (approve ⇒ done | object ⇒ revise >>= X)`
on `Dlg`. `Nat.rec` in the metalanguage building the unrolling; `reviseLoop`
(`Denote.lean:477`) is the same recursion at the meaning; `denotes_revising`
(`:493`) is the two agreeing. The categorical home is the free monad / Kleene
star, and the package *already owns* that vocabulary in `Agentic/Star.lean`
(1,035 lines, `KleeneAlgebra`, `x∗ = ⨆ₙ xⁿ`). If anything should be connected,
it is `revising` to `Star`, not `revising` to optics.

**Panels: the useful half of seed 2, and it is not Day convolution.** Mathlib
*does* have Day convolution (`Mathlib/CategoryTheory/Monoidal/DayConvolution.lean`
+ `DayConvolution/{Braided,Closed,DayFunctor}.lean`, as a `DayConvolution`
typeclass over pointwise left Kan extensions). It is the wrong tool: the
statement you want is the elementary one that a **lax monoidal functor carries
monoids to monoids**, at `Dlg`:

```lean
instance dlgMonoid [Monoid M] : Monoid (Dlg M)     -- product = liftA2 (*)
def runHom   (ω : Ω) : Dlg M →* M                  -- run   is a monoid hom
def traceHom (ω : Ω) : Dlg M →* FreeMonoid Event   -- trace is a monoid hom
theorem denote_panel_prod : denote (panel ps) γ = (ps.map (denote · γ)).prod
theorem run_panel'   := (runHom ω).map_list_prod _
theorem trace_panel' := (traceHom ω).map_list_prod _
```

All ✅ (§6.4). `run_panel` and `trace_panel` (`Denote.lean:365`, `:378`) stop
being inductions and become `map_list_prod`; `flatten_perm` (`:424`, 8 lines of
`List.Perm` induction) becomes `List.Perm.prod_eq` in `FreeMonoid Event`;
`billFresh` composed with `traceHom` is a `MonoidHom` composite, which is
`billFresh_append` (`Cost.lean:202`) said once.

The **noncommutativity** the package is careful about survives untouched: the
monoid on `Dlg M` is sequential in the transcript by construction, so
`trace_panel_not_perm_invariant` (`Morphism.lean:425`) remains true and remains
the honest statement. That is the test of whether an abstraction is the right
one — it must not quietly make the false thing provable — and this one passes.

### 2.3 Seed 3 — `Plan` is a profunctor; handles as profunctor lenses

**First half: correct after the variance fix of §1.1, and the real content is
Yoneda, not the profunctor packaging.** See §6.1. Note that the "`Builder`'s
graft/weaken machinery is its composition" clause is *not* right on the Lean
side: `graft` is not profunctor composition (a coend); it is the Kleisli
extension of a relative monad. Profunctor composition would be
`(P ⋄ Q)(Γ,A) = ∫^Δ P(Γ,Δ) × Q(Δ,A)`, which is a quotient (§3) and is not what
`graft` computes.

**Second half: not a Lean-side question at all.** "Handles could be profunctor
lenses into a structural environment, replacing nominal type-family scope
machinery" is a Haskell problem (`Workflow.hs`'s indexed CPS surface, 639 lines;
`Builder.hs`, 1,278 lines). In Lean the environment is *already* structural — a
right-nested product with `Env.head`/`Env.tail` projections and `η`
(`cons_head_tail`, `Plan.lean:117`) — `Var` is *already* a projection with
`Var.get` as its meaning (`:137`), and `Expr Γ A = Env Γ → A` is already the
reader. There is no nominal scope machinery in the Lean formalization to
replace. Route this observation to the Haskell page.

---

## 3. Mathlib feasibility, namespace by namespace

Read in this checkout (`mathlib4 @ v4.30.0`). ✅ present / ❌ absent.

| ✅/❌ | namespace / file | what is there, exactly |
|---|---|---|
| ✅ | `Mathlib.CategoryTheory.Profunctor.Basic` | `CategoryTheory.Profunctor.{w} C D := C ⥤ Dᵒᵖ ⥤ Type w`; `ProfunctorCore` + `ProfunctorCore.Hom` constructors; `Profunctor.id` (= `yoneda`), `.op`, `whiskerLeft₂`, `ulift`, `ulift1`; `Functor.toProfunctor`. Authors Asgeirsson, Topaz, Marti, 2026. **Module header, verbatim, under "Future work": "Define composition of profunctors." and "Define the bicategory of categories where the 1-morphisms are profunctors."** |
| ❌ | Tambara modules | `grep -rl Tambara Mathlib/` → nothing |
| ❌ | profunctor optics / `Strong` / `Choice` / `Cartesian`/`Cocartesian` profunctor classes | `grep -rl Optic Mathlib/` → nothing; the only `Strong` hits are `Order/Antichain`, `Probability/StrongLaw`, `Topology/MetricSpace/BundledFun` — unrelated |
| ❌ | Freyd categories | `grep -rl Freyd Mathlib/` → three hits, all the *keyword tag* `Freyd` on Freyd's small-complete theorem (`Limits/SmallComplete.lean:26`). No Freyd categories. |
| ❌ | premonoidal categories | `grep -ril premonoidal Mathlib/` → nothing |
| ❌ | free applicative / free arrow / `Selective` / `ArrowApply` | nothing. `Mathlib/Control/` is `Applicative.lean`, `Bifunctor.lean`, `Fold.lean`, `Lawful.lean`, `Traversable/`, `Monad/`, `Fix.lean`, … — the `Control` hierarchy, no free constructions. `Mathlib/Algebra/Free.lean` is free *magmas/semigroups*, unrelated. |
| ✅ | `Mathlib.CategoryTheory.Monoidal.Functor` | `Functor.LaxMonoidal` (class, `:65`), `OplaxMonoidal` (`:241`), `Monoidal` (`:367`), `NatTrans.IsMonoidal` (`:952`) |
| ✅ | `Mathlib.CategoryTheory.Monoidal.Mon` | `CategoryTheory.Mon` (`:254`) — monoid objects in a monoidal category, with `Mon C ≌ LaxMonoidalFunctor (unit) C`, and monoidal when `C` is braided. `Monoidal/Mon_.lean` is `deprecated_module (since := "2026-04-27")` forwarding here. Also `CommMon_`, `Comon_`, `Bimod`, `Bimon_`, `Mod_`, `Grp_`, `Hopf_`. |
| ✅ | `Mathlib.CategoryTheory.Monoidal.DayConvolution` (+ `/Braided`, `/Closed`, `/DayFunctor`) | `DayConvolution` and `DayConvolutionUnit` typeclasses via pointwise left Kan extension along `⊗`; `LawfulDayConvolutionMonoidalCategoryStruct`. New (2025, Carlier) and stated as work in progress ("although we do not show it yet, this operation defines a monoidal structure"). |
| ✅ ⚠️ | `Mathlib.CategoryTheory.Limits.Types.End` | ends **and coends** in `Type`. `Limits.Types.coendRel` (inductive relation), `coend F := Quot (coendRel F)`, `cowedge`, `cowedgeIsColimit`, `ChosenCoends (Type _)`. **`coend.condition`'s proof is `apply Quot.sound`.** Also `Limits/Shapes/End.lean`, `Limits/Chosen/End.lean`. |
| ✅ ⚠️ | `Mathlib.CategoryTheory.Types.Basic` | the category `Type u`, but morphisms are now **wrapped**: `TypeCat.Fun` (a `FunLike` one-field structure), `TypeCat.Hom` wrapping it (`:88`), `ConcreteCategory` instance with `FC = TypeCat.Fun`, `↾f` notation for `TypeCat.ofHom`. Bare `A → B` is *not* the hom type. |
| ✅ | `Mathlib.CategoryTheory.Bicategory.*` | `Basic`, `Free`, `Coherence`, `FunctorBicategory`, `Monad`, `Kan`, `Grothendieck`, … — bicategories exist; the bicategory of profunctors does not. |
| ✅ | `Mathlib.Data.FinEnum` | `class FinEnum (α : Sort*)` = `card : ℕ` + `equiv : α ≃ Fin card` + `[decEq]`. **Quotient-free**, which is the whole point of `Plan.case`'s choice. |
| ✅ | `Mathlib.CategoryTheory.FintypeCat` | the category of finite types — exists, and is a **hazard**, not an asset (§5.2). |

**Two frictions worth pricing before anyone starts.**

1. **`TypeCat.Hom`.** Any use of Mathlib's category of types puts a one-field
   wrapper between `mapP f` and `f`. Structure eta keeps things definitionally
   equal, so nothing becomes *false*; but every `simp` set and every `rfl` in
   the affected proofs acquires `TypeCat.Hom.hom` / `ofHom` noise. This is the
   single biggest reason to write the light version in the package's own
   vocabulary rather than as Mathlib `Functor` instances.

2. **Universes.** `Plan Γ A : Type 1` (because `case` and `dyn` quantify over
   `Type`), while `Env`, `Expr`, `Sub`, `Level`, `Dlg A` are all `Type 0`. Any
   Mathlib functor packaging crosses the boundary in every statement. The
   algebra layer sidesteps this cleanly with `universe v` and
   `P : Ctx → Type → Type v` — ✅ verified: the same `PlanAlg` accommodates
   `Level : Type 0`, `Env Γ → Dlg A : Type 0` and `CostTree S : Type 1`.

---

## 4. Cost estimates

### 4.1 Light version — recommended

Stated in the package's own vocabulary. No `CategoryTheory` import is required;
the `Category Ctx` instance is optional and should be `scoped` if taken at all
(`test/Pollution.lean` exists precisely to police what this package installs on
other people's types, and `Agentic/Meaning.lean:2698–2704` already documents the
"two instances on one type is not a category, it is an ambiguity" trap it hit
with `StaticObj`).

| item | new lines | deletes | status |
|---|---|---|---|
| **L1** `instance : Category Ctx` (scoped) | 10 | — | ✅ compiles, all laws `rfl` |
| **L2** `PlanAlg` + `fold` + `fold_unique` | 35 | — | ✅ |
| **L3** re-express the folds as algebras + `X = fold XAlg` | ~200 | 11 recursion bodies (~130) | ✅ for `level`, `denote`; ⚠️ 9 remaining are mechanical |
| **L4** fusion law for algebra morphisms; `Expr`-blind ⇒ `sub`-invariant; `Q`-blind ⇒ `under`-invariant | 45 | `level_sub`, `level_under` proofs (~35) | ⚠️ the general law; ✅ two instances |
| **L5** `Cont.Natural`, `Cont.ofPlan`/`toPlan`, the two round trips, `sub_graft_of_natural`, `sub_mapP`, `Cont.denotes_ofPlan` | 95 | `sub_graft_not_natural` **stays** (it is the reason `Natural` exists); 10 `Denotes` hypothesis occurrences across 7 theorems; 4 hand `Denotes` proofs in `HardenPatch` (~55) | ✅ all |
| **L6** `Monoid (Dlg M)`, `runHom`, `traceHom`, `panel = List.prod`, `run_panel'`, `trace_panel'` | 85 | 2 inductions + `flatten_perm` (~35) | ✅ all |
| **L7** `billFresh` as `FreeMonoid Event →* S` | 15 | `billFresh_nil/cons/append` (~12) | ⚠️ trivial |
| **L8** syntactic `mapP_id`, `mapP_comp` | 6 | strengthens `Morphism.mapP_id`/`mapP_comp` | ✅ |
| | **~490** | **~260** | 30 declarations compiled |

Net **+230 lines**. Do not sell it as a shrink; sell it as a change in the
*number of distinct obligations*: twelve structural recursions become one fold
plus twelve algebra records, the 29 level-hypothesis theorems become 6
structural theorems plus corollaries, and the two-move `absurd … decide`
boilerplate (11 + 11 occurrences) collapses into the algebras' `dyn` and `case`
clauses.

**Wall-clock.** For a competent Lean/Mathlib user with the build warm:
L1–L2 half a day, L3 a day (mechanical but wide), L4–L5 a day and a half (L5's
ripple through `Denote.lean`, `Morphism.lean`, `Dsl.lean`, `HardenPatch.lean` is
the real work), L6–L8 half a day. **3–5 focused days.**

**The real cost is not the proofs, it is the loop.** Any change to `Plan`,
`Sub`, `graft` or `revising` re-elaborates `Agentic/Core/DslFlagship.lean`
(438 lines, **249 s**, nineteen `decide +kernel` proofs — `lakefile.toml` warns
that two concurrent elaborations have exhausted 48 GB) and
`Agentic/Core/HardenPatch.lean` (991 lines, 75 s). At ~6 minutes a full check
and five `Denotes` rewrites in `HardenPatch`, budget the L5 day as *two*. This
is also the argument for doing L1–L4 first (additive, touches no definition, so
the flagship never re-elaborates) and L5 as a separate, reviewed change.

### 4.2 Full version — not recommended

If attempted anyway, honestly priced:

| piece | estimate |
|---|---|
| `Strong`/`Choice`/`Closed` profunctor classes over a general base, with laws | 400–700 lines |
| Tambara modules + the Pastro–Street adjunction | 600–1,000 |
| Profunctor composition over C and `Type` (needs coends ⇒ `Quot`) + coherence | 500–900 |
| `Mon` in that monoidal category, and the free-monoid construction | 400–800 |
| Free applicative / free arrow / free selective / free monad as instances | 600–1,200 |
| An equivalence `Plan ≃ ` each free construction on its fragment — **the hard part** | 500–1,400 |
| **Total** | **3,000–6,000 lines, 3–6 months** |

For scale: Mathlib's entire `CategoryTheory/Monoidal/` is 107 files and 26,764
lines. This would be a Mathlib-sized contribution in its own right, and the
deliverable is a *second* development that must be glued to `Plan` by exactly
the equivalence the graded-index refutation says is awkward.

**Verdict: no.** Five reasons, in order of decisiveness.

1. **The rungs are a fold, not four types** (§2.1(3)). The tower's subject
   matter does not exist in this package, and creating it re-opens
   `D_graded_index_fails.lean`.
2. **The `⇒` direction stays a witness.** The single thing the meta-theorem was
   supposed to buy — replacing bespoke non-existence proofs — is not obtainable
   in Lean and not obtainable by parametricity anyway.
3. **Quotients.** Profunctor composition is a coend; Mathlib's coend in `Type`
   is `Quot (coendRel F)` with `Quot.sound` in its universal property. Building
   the tower out of quotients, in a package that chose `FinEnum` over `Fintype`
   specifically to keep `Quot` out of the *type* `Plan`
   (`Plan.lean:266–277`), is a direct contradiction of the design's own
   discipline — even where it is technically harmless (§5.1).
4. **Mathlib supplies none of it.** Not the composition (its own header says
   so), not Tambara, not the profunctor classes, not Freyd, not premonoidal.
5. **`Type 1` + `TypeCat.Hom`.** A constant tax on every statement (§3).

---

## 5. The kernel discipline: does the layer sit above?

### 5.1 Axiom footprints, measured

`#print axioms` on the existing package, run in this checkout:

```
Agentic.Core.certify_sound                     does not depend on any axioms
Agentic.Core.Plan.adequacy                     [propext]
Agentic.Core.Plan.sub_id                       [propext, Quot.sound]
Agentic.Core.Plan.sub_comp                     [Quot.sound]
Agentic.Core.Sub.lift_id                       [Quot.sound]
Agentic.Core.denote_sub                        [propext, Quot.sound]
Agentic.Core.Morphism.graft_pure               [Quot.sound]
Agentic.Core.Morphism.graft_assoc              [Quot.sound]
Agentic.Core.level_sub                         [propext, Classical.choice, Quot.sound]
Agentic.Core.level_under                       [propext, Classical.choice, Quot.sound]
Agentic.Core.shapes_eq_trace_of_le_pipeline    [propext, Classical.choice, Quot.sound]
Agentic.Core.bill_mem_leaves                   [propext, Classical.choice, Quot.sound]
```

And the same command on the new material (the tail of
`c-lean-side-probes.lean`, run in the same checkout):

```
Agentic.Core.Cont.toPlan_ofPlan       [propext, Quot.sound]
Agentic.Core.Cont.ofPlan_toPlan       [Quot.sound]
Agentic.Core.sub_graft_of_natural     [Quot.sound]
Agentic.Core.PlanAlg.fold_unique      [Quot.sound]
Agentic.Core.run_panel'               [propext, Quot.sound]
Agentic.Core.codes_eq_map_shapes      [propext]
Agentic.Core.shapes_eq_map_asks       [propext]
```

Three facts follow, and they answer the question cleanly.

1. **`Quot.sound` is already everywhere**, because Lean 4 derives `funext` from
   it. Every substitution lemma in `Plan.lean` carries it. The new material
   carries **exactly the footprint the modules it would join already have** —
   and two of the seven are strictly *cleaner* than the theorems they subsume:
   `codes_eq_map_shapes` and `shapes_eq_map_asks` are `[propext]`, where
   `codes_eq_of_le_pipeline` and `shapes_eq_trace_of_le_pipeline` are
   `[propext, Classical.choice, Quot.sound]`. Factorisation does not need the
   order theory; only totality does.
2. **`Classical.choice` is already in the analyses**, entering through
   `Finset.sup` / `LinearOrder` in `level` and `Cost`. Worth stating in the docs
   because it is easy to assume otherwise: `level` *computes* without axioms
   (`level_upToTwice` is `by decide`, `Level.lean:332`), but its *lemmas* are
   classical. If anyone ever wants a clean `level`, the change is
   `List.foldr max` over `FinEnum.toList` instead of `Finset.univ.sup` — an
   independent finding, unrelated to profunctors.
3. **The two pinned claims are unreachable from any of this.** `certify_sound`'s
   proof is `fun h => ⟨worldOf t, of_decide_eq_true h⟩` (`Certify.lean:179`) and
   reaches only `Plan`, `denote`, `worldOf`, `lookup`, `Q`, `El`.
   `Plan.adequacy` adds `Dlg.execM` and `Extends`. Neither reaches `level`,
   `Cost`, `Morphism` or anything a categorical layer would add.

> **The invariant to state and check.** The categorical layer is safe with
> respect to `Certify.lean`'s two `#guard_msgs` **iff** it does not change the
> definitions of `Plan`, `denote`, `worldOf`, `lookup`, `Q` or `El`. Everything
> in §4.1 except L5-as-refactor satisfies this by construction. The guards are
> themselves the check — they are build failures, not comments — so the
> discipline is self-enforcing.

### 5.2 Fintype / quotient hazards

Four, in decreasing order of danger.

1. **Do not index `case` by `FintypeCat`.** The tempting move, once you have a
   categorical layer, is to make `case`'s tag an object of Mathlib's category of
   finite types. `FintypeCat` bundles a `Fintype`, which holds a `Finset`, which
   holds a `Multiset`, which is a `Quot`. That would put `Quot.sound` into the
   *type* `Plan` and break `certify_sound`'s zero-axiom guard immediately. The
   `FinEnum` note (`Plan.lean:266–277`) is exactly this hazard, already
   written down; the categorical layer must respect it and the temptation is
   new.

2. **The safe move is the opposite direction, and the Haskell already made it.**
   `haskell/src/Agentic/Plan.hs:502` has `PCase :: Tag t -> Expr g t -> (t -> Plan g a) -> Plan g a`
   with `Tag` a closed two-constructor GADT (`TBool`, `TVTag`) and
   `tagValues` reproducing Lean's `FinEnum` order by hand. Porting that shape
   back to Lean — an explicit finite tag *object* instead of
   `[FinEnum T] [DecidableEq T]` — would drop `Plan` from `Type 1` to `Type 0`,
   remove the last higher-order quantification from `case`, and dissolve the
   universe friction of §3 at a stroke. **Caveat:** `Plan.explain`
   (`Explain.lean:238–243`) prints `FinEnum.toList T` arm counts, and
   `finEnum_toList_bool` / `finEnum_toList_vtag` (`:96`, `:100`) pin the order,
   which `cli_smoke` checks against `agent-cat plan` output. A `Tag` object must
   reproduce that order exactly. This is a separable refactor that the
   profunctor work does not need but would benefit from; it is an owner
   decision and it is not free.

3. **`CostTree.node` carries `(inst : Fintype T)`** (`Cost.lean:614`) — a
   `Quot` inside a `Type 1` inductive, in the *analysis* layer. Harmless today
   (not in `certify_sound`'s graph) and deleted outright by §7.2.

4. **Coends.** If profunctor composition is ever wanted, it arrives as
   `Quot (coendRel F)`. Keep it out of `Agentic/Core/`; if it must exist, it
   belongs in the `Agentic/` "mathematical space", which is already where the
   quotient-based material lives (`Agentic/Trace.lean`'s `Con.monoid`,
   `Agentic/Meaning.lean`'s `noncomputable instance staticCategory` over a
   `Quotient`).

### 5.3 Conformance

`test/corpus/` holds **128** frozen JSON vectors. Read one
(`battery-007-…json`): the pinned reply record is

```
level, size, askNodes, codes, shapes, asks, blockAsks, fnAsks,
costSummary { paths, minFold, maxFold },
worlds[] { world, trace[], billFresh, billMemo }
```

So `Plan.size` and `Plan.askNodes` — node counts of the elaborated term — are
part of the frozen specification, as is `costSummary` and the whole trace.
`connection.md` §3.1/§3.5 fixes the same list, and D8 fixes "no normalization in
the comparison of traces".

| item | corpus impact |
|---|---|
| L1–L4, L6–L8 | **none.** Additive: new statements about unchanged definitions. `PlanAlg` proves `level = levelAlg.fold` rather than replacing `level`. |
| L5 as *theorems* (`Cont.Natural`, the Yoneda pair, `sub_graft_of_natural`, `Denotes` corollaries) | **none.** Purely additive. |
| L5 as a *refactor* of `revising`'s definition (§7.1) | ⚠️ **must be validated.** `revising` currently threads `Sub.comp (Sub.comp σ τ) ρ` explicitly (`Plan.lean:632–633`); a Yoneda-form version builds the same grafts differently. I expect the resulting term to be identical, hence `size`/`askNodes`/`trace` unchanged — because `sub` and `graft` are folds, not constructors, so neither adds nodes — but I have **not** verified it, and `Plan.size` being pinned means the check is a run of `corpus-gen` and a diff, plus `DslFlagship`'s nineteen `decide +kernel` numbers. **Owner decision.** |
| §7.2 (`CostTree` → `Multiset`) | **none, by argument.** `costSummary` reports `(minFold, maxFold, Multiset.card leaves)` and `leafBills` sorts `leaves`; the Multiset fold produces the same multiset, so the same three numbers. The empty-arm case agrees too: an arm-less `case` gives `Finset.univ.inf … = ⊤` today and `Multiset.inf ∅ = ⊤` after, both printed `—` by `sayNat?`. ⚠️ reasoned, not compiled. |

**Standing rule for this work:** an additive theorem layer cannot move the
corpus, and every item above that *can* is flagged as an owner decision, exactly
as `connection.md` requires for a core refactor.

---

## 6. The compiled results

All five blocks below elaborated with `lake env lean` against the built
package. Full source in `c-lean-side-probes.lean`.

### 6.1 The `Cont`–Yoneda equivalence ✅

The key observation is a **representability** fact about context extension.
Because `Env (c :: Γ) ≅ El c × Env Γ` — which is `Env.cons_head_tail`,
already proved (`Plan.lean:117`) —

```
Hom_C(c :: Γ, Δ)  =  Env Δ → Env (c :: Γ)
                  ≅  (Env Δ → El c) × (Env Δ → Env Γ)
                  =  Expr Δ (El c) × Hom_C(Γ, Δ)         naturally in Δ
```

so **`c :: Γ` represents the functor `Expr (−) (El c) × Hom_C(Γ, −)`**, with
universal element `(Sub.wk, Expr.var .here)` — weakening paired with the
variable just bound. The covariant Yoneda lemma then reads:

> `{k : Cont Γ (El c) B // Cont.Natural k}  ≅  Plan (c :: Γ) B`

```lean
def Cont.ofPlan (q : Plan (c :: Γ) B) : Cont Γ (El c) B :=
  fun _ σ e => Plan.sub q (fun δ => Env.cons (e δ) (σ δ))

def Cont.toPlan (k : Cont Γ (El c) B) : Plan (c :: Γ) B :=
  k (c :: Γ) Sub.wk (Expr.var .here)          -- evaluate at the universal element

theorem Cont.ofPlan_natural  (q) : Cont.Natural (Cont.ofPlan q)               -- ✅
theorem Cont.toPlan_ofPlan   (q) : Cont.toPlan (Cont.ofPlan q) = q            -- ✅ NO hypothesis
theorem Cont.ofPlan_toPlan   (k) (hk : Cont.Natural k) :
    Cont.ofPlan (Cont.toPlan k) = k                                           -- ✅ hypothesis IS naturality
theorem Cont.denotes_ofPlan  (q) :
    Plan.Denotes (Cont.ofPlan q) (fun a γ => denote q (Env.cons a γ))          -- ✅ by denote_sub
theorem sub_graft_of_natural (p) (σ) (k) (hk : Cont.Natural k) :
    Plan.sub (Plan.graft p k) σ = Plan.graft (Plan.sub p σ) (Cont.reindex k σ) -- ✅
theorem sub_mapP (f) (p) (σ) : Plan.sub (Plan.mapP f p) σ = Plan.mapP f (Plan.sub p σ)  -- ✅
```

Note what each proof needs. `toPlan_ofPlan` needs `Env.cons_head_tail` and
`sub_id` and no hypothesis at all. `ofPlan_toPlan` needs naturality and
*nothing else* — the round trip **is** the naturality condition, which is the
categorical content stated as a Lean proof obligation. `denotes_ofPlan` is
`denote_sub` and one `simp only`.

`Cont.ofPlan` is not an exotic construction: `Acceptance.check`
(`Denote.lean:564`) is literally `fun _ _ a => Plan.ask1 .verdict reviewShape a`,
i.e. `Cont.ofPlan (Plan.ask1 .verdict reviewShape (fun δ => δ.head))`, and
`HardenPatch.review`/`redraft` are `ofPlan` of a panel and of an ask. Every
author-written `Cont` in the repository ignores its `Sub` argument.

**Where the collapse stops, and it is informative.** `A` must be representable,
i.e. a finite product of answer types (`El c₁ × … × El cₙ`, represented by
`c₁ :: … :: cₙ :: Γ`). `revise : Cont Γ (El c × Verdict) (El c)` qualifies
(`Verdict` is `El .verdict`, `Plan.lean:572`). `HardenPatch.finishK :
Cont Γ (Option (El .text)) Unit` (`:255`) does **not** — `Option (El .text)` is
not an answer type, because `revising` returns `Option (El c)`
(`Plan.lean:624`). So the one place the language leaves the "answers only"
universe is exactly the one place Yoneda fails to apply. That is a real
observation about the design, not about the mathematics, and the honest fix
(a code for the failure, or a `declined` marker in the artefact) is an owner
question outside this page.

### 6.2 The initial algebra ✅

```lean
universe v
structure PlanAlg (P : Ctx → Type → Type v) where
  ret  : {Γ : Ctx} → {A : Type} → Expr Γ A → P Γ A
  askC : {Γ : Ctx} → {A : Type} → (c : Code) → Q c → P (c :: Γ) A → P Γ A
  ask  : {Γ : Ctx} → {A : Type} → (c : Code) → Q.Shape c → Expr Γ String → P (c :: Γ) A → P Γ A
  case : {Γ : Ctx} → {A T : Type} → [FinEnum T] → [DecidableEq T] →
           Expr Γ T → (T → P Γ A) → P Γ A
  dyn  : {Γ : Ctx} → {A B : Type} → Expr Γ B → (B → P Γ A) → P Γ A

def PlanAlg.fold (alg : PlanAlg P) : {Γ : Ctx} → {A : Type} → Plan Γ A → P Γ A   -- 6 lines
theorem PlanAlg.fold_unique (alg) (h) (hret) (haskC) (hask) (hcase) (hdyn) :
    ∀ p, h p = alg.fold p                                                        -- ✅ one induction

def levelAlg  : PlanAlg (fun _ _ => Level)          ; theorem level_eq_fold  : level p = levelAlg.fold p   -- ✅
def denoteAlg : PlanAlg (fun Γ A => Env Γ → Dlg A)  ; theorem denote_eq_fold : denote p γ = denoteAlg.fold p γ -- ✅
```

`universe v` is what makes this work across the existing targets: `Level` and
`Env Γ → Dlg A` are `Type 0`, `CostTree S` is `Type 1`, and `Plan.rec` is
universe-polymorphic in its motive, so one structure serves every carrier in the
package. Footprint `[Quot.sound]` — i.e. `funext`, and nothing else.

**Which of the twelve recursions fit, precisely.** Ten fit at the obvious
carrier (`denote`, `level`, `codes`, `shapes`, `asks`, `size`, `askNodes`,
`explain`, and `under` at `P Γ A = Plan Γ A`). Two fit at a *function-space*
carrier, which is the standard fold-with-accumulator move and worth spelling
out because it is not obvious: `sub` is the fold at
`P Γ A = ∀ Δ, Sub Γ Δ → Plan Δ A`, and `graft` is the fold at
`P Γ A = Cont Γ A B → Plan Γ B` — its `askC` clause being
`fun rec k => .askC c q (rec (Cont.reindex k Sub.wk))`, where `Cont.reindex`
is §6.1's. So `graft`'s "rebuild the continuation with one more weakening" is
literally the algebra's action on the accumulator, which is a better
explanation than the current comment.

**One does not fit**: `costTree` (`Cost.lean:668`), because its signature
absorbs the level bound (`(p : Plan Γ A) → level p ≤ Level.branch → …`) and an
algebra carrier may not mention `p`. That is a deliberate design decision —
"the analysis applies at this rung is the *type* of the fold rather than a side
condition" (`:651–656`) — and it is exactly what §7.2's move to a
`Multiset`-valued fold would dissolve. Until then `costTree` stays hand-written,
and the honest count is eleven of twelve.

### 6.3 Analysis fusion ✅

```lean
theorem codes_eq_map_shapes (p : Plan Γ A) :
    codes p = (shapes p).map (List.map Shape.code)                       -- ✅ NO level hypothesis
theorem shapes_eq_map_asks (p : Plan Γ A) (γ : Env Γ) :
    shapes p = (asks p γ).map (List.map Key.shape)                       -- ✅ NO level hypothesis, ANY γ
example (h : level p ≤ Level.pipeline) : (codes p).isSome := by
  rw [codes_eq_map_shapes]; simpa using shapes_isSome_of_le_pipeline p h  -- ✅
```

Two things to notice. First, the fusions carry **no level hypothesis** — they
are true at `branch` and `dynamic` too, where both sides are `none`. That is the
right shape: the level hypothesis belongs to *totality*, not to *factorisation*,
and the package currently entangles them. Second, `shapes_eq_map_asks` holds
for *every* environment, which is a sharper statement of "the shape is a
projection of the syntax" than `shapes_eq_of_le_pipeline` (`Cost.lean:529`) and
subsumes `Event.map_shape` (`:121`) at the analysis level.

`codes_isSome_of_le_pipeline` and `codes_eq_of_le_pipeline` become corollaries;
two 8-line inductions with their `absurd … decide` tails go away.

### 6.4 `Dlg` as a lax monoidal functor ✅

```lean
instance dlgMonoid [Monoid M] : Monoid (Dlg M) where
  one := Dlg.done 1
  mul x y := Dlg.bind x (fun a => Dlg.bind y (fun b => Dlg.done (a * b)))
  -- all three laws: `simp only` over Dlg's LawfulMonad instance                  ✅

def runHom   (ω : Ω) : Dlg M →* M                                                 -- ✅
def traceHom (ω : Ω) : Dlg M →* FreeMonoid Event                                  -- ✅
theorem denote_panel_prod : denote (Plan.panel ps) γ = (ps.map (denote · γ)).prod  -- ✅
theorem run_panel'   : … = (ps.map (Plan.run ω · γ)).prod                          -- ✅ (runHom ω).map_list_prod
theorem trace_panel' : … = (ps.map (Plan.trace ω · γ)).flatten                     -- ✅ (traceHom ω).map_list_prod
```

`Plan.panel` (`Plan.lean:595`) is `List.foldr (zipWith (·*·)) (ret 1)`; under
this instance it is `List.prod` in `Dlg (El c)`, and the two morphism equations
`run_panel`/`trace_panel` (`Denote.lean:365`, `:378`) are `map_list_prod`
instead of inductions. The `Monoid (El .verdict)` instance the package already
declares (`Plan.lean:572`) is what feeds it.

### 6.5 `Ctx` as a Mathlib category ✅

```lean
instance ctxCat : CategoryTheory.Category.{0,0} Ctx where
  Hom Γ Δ := Sub Γ Δ ; id Γ := Sub.id ; comp σ τ := Sub.comp σ τ
  id_comp _ := rfl ; comp_id _ := rfl ; assoc _ _ _ := rfl
```

Ten lines, three `rfl`s. Include it only if the vocabulary is wanted, and make
it `scoped`.

---

## 7. The two most valuable new theorems

### 7.1 `Cont`–Yoneda: `Plan (c :: Γ) B ≅ {k : Cont Γ (El c) B // Natural k}`

**What it says.** A continuation grafted onto every leaf of a plan is the same
thing as a plan in the extended context — provided it is natural in the
context, and naturality is *precisely* the round-trip condition. The universal
element is `(weakening, the variable just bound)`.

**What it buys, item by item.**

1. **The higher-rank type leaves the interface.** `Cont Γ A B :=
   ∀ Δ, Sub Γ Δ → Expr Δ A → Plan Δ B` (`Type 1`, rank-2) stays as the internal
   machinery of `graft`'s recursion, but every author-facing signature loses it:
   `Plan.revising : Cont Γ (El c) Verdict → Cont Γ (El c × Verdict) (El c) →
   Nat → Cont Γ (El c) (Option (El c))` (`Plan.lean:621`) becomes
   `Plan (c :: Γ) Verdict → Plan (c :: .verdict :: Γ) (El c) → Nat → …`, and
   `Plan.lean:632–633`'s `Sub.comp (Sub.comp σ τ) ρ` chain disappears from the
   definition. So do `Acceptance.check`/`revise`'s `fun _ _ a =>` prefixes, and
   `HardenPatch`'s four.
2. **`Plan.Denotes` stops being a hypothesis.** `Cont.denotes_ofPlan` (✅)
   supplies it for every `ofPlan` continuation, from `denote_sub`. The seven
   theorems in `Denote.lean`/`Morphism.lean` get `Denotes`-free
   corollaries; the 4 hand-written discharges in `HardenPatch.lean` become
   one-liners.
3. **The failed square is repaired.** `Morphism.sub_graft_not_natural` (`:324`)
   stays — it is now the *reason* `Cont.Natural` exists, and `wobbly`
   (`:310`) is the compiled witness that it is not vacuous — with
   `sub_graft_of_natural` (✅) beside it as the positive statement. That turns a
   documented wart into a matched pair, which is the module's own house style
   (`Morphism.lean:33–35`: "each is invisible until the equation is stated in
   full").
4. **It explains an existing design boundary.** The collapse fails exactly at
   `Option (El c)` — `revising`'s result type — which is exactly the one place
   the language steps outside the answer universe (§6.1). The theorem *locates*
   that; nothing else in the development does.

**What it costs.** The theorem layer is additive and corpus-safe (~95 lines,
✅ compiled). Rewriting `revising`'s definition to Yoneda form is a separate,
corpus-relevant change (§5.3) and an owner decision.

**Prior art to cite.** Boisseau and Gibbons, *What you needa know about Yoneda*
(ICFP 2018) — the programming-side reading of exactly this move. Altenkirch,
Chapman and Uustalu, *Monads need not be endofunctors* — for `graft` as a
relative-monad extension, which is what the equivalence makes visible.

### 7.2 Fold fusion: one law for every factorisation and every invariance

**What it says.** Given `alg : PlanAlg P`, `alg' : PlanAlg P'` and a family
`h : ∀ Γ A, P Γ A → P' Γ A` commuting with the five operations,
`h ∘ alg.fold = alg'.fold`. Plus two specialisations that need no `alg'`:

- an algebra whose clauses ignore their `Expr` arguments gives a
  `sub`-invariant fold;
- an algebra whose clauses ignore their `Expr`, `Q` and `Q.Shape` arguments
  gives a fold invariant under both `sub` and `under`.

**What it buys.**

1. **Three factorisations, two already compiled.** `codes = Shape.code <$>
   shapes` ✅, `shapes = Key.shape <$> asks` ✅ (both *without* a level
   hypothesis — §6.3), and `leaves ∘ costTree = costMultiset`.
2. **Four missing invariance lemmas, for free.** The package has `level_sub`
   (`Level.lean:190`) and `level_under` (`:207`). It has **no** `size_sub`,
   `askNodes_sub`, `codes_sub`, `shapes_sub` — and `codes`/`shapes` being facts
   about the term alone is precisely what the conformance record depends on
   (`connection.md` §3.5, comparand 5). The specialisation supplies all six from
   one statement.
3. **`CostTree` becomes deletable, and with it a `Fintype` inside a `Type 1`
   inductive.** Define
   ```lean
   def costM [CommMonoid S] (price : Price S) : … → Env Γ → Multiset S
     | .ret _,        _ => {1}
     | .askC c q k,   γ => (costM price k (Env.cons default γ)).map (price c q * ·)
     | .ask c s e k,  γ => (costM price k (Env.cons default γ)).map (price c (s.withPrompt (e γ)) * ·)
     | .case _ arms,  γ => Finset.univ.val.bind (fun t => costM price (arms t) γ)
   ```
   Then `leaves (costTree price p h γ) = costM price p h γ` by one induction —
   itself an instance of the fusion law, with `leaves` the algebra morphism.
   `CostTree.minFold`/`maxFold` become `Multiset.inf`/`sup` in `WithTop`/`WithBot`;
   `CostTree.leaves_map` (`Cost.lean:639`) is `Multiset.map_bind`;
   `CostTree.map` (`:621`) goes away. `bill_mem_leaves` (`:691`) becomes
   membership in the fold. Net: `Cost.lean` loses ~45 lines and the analysis
   layer loses its only `Quot`-bearing datatype. The target has moved from a
   monoid to the **monoid semiring** `Multiset S`, which is exactly the object
   `Agentic/Panel.lean` calls `S⟨K⟩`, so the branch rung finally sits in the
   same algebra as the panel convolution instead of in a bespoke tree.
   Corpus-safe by argument (§5.3); ⚠️ not compiled.
4. **The `absurd … decide` boilerplate goes into one place.** 22 occurrences
   across 11 proofs become the `dyn` clause of the relevant algebras.

**Why this and not the meta-theorem.** This *is* the meta-theorem's `⇐`
direction, made concrete and Lean-shaped: "an interpretation into `P` exists iff
`P` carries the rung's structure" becomes "here is the algebra; here is the
unique fold; here is when two folds agree". It costs 80 lines instead of 4,000,
it needs no Mathlib category theory, it does not touch the axiom footprint, and
it delivers the four factorisation/invariance families the package is currently
missing. The `⇒` direction stays what it already is: five compiled witnesses.

---

## 8. What not to do

1. **Do not import `Mathlib.CategoryTheory.Profunctor.Basic` to say `Plan` is a
   profunctor.** The instance would be `Profunctor.{1} (Type 0) E` and would buy
   nothing Mathlib has anything to say about — no composition (its own header),
   no `Strong`, no `Choice` — while paying `TypeCat.Hom` and a universe crossing
   in every statement. Say the two functor laws in the package's own vocabulary.
   (It is also not yet built in this checkout: the probe hit
   *"object file … Profunctor/Basic.olean … does not exist"*, so importing it
   costs a Mathlib rebuild in the flagship's build graph.)
2. **Do not make `case`'s tag a `FintypeCat` object.** §5.2(1). It breaks
   `certify_sound`'s zero-axiom guard through the *type* of `Plan`.
3. **Do not put coends in `Agentic/Core/`.** §5.2(4).
4. **Do not pursue the optics framing of `revising`.** §2.2 — all three lens
   laws fail, and each failure is load-bearing. If a categorical home is wanted,
   connect `revising` to `Agentic/Star.lean`.
5. **Do not install a global `Category Ctx` instance.** `test/Pollution.lean` and
   `Agentic/Meaning.lean:2698–2704` both exist because of this class of mistake.
   `scoped`, or not at all.
6. **Do not begin with L5.** L1–L4 and L6–L8 are additive and never
   re-elaborate `DslFlagship` (249 s) or `HardenPatch` (75 s). L5's `revising`
   refactor is the only corpus-relevant item and should be a separate, reviewed
   change with a `corpus-gen` diff attached.

---

## Appendix A — citations

Exact where I am confident; flagged where I am not.

1. Sam Lindley, Philip Wadler, Jeremy Yallop. **Idioms are oblivious, arrows are
   meticulous, monads are promiscuous.** *Electronic Notes in Theoretical
   Computer Science* 229(5):97–117, 2011 (MSFP 2008 proceedings).
   ⚠️ I am confident of authors/title/venue; slightly less of the volume/issue
   and page range.
2. Robert Atkey. **What is a categorical model of arrows?** *Electronic Notes in
   Theoretical Computer Science* 229(5):19–37, 2011 (MSFP 2008).
   ⚠️ same caveat on volume/pages. This is the paper that gets the
   "arrows = monoids in a category of profunctors *with strength*" statement
   right, and it is more precise than the seed's phrasing.
3. Exequiel Rivas, Mauro Jaskelioff. **Notions of computation as monoids.**
   *Journal of Functional Programming* 27, e21, 2017.
4. Kazuyuki Asada. **Arrows are strong monads.** MSFP 2010, ACM.
5. Bart Jacobs, Chris Heunen, Ichiro Hasuo. **Categorical semantics for
   arrows.** *Journal of Functional Programming* 19(3–4):403–438, 2009.
6. John Hughes. **Generalising monads to arrows.** *Science of Computer
   Programming* 37(1–3):67–111, 2000. (`ArrowApply ≅ Monad`.)
7. Ross Paterson. **A new notation for arrows.** ICFP 2001.
8. Conor McBride, Ross Paterson. **Applicative programming with effects.**
   *Journal of Functional Programming* 18(1):1–13, 2008.
9. Paolo Capriotti, Ambrus Kaposi. **Free applicative functors.** MSFP 2014,
   *EPTCS* 153:2–30. ⚠️ volume/pages from memory.
10. Andrey Mokhov, Georgy Lukyanov, Simon Marlow, Jeremie Dimino. **Selective
    applicative functors.** ICFP 2019, *PACMPL* 3(ICFP), article 90.
11. Andrey Mokhov, Neil Mitchell, Simon Peyton Jones. **Build systems à la
    carte.** ICFP 2018, *PACMPL* 2(ICFP), article 79; extended version *JFP*
    30, e11, 2020. — the same static/dynamic-dependency grading as the level
    lattice, independently discovered.
12. Simon Marlow, Louis Brandy, Jonathan Coens, Jon Purdy. **There is no fork: an
    abstraction for efficient, concurrent, and concise data access.** ICFP 2014.
    — the applicative rung as the batching licence; relevant to `panel`.
13. Thorsten Altenkirch, James Chapman, Tarmo Uustalu. **Monads need not be
    endofunctors.** *Logical Methods in Computer Science* 11(1:3), 2015 (earlier
    FoSSaCS 2010). — `graft` as a relative-monad extension over `Expr`; the
    citation `Morphism.lean:218–226` is reaching for.
14. Thorsten Altenkirch, Bernhard Reus. **Monadic presentations of lambda terms
    using generalized inductive types.** CSL 1999. — intrinsically-typed de
    Bruijn syntax as a monad on contexts.
15. Marcelo Fiore, Gordon Plotkin, Daniele Turi. **Abstract syntax and variable
    binding.** LICS 1999. — the presheaf/substitution-algebra reading of §1.1.
16. Guillaume Allais, Robert Atkey, James Chapman, Conor McBride, James McKinna.
    **A type- and scope-safe universe of syntaxes with binding: their semantics
    and proofs.** ICFP 2018; *Journal of Functional Programming* 31, e22, 2021.
    — the state of the art for "N bespoke traversals become one generic
    semantics", formalised in Agda. **The direct prior art for §6.2/§7.2**, and
    the reason to write `PlanAlg` rather than a profunctor tower.
17. Matthew Pickering, Jeremy Gibbons, Nicolas Wu. **Profunctor optics: modular
    data accessors.** *The Art, Science, and Engineering of Programming*
    1(2), article 7, 2017.
18. Guillaume Boisseau, Jeremy Gibbons. **What you needa know about Yoneda:
    profunctor optics and the Yoneda lemma.** ICFP 2018, *PACMPL* 2(ICFP),
    article 84. — the reference for §7.1.
19. Mitchell Riley. **Categories of optics.** arXiv:1809.00738, 2018.
20. Bryce Clarke, Derek Elkins, Jeremy Gibbons, Fosco Loregian, Bartosz
    Milewski, Emily Pillmore, Mario Román. **Profunctor optics, a categorical
    update.** *Compositionality* 6, 2024. ⚠️ I am confident of the author list
    and title; less of volume/year (it circulated as arXiv:2001.07488 for
    several years before journal publication).
21. Daisuke Tambara. **Distributed modules over a monoidal category.** *Journal
    of Algebra*, 2006. ⚠️ Title wording and volume/pages uncertain; this is the
    origin of "Tambara module" as used in the optics literature and should be
    checked before quoting.
22. John Power, Edmund Robinson. **Premonoidal categories and notions of
    computation.** *Mathematical Structures in Computer Science* 7(5):453–468,
    1997.
23. Paul Blain Levy, John Power, Hayo Thielecke. **Modelling environments in
    call-by-value programming languages.** *Information and Computation*
    185(2):182–210, 2003. — Freyd categories, the `pipeline` rung's home.
24. Neil Ghani, Jules Hedges, Viktor Winschel, Philipp Zahn. **Compositional
    game theory.** LICS 2018. And Jules Hedges, *Towards compositional game
    theory*, PhD thesis, Queen Mary University of London, 2016. — assessed in
    §2.2 and found not to apply.

Mathlib, read in this checkout rather than cited from memory:
`Mathlib/CategoryTheory/Profunctor/Basic.lean` (Dagur Asgeirsson, Adam Topaz,
Adrian Marti, 2026); `Mathlib/CategoryTheory/Limits/Types/End.lean`;
`Mathlib/CategoryTheory/Monoidal/{Functor,Mon,DayConvolution}.lean`;
`Mathlib/CategoryTheory/Types/Basic.lean`; `Mathlib/Data/FinEnum.lean`.

## Appendix B — how to re-run the probes

```
export PATH=/nix/store/…-lean4-4.30.0/bin:$PATH     # or: nix develop
cd /Users/johnw/src/agent-cat
lake env lean doc/research/profunctor-design/c-lean-side-probes.lean
```

Expect no output. The file is not in any `lean_lib` glob (`["Agentic",
"Agentic.Core.+"]`) or `srcDir`, so it cannot affect `lake build`.
