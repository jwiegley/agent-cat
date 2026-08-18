import Agentic.Core.Level

/-!
# The initial algebra, spent: what the twelve analyses now share

`Agentic/Core/Plan.lean`'s five formers are a signature, and every analysis in
this package is a homomorphism out of the syntax for that signature.
`Agentic/Core/Plan.lean` says so where the syntax is: `PlanAlg` is the
signature's algebra, `PlanAlg.fold` is the homomorphism it induces, and
`PlanAlg.fold_unique` is initiality — the fold is the *only* homomorphism.

**And now it is spent, not merely stated.** Eleven of the twelve structural
recursions in this package *are* `PlanAlg.fold` at an algebra, by definition and
not up to a proved equation:

| recursion | module | algebra | carrier |
|---|---|---|---|
| `Plan.sub` | `Plan.lean` | `Plan.subAlg` | `∀ Δ, Sub Γ Δ → Plan Δ A` |
| `Plan.under σ` | `Plan.lean` | `Plan.underAlg σ` | `Plan Γ A` |
| `Plan.graft` | `Plan.lean` | `Plan.graftAlg B` | `Cont Γ A B → Plan Γ B` |
| `denote` | `Denote.lean` | `denoteAlg` | `Env Γ → Dlg A` |
| `level` | `Level.lean` | `levelAlg` | `Level` |
| `codes` | `Cost.lean` | `codesAlg` | `Option (List Code)` |
| `shapes` | `Cost.lean` | `shapesAlg` | `Option (List Shape)` |
| `asks` | `Cost.lean` | `asksAlg` | `Env Γ → Option (List Key)` |
| `Plan.size` | `Explain.lean` | `Plan.sizeAlg` | `Nat` |
| `Plan.askNodes` | `Explain.lean` | `Plan.askNodesAlg` | `Nat` |
| `Plan.explain` | `Explain.lean` | `Plan.explainAlg` | `Nat → List String` |

Each keeps its five defining equations, as named theorems proved by `rfl`
(`sub_askC`, `level_case`, `denote_ask`, `codes_askC`, …), so the proofs that
used to unfold the recursion still say exactly what they said; what has gone is
eleven separate structural recursions and the eleven separate inductions that
would justify them. Three carriers are function spaces (`sub`, `graft`, `asks`,
and `explain`'s accumulator is its depth) — the ordinary fold-with-accumulator
move, and worth naming because it is the part that is not obvious.

**One does not fit**: `Cost.costM`, whose signature absorbs the level bound
(`(p : Plan Γ A) → level p ≤ Level.branch → …`) and an algebra carrier may not
mention `p`. That is the deliberate decision recorded at `Cost.lean`'s C3
section — "the analysis applies at this rung is the *type* of the fold rather
than a side condition" — so the honest count is eleven of twelve.

**Universe polymorphism is what makes one record serve every carrier**, and it
is now polymorphism with nothing to do: every carrier in the table is `Type 0`,
because closing `case`'s tag and `dyn`'s answer type — and making the answer
type `PlanF`'s *parameter* rather than an index — put `Plan` and `Cont` there
too. `PlanAlg` stays stated at `Type v` all the same: `Plan.rec` is
universe-polymorphic in its motive, the statement costs nothing, and an analysis
into a large carrier remains writable.

**What is left in this module** is what the substitution makes cheap: the
`X = fold XAlg` equations, now `rfl` rather than inductions, and the *uniqueness*
statements that follow from `fold_unique` — of which `denote_unique` is the one
the kernel's C-obligations assume and never state.
-/

namespace Agentic.Core

open Plan

/-! ## The two equations that used to be inductions -/

/-- **`level` is a fold** — now by definition. Kept as a theorem because the
statement is the content: `levelAlg`'s five fields are the five clauses. -/
theorem level_eq_fold {Γ : Ctx} {A : Type} (p : Plan Γ A) : level p = levelAlg.fold p := rfl

/-- **`denote` is a fold**, and the five clauses of `denoteAlg` are the kernel's
five morphism equations read as an algebra. Now by definition. -/
theorem denote_eq_fold {Γ : Ctx} {A : Type} (p : Plan Γ A) (γ : Env Γ) :
    denote p γ = denoteAlg.fold p γ := rfl

/-- **`sub` is a fold**, at the function-space carrier. -/
theorem sub_eq_fold {Γ Δ : Ctx} {A : Type} (p : Plan Γ A) (σ : Sub Γ Δ) :
    Plan.sub p σ = Plan.subAlg.fold p Δ σ := rfl

/-- **`under σ` is a fold**, back into the syntax. -/
theorem under_eq_fold {Γ : Ctx} {A : Type} (σ : Sig) (p : Plan Γ A) :
    Plan.under σ p = (Plan.underAlg σ).fold p := rfl

/-- **`graft` is a fold**, at the continuation-accumulating carrier. -/
theorem graft_eq_fold {Γ : Ctx} {A B : Type} (p : Plan Γ A) (k : Cont Γ A B) :
    Plan.graft p k = (Plan.graftAlg B).fold p k := rfl

/-! ## Uniqueness, which is what initiality buys -/

/-- …and `denote` is *the* homomorphism into that carrier: anything satisfying
the five morphism equations is `denote`. `fold_unique` at `denoteAlg`, which is
the uniqueness half the kernel's C-obligations assume and never state. -/
theorem denote_unique (h : {Γ : Ctx} → {A : Type} → Plan Γ A → Env Γ → Dlg A)
    (hret : ∀ {Γ A} (e : Expr Γ A), h (.ret e) = fun γ => Dlg.done (e γ))
    (haskC : ∀ {Γ A} c q (k : Plan (c :: Γ) A),
       h (.askC c q k) = fun γ => Dlg.ask c q (fun x => h k (Env.cons x γ)))
    (hask : ∀ {Γ A} c s e (k : Plan (c :: Γ) A),
       h (.ask c s e k) = fun γ => Dlg.ask c (s.withPrompt (e γ)) (fun x => h k (Env.cons x γ)))
    (hcase : ∀ {Γ A} (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A),
       h (.case t e arms) = fun γ => h (arms (e γ)) γ)
    (hdyn : ∀ {Γ A} (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A),
       h (.dyn b e f) = fun γ => h (f (e γ)) γ) :
    ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A) (γ : Env Γ), h p γ = denote p γ := by
  intro Γ A p γ
  rw [denoteAlg.fold_unique h hret haskC hask hcase hdyn p, ← denote_eq_fold]

/-- Likewise for the grading: anything satisfying `level`'s five equations *is*
`level`. The statement the package's `level_*` simp lemmas amount to, said
once. -/
theorem level_unique (h : {Γ : Ctx} → {A : Type} → Plan Γ A → Level)
    (hret : ∀ {Γ A} (e : Expr Γ A), h (.ret e) = Level.batch)
    (haskC : ∀ {Γ A} c q (k : Plan (c :: Γ) A), h (.askC c q k) = h k)
    (hask : ∀ {Γ A} c s e (k : Plan (c :: Γ) A),
       h (.ask c s e k) = max Level.pipeline (h k))
    (hcase : ∀ {Γ A} (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A),
       h (.case t e arms) = max Level.branch (Finset.univ.sup fun x => h (arms x)))
    (hdyn : ∀ {Γ A} (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A),
       h (.dyn b e f) = Level.dynamic) :
    ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A), h p = level p := by
  intro Γ A p
  rw [levelAlg.fold_unique h hret haskC hask hcase hdyn p, ← level_eq_fold]

end Agentic.Core
