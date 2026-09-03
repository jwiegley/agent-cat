import Agentic.Core.Denote
import Mathlib.Data.Fintype.Lattice
import Mathlib.Order.Basic
import Mathlib.Tactic.DeriveFintype

/-!
# The level: which analyses apply, computed by a fold

Rederivation kernel §1 (row `Level`), §3 q4 (the four rungs and the recognized
class at each), §4 C5, §8.1 (why the grade is not an index), and
`attack-realizability`'s compiled pair `D_graded_index_fails.lean` /
`E_grade_as_fold_works.lean`.

**The grade is a fold and not an index.** Lean refuses to eliminate
`W : Grade → Type → Type` whose index is a computed `max g g'` — the probe
`D_graded_index_fails.lean` is the compiler saying *"Dependent elimination
failed"* — so every theorem stated about such a family never gets off the
ground. The verified repair, `E_grade_as_fold_works.lean`, is grade-as-fold plus
a totality theorem, and that is the shape used here and in
`Agentic/Core/Cost.lean`: `level` is a function of a finished term, the analyses
are `Option`-valued folds, and "the analysis applies at this rung" is a theorem
(`asks_isSome_of_le_pipeline`) or, where the fold's result is a tree, the *type*
of the fold (`costM` takes the level bound as an argument) — never a typing
discipline on the family.

**The fold classifies terms, not meanings, and that is why it is sound.** A
`case` node whose two arms happen to ask the same questions is still `branch`
here. Defining the rungs as predicates on traces instead is what makes MF's
Pipeline theorem false (`attack-simplicity` §2, Test 3: constant trace length,
world-dependent cost); classifying the *term* avoids the refuted statement by
construction, at the stated price that the classification is an
over-approximation whose completeness is kernel open question 1.
-/

namespace Agentic.Core

open Plan

/-! ## The four rungs -/

/-- `[[Level]]` = which analyses apply: a point of the four-element chain
`batch ≤ pipeline ≤ branch ≤ dynamic`.

One rung per *recognized class*, and the entry in the last column is what
`Agentic/Core/Cost.lean` proves at it:

| rung | syntactic criterion | class | the analysis |
|---|---|---|---|
| `batch` | only `askC` and `ret` | free `Applicative` | the exact question list, world-independent; exact bill |
| `pipeline` | `ask` allowed; no `case`, no `dyn` | static arrow | the exact count, code sequence and question *shapes*; exact bill under `PricesByShape` |
| `branch` | `case` allowed; no `dyn` | `Selective.branch` | a finite `Multiset` of bills containing every run's own (`bill_mem_leaves`); sound bounds, and the best and worst *achievable* bills attained by worlds |
| `dynamic` | `dyn` present | `Monad` | nothing survives: a `dyn` plan is exhibited (`unbounded`) for which **no finite set of bills exists at all** (`no_finite_bill_set_at_dyn`), hence no cost tree of any shape. The claim is a witness at this rung, not a universal over its inhabitants — a `dyn` whose function is constant costs what its body costs | -/
inductive Level where
  /-- Every question is closed: the term names its whole question list. -/
  | batch
  /-- Questions may be built from earlier answers; the shape of the
  conversation is still fixed by the term. -/
  | pipeline
  /-- Finite-tag branching, with every arm in the term. -/
  | branch
  /-- A plan computed from an unbounded answer. -/
  | dynamic
  deriving DecidableEq, Repr, Inhabited, Fintype

/-- **Morphism equation.** `[[Level.toNat]]` is the order isomorphism onto
`{0,1,2,3} ⊆ ℕ` that presents the chain; the linear order below is defined as
its pullback, so every order fact about `Level` is a fact about `ℕ` and none of
them is asserted here. -/
def Level.toNat : Level → Nat
  | .batch => 0
  | .pipeline => 1
  | .branch => 2
  | .dynamic => 3

theorem Level.toNat_injective : Function.Injective Level.toNat := by decide

/-- The chain, as Mathlib's `LinearOrder` pulled back along `toNat`. Standard
vocabulary on purpose: `≤`, `max`, `⊥` and `Finset.sup` are then all Mathlib's,
and `level`'s "join along the structure" needs no bespoke algebra. -/
instance instLinearOrderLevel : LinearOrder Level :=
  LinearOrder.lift' Level.toNat Level.toNat_injective

theorem Level.le_def {ℓ ℓ' : Level} : ℓ ≤ ℓ' ↔ ℓ.toNat ≤ ℓ'.toNat := Iff.rfl

/-- `batch` is the bottom of the chain: a term that asks only closed questions
admits every analysis. -/
instance instOrderBotLevel : OrderBot Level where
  bot := .batch
  bot_le := by decide

/-- `dynamic` is the top: the rung at which the analyses stop. -/
instance instOrderTopLevel : OrderTop Level where
  top := .dynamic
  le_top := by decide

@[simp] theorem Level.bot_eq_batch : (⊥ : Level) = .batch := rfl

@[simp] theorem Level.top_eq_dynamic : (⊤ : Level) = .dynamic := rfl

/-! ## The fold -/

/-- The grading, as an algebra. `level` just below is its fold.

A **fold**, over the finished term, never an index on the family:

```
level (ret e)        = batch
level (askC c q k)   = level k
level (ask c s e k)  = pipeline ⊔ level k
level (case e arms) = branch ⊔ ⨆ t, level (arms t)
level (dyn e f)     = dynamic
```

Each clause is the rung its former forces, joined with what the subterms force —
which is the "join along the structure" of kernel §3 q4, and is Mathlib's `max`
and `Finset.sup` rather than a bespoke semilattice. The five equations are
`level_ret`, `level_askC`, `level_ask`, `level_case` and `level_dyn` below,
each a `rfl`.

The carrier is `Const Level` — no argument position at all, which is what "the
level is a fact about the term" means — and the `case` clause is the join, which
is the tight case of the domination condition recorded beside it. -/
def levelAlg : PlanAlg (fun _ _ => Level) where
  ret _ := .batch
  askC _ _ l := l
  ask _ _ _ l := max .pipeline l
  case := fun _ _ arms => max .branch (Finset.univ.sup fun x => arms x)
  dyn _ _ _ := .dynamic

/-- `[[level p]]` = the lowest rung of the grading at which `p` sits.

`levelAlg.fold`; the five equations below are its clauses, each still a `rfl`. -/
def level {A : Type} : {Γ : Ctx} → Plan Γ A → Level :=
  fun p => levelAlg.fold p

variable {Γ Δ : Ctx} {A B C : Type}

@[simp] theorem level_ret (e : Expr Γ A) : level (Plan.ret e) = .batch := rfl

@[simp] theorem level_askC (c : Code) (q : Request c) (k : Plan (c :: Γ) A) :
    level (Plan.askC c q k) = level k := rfl

@[simp] theorem level_ask (c : Code) (s : Request.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) :
    level (Plan.ask c s e k) = max .pipeline (level k) := rfl

@[simp] theorem level_case (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A) :
    level (Plan.case t e arms) = max .branch (Finset.univ.sup fun x => level (arms x)) := rfl

@[simp] theorem level_dyn (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A) :
    level (Plan.dyn b e f) = .dynamic := rfl

/-! ### Why this fold survives `case` when an exact bill does not

The `case` clause is a `Finset.sup` and every other analysis in the package that
crosses a branch is *not*, so it is worth saying exactly what the difference is —
because the obvious answer is wrong.

**It is not idempotence.** The tempting statement is "a `Const M`-valued analysis
survives `case` iff `M`'s combination is idempotent, which `max` is and a product
is not". Two folds in this repository refute it: `Plan.size` and
`Plan.askNodes` (`Agentic/Core/Explain.lean`) are total across `case`, which they
interpret as a *sum* over `FinEnum.toList` in `(ℕ, +)` — a monoid that is not
idempotent. What makes the sum an admissible reading of a branch is that a run
walks one arm and every node on that arm is a node of the term, so the arm's
count is bounded by the total; `Plan.length_trace_eq_askNodes` states the tight
half of that, at `≤ pipeline`, where there is no branch to bound. (The
over-approximation at `branch` itself is not formalized here; what is formalized
is that no *exact* analysis exists there, in `Agentic/Core/Cost.lean`.)

**The condition is order-theoretic: the interpretation of the copair must
dominate each arm.** `(ℕ, +, 0)` qualifies because it is *positively ordered*
(`0 ≤ n`, so every arm is `≤` the sum) and monotone in each argument; `sup` — the
`level_case` clause above — qualifies as the special case where the bound is
tight arm by arm;
a monoid with inverses does not qualify at all. So the honest statement of the
`branch` rung is not that a `Const M` analysis is impossible there but that an
**exact** one is: `Cost.no_static_bill_at_branch` is a witness (`coinBranch`
costs `ofAdd 2` under one world and `ofAdd 1` under another), and
`Cost.costM` exists because exactness, not soundness, is what a branch
destroys.

`level` itself is the tight case, which is why `level_case` needs no side
condition and why the analysis-availability theorems can take `level p ≤ ℓ` as
their only hypothesis. -/

/-! ## The elimination lemmas the analyses run on

Each says what a bound on a term's level says about its subterms: this is the
whole of how a `level p ≤ ℓ` hypothesis is consumed, and it is why the analyses
in `Agentic/Core/Cost.lean` need no auxiliary predicate on terms. -/

/-- Under an `askC` the level is unchanged. -/
theorem level_le_of_askC {ℓ : Level} {c : Code} {q : Request c} {k : Plan (c :: Γ) A}
    (h : level (Plan.askC c q k) ≤ ℓ) : level k ≤ ℓ := h

/-- An `ask` forces `pipeline` and bounds its continuation. -/
theorem le_of_ask {ℓ : Level} {c : Code} {s : Request.Shape c} {e : Expr Γ String}
    {k : Plan (c :: Γ) A} (h : level (Plan.ask c s e k) ≤ ℓ) :
    Level.pipeline ≤ ℓ ∧ level k ≤ ℓ :=
  max_le_iff.mp h

/-- A `case` forces `branch` and bounds every arm — *every* arm, because both
arms are in the term, which is exactly what makes the cost a finite tree. -/
theorem le_of_case {ℓ : Level} {t : Tag}
    {e : Expr Γ t.El} {arms : t.El → Plan Γ A} (h : level (Plan.case t e arms) ≤ ℓ) :
    Level.branch ≤ ℓ ∧ ∀ x, level (arms x) ≤ ℓ := by
  obtain ⟨hb, hs⟩ := max_le_iff.mp h
  exact ⟨hb, fun x => le_trans (Finset.le_sup (f := fun x => level (arms x))
    (Finset.mem_univ x)) hs⟩

/-- A `dyn` is at the top, so no bound below `dynamic` admits one. This is the
lemma that discharges the `dyn` case of every analysis: the fragment is not
described by a side condition, it is described by the level. -/
theorem not_le_of_dyn {ℓ : Level} {b : Code} {e : Expr Γ (El b)} {f : El b → Plan Γ A}
    (hlt : ℓ < Level.dynamic) (h : level (Plan.dyn b e f) ≤ ℓ) : False :=
  absurd (level_dyn b e f ▸ h) (not_le_of_gt hlt)

theorem pipeline_lt_dynamic : Level.pipeline < Level.dynamic := by decide

theorem branch_lt_dynamic : Level.branch < Level.dynamic := by decide

theorem batch_le_pipeline : Level.batch ≤ Level.pipeline := by decide

theorem pipeline_le_branch : Level.pipeline ≤ Level.branch := by decide

/-! ## The level is an invariant of the two structural operations -/

/-- **Morphism equation.** Renaming does not move the rung: the level is a fact
about which *formers* a term uses, and renaming rewrites only the pure `Expr`s.
With `Plan.sub_id` and `Plan.sub_comp` this says `level` is a natural
transformation out of the presheaf `Γ ↦ Plan Γ A` to the constant presheaf. -/
@[simp] theorem level_sub (p : Plan Γ A) : ∀ {Δ : Ctx} (σ : Sub Γ Δ), level (Plan.sub p σ) = level p := by
  induction p with
  | ret e => intro Δ σ; rfl
  | askC c q k ih => intro Δ σ; simpa [Plan.sub_askC] using ih _
  | ask c s e k ih =>
    intro Δ σ
    simp only [Plan.sub_ask, level_ask]
    exact congrArg _ (ih (Sub.lift σ))
  | case t e arms ih =>
    intro Δ σ
    simp only [Plan.sub_case, level_case]
    exact congrArg _ (Finset.sup_congr rfl fun t _ => ih t σ)
  | dyn b e f ih => intro Δ σ; rfl

/-- **Morphism equation.** Scope does not move the rung either: `under σ`
relabels questions and leaves the shape of the term alone, so the analyses
licensed at a rung are licensed at every scope. -/
@[simp] theorem level_under (σ : Sig) (p : Plan Γ A) : level (Plan.under σ p) = level p := by
  induction p with
  | ret e => rfl
  | askC c q k ih => simpa [Plan.under_askC] using ih
  | ask c s e k ih =>
    simp only [Plan.under_ask, level_ask]
    exact congrArg _ ih
  | case t e arms ih =>
    simp only [Plan.under_case, level_case]
    exact congrArg _ (Finset.sup_congr rfl fun t _ => ih t)
  | dyn b e f ih => rfl

/-! ## The derived forms, and where the rung actually moves

`Agentic/Core/Plan.lean` claims, in its module docstring, that the functorial
and applicative structure costs nothing while the monadic structure costs the
quarantine. These are the theorems that claim is made of. -/

/-- **Morphism equation for `graft`, as an over-approximation.** Grafting a
continuation that stays at or below `ℓ₀` cannot push a plan above
`level p ⊔ ℓ₀`. `≤` and not `=`: an arm-less `case` (`T` empty) grafts nothing,
so the continuation's rung need not appear in the result — the one place where
the join is genuinely lossy, and it is lossy in the safe direction. -/
theorem level_graft_le {B : Type} {ℓ₀ : Level} (p : Plan Γ A) :
    ∀ (k : Cont Γ A B), (∀ (Δ : Ctx) (σ : Sub Γ Δ) (e : Expr Δ A), level (k Δ σ e) ≤ ℓ₀) →
      level (Plan.graft p k) ≤ max (level p) ℓ₀ := by
  induction p with
  | ret e => intro k hk; exact le_trans (hk _ Sub.id e) (le_max_right _ _)
  | askC c q k ih =>
    intro k' hk
    simpa [Plan.graft_askC] using ih _ (fun Δ σ e => hk Δ _ e)
  | ask c s e k ih =>
    intro k' hk
    simp only [Plan.graft_ask, level_ask, level_ask, max_le_iff]
    refine ⟨le_trans (le_max_left _ _) (le_max_left _ _), ?_⟩
    refine le_trans (ih _ (fun Δ σ e => hk Δ _ e)) ?_
    exact max_le_max (le_max_right _ _) le_rfl
  | case t e arms ih =>
    intro k hk
    simp only [Plan.graft_case, level_case, max_le_iff, Finset.sup_le_iff]
    refine ⟨le_trans (le_max_left _ _) (le_max_left _ _), fun t _ => ?_⟩
    refine le_trans (ih t k hk) (max_le_max ?_ le_rfl)
    exact le_trans (Finset.le_sup (f := fun t => level (arms t)) (Finset.mem_univ t))
      (le_max_right _ _)
  | dyn b e f ih =>
    intro k hk
    simp only [Plan.graft_dyn, level_dyn]
    exact le_trans le_top (le_max_left _ _)

/-- **Grafting pure leaves is exact.** When the continuation is itself `batch`
the bound above is an equality, and the empty-`case` slack disappears because
`⊥` is the unit of the join. This is the lemma that gives `mapP` its rung. -/
theorem level_graft_of_batch {B : Type} (p : Plan Γ A) :
    ∀ (k : Cont Γ A B), (∀ (Δ : Ctx) (σ : Sub Γ Δ) (e : Expr Δ A), level (k Δ σ e) = .batch) →
      level (Plan.graft p k) = level p := by
  induction p with
  | ret e => intro k hk; exact (hk _ Sub.id e).trans rfl
  | askC c q k ih => intro k' hk; simpa [Plan.graft_askC] using ih _ (fun Δ σ e => hk Δ _ e)
  | ask c s e k ih =>
    intro k' hk
    simp only [Plan.graft_ask, level_ask]
    exact congrArg _ (ih _ (fun Δ σ e => hk Δ _ e))
  | case t e arms ih =>
    intro k hk
    simp only [Plan.graft_case, level_case]
    exact congrArg _ (Finset.sup_congr rfl fun t _ => ih t k hk)
  | dyn b e f ih => intro k hk; rfl

/-- **`mapP` does not move the rung.** The functorial action of a plan is free
of the analysis, which is the first half of `Plan.lean`'s asymmetry claim. -/
@[simp] theorem level_mapP (f : A → B) (p : Plan Γ A) : level (Plan.mapP f p) = level p :=
  level_graft_of_batch p _ (fun _ _ _ => rfl)

/-- **`zipWith` joins the rungs and adds nothing.** So a panel of `pipeline`
members is `pipeline`, and the applicative structure is free of the analysis
too — the second half of the asymmetry claim. -/
theorem level_zipWith_le (f : A → B → C) (p : Plan Γ A) (q : Plan Γ B) :
    level (Plan.zipWith f p q) ≤ max (level p) (level q) := by
  refine level_graft_le (ℓ₀ := level q) p _ (fun Δ σ e => ?_)
  refine le_trans (level_graft_le (ℓ₀ := Level.batch) (Plan.sub q σ) _
    (fun _ _ _ => le_of_eq (level_ret _))) ?_
  rw [level_sub]
  exact max_le le_rfl bot_le

/-- `seq` likewise. -/
theorem level_seq_le (p : Plan Γ A) (q : Plan Γ B) :
    level (Plan.seq p q) ≤ max (level p) (level q) :=
  level_graft_le p _ (fun _ σ _ => le_of_eq (level_sub q σ))

/-- A panel is at the join of its members' rungs: the owner's own example —
two reviewers sharing one reading of a style guide — is therefore `pipeline`,
and `Agentic/Core/Cost.lean` bills it exactly. -/
theorem level_panel_le [Monoid (El c)] (ps : List (Plan Γ (El c))) :
    level (Plan.panel ps) ≤ (ps.map level).foldr max .batch := by
  induction ps with
  | nil => exact le_of_eq rfl
  | cons p ps ih =>
    refine le_trans (level_zipWith_le _ p (Plan.panel ps)) ?_
    simpa using max_le_max (le_refl (level p)) ih

/-- **And `bindP` is dynamic, in the types.** General value-sequencing puts a
`dyn` at every leaf, so the one derived form the domain does *not* need is the
one that costs the quarantine. Stated at a `ret`, which is the leaf every
non-degenerate plan has. -/
@[simp] theorem level_bindP_ret {c : Code} (e : Expr Γ (El c)) (k : El c → Plan Γ B) :
    level (Plan.bindP (Plan.ret e) k) = .dynamic := rfl

/-! ## The four rungs are inhabited, and the authoring forms sit where they say -/

/-- A closed question is `batch`. -/
@[simp] theorem level_askC1 (c : Code) (q : Request c) :
    level (Plan.askC1 (Γ := Γ) c q) = .batch := rfl

/-- A question built from what is known is `pipeline` — the rung the kernel
exists to carry, and the reason a content-dependent prompt is not monadic. -/
@[simp] theorem level_ask1 (c : Code) (s : Request.Shape c) (e : Expr Γ String) :
    level (Plan.ask1 c s e) = .pipeline := rfl

/-- A two-armed branch is at least `branch`. -/
theorem branch_le_level_caseB (e : Expr Γ Bool) (t f : Plan Γ A) :
    Level.branch ≤ level (Plan.caseB e t f) :=
  le_max_left _ _

/-- The acceptance workload comes out `branch`, exactly as kernel §6's survival
table requires of `HardenPatch`: bounded revision branches on a finite verdict
tag and does nothing dynamic. -/
theorem level_upToTwice : level Acceptance.upToTwice = .branch := by decide

end Agentic.Core
