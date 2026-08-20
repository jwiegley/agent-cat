/-
Verification artefact for `doc/research/profunctor-design/c-lean-side.md`.

Every declaration below elaborates against the built package at
`leanprover/lean4:v4.30.0` / `mathlib4 @ v4.30.0`:

    lake env lean doc/research/profunctor-design/c-lean-side-probes.lean

Expect no output. This file is NOT in any `lean_lib` glob (`["Agentic",
"Agentic.Core.+"]`) nor in any `srcDir`, so it cannot affect `lake build` and
changes nothing about the package.

It imports nothing that `Agentic/Core/` does not already import:
`Mathlib.Algebra.BigOperators.Group.List.Basic` by `Agentic/Core/Denote.lean`.
(`Mathlib.CategoryTheory.Category.Basic` used to be justified by
`Agentic/Meaning.lean`, which the `acat-q1i` excision removed on 2026-08-20; this
file is outside every `lake` target, so nothing depends on the claim either way.)

Contents, keyed to the page:

  §6.5  ctxCat                     — contexts and substitutions are a category
  §1.1  mapP_id', mapP_comp'       — the covariant functor laws, AT THE SYNTAX
  §6.1  Cont.Natural               — syntactic naturality of a continuation
        Cont.ofPlan / Cont.toPlan  — the Yoneda pair
        Cont.toPlan_ofPlan         — round trip one, no hypothesis
        Cont.ofPlan_toPlan         — round trip two, hypothesis IS naturality
        Cont.denotes_ofPlan        — `Plan.Denotes` for free
        sub_graft_of_natural       — the repair of `Morphism.sub_graft_not_natural`
        sub_mapP                   — the bifunctor coherence square
  §6.2  PlanAlg, fold, fold_unique — the initial algebra and its uniqueness
        levelAlg,  level_eq_fold   — `level` is a fold
        denoteAlg, denote_eq_fold  — `denote` is a fold
  §6.3  codes_eq_map_shapes        — fusion, unconditional
        shapes_eq_map_asks         — fusion, unconditional, in every environment
  §6.4  dlgMonoid                  — `Dlg` is lax monoidal
        runHom, traceHom           — `run ω`, `trace ω` are monoid homomorphisms
        denote_panel_prod          — `panel` is `List.prod`
        run_panel', trace_panel'   — both are `map_list_prod`, not inductions
-/

import Agentic.Core.Cost
import Agentic.Core.Morphism
import Mathlib.CategoryTheory.Category.Basic
import Mathlib.Algebra.BigOperators.Group.List.Basic

namespace Agentic.Core

open Plan

universe v

/-! ## §6.5 — contexts and substitutions are a Mathlib category, all laws `rfl` -/

/-- `Sub Γ Δ = Env Δ → Env Γ` is already the opposite of the environment
category, so `Plan.sub` is *covariant* here: `Plan (−) A : Ctx ⥤ Type 1`. -/
scoped instance ctxCat : CategoryTheory.Category.{0, 0} Ctx where
  Hom Γ Δ := Sub Γ Δ
  id _ := Sub.id
  comp σ τ := Sub.comp σ τ
  id_comp _ := rfl
  comp_id _ := rfl
  assoc _ _ _ := rfl

/-! ## §1.1 — the covariant functor laws hold at the syntax

`Morphism.mapP_id` and `Morphism.mapP_comp` state these up to `≈ᵖ`, through the
denotation. They hold on the nose. -/

section Functorial

variable {Γ Δ : Ctx} {A B C : Type}

theorem mapP_id' (p : Plan Γ A) : Plan.mapP id p = p := Morphism.graft_pure p

theorem mapP_comp' (f : A → B) (g : B → C) (p : Plan Γ A) :
    Plan.mapP g (Plan.mapP f p) = Plan.mapP (g ∘ f) p := by
  rw [Plan.mapP, Plan.mapP, Morphism.graft_assoc]
  rfl

end Functorial

/-! ## §6.1 — the `Cont`–Yoneda equivalence

`Env (c :: Γ) ≅ El c × Env Γ` (`Env.cons_head_tail`) gives, naturally in `Δ`,

    Hom(c :: Γ, Δ)  ≅  Expr Δ (El c) × Hom(Γ, Δ)

so `c :: Γ` *represents* `Expr (−) (El c) × Hom(Γ, −)`, with universal element
`(Sub.wk, Expr.var .here)` — weakening paired with the variable just bound.
Covariant Yoneda then reads

    { k : Cont Γ (El c) B // Cont.Natural k }  ≅  Plan (c :: Γ) B
-/

section Yoneda

variable {Γ Δ Ξ : Ctx} {A B : Type} {c : Code}

/-- Naturality of a continuation family in the context variable: the condition
`Cont`'s *type* does not impose, and that `Morphism.wobbly` violates. -/
def Cont.Natural {Γ : Ctx} {A B : Type} (k : Cont Γ A B) : Prop :=
  ∀ (Δ Ξ : Ctx) (τ : Sub Γ Δ) (e : Expr Δ A) (ρ : Sub Δ Ξ),
    Plan.sub (k Δ τ e) ρ = k Ξ (Sub.comp τ ρ) (fun ξ => e (ρ ξ))

/-- Reindexing a continuation along a context morphism. -/
def Cont.reindex (k : Cont Γ A B) (σ : Sub Γ Δ) : Cont Δ A B :=
  fun Θ τ e => k Θ (Sub.comp σ τ) e

theorem Cont.reindex_natural {k : Cont Γ A B} (hk : Cont.Natural k) (σ : Sub Γ Δ) :
    Cont.Natural (Cont.reindex k σ) := by
  intro Θ Ξ τ e ρ
  exact hk Θ Ξ (Sub.comp σ τ) e ρ

/-- Yoneda, one way: a plan in the extended context *is* a natural
continuation. -/
def Cont.ofPlan (q : Plan (c :: Γ) B) : Cont Γ (El c) B :=
  fun _ σ e => Plan.sub q (fun δ => Env.cons (e δ) (σ δ))

/-- Yoneda, the other way: evaluate the family at the universal element. -/
def Cont.toPlan (k : Cont Γ (El c) B) : Plan (c :: Γ) B :=
  k (c :: Γ) Sub.wk (Expr.var .here)

theorem Cont.ofPlan_natural (q : Plan (c :: Γ) B) : Cont.Natural (Cont.ofPlan q) := by
  intro Δ Ξ τ e ρ
  simp only [Cont.ofPlan, Plan.sub_comp]

/-- **Round trip one: no hypothesis at all.**  `Env.cons_head_tail` and
`Plan.sub_id` are the whole proof. -/
theorem Cont.toPlan_ofPlan (q : Plan (c :: Γ) B) : Cont.toPlan (Cont.ofPlan q) = q := by
  simp only [Cont.toPlan, Cont.ofPlan]
  have h : (fun δ : Env (c :: Γ) => Env.cons (Expr.var (Var.here) δ) (Sub.wk δ)) = Sub.id := by
    funext δ; exact Env.cons_head_tail δ
  rw [h, Plan.sub_id]

/-- **Round trip two: exactly naturality, nothing more.**  The round trip *is*
the naturality condition — which is what makes `Cont.Natural` the right notion
rather than a guess. -/
theorem Cont.ofPlan_toPlan (k : Cont Γ (El c) B) (hk : Cont.Natural k) :
    Cont.ofPlan (Cont.toPlan k) = k := by
  funext Δ σ e
  simp only [Cont.ofPlan, Cont.toPlan]
  rw [hk (c :: Γ) Δ Sub.wk (Expr.var .here) (fun δ => Env.cons (e δ) (σ δ))]
  rfl

/-- **`Plan.Denotes` stops being a hypothesis.**  A continuation that comes from
a plan denotes the obvious semantic continuation, by `denote_sub`. -/
theorem Cont.denotes_ofPlan (q : Plan (c :: Γ) B) :
    Plan.Denotes (Cont.ofPlan q) (fun a γ => denote q (Env.cons a γ)) := by
  intro Δ σ e δ
  simp only [Cont.ofPlan, denote_sub]

/-- **The repair of `Morphism.sub_graft_not_natural`.**  Grafting commutes with
renaming exactly when the continuation does.  The counterexample stays: it is
now the witness that this hypothesis is not vacuous. -/
theorem sub_graft_of_natural {B : Type} :
    ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A) {Δ : Ctx} (σ : Sub Γ Δ) (k : Cont Γ A B),
      Cont.Natural k →
      Plan.sub (Plan.graft p k) σ = Plan.graft (Plan.sub p σ) (Cont.reindex k σ) := by
  intro Γ A p
  induction p with
  | ret e => intro Δ σ k hk; exact hk _ _ Sub.id e σ
  | askC c q k ih =>
      intro Δ σ k₁ hk
      simp only [Plan.graft, Plan.sub]
      exact congrArg _ (ih (Sub.lift σ) _ (fun Θ Ξ τ e ρ => hk Θ Ξ _ e ρ))
  | ask c s e k ih =>
      intro Δ σ k₁ hk
      simp only [Plan.graft, Plan.sub]
      exact congrArg _ (ih (Sub.lift σ) _ (fun Θ Ξ τ e ρ => hk Θ Ξ _ e ρ))
  | case e arms ih =>
      intro Δ σ k₁ hk
      simp only [Plan.graft, Plan.sub]
      exact congrArg _ (funext fun t => ih t σ _ hk)
  | dyn e f ih =>
      intro Δ σ k₁ hk
      simp only [Plan.graft, Plan.sub]
      exact congrArg _ (funext fun b => ih b σ _ hk)

/-- **The bifunctor coherence square**, which the package does not currently
state: `Plan` really is a functor in both variables at the syntax. -/
theorem sub_mapP (f : A → B) (p : Plan Γ A) (σ : Sub Γ Δ) :
    Plan.sub (Plan.mapP f p) σ = Plan.mapP f (Plan.sub p σ) :=
  sub_graft_of_natural p σ _ (fun _ _ _ _ _ => rfl)

end Yoneda

/-! ## §6.2 — the initial algebra: one recursion, one uniqueness theorem -/

/-- An algebra for the `Plan` signature, indexed the way `Plan` is.  Universe
polymorphic in the carrier, so `Level : Type 0`, `Env Γ → Dlg A : Type 0` and
`CostTree S : Type 1` are all admissible targets. -/
structure PlanAlg (P : Ctx → Type → Type v) where
  ret  : {Γ : Ctx} → {A : Type} → Expr Γ A → P Γ A
  askC : {Γ : Ctx} → {A : Type} → (c : Code) → Q c → P (c :: Γ) A → P Γ A
  ask  : {Γ : Ctx} → {A : Type} → (c : Code) → Q.Shape c → Expr Γ String → P (c :: Γ) A → P Γ A
  case : {Γ : Ctx} → {A : Type} → {T : Type} → [FinEnum T] → [DecidableEq T] →
           Expr Γ T → (T → P Γ A) → P Γ A
  dyn  : {Γ : Ctx} → {A B : Type} → Expr Γ B → (B → P Γ A) → P Γ A

namespace PlanAlg

variable {P : Ctx → Type → Type v} (alg : PlanAlg P)

/-- The homomorphism out of the syntax: **one** structural recursion for all ten
analysis folds. -/
def fold : {Γ : Ctx} → {A : Type} → Plan Γ A → P Γ A
  | _, _, .ret e => alg.ret e
  | _, _, .askC c q k => alg.askC c q (fold k)
  | _, _, .ask c s e k => alg.ask c s e (fold k)
  | _, _, @Plan.case _ _ T _ _ e arms => alg.case (T := T) e (fun t => fold (arms t))
  | _, _, .dyn e f => alg.dyn e (fun b => fold (f b))

/-- **Initiality: the fold is the only homomorphism.**  One induction, once, in
place of one per analysis. -/
theorem fold_unique (h : {Γ : Ctx} → {A : Type} → Plan Γ A → P Γ A)
    (hret : ∀ {Γ A} (e : Expr Γ A), h (.ret e) = alg.ret e)
    (haskC : ∀ {Γ A} c q (k : Plan (c :: Γ) A), h (.askC c q k) = alg.askC c q (h k))
    (hask : ∀ {Γ A} c s e (k : Plan (c :: Γ) A), h (.ask c s e k) = alg.ask c s e (h k))
    (hcase : ∀ {Γ A T} [FinEnum T] [DecidableEq T] (e : Expr Γ T) (arms : T → Plan Γ A),
       h (.case e arms) = alg.case e (fun t => h (arms t)))
    (hdyn : ∀ {Γ A B} (e : Expr Γ B) (f : B → Plan Γ A),
       h (.dyn e f) = alg.dyn e (fun b => h (f b))) :
    ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A), h p = alg.fold p := by
  intro Γ A p
  induction p with
  | ret e => exact hret e
  | askC c q k ih => rw [haskC, ih]; rfl
  | ask c s e k ih => rw [hask, ih]; rfl
  | case e arms ih => rw [hcase]; exact congrArg _ (funext fun t => ih t)
  | dyn e f ih => rw [hdyn]; exact congrArg _ (funext fun b => ih b)

end PlanAlg

/-- `Agentic.Core.level` as an algebra. -/
def levelAlg : PlanAlg (fun _ _ => Level) where
  ret _ := .batch
  askC _ _ l := l
  ask _ _ _ l := max .pipeline l
  case := fun {_} {_} {_} _ _ _ arms => max .branch (Finset.univ.sup fun t => arms t)
  dyn _ _ := .dynamic

theorem level_eq_fold {Γ : Ctx} {A : Type} (p : Plan Γ A) : level p = levelAlg.fold p := by
  induction p with
  | ret e => rfl
  | askC c q k ih => exact ih
  | ask c s e k ih => exact congrArg _ ih
  | case e arms ih => exact congrArg _ (Finset.sup_congr rfl fun t _ => ih t)
  | dyn e f _ => rfl

/-- `Agentic.Core.denote` as an algebra, at the carrier `P Γ A = Env Γ → Dlg A`. -/
def denoteAlg : PlanAlg (fun Γ A => Env Γ → Dlg A) where
  ret e := fun γ => Dlg.done (e γ)
  askC c q k := fun γ => Dlg.ask c q (fun x => k (Env.cons x γ))
  ask c s e k := fun γ => Dlg.ask c (s.withPrompt (e γ)) (fun x => k (Env.cons x γ))
  case := fun e arms γ => arms (e γ) γ
  dyn := fun e f γ => f (e γ) γ

theorem denote_eq_fold : ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A) (γ : Env Γ),
    denote p γ = denoteAlg.fold p γ := by
  intro Γ A p
  induction p with
  | ret e => intro γ; rfl
  | askC c q k ih =>
      intro γ
      show Dlg.ask c q (fun x => denote k (Env.cons x γ)) = _
      exact congrArg _ (funext fun x => ih _)
  | ask c s e k ih =>
      intro γ
      show Dlg.ask c (s.withPrompt (e γ)) (fun x => denote k (Env.cons x γ)) = _
      exact congrArg _ (funext fun x => ih _)
  | case e arms ih => intro γ; exact ih (e γ) γ
  | dyn e f ih => intro γ; exact ih (e γ) γ

/-! ## §6.3 — analysis fusion, with no level hypothesis

The level bound belongs to *totality*, not to *factorisation*.  Both equations
below hold at `branch` and `dynamic` too, where both sides are `none`. -/

section Fusion

variable {Γ : Ctx} {A : Type}

/-- **Fusion 1.**  `codes` is not an independent analysis: it is `shapes` read
through `Shape.code`. -/
theorem codes_eq_map_shapes (p : Plan Γ A) :
    codes p = (shapes p).map (List.map Shape.code) := by
  induction p with
  | ret e => rfl
  | askC c q k ih => simp [codes, shapes, ih, Option.map_map, Function.comp_def, Shape.code]
  | ask c s e k ih => simp [codes, shapes, ih, Option.map_map, Function.comp_def, Shape.code]
  | case e arms _ => rfl
  | dyn e f _ => rfl

/-- **Fusion 2, and in every environment.**  `shapes` is `asks` read through
`Key.shape`: the environment `asks` needs is exactly the data `Key.shape`
throws away.  This is a sharper statement of "the shape is a projection of the
syntax" than `shapes_eq_of_le_pipeline`. -/
theorem shapes_eq_map_asks : ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A) (γ : Env Γ),
    shapes p = (asks p γ).map (List.map Key.shape) := by
  intro Γ A p
  induction p with
  | ret e => intro γ; rfl
  | askC c q k ih =>
      intro γ
      simp [shapes, asks, ih (Env.cons default γ), Option.map_map, Function.comp_def, Key.shape]
  | ask c s e k ih =>
      intro γ
      simp [shapes, asks, ih (Env.cons default γ), Option.map_map, Function.comp_def, Key.shape]
  | case e arms _ => intro γ; rfl
  | dyn e f _ => intro γ; rfl

/-- …and the three totality theorems collapse to one. -/
example (p : Plan Γ A) (h : level p ≤ Level.pipeline) : (codes p).isSome := by
  rw [codes_eq_map_shapes]; simpa using shapes_isSome_of_le_pipeline p h

end Fusion

/-! ## §6.4 — `Dlg` is a lax monoidal functor, so panels are `List.prod` -/

section LaxMonoidal

variable {M : Type} [Monoid M]

/-- **`Dlg` carries monoids to monoids.**  The product is `liftA2 (*)`,
sequential in the transcript — so `trace_panel_not_perm_invariant` stays true,
which is the test of whether the abstraction is the right one. -/
scoped instance dlgMonoid : Monoid (Dlg M) where
  one := Dlg.done 1
  mul x y := Dlg.bind x (fun a => Dlg.bind y (fun b => Dlg.done (a * b)))
  one_mul x := by
    show Dlg.bind (Dlg.done (1 : M)) _ = x
    simp only [Dlg.bind_eq_bind, Dlg.done_eq_pure, pure_bind, one_mul, bind_pure]
  mul_one x := by
    show Dlg.bind x (fun a => Dlg.bind (Dlg.done (1 : M)) _) = x
    simp only [Dlg.bind_eq_bind, Dlg.done_eq_pure, pure_bind, mul_one, bind_pure]
  mul_assoc x y z := by
    show Dlg.bind (Dlg.bind x _) _ = Dlg.bind x (fun a => Dlg.bind (Dlg.bind y _) _)
    simp only [Dlg.bind_eq_bind, Dlg.done_eq_pure, bind_assoc, pure_bind, mul_assoc]

/-- `run ω` is a monoid homomorphism out of it. -/
def runHom (ω : Ω) : Dlg M →* M where
  toFun := Dlg.run ω
  map_one' := rfl
  map_mul' x y := by
    show Dlg.run ω (Dlg.bind x (fun a => Dlg.bind y (fun b => Dlg.done (a * b)))) = _
    rw [Dlg.bind_eq_bind, Dlg.run_bind', Dlg.bind_eq_bind, Dlg.run_bind']
    rfl

/-- …and so is `trace ω`, into the free monoid on events. -/
def traceHom (ω : Ω) : Dlg M →* FreeMonoid Event where
  toFun := fun x => FreeMonoid.ofList (Dlg.trace ω x)
  map_one' := rfl
  map_mul' x y := by
    show FreeMonoid.ofList (Dlg.trace ω (Dlg.bind x (fun a => Dlg.bind y _))) = _
    rw [Dlg.bind_eq_bind, Dlg.trace_bind', Dlg.bind_eq_bind, Dlg.trace_bind']
    show FreeMonoid.ofList (Dlg.trace ω x ++ (Dlg.trace ω y ++ [])) = _
    rw [List.append_nil, FreeMonoid.ofList_append]

/-- **`panel` is `List.prod` in `Dlg (El c)`** — it has no fold of its own. -/
theorem denote_panel_prod {Γ : Ctx} {c : Code} [Monoid (El c)]
    (ps : List (Plan Γ (El c))) (γ : Env Γ) :
    denote (Plan.panel ps) γ = (ps.map (fun p => denote p γ)).prod := by
  induction ps with
  | nil => rfl
  | cons p ps ih =>
      simp only [Plan.panel_cons, List.map_cons, List.prod_cons, denote_zipWith, ih]
      rfl

/-- **`run_panel` is `map_list_prod`, not an induction.** -/
theorem run_panel' {Γ : Ctx} {c : Code} [Monoid (El c)] (ω : Ω)
    (ps : List (Plan Γ (El c))) (γ : Env Γ) :
    Plan.run ω (Plan.panel ps) γ = (ps.map (fun p => Plan.run ω p γ)).prod := by
  show Dlg.run ω (denote (Plan.panel ps) γ) = _
  have hm : (ps.map fun p => Plan.run ω p γ)
      = (ps.map fun p => denote p γ).map (Dlg.run ω) := by
    simp [List.map_map, Plan.run, Function.comp_def]
  rw [denote_panel_prod, hm]
  exact (runHom ω).map_list_prod _

/-- **…and so is `trace_panel`.** -/
theorem trace_panel' {Γ : Ctx} {c : Code} [Monoid (El c)] (ω : Ω)
    (ps : List (Plan Γ (El c))) (γ : Env Γ) :
    Plan.trace ω (Plan.panel ps) γ = (ps.map (fun p => Plan.trace ω p γ)).flatten := by
  show Dlg.trace ω (denote (Plan.panel ps) γ) = _
  have h := (traceHom (M := El c) ω).map_list_prod (ps.map (fun p => denote p γ))
  have hm : (ps.map fun p => Plan.trace ω p γ)
      = (ps.map fun p => denote p γ).map (Dlg.trace ω) := by
    simp [List.map_map, Plan.trace, Function.comp_def]
  have hf : ∀ l : List (List Event),
      FreeMonoid.toList (l.map FreeMonoid.ofList).prod = l.flatten := by
    intro l; induction l with
    | nil => rfl
    | cons a l ih =>
        show a ++ FreeMonoid.toList (l.map FreeMonoid.ofList).prod = _
        rw [ih]; rfl
  rw [denote_panel_prod, hm]
  have hc := congrArg FreeMonoid.toList h
  simp only [traceHom, MonoidHom.coe_mk, OneHom.coe_mk, List.map_map, Function.comp_def] at hc
  refine hc.trans ?_
  have := hf (ps.map fun p => Dlg.trace ω (denote p γ))
  simp only [List.map_map, Function.comp_def] at this
  simp [List.map_map, Function.comp_def]

end LaxMonoidal

/-! ## Axiom footprints of the new material

The same footprint the modules these would join already have:
`Plan.sub_id` is `[propext, Quot.sound]`, `Plan.sub_comp` is `[Quot.sound]`,
`level_sub` and `bill_mem_leaves` are `[propext, Classical.choice, Quot.sound]`.
`Quot.sound` is unavoidable wherever `funext` is used — Lean 4 derives `funext`
from it.  Neither `Certify.certify_sound` (no axioms) nor `Plan.adequacy`
(`[propext]`) reaches any of this. -/

#print axioms Cont.toPlan_ofPlan
#print axioms Cont.ofPlan_toPlan
#print axioms sub_graft_of_natural
#print axioms codes_eq_map_shapes
#print axioms shapes_eq_map_asks
#print axioms PlanAlg.fold_unique
#print axioms run_panel'

end Agentic.Core
