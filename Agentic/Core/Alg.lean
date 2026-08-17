import Agentic.Core.Level

/-!
# The initial algebra: one recursion for twelve analyses

`Agentic/Core/Plan.lean`'s five formers are a signature, and every analysis in
this package is a homomorphism out of the syntax for that signature. This module
says so once: `PlanAlg` is the signature's algebra, `PlanAlg.fold` is the
homomorphism it induces, and `PlanAlg.fold_unique` is initiality — the fold is
the *only* homomorphism, so the structural inductions the package writes one per
analysis are all the same induction.

**Additive, and deliberately so.** `level` and `denote` keep their own recursive
definitions and their own `@[simp]` equation lemmas; what is proved here is that
each *equals* the corresponding fold (`level_eq_fold`, `denote_eq_fold`).
Replacing the twelve recursion bodies with `fold` is a different change with a
different risk, and the risk is not line count: `Level.lean`'s
`level_upToTwice` is `by decide`, `Denote.lean`'s `trace_upToTwice_stubborn` and
`run_upToTwice_stubborn` are `by rfl`, `Cost.lean`'s `bill_constBranch` is
`rfl`, and `Agentic/Core/DslFlagship.lean` carries nineteen `decide +kernel`
proofs. Routing a definition through `fold` puts `Plan.brecOn` and a structure
projection between the kernel and every one of those, and *kernel reduction*,
not elaboration, is the thing that would break. So this module proves the
equations and changes no definition; the substitution waits on a measured timing
diff.

**Universe polymorphism is what makes one record serve every carrier.** The
package's analysis targets live at different universes — `Level` and
`Env Γ → Dlg A` are `Type 0`, `Cost.CostTree S` is `Type 1` — and `Plan.rec` is
universe-polymorphic in its motive, so `PlanAlg` is stated at `Type v` and one
structure covers all of them.

**Which recursions fit.** Ten fit at the obvious carrier (`denote`, `level`,
`codes`, `shapes`, `asks`, `Plan.size`, `Plan.askNodes`, `Plan.explain`, and
`Plan.under` at `P Γ A = Plan Γ A`). Two fit at a function-space carrier, which
is the ordinary fold-with-accumulator move: `Plan.sub` is the fold at
`P Γ A = ∀ Δ, Sub Γ Δ → Plan Δ A`, and `Plan.graft` is the fold at
`P Γ A = Cont Γ A B → Plan Γ B`, whose `askC` clause is
`fun rec k => .askC c q (rec (Cont.reindex k Sub.wk))` — so "rebuild the
continuation with one more weakening" is literally the algebra acting on its
accumulator. **One does not fit**: `Cost.costTree`, whose signature absorbs the
level bound (`(p : Plan Γ A) → level p ≤ Level.branch → …`) and an algebra
carrier may not mention `p`. That is the deliberate decision recorded at
`Cost.lean`'s cost-tree section — "the analysis applies at this rung is the
*type* of the fold rather than a side condition" — so the honest count is eleven
of twelve.
-/

namespace Agentic.Core

open Plan

universe v

/-- `[[PlanAlg P]]` = an algebra for the `Plan` signature, indexed the way `Plan`
is: one field per former, with the recursive positions replaced by the carrier.

The five fields *are* the structure a target must carry for an interpretation to
exist — in this package's own vocabulary, and not in a hierarchy of profunctor
classes. `ret` is the pure part, `askC` a nullary generator's binding, `ask` a
unary generator's, `case` the finite copair and `dyn` the one higher-order
former. -/
structure PlanAlg (P : Ctx → Type → Type v) where
  /-- What a pure leaf becomes. -/
  ret  : {Γ : Ctx} → {A : Type} → Expr Γ A → P Γ A
  /-- What a closed question and its binding become. -/
  askC : {Γ : Ctx} → {A : Type} → (c : Code) → Q c → P (c :: Γ) A → P Γ A
  /-- What an open question — shape in the term, words computed — and its
  binding become. -/
  ask  : {Γ : Ctx} → {A : Type} → (c : Code) → Q.Shape c → Expr Γ String → P (c :: Γ) A → P Γ A
  /-- What a finite branch becomes: the copair over the tag type. -/
  case : {Γ : Ctx} → {A : Type} → {T : Type} → [FinEnum T] → [DecidableEq T] →
           Expr Γ T → (T → P Γ A) → P Γ A
  /-- What the quarantined dynamic former becomes. -/
  dyn  : {Γ : Ctx} → {A B : Type} → Expr Γ B → (B → P Γ A) → P Γ A

namespace PlanAlg

variable {P : Ctx → Type → Type v} (alg : PlanAlg P)

/-- `[[alg.fold p]]` = the homomorphism out of the syntax. **One** structural
recursion, in place of one per analysis. -/
def fold : {Γ : Ctx} → {A : Type} → Plan Γ A → P Γ A
  | _, _, .ret e => alg.ret e
  | _, _, .askC c q k => alg.askC c q (fold k)
  | _, _, .ask c s e k => alg.ask c s e (fold k)
  | _, _, @Plan.case _ _ T _ _ e arms => alg.case (T := T) e (fun t => fold (arms t))
  | _, _, .dyn e f => alg.dyn e (fun b => fold (f b))

@[simp] theorem fold_ret {Γ : Ctx} {A : Type} (e : Expr Γ A) :
    alg.fold (Plan.ret e) = alg.ret e := rfl

@[simp] theorem fold_askC {Γ : Ctx} {A : Type} (c : Code) (q : Q c) (k : Plan (c :: Γ) A) :
    alg.fold (Plan.askC c q k) = alg.askC c q (alg.fold k) := rfl

@[simp] theorem fold_ask {Γ : Ctx} {A : Type} (c : Code) (s : Q.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) :
    alg.fold (Plan.ask c s e k) = alg.ask c s e (alg.fold k) := rfl

@[simp] theorem fold_case {Γ : Ctx} {A T : Type} [FinEnum T] [DecidableEq T]
    (e : Expr Γ T) (arms : T → Plan Γ A) :
    alg.fold (Plan.case e arms) = alg.case e (fun t => alg.fold (arms t)) := rfl

@[simp] theorem fold_dyn {Γ : Ctx} {A B : Type} (e : Expr Γ B) (f : B → Plan Γ A) :
    alg.fold (Plan.dyn e f) = alg.dyn e (fun b => alg.fold (f b)) := rfl

/-- **Initiality: the fold is the only homomorphism.** Anything that satisfies
the five equations *is* the fold.

This is the theorem the package has been proving one instance at a time. Given
it, a new analysis costs an algebra record and its five equations — which are
`rfl` if the analysis was written as a recursion — and every invariance result
about it is a fusion argument rather than a fresh induction. -/
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

/-! ## The two instances that matter, at opposite ends of the package -/

/-- `Agentic/Core/Level.lean`'s `level`, as an algebra. The carrier is
`Const Level` — no argument position at all, which is what "the level is a fact
about the term" means — and the `case` clause is the join, which is the tight
case of the domination condition recorded beside `level`. -/
def levelAlg : PlanAlg (fun _ _ => Level) where
  ret _ := .batch
  askC _ _ l := l
  ask _ _ _ l := max .pipeline l
  case := fun {_} {_} {_} _ _ _ arms => max .branch (Finset.univ.sup fun t => arms t)
  dyn _ _ := .dynamic

/-- **`level` is a fold.** Its definition stays; this says what it is. -/
theorem level_eq_fold {Γ : Ctx} {A : Type} (p : Plan Γ A) : level p = levelAlg.fold p := by
  induction p with
  | ret e => rfl
  | askC c q k ih => exact ih
  | ask c s e k ih => exact congrArg _ ih
  | case e arms ih => exact congrArg _ (Finset.sup_congr rfl fun t _ => ih t)
  | dyn e f _ => rfl

/-- `Agentic/Core/Denote.lean`'s `denote`, as an algebra, at the function-space
carrier `P Γ A = Env Γ → Dlg A`. The meaning is a fold like every other analysis;
what distinguishes it is the carrier, not the shape of the recursion. -/
def denoteAlg : PlanAlg (fun Γ A => Env Γ → Dlg A) where
  ret e := fun γ => Dlg.done (e γ)
  askC c q k := fun γ => Dlg.ask c q (fun x => k (Env.cons x γ))
  ask c s e k := fun γ => Dlg.ask c (s.withPrompt (e γ)) (fun x => k (Env.cons x γ))
  case := fun e arms γ => arms (e γ) γ
  dyn := fun e f γ => f (e γ) γ

/-- **`denote` is a fold**, and the five clauses of `denoteAlg` are the kernel's
five morphism equations read as an algebra. Its definition stays. -/
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

/-- …and `denote` is *the* homomorphism into that carrier: anything satisfying
the five morphism equations is `denote`. `fold_unique` at `denoteAlg`, which is
the uniqueness half the kernel's C-obligations assume and never state. -/
theorem denote_unique (h : {Γ : Ctx} → {A : Type} → Plan Γ A → Env Γ → Dlg A)
    (hret : ∀ {Γ A} (e : Expr Γ A), h (.ret e) = fun γ => Dlg.done (e γ))
    (haskC : ∀ {Γ A} c q (k : Plan (c :: Γ) A),
       h (.askC c q k) = fun γ => Dlg.ask c q (fun x => h k (Env.cons x γ)))
    (hask : ∀ {Γ A} c s e (k : Plan (c :: Γ) A),
       h (.ask c s e k) = fun γ => Dlg.ask c (s.withPrompt (e γ)) (fun x => h k (Env.cons x γ)))
    (hcase : ∀ {Γ A T} [FinEnum T] [DecidableEq T] (e : Expr Γ T) (arms : T → Plan Γ A),
       h (.case e arms) = fun γ => h (arms (e γ)) γ)
    (hdyn : ∀ {Γ A B} (e : Expr Γ B) (f : B → Plan Γ A),
       h (.dyn e f) = fun γ => h (f (e γ)) γ) :
    ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A) (γ : Env Γ), h p γ = denote p γ := by
  intro Γ A p γ
  rw [denoteAlg.fold_unique h hret haskC hask hcase hdyn p, ← denote_eq_fold]

end Agentic.Core
