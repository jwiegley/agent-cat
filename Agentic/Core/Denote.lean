import Agentic.Core.Plan
import Mathlib.Algebra.BigOperators.Group.List.Basic

/-!
# The meaning of a plan: `denote`, the fold

Rederivation kernel §2.2 (the five morphism equations *are* the specification),
§3 q9 (equality is the kernel of the meaning), §4 C0, §5(i) (the interpreter is
the fold, so commutation is `rfl`).

```
denote : Plan Γ A → Env Γ → Dlg A
```

is the whole content of this module: one compositional map, defined by
structural recursion on the syntax, into the object that already *is* the
coherent world-indexed `(answer, transcript)` pair. Everything else here is a
morphism equation — for the five formers, for renaming, for scope, for grafting,
and for each derived form of `Agentic/Core/Plan.lean` — proved adjacent to the
fold it is about, because the fold lives here.

Three consequences worth stating in advance.

* **`run` and `trace` of a plan are `run` and `trace` of its denotation**, by
  definition (`Plan.run`, `Plan.trace`). There is no second semantics, no
  interpreter to be proved adequate against the meaning, and no `IO`: §5(i)'s
  commutation is `rfl` because the interpreter *is* this fold.
* **Congruence is free.** `Plan.Equiv` is the kernel of `denote`, hence an
  equivalence and a congruence for every derived form, with no proof obligation
  beyond the morphism equations themselves.
* **The asymmetry is in the types.** `mapP`, `zipWith`, `panel`, `seq` and
  `graft` all get exact morphism equations with no side condition; the only
  derived form whose equation needs the `dyn` former is `bindP`, general
  value-sequencing. That is the graded hierarchy showing up in the derivations
  rather than being asserted about them.
-/

namespace Agentic.Core

open Plan

/-! ## The fold -/

/-- The meaning, as an algebra, at the function-space carrier
`P Γ A = Env Γ → Dlg A`. `denote` just below is its fold.

Compositional by construction: one field per former, each of which is the
morphism equation of kernel §2.2, so the equations below are the specification
and this algebra is their solved form.

```
denote (ret e)        γ = .done (e γ)
denote (askC c q k)   γ = .ask c q                    (fun x => denote k (γ ▷ x))
denote (ask c s e k)  γ = .ask c (s.withPrompt (e γ)) (fun x => denote k (γ ▷ x))
denote (case e arms)  γ = denote (arms (e γ)) γ
denote (dyn  e f)     γ = denote (f (e γ))    γ
```

`case` and `dyn` have the *same* meaning clause. That is not redundancy: the
difference between them is that `case`'s tag type is finite and its arms are
both in the term, so the two nodes are distinguished by what can be *analysed*
about them, not by what they mean. Recording the distinction in the syntax is
exactly `attack-adequacy` F1's requirement, and it is available here precisely
because the meaning does not record it. -/
def denoteAlg : PlanAlg (fun Γ A => Env Γ → Dlg A) where
  ret e := fun γ => Dlg.done (e γ)
  askC c q k := fun γ => Dlg.ask c q (fun x => k (Env.cons x γ))
  ask c s e k := fun γ => Dlg.ask c (s.withPrompt (e γ)) (fun x => k (Env.cons x γ))
  case := fun _ e arms γ => arms (e γ) γ
  dyn := fun _ e f γ => f (e γ) γ

/-- `[[denote p γ]]` = the dialogue `p` is, under the environment `γ`.

`denoteAlg.fold`: the meaning is the fold like every other analysis, and the
five clauses of `denoteAlg` are the kernel's five morphism equations read as an
algebra. The equations below are `rfl` and stay `@[simp]`. -/
def denote {A : Type} : {Γ : Ctx} → Plan Γ A → Env Γ → Dlg A :=
  fun p => denoteAlg.fold p

variable {Γ Δ Θ : Ctx} {A B C : Type}

@[simp] theorem denote_ret (e : Expr Γ A) (γ : Env Γ) :
    denote (Plan.ret e) γ = .done (e γ) := rfl

@[simp] theorem denote_askC (c : Code) (q : Q c) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    denote (Plan.askC c q k) γ = .ask c q (fun x => denote k (.cons x γ)) := rfl

@[simp] theorem denote_ask (c : Code) (s : Q.Shape c) (e : Expr Γ String) (k : Plan (c :: Γ) A)
    (γ : Env Γ) :
    denote (Plan.ask c s e k) γ
      = .ask c (s.withPrompt (e γ)) (fun x => denote k (.cons x γ)) := rfl

@[simp] theorem denote_case (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A) (γ : Env Γ) :
    denote (Plan.case t e arms) γ = denote (arms (e γ)) γ := rfl

@[simp] theorem denote_dyn (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A) (γ : Env Γ) :
    denote (Plan.dyn b e f) γ = denote (f (e γ)) γ := rfl

/-- `Dlg.bind` is the `Monad` instance's `>>=`. A `rfl`, stated so that the
class morphism equations below can be written in the standard vocabulary. -/
theorem Dlg.bind_eq_bind (x : Dlg A) (k : A → Dlg B) : Dlg.bind x k = x >>= k := rfl

/-- `Dlg.done` is the `Monad` instance's `pure`. -/
theorem Dlg.done_eq_pure (a : A) : (Dlg.done a : Dlg A) = pure a := rfl

/-! ## The two observations, transported to plans -/

namespace Plan

/-- `[[run ω p γ]]` = what `p` answers in the world `ω`, given what is already
known. Definitionally the dialogue's `run`, because the meaning of a plan *is*
its dialogue: §5(i)'s commutation between the interpreter and the meaning is
`rfl` and there is nothing else to prove. -/
def run (ω : Ω) (p : Plan Γ A) (γ : Env Γ) : A := Dlg.run ω (denote p γ)

/-- `[[trace ω p γ]]` = what `p` consulted, in order, in the world `ω`. -/
def trace (ω : Ω) (p : Plan Γ A) (γ : Env Γ) : Trace := Dlg.trace ω (denote p γ)

/-- **The interpreter is the fold.** Running a plan is running its denotation;
there is no second semantics to reconcile. -/
theorem run_eq_run_denote (ω : Ω) (p : Plan Γ A) (γ : Env Γ) :
    run ω p γ = Dlg.run ω (denote p γ) := rfl

/-- Likewise for the transcript. -/
theorem trace_eq_trace_denote (ω : Ω) (p : Plan Γ A) (γ : Env Γ) :
    trace ω p γ = Dlg.trace ω (denote p γ) := rfl

@[simp] theorem run_ret (ω : Ω) (e : Expr Γ A) (γ : Env Γ) : run ω (Plan.ret e) γ = e γ := by
  simp [run]

@[simp] theorem trace_ret (ω : Ω) (e : Expr Γ A) (γ : Env Γ) : trace ω (Plan.ret e) γ = [] := by
  simp [trace]

/-- Asking records one event and continues with the answer the world gives. -/
@[simp] theorem run_askC (ω : Ω) (c : Code) (q : Q c) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    run ω (Plan.askC c q k) γ = run ω k (.cons (ω c q) γ) := by simp [run]

@[simp] theorem trace_askC (ω : Ω) (c : Code) (q : Q c) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    trace ω (Plan.askC c q k) γ = ⟨c, q, ω c q⟩ :: trace ω k (.cons (ω c q) γ) := by simp [trace]

@[simp] theorem run_ask (ω : Ω) (c : Code) (s : Q.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) (γ : Env Γ) :
    run ω (Plan.ask c s e k) γ = run ω k (.cons (ω c (s.withPrompt (e γ))) γ) := by simp [run]

@[simp] theorem trace_ask (ω : Ω) (c : Code) (s : Q.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) (γ : Env Γ) :
    trace ω (Plan.ask c s e k) γ
      = ⟨c, s.withPrompt (e γ), ω c (s.withPrompt (e γ))⟩
          :: trace ω k (.cons (ω c (s.withPrompt (e γ))) γ) := by simp [trace]

end Plan

/-! ## C0: the one admitted redundancy is coherent -/

/-- **Kernel obligation C0.** `askC` and `ask` at a constant question have the
same meaning. The redundancy is deliberate — `askC` is what records, *in the
term*, that a question is closed, which is what gives a `Const S`-valued
analysis a domain — and this is the coherence it owes. -/
theorem askC_coherent (c : Code) (q : Q c) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    denote (Plan.askC c q k) γ = denote (Plan.ask c q.shape (fun _ => q.prompt) k) γ := by simp

/-! ## Renaming and substitution -/

/-- **Morphism equation for `sub`** — the substitution/weakening lemma, and the
reason a context morphism was taken to be a function on environments: reading a
plan in another context is precomposing its meaning. -/
@[simp] theorem denote_sub (p : Plan Γ A) :
    ∀ {Δ : Ctx} (σ : Sub Γ Δ) (δ : Env Δ), denote (Plan.sub p σ) δ = denote p (σ δ) := by
  induction p with
  | ret e => intro Δ σ δ; simp [Plan.sub_ret]
  | askC c q k ih =>
    intro Δ σ δ
    simp only [Plan.sub_askC, denote_askC, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x => ih (Sub.lift σ) (.cons x δ)
  | ask c s e k ih =>
    intro Δ σ δ
    simp only [Plan.sub_ask, denote_ask, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x => ih (Sub.lift σ) (.cons x δ)
  | case t e arms ih => intro Δ σ δ; simp only [Plan.sub_case, denote_case]; exact ih _ σ δ
  | dyn b e f ih => intro Δ σ δ; simp only [Plan.sub_dyn, denote_dyn]; exact ih _ σ δ

/-! ## Scope -/

/-- **Morphism equation for `under`**: the plan-level relabelling is the
dialogue-level one, transported along the meaning. With `Dlg.run_under` and
`Dlg.trace_under` this says scope is part of the question and not a layer around
the meaning; with `Plan.under_idSig` and `Plan.under_under` it says relabellings
*act*, and the action laws are the same at the syntax and at the meaning. -/
@[simp] theorem denote_under (σ : Sig) (p : Plan Γ A) (γ : Env Γ) :
    denote (Plan.under σ p) γ = Dlg.under σ (denote p γ) := by
  induction p with
  | ret e => simp [Plan.under_ret]
  | askC c q k ih =>
    simp only [Plan.under_askC, denote_askC, Dlg.under_ask, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x => ih _
  | ask c s e k ih =>
    simp only [Plan.under_ask, denote_ask, Dlg.under_ask, Sig.onQ_withPrompt, Dlg.ask.injEq,
      heq_eq_eq, true_and]
    exact funext fun x => ih _
  | case t e arms ih => simp only [Plan.under_case, denote_case]; exact ih _ _
  | dyn b e f ih => simp only [Plan.under_dyn, denote_dyn]; exact ih _ _

/-- Relabelling a plan is precomposition on worlds, at the plan level. -/
theorem run_under (ω : Ω) (σ : Sig) (p : Plan Γ A) (γ : Env Γ) :
    Plan.run ω (Plan.under σ p) γ = Plan.run (fun c q => ω c (σ.onQ c q)) p γ := by
  simp [Plan.run, Dlg.run_under]

/-! ## Grafting: the master lemma -/

/-- `[[Denotes k K]]` = the continuation `k` means the semantic continuation
`K`: at every leaf, in every context the leaf might sit in, what `k` builds
there means `K` applied to the leaf's value and the `Γ`-environment the leaf
reaches back to.

This is the coherence a context-polymorphic continuation owes, and it is not
bookkeeping: a `Cont` is an arbitrary family, so a `Cont` that behaves
differently in different contexts denotes nothing uniform and no equation about
it can close. `Denotes k K` is exactly the naturality that makes grafting mean
binding, and it is the hypothesis of every equation below that grafts. -/
def Plan.Denotes {Γ : Ctx} {A B : Type} (k : Cont Γ A B) (K : A → Env Γ → Dlg B) : Prop :=
  ∀ (Δ : Ctx) (σ : Sub Γ Δ) (e : Expr Δ A) (δ : Env Δ), denote (k Δ σ e) δ = K (e δ) (σ δ)

/-! ## The Yoneda collapse: a natural `Cont` at an answer type *is* a plan

An additive layer, and a representability fact about context extension rather
than a proposal. `Env (c :: Γ) ≅ El c × Env Γ` (`Env.cons_head_tail`) says that,
naturally in `Δ`,

```
Sub (c :: Γ) Δ  =  Env Δ → Env (c :: Γ)
                ≅  (Env Δ → El c) × (Env Δ → Env Γ)
                =  Expr Δ (El c) × Sub Γ Δ
```

so the context `c :: Γ` **represents** the functor `Δ ↦ Expr Δ (El c) × Sub Γ Δ`,
with universal element `(Sub.wk, Expr.var .here)` — weakening paired with the
variable just bound. Covariant Yoneda then reads

> `{k : Cont Γ (El c) B // Cont.Natural k}  ≅  Plan (c :: Γ) B`

and the two halves of the bijection are `Cont.ofPlan` and `Cont.toPlan` below.
One round trip holds unconditionally; **the other round trip *is* the naturality
condition**, which is what makes `Cont.Natural` the right notion rather than a
guess, and is why `Morphism.sub_graft_not_natural`'s counterexample stays: it is
the witness that the hypothesis is not vacuous.

Nothing here replaces anything. `Plan.revising`'s definition, `graft`'s
recursion and `Plan.Denotes` are all untouched; what the layer adds is that a
continuation written as `ofPlan` of a plan discharges its coherence obligation
for free (`Cont.denotes_ofPlan`), which is the Lean counterpart of the
parametricity Haskell's rank-2 `forall` would have given away — and that is why
`Denotes` exists on this side and has no Haskell counterpart.

`Cont.Natural`'s other consumer is `Morphism.sub_graft_of_natural`, the fourth
presheaf law, which is stated there beside the counterexample it repairs.

**Where the collapse stops is a fact about the design, not about the
mathematics.** `A` must be an answer type — `El c` for a code `c` — because a
context is a list of codes and nothing else. `Plan.revising` returns
`El c × Bool`, so its consuming continuation (`Harden.finishK`) sits at an `A`
no context represents, and that is exactly the one place the language leaves the
answers-only universe. The theorem *locates* that; removing it is a change to
the specification and not to this file. -/

/-- `[[Cont.Natural k]]` = the continuation family is natural in the context it
lands in: what it builds at `Δ` and then renames along `ρ` is what it builds at
`Ξ` directly.

The condition `Cont`'s *type* does not impose and that `Morphism.wobbly`
violates — `wobbly` reads the *length* of the context it lands in, which is
precisely the data a natural family may not see. Purely syntactic: no `denote`,
no world, no environment. -/
def Cont.Natural {Γ : Ctx} {A B : Type} (k : Cont Γ A B) : Prop :=
  ∀ (Δ Ξ : Ctx) (τ : Sub Γ Δ) (e : Expr Δ A) (ρ : Sub Δ Ξ),
    Plan.sub (k Δ τ e) ρ = k Ξ (Sub.comp τ ρ) (fun ξ => e (ρ ξ))

/-- `[[Cont.reindex k σ]]` = the continuation `k`, written against `Γ`, read
against `Δ`. This is what `graft`'s `askC` and `ask` clauses do to their
continuation at each binder — `Cont.reindex k Sub.wk` is "rebuild the
continuation with one more weakening" — and naming it is what lets
`sub_graft_of_natural` state the square at all. -/
def Cont.reindex {Γ Δ : Ctx} {A B : Type} (k : Cont Γ A B) (σ : Sub Γ Δ) : Cont Δ A B :=
  fun Θ τ e => k Θ (Sub.comp σ τ) e

/-- Reindexing preserves naturality, which is what makes the induction in
`Morphism.sub_graft_of_natural` go under a binder. -/
theorem Cont.reindex_natural {Γ Δ : Ctx} {A B : Type} {k : Cont Γ A B}
    (hk : Cont.Natural k) (σ : Sub Γ Δ) : Cont.Natural (Cont.reindex k σ) := by
  intro Θ Ξ τ e ρ
  exact hk Θ Ξ (Sub.comp σ τ) e ρ

/-- **Yoneda, one way**: a plan in the extended context *is* a continuation.
Substitute the leaf's value for the variable just bound and the leaf's reach-back
for the rest. -/
def Cont.ofPlan {Γ : Ctx} {B : Type} {c : Code} (q : Plan (c :: Γ) B) : Cont Γ (El c) B :=
  fun _ σ e => Plan.sub q (fun δ => Env.cons (e δ) (σ δ))

/-- **Yoneda, the other way**: evaluate the family at the universal element
`(Sub.wk, Expr.var .here)`. -/
def Cont.toPlan {Γ : Ctx} {B : Type} {c : Code} (k : Cont Γ (El c) B) : Plan (c :: Γ) B :=
  k (c :: Γ) Sub.wk (Expr.var .here)

/-- A continuation that comes from a plan is natural, by `sub_comp` alone. -/
theorem Cont.ofPlan_natural {Γ : Ctx} {B : Type} {c : Code} (q : Plan (c :: Γ) B) :
    Cont.Natural (Cont.ofPlan q) := by
  intro Δ Ξ τ e ρ
  simp only [Cont.ofPlan, Plan.sub_comp]

/-- **Round trip one, with no hypothesis at all.** `Env.cons_head_tail` and
`Plan.sub_id` are the whole proof: substituting the variable just bound for
itself is the identity substitution. -/
theorem Cont.toPlan_ofPlan {Γ : Ctx} {B : Type} {c : Code} (q : Plan (c :: Γ) B) :
    Cont.toPlan (Cont.ofPlan q) = q := by
  simp only [Cont.toPlan, Cont.ofPlan]
  have h : (fun δ : Env (c :: Γ) => Env.cons (Expr.var (Var.here) δ) (Sub.wk δ)) = Sub.id := by
    funext δ; exact Env.cons_head_tail δ
  rw [h, Plan.sub_id]

/-- **Round trip two: exactly naturality, and nothing more.** The hypothesis is
not a convenience — the round trip *is* the naturality condition, which is the
categorical content of the collapse stated as a Lean proof obligation. -/
theorem Cont.ofPlan_toPlan {Γ : Ctx} {B : Type} {c : Code} (k : Cont Γ (El c) B)
    (hk : Cont.Natural k) : Cont.ofPlan (Cont.toPlan k) = k := by
  funext Δ σ e
  simp only [Cont.ofPlan, Cont.toPlan]
  rw [hk (c :: Γ) Δ Sub.wk (Expr.var .here) (fun δ => Env.cons (e δ) (σ δ))]
  rfl

/-- **`Plan.Denotes` stops being a hypothesis** — for a continuation that comes
from a plan, which is the shape every author-written `Cont` in this package has.
The proof is `denote_sub` and one `simp only`: substituting into the leaf and
then reading the meaning is reading the meaning in the extended environment.

This is the whole return on the layer. Its `K` is forced — `fun a γ => denote q
(Env.cons a γ)` and nothing else — so where the semantic continuation is
*written independently* (as `Harden.Kreview` and `Harden.Kredraft` are, against
a dialogue-level recursion) the residual obligation is the identification of the
two, and this lemma does not discharge that. What it does discharge is the
context-polymorphic half, which is the half nothing else can do. -/
theorem Cont.denotes_ofPlan {Γ : Ctx} {B : Type} {c : Code} (q : Plan (c :: Γ) B) :
    Plan.Denotes (Cont.ofPlan q) (fun a γ => denote q (Env.cons a γ)) := by
  intro Δ σ e δ
  simp only [Cont.ofPlan, denote_sub]

/-- **Morphism equation for `graft`.** If the continuation means the semantic
continuation `K`, then grafting means binding:

```
denote (graft p k) γ = denote p γ >>= fun a => K a γ
```

The hypothesis is not a weakening of the equation; it is the other half of it.
`graft`'s continuation may read the answers bound between the root and the
leaf — that is the point of a syntax with binders — and `Denotes k K` says what
it means when what it reads is only the leaf's value and the enclosing
environment, which is exactly when the graft is a `bind`. Every derived form
below is checked against this one lemma, so each costs a two-line instantiation
and no induction of its own. -/
theorem denote_graft {B : Type} {A : Type} {Γ : Ctx} (p : Plan Γ A) :
    ∀ (K : A → Env Γ → Dlg B) (k : Cont Γ A B), Plan.Denotes k K →
      ∀ γ : Env Γ, denote (Plan.graft p k) γ = Dlg.bind (denote p γ) (fun a => K a γ) := by
  induction p with
  | ret e =>
    intro K k hk γ
    simp only [Plan.graft_ret, denote_ret, Dlg.bind_done]
    exact hk _ Sub.id e γ
  | askC c q p ih =>
    intro K k hk γ
    simp only [Plan.graft_askC, denote_askC, Dlg.bind_ask, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x =>
      ih (fun a δ => K a δ.tail) _ (fun Δ σ e δ => hk Δ _ e δ) (.cons x γ)
  | ask c s d p ih =>
    intro K k hk γ
    simp only [Plan.graft_ask, denote_ask, Dlg.bind_ask, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x =>
      ih (fun a δ => K a δ.tail) _ (fun Δ σ e δ => hk Δ _ e δ) (.cons x γ)
  | case t d arms ih =>
    intro K k hk γ
    simp only [Plan.graft_case, denote_case]
    exact ih _ K k hk γ
  | dyn b d f ih =>
    intro K k hk γ
    simp only [Plan.graft_dyn, denote_dyn]
    exact ih _ K k hk γ

/-- **The master square with the hypothesis spent.** At a continuation that comes
from a plan there is no coherence left to state: grafting `q` onto `p`'s leaves
means binding `q`'s meaning in the extended environment.

The general form above **stays**, and must: `A` there is an arbitrary `Type` and
`k` an arbitrary family, and `Morphism.sub_graft_not_natural` exhibits a `Cont`
that is not `ofPlan` of anything. This corollary is the shape an author reaches
for; the theorem is the shape the induction needs. -/
theorem denote_graft_ofPlan {Γ : Ctx} {B : Type} {c : Code}
    (p : Plan Γ (El c)) (q : Plan (c :: Γ) B) (γ : Env Γ) :
    denote (Plan.graft p (Cont.ofPlan q)) γ
      = Dlg.bind (denote p γ) (fun a => denote q (Env.cons a γ)) :=
  denote_graft p _ _ (Cont.denotes_ofPlan q) γ

/-! ## The derived forms, each against its equation -/

/-- **Functor.** `[[mapP f p]] = f <$> [[p]]`, with no `dyn` and no side
condition: mapping a plan does not move its rung. -/
@[simp] theorem denote_mapP (f : A → B) (p : Plan Γ A) (γ : Env Γ) :
    denote (Plan.mapP f p) γ = Dlg.bind (denote p γ) (fun a => .done (f a)) := by
  refine denote_graft p (fun a _ => .done (f a)) _ ?_ γ
  intro Δ σ e δ; simp

/-- The same in `Functor` vocabulary, which is what the morphism equation of
the doctrine's table actually says. -/
theorem denote_mapP' (f : A → B) (p : Plan Γ A) (γ : Env Γ) :
    denote (Plan.mapP f p) γ = f <$> denote p γ := by
  simp only [denote_mapP, map_eq_pure_bind]
  rfl

/-- **Applicative.** `[[zipWith f p q]] = f <$> [[p]] <*> [[q]]`, again with no
`dyn`. The `<*>` is `Dlg`'s, hence sequential in the transcript — which is
correct, since a transcript is what was actually said and in what order; what a
runtime may reorder is settled separately, by `approved_panel_perm` and
`trace_panel_perm_multiset`. -/
@[simp] theorem denote_zipWith (f : A → B → C) (p : Plan Γ A) (q : Plan Γ B) (γ : Env Γ) :
    denote (Plan.zipWith f p q) γ
      = Dlg.bind (denote p γ) (fun a => Dlg.bind (denote q γ) (fun b => .done (f a b))) := by
  refine denote_graft p (fun a γ' => Dlg.bind (denote q γ') (fun b => .done (f a b))) _ ?_ γ
  intro Δ σ e δ
  refine (denote_graft (Plan.sub q σ) (fun b δ' => .done (f (e δ') b)) _ ?_ δ).trans ?_
  · intro Θ τ e' θ; simp
  · rw [denote_sub]

/-- The same in `Applicative` vocabulary. -/
theorem denote_zipWith' (f : A → B → C) (p : Plan Γ A) (q : Plan Γ B) (γ : Env Γ) :
    denote (Plan.zipWith f p q) γ = f <$> denote p γ <*> denote q γ := by
  simp only [denote_zipWith, Dlg.bind_eq_bind, Dlg.done_eq_pure, seq_eq_bind_map,
    map_eq_pure_bind, bind_assoc, pure_bind]

/-- `[[pairP p q]] = (·, ·) <$> [[p]] <*> [[q]]`. -/
@[simp] theorem denote_pairP (p : Plan Γ A) (q : Plan Γ B) (γ : Env Γ) :
    denote (Plan.pairP p q) γ
      = Dlg.bind (denote p γ) (fun a => Dlg.bind (denote q γ) (fun b => .done (a, b))) :=
  denote_zipWith _ p q γ

/-- `[[seq p q]] = [[p]] >> [[q]]`: the answer is discarded, so no `dyn`. -/
@[simp] theorem denote_seq (p : Plan Γ A) (q : Plan Γ B) (γ : Env Γ) :
    denote (Plan.seq p q) γ = Dlg.bind (denote p γ) (fun _ => denote q γ) := by
  refine denote_graft p (fun _ γ' => denote q γ') _ ?_ γ
  intro Δ σ e δ; simp

/-- **Monad, and the price of it.** `[[bindP p k]] = [[p]] >>= [[k ·]]` — the
kernel's `den (p ≫= k) γ = den p γ >>= fun a => den (k a) γ`. It holds, and the
term it holds of contains a `dyn`, which is the honest statement that general
value-sequencing is the dynamic rung. -/
@[simp] theorem denote_bindP {c : Code} (p : Plan Γ (El c)) (k : El c → Plan Γ B) (γ : Env Γ) :
    denote (Plan.bindP p k) γ = Dlg.bind (denote p γ) (fun a => denote (k a) γ) := by
  refine denote_graft p (fun a γ' => denote (k a) γ') _ ?_ γ
  intro Δ σ e δ; simp

/-- Sequencing associates, because binding does — the monad law, transported to
plans as a lemma from the denotation rather than asserted about the syntax. -/
theorem denote_bindP_assoc {c c' : Code} {D : Type} (p : Plan Γ (El c))
    (k : El c → Plan Γ (El c')) (h : El c' → Plan Γ D) (γ : Env Γ) :
    denote (Plan.bindP (Plan.bindP p k) h) γ
      = denote (Plan.bindP p (fun a => Plan.bindP (k a) h)) γ := by
  simp [Dlg.bind_assoc]

/-! ## Authoring forms -/

@[simp] theorem denote_askC1 (c : Code) (q : Q c) (γ : Env Γ) :
    denote (Plan.askC1 c q) γ = Dlg.ask1 c q := by
  simp [Plan.askC1, Dlg.ask1]

@[simp] theorem denote_ask1 (c : Code) (s : Q.Shape c) (e : Expr Γ String) (γ : Env Γ) :
    denote (Plan.ask1 c s e) γ = Dlg.ask1 c (s.withPrompt (e γ)) := by
  simp [Plan.ask1, Dlg.ask1]

@[simp] theorem denote_caseB (e : Expr Γ Bool) (t f : Plan Γ A) (γ : Env Γ) :
    denote (Plan.caseB e t f) γ = if e γ then denote t γ else denote f γ := by
  cases h : e γ <;> simp [Plan.caseB, h]

@[simp] theorem denote_caseV (e : Expr Γ Verdict) (arms : VTag → Plan Γ A) (γ : Env Γ) :
    denote (Plan.caseV e arms) γ = denote (arms (Verdict.tag (e γ))) γ := by
  simp [Plan.caseV]

/-! ## Sharing is a variable used twice, at the syntax -/

/-- One consultation whose answer is read twice records **one** event. The
answer flows into a *question* — which is what the dossier's applicative kernels
cannot do below the monadic rung and what `ask` exists for. -/
theorem trace_share (ω : Ω) (c : Code) (q : Q c) (s : Q.Shape c) (f : El c → El c → String) :
    Plan.trace ω
        (Plan.askC c q (Plan.ask c s (fun γ => f γ.head γ.head) (Plan.ret (Expr.var .here))))
        Env.nil
      = [⟨c, q, ω c q⟩,
         ⟨c, s.withPrompt (f (ω c q) (ω c q)), ω c (s.withPrompt (f (ω c q) (ω c q)))⟩] := by
  simp [Plan.trace]

/-- Two consultations record **two** events, even though the world answers them
identically. No label is needed to tell sharing from duplication: the transcript
is in the meaning, so cost is an invariant of semantic equality. -/
theorem trace_dup (ω : Ω) (c : Code) (q : Q c) :
    Plan.trace ω (Plan.askC c q (Plan.askC c q (Plan.ret (Expr.var .here)))) Env.nil
      = [⟨c, q, ω c q⟩, ⟨c, q, ω c q⟩] := by
  simp [Plan.trace]

/-! ## Panels

### `Dlg` carries monoids to monoids, so a panel has no fold of its own

`Dlg` is a lax monoidal functor: a monoid on `M` induces one on `Dlg M`, with
`1 = done 1` and `x * y = liftA2 (*) x y`. Under that instance `Plan.panel` — a
`List.foldr (zipWith (·*·)) (ret 1)` — denotes `List.prod`, and the two morphism
equations below are `MonoidHom.map_list_prod` at the two homomorphisms out of a
dialogue (`runHom`, `traceHom`) instead of two inductions.

**The test of whether an abstraction is the right one is that it must not
quietly make the false thing provable, and this one passes.** The product on
`Dlg M` is *sequential in the transcript* by construction — `liftA2` at `Dlg`'s
own `bind`, left then right — so `Morphism.trace_panel_not_perm_invariant` stays
true and stays the honest statement. What the monoid buys is the two equations;
what it does not buy, and must not, is commutativity.

Day convolution is the right name for *why* the applicative structure exists at
all (an applicative is a monoid in `[Set,Set]` under Day) and the wrong name for
this fold, which is ordinary `foldMap`. The statement wanted is the elementary
one: a lax monoidal functor carries monoid objects to monoid objects. -/

/-- **`Dlg` carries monoids to monoids.** `scoped`, because a `Monoid` instance
is a claim about a type and a claim should be made only where the package's
vocabulary has been opened — the discipline `instFinEnumBool` follows in
`Agentic/Core/Plan.lean` and `test/Pollution.lean` polices. `Dlg` is this
package's own type, so nothing here is imposed on anyone else's. -/
scoped instance dlgMonoid {M : Type} [Monoid M] : Monoid (Dlg M) where
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

/-- `[[runHom ω]]` = `Dlg.run ω` as a monoid homomorphism. One of the two
morphisms that *are* the meaning (`Agentic/Core/Dlg.lean`), now with its
multiplicative structure named. -/
def runHom {M : Type} [Monoid M] (ω : Ω) : Dlg M →* M where
  toFun := Dlg.run ω
  map_one' := rfl
  map_mul' x y := by
    show Dlg.run ω (Dlg.bind x (fun a => Dlg.bind y (fun b => Dlg.done (a * b)))) = _
    rw [Dlg.bind_eq_bind, Dlg.run_bind', Dlg.bind_eq_bind, Dlg.run_bind']
    rfl

/-- `[[traceHom ω]]` = `Dlg.trace ω` as a monoid homomorphism into the free
monoid on events. The transcript's concatenation *is* the multiplication, which
is the sentence every bill theorem in `Agentic/Core/Cost.lean` relies on. -/
def traceHom {M : Type} [Monoid M] (ω : Ω) : Dlg M →* FreeMonoid Event where
  toFun := fun x => FreeMonoid.ofList (Dlg.trace ω x)
  map_one' := rfl
  map_mul' x y := by
    show FreeMonoid.ofList (Dlg.trace ω (Dlg.bind x (fun a => Dlg.bind y _))) = _
    rw [Dlg.bind_eq_bind, Dlg.trace_bind', Dlg.bind_eq_bind, Dlg.trace_bind']
    show FreeMonoid.ofList (Dlg.trace ω x ++ (Dlg.trace ω y ++ [])) = _
    rw [List.append_nil, FreeMonoid.ofList_append]

/-- **`panel` is `List.prod` in `Dlg (El c)`.** The panel former has no fold of
its own; it is the monoid's product, read through the meaning. -/
theorem denote_panel_prod [Monoid (El c)] (ps : List (Plan Γ (El c))) (γ : Env Γ) :
    denote (Plan.panel ps) γ = (ps.map (fun p => denote p γ)).prod := by
  induction ps with
  | nil => rfl
  | cons p ps ih =>
      simp only [Plan.panel_cons, List.map_cons, List.prod_cons, denote_zipWith, ih]
      rfl

/-- **Morphism equation for `panel`, on values**: the answer is the `foldMap` of
the members' answers into the monoid. Quorum, "everyone approved" and the
objection product are all this one equation at three monoids.

Proved as `(runHom ω).map_list_prod` — a monoid homomorphism applied to a
product — rather than by induction on the list. -/
@[simp] theorem run_panel [Monoid (El c)] (ω : Ω) (ps : List (Plan Γ (El c))) (γ : Env Γ) :
    Plan.run ω (Plan.panel ps) γ = (ps.map (fun p => Plan.run ω p γ)).prod := by
  show Dlg.run ω (denote (Plan.panel ps) γ) = _
  have hm : (ps.map fun p => Plan.run ω p γ)
      = (ps.map fun p => denote p γ).map (Dlg.run ω) := by
    simp [List.map_map, Plan.run, Function.comp_def]
  rw [denote_panel_prod, hm]
  exact (runHom ω).map_list_prod _

/-- **Morphism equation for `panel`, on transcripts**: the transcript is the
concatenation of the members' transcripts, in the order written. A panel is not
"parallel" in the meaning; parallelism is a fact about a runtime, licensed by a
theorem about the term.

Proved as `(traceHom ω).map_list_prod`, read back through `FreeMonoid.toList`. -/
@[simp] theorem trace_panel [Monoid (El c)] (ω : Ω) (ps : List (Plan Γ (El c))) (γ : Env Γ) :
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

/-- `Verdict.approved_prod` at the `El .verdict` presentation of the verdict
monoid. Stated because instance search does not unfold `El`, so a `rw` against
the theorem as proved at `Verdict` does not fire on a `panel`'s product. -/
theorem approved_prod_el (vs : List (El .verdict)) :
    Verdict.Approved vs.prod ↔ ∀ v ∈ vs, Verdict.Approved v :=
  Verdict.approved_prod vs

/-! ### The scheduling licence, stated where it is not vacuous

A panel's aggregate value is **not** permutation-invariant, and no hypothesis
rescues it: the licence would need `CommMonoid (El c)`, and nothing in the
answer universe carries one — `Verdict` is `WithZero (FreeMonoid Objection)`,
whose product is concatenation of objection lists, and an objection list is a
*record* of what was said. So the earlier `run_panel_perm [CommMonoid (El c)]`
was a theorem with no instances, which is a way of saying nothing.

Two statements say what a scheduler may actually be given, and both have
inhabited hypotheses.

**What these theorems are, in one word: the centre.** `Plan.zipWith` chooses
left-then-right sequentialization — `denote_zipWith` binds `p` and then `q` —
so the tensor a panel is built from is **premonoidal** in Power and Robinson's
sense: `− ⊗ q` and `p ⊗ −` are functors, but the interchange law that would make
the two orders agree is exactly what a transcript refuses. In a premonoidal
category the *centre* is the subcategory of maps for which interchange does
hold, and the four scheduling-licence theorems of this package —
`approved_panel_perm` here, `trace_panel_perm` and `trace_panel_perm_multiset`
below, and `Cost.billFresh_panel_perm` — are each a measurement of how far a
component is from being central: the transcript is not central as a list, is
central as a multiset, and the approval decision and the bill in a commutative
carrier are central outright.

They do not merge, and the temptation to merge them should be resisted:
`approved_panel_perm` is a monoid morphism into `(Prop, ∧)`, `trace_panel_perm`
is `List.Perm.flatten`, `trace_panel_perm_multiset` is a multiset coercion, and
`billFresh_panel_perm` needs a `CommMonoid`. Four theorems stay four theorems;
what the vocabulary adds is a name for what they are all instances of, and the
reason there cannot be a fifth that makes the aggregate verdict reorderable. -/

/-- **The licence on values, at the projection a policy reads.** `Approved` is
the monoid morphism into conjunction (`Verdict.approved_mul`), and conjunction
is commutative — so *whether everyone approved* is invariant under reordering
the panel, even though the aggregate verdict is not.

That is exactly the licence: a runtime may reorder a panel whenever what depends
on the panel is the approval decision rather than the objection record. -/
theorem approved_panel_perm (ω : Ω) {ps ps' : List (Plan Γ (El .verdict))}
    (h : ps.Perm ps') (γ : Env Γ) :
    Verdict.Approved (Plan.run (A := El .verdict) ω (Plan.panel ps) γ)
      ↔ Verdict.Approved (Plan.run (A := El .verdict) ω (Plan.panel ps') γ) := by
  rw [run_panel, run_panel, approved_prod_el, approved_prod_el]
  exact ⟨fun H v hv => H v ((h.map _).mem_iff.mpr hv),
         fun H v hv => H v ((h.map _).mem_iff.mp hv)⟩

/-- Concatenating a permuted list of lists permutes the concatenation. The
scheduler's freedom, before any of it is about workflows: the order of the
blocks may change, the contents may not.

Mathlib's own lemma, once the statement is named the way Mathlib names it
(`List.Perm.flatten`); the eight-line `List.Perm` induction this used to carry
was a re-proof. Kept as a name, and kept here rather than inlined, because it is
the general fact `trace_panel_perm` below is an instance of and the sentence
above is worth having somewhere. -/
theorem flatten_perm {α : Type} {L L' : List (List α)} (h : L.Perm L') :
    L.flatten.Perm L'.flatten := h.flatten

/-- **The licence on transcripts.** Reordering a panel reorders its events —
`Morphism.trace_panel_not_perm_invariant` says the transcript *as a list* is
never invariant — but it does not change *which* events occurred. Up to
permutation the transcript is invariant, and that is exactly the amount of
freedom a scheduler has: it may choose an order, and it may not add, drop or
change a consultation.

`Agentic/Core/Cost.lean`'s `billFresh_panel_perm` is the cost reading. -/
theorem trace_panel_perm [Monoid (El c)] (ω : Ω) {ps ps' : List (Plan Γ (El c))}
    (h : ps.Perm ps') (γ : Env Γ) :
    (Plan.trace ω (Plan.panel ps) γ).Perm (Plan.trace ω (Plan.panel ps') γ) := by
  rw [trace_panel, trace_panel]
  exact flatten_perm (h.map _)

/-- …and the same fact read in the object that forgets order: as a `Multiset` of
events, a panel's transcript does not depend on the order of its members. -/
theorem trace_panel_perm_multiset [Monoid (El c)] (ω : Ω) {ps ps' : List (Plan Γ (El c))}
    (h : ps.Perm ps') (γ : Env Γ) :
    (Plan.trace ω (Plan.panel ps) γ : Multiset Event)
      = (Plan.trace ω (Plan.panel ps') γ : Multiset Event) :=
  Multiset.coe_eq_coe.mpr (trace_panel_perm ω h γ)

/-- A panel of verdicts approves exactly when every member approves — the
`foldMap` of `Verdict.Approved`'s morphism into conjunction (§3 q6), which is
what makes the policy compositional. -/
theorem approved_panel_cons (ω : Ω) (p : Plan Γ (El .verdict))
    (ps : List (Plan Γ (El .verdict))) (γ : Env Γ) :
    Verdict.Approved (Plan.run (A := El .verdict) ω (Plan.panel (p :: ps)) γ)
      ↔ Verdict.Approved (Plan.run (A := El .verdict) ω p γ)
        ∧ Verdict.Approved (Plan.run (A := El .verdict) ω (Plan.panel ps) γ) := by
  simp only [run_panel, List.map_cons, List.prod_cons]
  exact Verdict.approved_mul _ _

/-! ## Bounded revision, and the shape of the recursion -/

/-- `[[reviseLoop Kc Kr n a γ]]` = the meaning of "check the artefact; if it is
approved, stop with it; otherwise revise and go again, at most `n` more times;
if the last check still objects, hand back the candidate it ran out holding,
marked unsettled".

Written as an ordinary recursion at the *meaning*, so that
`denotes_revising` below is a genuine morphism equation between two independent
definitions rather than an unfolding of one of them. Note the shape: the check
comes first at every rung, including the last; and note that **the exhausted
ending carries the candidate** (D3), which is what the `Option` spelling threw
away. -/
def reviseLoop {Γ : Ctx} {c : Code} (Kc : El c → Env Γ → Dlg Verdict)
    (Kr : El c × Verdict → Env Γ → Dlg (El c)) :
    Nat → El c → Env Γ → Dlg (El c × Bool)
  | 0, a, γ => Dlg.bind (Kc a γ) (fun v => .done (a, Verdict.approvedB v))
  | n + 1, a, γ => Dlg.bind (Kc a γ) (fun v =>
      if Verdict.approvedB v then .done (a, true)
      else Dlg.bind (Kr (a, v) γ) (fun a' => reviseLoop Kc Kr n a' γ))

/-- `[[reviseLoopOn Kc Kr n a γ]]` = the same, reading the review's verdict tag
three ways: approval settles, an objection buys another trip (or, at the last
round, leaves the loop unsettled), a refusal abandons it at once (D4).

A second, independently written recursion, so that `denotes_revisingOn` below is
a genuine morphism equation and not an unfolding — the same discipline
`reviseLoop` is held to. -/
def reviseLoopOn {Γ : Ctx} {c : Code} (Kc : El c → Env Γ → Dlg Verdict)
    (Kr : El c × Verdict → Env Γ → Dlg (El c)) :
    Nat → El c → Env Γ → Dlg (El c × Ending) := fun n a γ =>
  match n with
  | 0 => Dlg.bind (Kc a γ) (fun v => .done (a, Ending.ofVTag (Verdict.tag v)))
  | n + 1 => Dlg.bind (Kc a γ) (fun v =>
      match Verdict.tag v with
      | .approve => .done (a, Ending.settled)
      | .declined => .done (a, Ending.abandoned)
      | .object => Dlg.bind (Kr (a, v) γ) (fun a' => reviseLoopOn Kc Kr n a' γ))

/-- **Morphism equation for `revising`**: the unrolled plan means the semantic
loop, for every fuel.

`attack-adequacy` A1 in positive form. The meaning of "revise up to `n` times"
is `n + 1` checks and at most `n` revisions, each revision preceded by the check
that asked for it and followed by the check that judges it — and there is no
truncated star, no fuel index in the syntax and no `ℕ∞` anywhere, because the
meaning of a bounded loop is its unrolling (§3 q5).

**Why the two `Denotes` hypotheses stay, after the Yoneda collapse.** `hc` could
go: `check : Cont Γ (El c) Verdict` sits at an answer type, so `Cont.ofPlan` and
`Cont.denotes_ofPlan` discharge it. `hr` cannot: `revise` sits at
`El c × Verdict`, a *product* of answer types, and `c :: Γ` represents one
extension and not two. A two-variable Yoneda — `Plan (c :: .verdict :: Γ) B ≅
{k : Cont Γ (El c × Verdict) B // Natural k}` — would close it, and it is a real
theorem rather than a one-line corollary of the one above, so it is not taken
here. Discharging one hypothesis of two and leaving the statement asymmetric
would be worse than leaving both, so both stay. -/
theorem denotes_revising {Γ : Ctx} {c : Code}
    {check : Cont Γ (El c) Verdict} {revise : Cont Γ (El c × Verdict) (El c)}
    {Kc : El c → Env Γ → Dlg Verdict} {Kr : El c × Verdict → Env Γ → Dlg (El c)}
    (hc : Plan.Denotes check Kc) (hr : Plan.Denotes revise Kr) :
    ∀ n : Nat, Plan.Denotes (Plan.revising check revise n) (reviseLoop Kc Kr n) := by
  intro n
  induction n with
  | zero =>
    intro Δ σ a δ
    refine (denote_graft (check Δ σ a)
      (fun v δ' => .done (a δ', Verdict.approvedB v)) _ ?_ δ).trans ?_
    · intro Θ τ e θ; simp
    · rw [hc Δ σ a δ]; rfl
  | succ n ih =>
    intro Δ σ a δ
    refine (denote_graft (check Δ σ a)
      (fun v δ' => if Verdict.approvedB v then .done (a δ', true)
        else Dlg.bind (Kr (a δ', v) (σ δ')) (fun a' => reviseLoop Kc Kr n a' (σ δ'))) _ ?_ δ).trans
      ?_
    · intro Θ τ e θ
      simp only [Plan.caseB, denote_case]
      cases h : Verdict.approvedB (e θ) with
      | true => simp
      | false =>
        simp only [cond_false, Bool.false_eq_true, if_false]
        refine (denote_graft _ (fun a' θ' => reviseLoop Kc Kr n a' (σ (τ θ'))) _ ?_ θ).trans ?_
        · intro Ξ ρ e' ξ; exact ih Ξ _ e' ξ
        · rw [hr Θ (Sub.comp σ τ) (fun θ' => (a (τ θ'), e θ')) θ]
    · rw [hc Δ σ a δ]; rfl

/-- **Morphism equation for `revisingOn`**: the unrolled three-way plan means
the semantic three-way loop, for every fuel.

The same shape as `denotes_revising`, one arm wider: the round's `caseV` splits
on `Verdict.tag`, the approve and declined arms are `ret` leaves, and only the
`object` arm recurses. The two `Denotes` hypotheses stay for the two reasons
`denotes_revising`'s docstring gives, unchanged. -/
theorem denotes_revisingOn {Γ : Ctx} {c : Code}
    {check : Cont Γ (El c) Verdict} {revise : Cont Γ (El c × Verdict) (El c)}
    {Kc : El c → Env Γ → Dlg Verdict} {Kr : El c × Verdict → Env Γ → Dlg (El c)}
    (hc : Plan.Denotes check Kc) (hr : Plan.Denotes revise Kr) :
    ∀ n : Nat, Plan.Denotes (Plan.revisingOn check revise n) (reviseLoopOn Kc Kr n) := by
  intro n
  induction n with
  | zero =>
    intro Δ σ a δ
    refine (denote_graft (check Δ σ a)
      (fun v δ' => .done (a δ', Ending.ofVTag (Verdict.tag v))) _ ?_ δ).trans ?_
    · intro Θ τ e θ; simp
    · rw [hc Δ σ a δ]; rfl
  | succ n ih =>
    intro Δ σ a δ
    refine (denote_graft (check Δ σ a)
      (fun v δ' =>
        match Verdict.tag v with
        | .approve => .done (a δ', Ending.settled)
        | .declined => .done (a δ', Ending.abandoned)
        | .object =>
            Dlg.bind (Kr (a δ', v) (σ δ')) (fun a' => reviseLoopOn Kc Kr n a' (σ δ'))) _ ?_ δ).trans
      ?_
    · intro Θ τ e θ
      simp only [Plan.caseV, denote_case]
      cases h : Verdict.tag (e θ) with
      | approve => simp
      | declined => simp
      | object =>
        simp only []
        refine (denote_graft _ (fun a' θ' => reviseLoopOn Kc Kr n a' (σ (τ θ'))) _ ?_ θ).trans ?_
        · intro Ξ ρ e' ξ; exact ih Ξ _ e' ξ
        · rw [hr Θ (Sub.comp σ τ) (fun θ' => (a (τ θ'), e θ')) θ]
    · rw [hc Δ σ a δ]; rfl

/-! ## The acceptance test: three reviews and two revisions

`attack-adequacy` A1 says that three independent derivations wrote the domain's
most-used combinator backwards, so that "revise up to twice" performed two
reviews and paid for an unreviewed revision. The two theorems below are the
machine-checked statement that this one does not: the transcript of
`revising … 2` against an addressee that never approves is

```
review, revise, review, revise, review
```

— three reviews and two revisions, checking first — and against an addressee
that approves immediately it is one review and nothing else. -/

namespace Acceptance

/-- `[[reviewShape]]` = whom the review goes to and under what: the part of the
reviewer's question that is written in the term. -/
def reviewShape : Q.Shape .verdict := { addressee := .model "reviewer", scope := 1, draw := 0 }

/-- The reviewer's question, whose words are built from the artefact under
review. -/
def reviewQ (s : String) : Q .verdict := reviewShape.withPrompt s

/-- What the reviewer's verdict comes to, in words the author can read. -/
def tagText : VTag → String
  | .approve => "approved"
  | .object => "objections raised"
  | .declined => "declined to review"

/-- `[[reviseShape]]` = whom a revision goes to and under what. -/
def reviseShape : Q.Shape .text := { addressee := .model "author", scope := 1, draw := 0 }

/-- The author's question, whose words are built from the artefact and the
objections. -/
def reviseQ (s : String) : Q .text := reviseShape.withPrompt s

/-- Check the artefact: one consultation, whose prompt is a function of the
artefact — the `ask` node, which is the whole reason the domain sits below the
monadic rung. -/
def check : Cont [] (El .text) Verdict :=
  fun _ _ a => Plan.ask1 .verdict reviewShape (fun δ => a δ)

/-- Revise the artefact, **threading the objections**: the question mentions
both the artefact and what the reviewer said. -/
def revise : Cont [] (El .text × Verdict) (El .text) :=
  fun _ _ a =>
    Plan.ask1 .text reviseShape
      (fun δ => String.append (a δ).1 (tagText (Verdict.tag (a δ).2)))

/-- The world in which the reviewer never approves. -/
def stubborn : Ω := fun c =>
  match c with
  | .text => fun _ => "revised"
  | .verdict => fun _ => Verdict.object ["needs work"]
  | .flag => fun _ => false
  | .ack => fun _ => ()

/-- The world in which the reviewer approves at once. -/
def agreeable : Ω := fun c =>
  match c with
  | .text => fun _ => "revised"
  | .verdict => fun _ => Verdict.approve
  | .flag => fun _ => true
  | .ack => fun _ => ()

/-- The plan: revise the draft up to twice. -/
def upToTwice : Plan [] (El .text × Bool) :=
  Plan.revising check revise 2 [] Sub.id (fun _ => "draft")

/-- **Check first, revise in the recursive call.** Against an addressee that
never approves, `revising … 2` consults five times, alternating review and
revision and *ending* with a review: three reviews, two revisions, and no
revision that is paid for and discarded unchecked. -/
theorem trace_upToTwice_stubborn :
    (Plan.trace stubborn upToTwice Env.nil).map Event.c
      = [.verdict, .text, .verdict, .text, .verdict] := by
  rfl

/-- And it gives up with an ordinary value, not an exception (§3 q8) — and the
value is **the candidate it ran out holding**, marked unsettled, rather than the
`none` the `Option` spelling threw it away for (D3). -/
theorem run_upToTwice_stubborn : Plan.run stubborn upToTwice Env.nil = ("revised", false) := by
  rfl

/-- Against an addressee that approves at once there is **one** consultation:
the loop pays for exactly the reviews it needs. -/
theorem trace_upToTwice_agreeable :
    (Plan.trace agreeable upToTwice Env.nil).map Event.c = [.verdict] := by
  rfl

/-- …and the answer is the draft, unrevised, marked settled. -/
theorem run_upToTwice_agreeable : Plan.run agreeable upToTwice Env.nil = ("draft", true) := by
  rfl

/-! ### The sharing example, at the pipeline rung

The owner's own example, and the one `attack-adequacy` §1 says no applicative
kernel can carry: **two reviewers sharing one reading of a style guide**. The
guide is read once and its text flows into two later *questions* — not into two
pure functions, which is the case the dossier's sharing theorems were stated
for. Here that is one `askC`, one variable used twice, and a `panel`: no label,
no `case`, no `dyn`, and the transcript proves in every world that the guide was
consulted exactly once. -/

/-- Read the style guide. -/
def guideQ : Q .text :=
  { addressee := .tool "cat", scope := 1, prompt := "STYLE.md", draw := 0 }

/-- `[[correctShape]]` = whom the correctness review goes to. -/
def correctShape : Q.Shape .verdict := { addressee := .model "reviewer-a", scope := 1, draw := 0 }

/-- `[[correctText guide]]` = what is said to the correctness reviewer: the only
part of the question the guide's text reaches. -/
def correctText (guide : String) : String := "correctness: " ++ guide

/-- Ask the correctness reviewer, quoting the guide. -/
def correctQ (guide : String) : Q .verdict := correctShape.withPrompt (correctText guide)

/-- `[[secureShape]]` = whom the security review goes to. -/
def secureShape : Q.Shape .verdict := { addressee := .model "reviewer-b", scope := 1, draw := 0 }

/-- `[[secureText guide]]` = what is said to the security reviewer. -/
def secureText (guide : String) : String := "security: " ++ guide

/-- Ask the security reviewer, quoting the same guide. -/
def secureQ (guide : String) : Q .verdict := secureShape.withPrompt (secureText guide)

/-- The plan: read the guide once, then a two-member panel whose questions both
mention it. Both reviewers' prompts are functions of an earlier answer, and the
term contains neither `case` nor `dyn`. -/
def sharedGuide : Plan [] (El .verdict) :=
  Plan.askC .text guideQ
    (Plan.panel [Plan.ask1 .verdict correctShape (fun γ => correctText γ.head),
                 Plan.ask1 .verdict secureShape (fun γ => secureText γ.head)])

/-- **Sharing is a variable used twice, and it costs one event — in every
world.** Three consultations, not four: the guide is read once and its text
appears inside both reviewers' questions. -/
theorem trace_sharedGuide (ω : Ω) :
    Plan.trace ω sharedGuide Env.nil
      = [⟨.text, guideQ, ω .text guideQ⟩,
         ⟨.verdict, correctQ (ω .text guideQ), ω .verdict (correctQ (ω .text guideQ))⟩,
         ⟨.verdict, secureQ (ω .text guideQ), ω .verdict (secureQ (ω .text guideQ))⟩] := by
  simp [Plan.trace, sharedGuide, Dlg.ask1, correctQ, secureQ]

/-- And the answer is the product of the two verdicts in the verdict monoid —
`foldMap`, which is all a panel's reducer ever is. -/
theorem run_sharedGuide (ω : Ω) :
    Plan.run ω sharedGuide Env.nil
      = ω .verdict (correctQ (ω .text guideQ)) * ω .verdict (secureQ (ω .text guideQ)) := by
  simp [Plan.run, sharedGuide, Dlg.ask1, correctQ, secureQ]

end Acceptance

/-! ## Equality is the kernel of the meaning -/

/-- `[[p ≈ p']]` = the two plans have the same meaning in every environment;
equivalently (`Dlg.Obs`) no world tells them apart in either answer or
transcript. Stating it needs no `Quot`: it is a relation used in theorem
statements, and `Dlg`'s monad laws already hold propositionally. -/
def Plan.Equiv (p p' : Plan Γ A) : Prop := ∀ γ : Env Γ, denote p γ = denote p' γ

@[inherit_doc] scoped infix:50 " ≈ᵖ " => Plan.Equiv

/-- Semantic equality is an equivalence, because it is the kernel of a
function. -/
theorem Plan.Equiv.equivalence : Equivalence (@Plan.Equiv Γ A) :=
  ⟨fun _ _ => rfl, fun h γ => (h γ).symm, fun h₁ h₂ γ => (h₁ γ).trans (h₂ γ)⟩

/-- **Congruence is free**, for grafting and hence for every derived form: the
kernel of a compositional meaning is a congruence for every former, with no
proof obligation beyond the morphism equations. -/
theorem Plan.Equiv.graft_congr {B : Type} {p p' : Plan Γ A} {k k' : Cont Γ A B}
    (K : A → Env Γ → Dlg B)
    (hk : ∀ (Δ : Ctx) (σ : Sub Γ Δ) (e : Expr Δ A) (δ : Env Δ), denote (k Δ σ e) δ = K (e δ) (σ δ))
    (hk' : ∀ (Δ : Ctx) (σ : Sub Γ Δ) (e : Expr Δ A) (δ : Env Δ),
      denote (k' Δ σ e) δ = K (e δ) (σ δ))
    (hp : p ≈ᵖ p') : Plan.graft p k ≈ᵖ Plan.graft p' k' := by
  intro γ
  rw [denote_graft p K k hk γ, denote_graft p' K k' hk' γ, hp γ]

/-- Every plan-level equality is a dialogue-level indistinguishability, so
everything `Dlg` proves about `run` and `trace` applies to plans. -/
theorem Plan.Equiv.obs {p p' : Plan Γ A} (h : p ≈ᵖ p') (γ : Env Γ) :
    Dlg.Obs (denote p γ) (denote p' γ) := Dlg.obs_of_eq (h γ)

end Agentic.Core
