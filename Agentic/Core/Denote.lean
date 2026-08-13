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

/-- `[[denote p]] : Env Γ → Dlg A` — **the** meaning function.

Compositional by construction: one clause per former, each of which is the
morphism equation of kernel §2.2, so the equations below are the specification
and this definition is their solved form.

```
denote (ret e)        γ = .done (e γ)
denote (askC c q k)   γ = .ask c q     (fun x => denote k (γ ▷ x))
denote (ask  c e k)   γ = .ask c (e γ) (fun x => denote k (γ ▷ x))
denote (case e arms)  γ = denote (arms (e γ)) γ
denote (dyn  e f)     γ = denote (f (e γ))    γ
```

`case` and `dyn` have the *same* meaning clause. That is not redundancy: the
difference between them is that `case`'s tag type is finite and its arms are
both in the term, so the two nodes are distinguished by what can be *analysed*
about them, not by what they mean. Recording the distinction in the syntax is
exactly `attack-adequacy` F1's requirement, and it is available here precisely
because the meaning does not record it. -/
def denote {A : Type} : {Γ : Ctx} → Plan Γ A → Env Γ → Dlg A
  | _, .ret e, γ => .done (e γ)
  | _, .askC c q k, γ => .ask c q (fun x => denote k (.cons x γ))
  | _, .ask c e k, γ => .ask c (e γ) (fun x => denote k (.cons x γ))
  | _, @Plan.case _ _ _ _ _ e arms, γ => denote (arms (e γ)) γ
  | _, .dyn e f, γ => denote (f (e γ)) γ

variable {Γ Δ Θ : Ctx} {A B C : Type}

@[simp] theorem denote_ret (e : Expr Γ A) (γ : Env Γ) :
    denote (Plan.ret e) γ = .done (e γ) := by simp [denote]

@[simp] theorem denote_askC (c : Code) (q : Q c) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    denote (Plan.askC c q k) γ = .ask c q (fun x => denote k (.cons x γ)) := by simp [denote]

@[simp] theorem denote_ask (c : Code) (e : Expr Γ (Q c)) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    denote (Plan.ask c e k) γ = .ask c (e γ) (fun x => denote k (.cons x γ)) := by simp [denote]

@[simp] theorem denote_case {T : Type} [Fintype T] [DecidableEq T]
    (e : Expr Γ T) (arms : T → Plan Γ A) (γ : Env Γ) :
    denote (Plan.case e arms) γ = denote (arms (e γ)) γ := by simp [denote]

@[simp] theorem denote_dyn {B : Type} (e : Expr Γ B) (f : B → Plan Γ A) (γ : Env Γ) :
    denote (Plan.dyn e f) γ = denote (f (e γ)) γ := by simp [denote]

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

@[simp] theorem run_ask (ω : Ω) (c : Code) (e : Expr Γ (Q c)) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    run ω (Plan.ask c e k) γ = run ω k (.cons (ω c (e γ)) γ) := by simp [run]

@[simp] theorem trace_ask (ω : Ω) (c : Code) (e : Expr Γ (Q c)) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    trace ω (Plan.ask c e k) γ
      = ⟨c, e γ, ω c (e γ)⟩ :: trace ω k (.cons (ω c (e γ)) γ) := by simp [trace]

end Plan

/-! ## C0: the one admitted redundancy is coherent -/

/-- **Kernel obligation C0.** `askC` and `ask` at a constant question have the
same meaning. The redundancy is deliberate — `askC` is what records, *in the
term*, that a question is closed, which is what gives a `Const S`-valued
analysis a domain — and this is the coherence it owes. -/
theorem askC_coherent (c : Code) (q : Q c) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    denote (Plan.askC c q k) γ = denote (Plan.ask c (fun _ => q) k) γ := by simp

/-! ## Renaming and substitution -/

/-- **Morphism equation for `sub`** — the substitution/weakening lemma, and the
reason a context morphism was taken to be a function on environments: reading a
plan in another context is precomposing its meaning. -/
@[simp] theorem denote_sub (p : Plan Γ A) :
    ∀ {Δ : Ctx} (σ : Sub Γ Δ) (δ : Env Δ), denote (Plan.sub p σ) δ = denote p (σ δ) := by
  induction p with
  | ret e => intro Δ σ δ; simp [Plan.sub]
  | askC c q k ih =>
    intro Δ σ δ
    simp only [Plan.sub, denote_askC, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x => ih (Sub.lift σ) (.cons x δ)
  | ask c e k ih =>
    intro Δ σ δ
    simp only [Plan.sub, denote_ask, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x => ih (Sub.lift σ) (.cons x δ)
  | case e arms ih => intro Δ σ δ; simp only [Plan.sub, denote_case]; exact ih _ σ δ
  | dyn e f ih => intro Δ σ δ; simp only [Plan.sub, denote_dyn]; exact ih _ σ δ

/-! ## Scope -/

/-- **Morphism equation for `under`**: the plan-level relabelling is the
dialogue-level one, transported along the meaning. With `Dlg.run_under` and
`Dlg.trace_under` this says scope is part of the question and not a layer around
the meaning; with `Plan.under_idSig` and `Plan.under_under` it says relabellings
*act*, and the action laws are the same at the syntax and at the meaning. -/
@[simp] theorem denote_under (σ : Sig) (p : Plan Γ A) (γ : Env Γ) :
    denote (Plan.under σ p) γ = Dlg.under σ (denote p γ) := by
  induction p with
  | ret e => simp [Plan.under]
  | askC c q k ih =>
    simp only [Plan.under, denote_askC, Dlg.under_ask, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x => ih _
  | ask c e k ih =>
    simp only [Plan.under, denote_ask, Dlg.under_ask, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x => ih _
  | case e arms ih => simp only [Plan.under, denote_case]; exact ih _ _
  | dyn e f ih => simp only [Plan.under, denote_dyn]; exact ih _ _

/-- Relabelling a plan is precomposition on worlds, at the plan level. -/
theorem run_under (ω : Ω) (σ : Sig) (p : Plan Γ A) (γ : Env Γ) :
    Plan.run ω (Plan.under σ p) γ = Plan.run (fun c q => ω c (σ c q)) p γ := by
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
    simp only [Plan.graft, denote_ret, Dlg.bind_done]
    exact hk _ Sub.id e γ
  | askC c q p ih =>
    intro K k hk γ
    simp only [Plan.graft, denote_askC, Dlg.bind_ask, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x =>
      ih (fun a δ => K a δ.tail) _ (fun Δ σ e δ => hk Δ _ e δ) (.cons x γ)
  | ask c d p ih =>
    intro K k hk γ
    simp only [Plan.graft, denote_ask, Dlg.bind_ask, Dlg.ask.injEq, heq_eq_eq, true_and]
    exact funext fun x =>
      ih (fun a δ => K a δ.tail) _ (fun Δ σ e δ => hk Δ _ e δ) (.cons x γ)
  | case d arms ih =>
    intro K k hk γ
    simp only [Plan.graft, denote_case]
    exact ih _ K k hk γ
  | dyn d f ih =>
    intro K k hk γ
    simp only [Plan.graft, denote_dyn]
    exact ih _ K k hk γ

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
runtime may reorder is settled separately, by `run_panel_perm`. -/
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
@[simp] theorem denote_bindP (p : Plan Γ A) (k : A → Plan Γ B) (γ : Env Γ) :
    denote (Plan.bindP p k) γ = Dlg.bind (denote p γ) (fun a => denote (k a) γ) := by
  refine denote_graft p (fun a γ' => denote (k a) γ') _ ?_ γ
  intro Δ σ e δ; simp

/-- Sequencing associates, because binding does — the monad law, transported to
plans as a lemma from the denotation rather than asserted about the syntax. -/
theorem denote_bindP_assoc {D : Type} (p : Plan Γ A) (k : A → Plan Γ B) (h : B → Plan Γ D)
    (γ : Env Γ) :
    denote (Plan.bindP (Plan.bindP p k) h) γ
      = denote (Plan.bindP p (fun a => Plan.bindP (k a) h)) γ := by
  simp [Dlg.bind_assoc]

/-! ## Authoring forms -/

@[simp] theorem denote_askC1 (c : Code) (q : Q c) (γ : Env Γ) :
    denote (Plan.askC1 c q) γ = Dlg.ask1 c q := by
  simp [Plan.askC1, Dlg.ask1]

@[simp] theorem denote_ask1 (c : Code) (e : Expr Γ (Q c)) (γ : Env Γ) :
    denote (Plan.ask1 c e) γ = Dlg.ask1 c (e γ) := by
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
theorem trace_share (ω : Ω) (c : Code) (q : Q c) (f : El c → El c → Q c) :
    Plan.trace ω
        (Plan.askC c q (Plan.ask c (fun γ => f γ.head γ.head) (Plan.ret (Expr.var .here)))) Env.nil
      = [⟨c, q, ω c q⟩, ⟨c, f (ω c q) (ω c q), ω c (f (ω c q) (ω c q))⟩] := by
  simp [Plan.trace]

/-- Two consultations record **two** events, even though the world answers them
identically. No label is needed to tell sharing from duplication: the transcript
is in the meaning, so cost is an invariant of semantic equality. -/
theorem trace_dup (ω : Ω) (c : Code) (q : Q c) :
    Plan.trace ω (Plan.askC c q (Plan.askC c q (Plan.ret (Expr.var .here)))) Env.nil
      = [⟨c, q, ω c q⟩, ⟨c, q, ω c q⟩] := by
  simp [Plan.trace]

/-! ## Panels -/

/-- **Morphism equation for `panel`, on values**: the answer is the `foldMap` of
the members' answers into the monoid. Quorum, "everyone approved" and the
objection product are all this one equation at three monoids. -/
@[simp] theorem run_panel [Monoid (El c)] (ω : Ω) (ps : List (Plan Γ (El c))) (γ : Env Γ) :
    Plan.run ω (Plan.panel ps) γ = (ps.map (fun p => Plan.run ω p γ)).prod := by
  induction ps with
  | nil => simp [Plan.run]
  | cons p ps ih =>
    simp only [Plan.panel_cons, Plan.run, denote_zipWith, Dlg.run_bind, List.map_cons,
      List.prod_cons]
    simpa [Plan.run] using congrArg (fun x => Dlg.run ω (denote p γ) * x) ih

/-- **Morphism equation for `panel`, on transcripts**: the transcript is the
concatenation of the members' transcripts, in the order written. A panel is not
"parallel" in the meaning; parallelism is a fact about a runtime, licensed by a
theorem about the term. -/
@[simp] theorem trace_panel [Monoid (El c)] (ω : Ω) (ps : List (Plan Γ (El c))) (γ : Env Γ) :
    Plan.trace ω (Plan.panel ps) γ = (ps.map (fun p => Plan.trace ω p γ)).flatten := by
  induction ps with
  | nil => simp [Plan.trace]
  | cons p ps ih =>
    simp only [Plan.panel_cons, Plan.trace, denote_zipWith, Dlg.trace_bind,
      List.map_cons, List.flatten_cons]
    simpa [Plan.trace] using congrArg (fun x => Dlg.trace ω (denote p γ) ++ x) ih

/-- **The scheduling licence, semantically.** When the reducer's monoid is
commutative, the panel's *answer* does not depend on the order of its members —
so a runtime may reorder them — while its transcript does, which is why cost
stays exact. This is a property of the plan and its meaning, not a hypothesis
about how the term was built. -/
theorem run_panel_perm [CommMonoid (El c)] (ω : Ω) {ps ps' : List (Plan Γ (El c))}
    (h : ps.Perm ps') (γ : Env Γ) :
    Plan.run ω (Plan.panel ps) γ = Plan.run ω (Plan.panel ps') γ := by
  simp only [run_panel]
  exact (h.map _).prod_eq

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
if the last check still objects, give up with `none`".

Written as an ordinary recursion at the *meaning*, so that
`denotes_revising` below is a genuine morphism equation between two independent
definitions rather than an unfolding of one of them. Note the shape: the check
comes first at every rung, including the last. -/
def reviseLoop {Γ : Ctx} {c : Code} (Kc : El c → Env Γ → Dlg Verdict)
    (Kr : El c × Verdict → Env Γ → Dlg (El c)) :
    Nat → El c → Env Γ → Dlg (Option (El c))
  | 0, a, γ => Dlg.bind (Kc a γ) (fun v => .done (if Verdict.approvedB v then some a else none))
  | n + 1, a, γ => Dlg.bind (Kc a γ) (fun v =>
      if Verdict.approvedB v then .done (some a)
      else Dlg.bind (Kr (a, v) γ) (fun a' => reviseLoop Kc Kr n a' γ))

/-- **Morphism equation for `revising`**: the unrolled plan means the semantic
loop, for every fuel.

`attack-adequacy` A1 in positive form. The meaning of "revise up to `n` times"
is `n + 1` checks and at most `n` revisions, each revision preceded by the check
that asked for it and followed by the check that judges it — and there is no
truncated star, no fuel index in the syntax and no `ℕ∞` anywhere, because the
meaning of a bounded loop is its unrolling (§3 q5). -/
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
      (fun v δ' => .done (if Verdict.approvedB v then some (a δ') else none)) _ ?_ δ).trans ?_
    · intro Θ τ e θ; simp
    · rw [hc Δ σ a δ]; rfl
  | succ n ih =>
    intro Δ σ a δ
    refine (denote_graft (check Δ σ a)
      (fun v δ' => if Verdict.approvedB v then .done (some (a δ'))
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

/-- The reviewer's question, built from the artefact under review. -/
def reviewQ (s : String) : Q .verdict :=
  { addressee := .model "reviewer", scope := 1, prompt := s, draw := 0 }

/-- What the reviewer's verdict comes to, in words the author can read. -/
def tagText : VTag → String
  | .approve => "approved"
  | .object => "objections raised"
  | .declined => "declined to review"

/-- The author's question, built from the artefact and the objections. -/
def reviseQ (s : String) : Q .text :=
  { addressee := .model "author", scope := 1, prompt := s, draw := 0 }

/-- Check the artefact: one consultation, whose prompt is a function of the
artefact — the `ask` node, which is the whole reason the domain sits below the
monadic rung. -/
def check : Cont [] (El .text) Verdict :=
  fun _ _ a => Plan.ask1 .verdict (fun δ => reviewQ (a δ))

/-- Revise the artefact, **threading the objections**: the question mentions
both the artefact and what the reviewer said. -/
def revise : Cont [] (El .text × Verdict) (El .text) :=
  fun _ _ a =>
    Plan.ask1 .text (fun δ => reviseQ (String.append (a δ).1 (tagText (Verdict.tag (a δ).2))))

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
def upToTwice : Plan [] (Option (El .text)) :=
  Plan.revising check revise 2 [] Sub.id (fun _ => "draft")

/-- **Check first, revise in the recursive call.** Against an addressee that
never approves, `revising … 2` consults five times, alternating review and
revision and *ending* with a review: three reviews, two revisions, and no
revision that is paid for and discarded unchecked. -/
theorem trace_upToTwice_stubborn :
    (Plan.trace stubborn upToTwice Env.nil).map Event.c
      = [.verdict, .text, .verdict, .text, .verdict] := by
  rfl

/-- And it gives up with an ordinary value, not an exception: `none` (§3 q8). -/
theorem run_upToTwice_stubborn : Plan.run stubborn upToTwice Env.nil = none := by
  rfl

/-- Against an addressee that approves at once there is **one** consultation:
the loop pays for exactly the reviews it needs. -/
theorem trace_upToTwice_agreeable :
    (Plan.trace agreeable upToTwice Env.nil).map Event.c = [.verdict] := by
  rfl

/-- …and the answer is the draft, unrevised. -/
theorem run_upToTwice_agreeable : Plan.run agreeable upToTwice Env.nil = some "draft" := by
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

/-- Ask the correctness reviewer, quoting the guide. -/
def correctQ (guide : String) : Q .verdict :=
  { addressee := .model "reviewer-a", scope := 1, prompt := "correctness: " ++ guide, draw := 0 }

/-- Ask the security reviewer, quoting the same guide. -/
def secureQ (guide : String) : Q .verdict :=
  { addressee := .model "reviewer-b", scope := 1, prompt := "security: " ++ guide, draw := 0 }

/-- The plan: read the guide once, then a two-member panel whose questions both
mention it. Both reviewers' prompts are functions of an earlier answer, and the
term contains neither `case` nor `dyn`. -/
def sharedGuide : Plan [] (El .verdict) :=
  Plan.askC .text guideQ
    (Plan.panel [Plan.ask1 .verdict (fun γ => correctQ γ.head),
                 Plan.ask1 .verdict (fun γ => secureQ γ.head)])

/-- **Sharing is a variable used twice, and it costs one event — in every
world.** Three consultations, not four: the guide is read once and its text
appears inside both reviewers' questions. -/
theorem trace_sharedGuide (ω : Ω) :
    Plan.trace ω sharedGuide Env.nil
      = [⟨.text, guideQ, ω .text guideQ⟩,
         ⟨.verdict, correctQ (ω .text guideQ), ω .verdict (correctQ (ω .text guideQ))⟩,
         ⟨.verdict, secureQ (ω .text guideQ), ω .verdict (secureQ (ω .text guideQ))⟩] := by
  simp [Plan.trace, sharedGuide, Dlg.ask1]

/-- And the answer is the product of the two verdicts in the verdict monoid —
`foldMap`, which is all a panel's reducer ever is. -/
theorem run_sharedGuide (ω : Ω) :
    Plan.run ω sharedGuide Env.nil
      = ω .verdict (correctQ (ω .text guideQ)) * ω .verdict (secureQ (ω .text guideQ)) := by
  simp [Plan.run, sharedGuide, Dlg.ask1]

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
