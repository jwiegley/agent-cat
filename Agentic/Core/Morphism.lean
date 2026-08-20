import Agentic.Core.Cost

/-!
# The commuting squares: every operation against `denote`

Rederivation kernel §2.2 (*"the morphism equations — these **are** the
specification"*), §2.3 (the redundancy obligation C0), §3 q3 (scope as
reindexing), §3 q6 (panels), §3 q5 (check first, revise in the recursive call),
§4 C5 (soundness of the level fold), §5(i) (commutation is `rfl`).

This module is the **audit**. `Agentic/Core/Plan.lean` writes an operation and
claims an equation in its docstring; `Agentic/Core/Denote.lean` proves each
equation adjacent to the fold. Here every one of those claims is written once
more as the literal commuting square, in the standard vocabulary the doctrine
asks for — `pure`, `>>=`, `<$>`, `<*>` — so that the specification can be read
off in one place and checked against §2.2 line by line, and so that the two
equations the dossier states *wrongly* are visible next to the true ones.

The square, in words: each theorem says that performing an operation on the
syntax and then taking the meaning is the same as taking the meaning and then
performing the corresponding operation on dialogues.

```
              op
     Plan Γ A ───► Plan Γ B
        │              │
 denote │              │ denote
        ▼              ▼
      Dlg A ─────────► Dlg B
              ⟦op⟧
```

**Three claims are refuted here, each in code and each beside the repaired
statement that replaces it.** They are the return on writing the squares out:
each is invisible until the equation is stated in full. (A fourth used to sit at
the head of this list — the kernel's C2, that the sequence of question shapes is
world-independent at `pipeline`. It was false of a representation in which
`ask` carried an arbitrary `Expr Γ (Q c)`. It is true of this one, in which the
`ask` node carries the shape as term-level data, and it is proved unconditionally
as `level_sound_pipeline_shape`.)

* **Grafting is not natural in the context** (`sub_graft_not_natural`): the
  square `sub (graft p k) σ = graft (sub p σ) (k ∘ σ)` fails at a `ret` root and
  the smallest weakening, because `Cont` is an arbitrary context-indexed family.
  That is precisely why `denote_graft` carries `Denotes k K`: the hypothesis is
  not bookkeeping, it is the missing half of the equation.
* **`level` is not an invariant of semantic equality**
  (`level_not_equiv_invariant`): `mapP` and `bindP` at a pure leaf mean the same
  dialogue and sit at opposite ends of the chain. Not a defect — it is the
  content of "the fold classifies **terms**, not meanings" (§8.1) — but it is
  the reason no cost theorem may be stated about a meaning where the kernel
  states it about a term.
* **The Forcing Lemma fails at the syntax too** (`plan_not_forcing`), inherited
  from `Dlg.not_forcing`: two plans can agree in answer and transcript in every
  world and still denote different dialogues. `≈ᵖ` is therefore the kernel of
  `denote` and *not* the kernel of `(run, trace)`; the two coincide on the
  repeat-free fragment, where plans in the domain live.

No declaration here introduces an axiom, leaves a hole, or appeals to compiled
evaluation: the three `decide`s are kernel evaluations of closed transcripts and
of the four-element chain.
-/

namespace Agentic.Core

open Plan

/-! Every commuting square of the kernel's §2.2, stated once in standard
vocabulary. The names are the kernel's own (`denote_ret`, `denote_graft`, …);
they live in this namespace so that they sit beside, rather than shadow, the
adjacent proofs in `Agentic/Core/Denote.lean` that they are read off from. -/

namespace Morphism

variable {Γ Δ Θ : Ctx} {A B C D : Type} {c : Code}

/-! ## The five leaf laws — kernel §2.2 verbatim

```
den (ret e)        γ = .done (e γ)
den (askC c q k)   γ = .ask c q                    (fun x => den k (γ ▷ x))
den (ask c s e k)  γ = .ask c (s.withPrompt (e γ)) (fun x => den k (γ ▷ x))
den (case e arms)  γ = den (arms (e γ)) γ
den (dyn  e f)     γ = den (f (e γ))  γ
```

Each is a `rfl`, because `denote` is *defined* as the solved form of these five
equations rather than checked against them. -/

/-- **`ret` is the unit.** `⟦ret e⟧ γ = pure (e γ)` — in `Monad` vocabulary,
which is the form kernel §2.3 states ("Morphism: `den (ret e) γ = pure (e γ)`").
-/
theorem denote_ret (e : Expr Γ A) (γ : Env Γ) : denote (Plan.ret e) γ = pure (e γ) := rfl

/-- **`askC` is the generator at a closed question.** `⟦askC c q k⟧ γ` puts `q`
and continues with `k` under the answer. -/
theorem denote_askC (c : Code) (q : Q c) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    denote (Plan.askC c q k) γ = Dlg.ask c q (fun x => denote k (.cons x γ)) := rfl

/-- **`ask` is the generator at a question whose *words* are built from what is
known** — the node the domain forces, and the whole reason a content-dependent
prompt stays below the monadic rung. The only difference from `askC` is that the
words are `e γ` rather than `q.prompt`; the shape `s` is written in the term
either way, which is what makes C2 hold with no hypothesis. -/
theorem denote_ask (c : Code) (s : Q.Shape c) (e : Expr Γ String) (k : Plan (c :: Γ) A)
    (γ : Env Γ) :
    denote (Plan.ask c s e k) γ
      = Dlg.ask c (s.withPrompt (e γ)) (fun x => denote k (.cons x γ)) := rfl

/-- **`case` is selection in the environment.** Both arms are in the term; the
meaning takes the one the tag names. -/
theorem denote_case (t : Tag) (e : Expr Γ t.El)
    (arms : t.El → Plan Γ A) (γ : Env Γ) :
    denote (Plan.case t e arms) γ = denote (arms (e γ)) γ := rfl

/-- **`dyn` has the same clause as `case`** — and that is the point. The two
formers are distinguished by what can be *analysed* about them (`case`'s tag is
a `Fintype` and its arms are all in the term), never by what they mean; the
distinction is recorded in the syntax precisely because the meaning does not
record it. -/
theorem denote_dyn (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A) (γ : Env Γ) :
    denote (Plan.dyn b e f) γ = denote (f (e γ)) γ := rfl

/-- **C0, the one admitted redundancy, is coherent.** A closed question asked by
`askC` and the same question asked by `ask` at a constant expression are one
dialogue. The redundancy buys the batch rung a domain and costs exactly this
theorem. -/
theorem askC_coherent (c : Code) (q : Q c) (k : Plan (c :: Γ) A) (γ : Env Γ) :
    denote (Plan.askC c q k) γ = denote (Plan.ask c q.shape (fun _ => q.prompt) k) γ := rfl

/-! ## Context morphisms: `denote` is a presheaf map -/

/-- **The substitution square.** `⟦sub p σ⟧ = ⟦p⟧ ∘ σ`: reading a plan in
another context is precomposing its meaning with the context morphism. This is
the equation that makes `Sub Γ Δ := Env Δ → Env Γ` the right notion of context
morphism — a syntactic renaming would have to earn this lemma, and a semantic
one *is* it. -/
theorem denote_sub (p : Plan Γ A) (σ : Sub Γ Δ) (δ : Env Δ) :
    denote (Plan.sub p σ) δ = denote p (σ δ) :=
  Agentic.Core.denote_sub p σ δ

/-! ## Scope: `under σ` is reindexing of the world -/

/-- **The scope square at the meaning.** `⟦under σ p⟧ γ = under σ ⟦p⟧ γ`: the
plan-level relabelling is the dialogue-level one, transported along `denote`.
With `Plan.under_idSig` and `Plan.under_under` this says relabellings *act*, and
that the action is the same at the syntax and at the meaning. -/
theorem denote_under (σ : Sig) (p : Plan Γ A) (γ : Env Γ) :
    denote (Plan.under σ p) γ = Dlg.under σ (denote p γ) :=
  Agentic.Core.denote_under σ p γ

/-- **Scope is reindexing, on values**: running a relabelled plan is running the
plan in the *precomposed world*.

```
run ω (⟦under σ p⟧ γ) = run (ω ∘ σ) (⟦p⟧ γ)
```

This is the kernel's "scope is part of the question": there is no scope layer
wrapped around the meaning, only a change of which world is being read. -/
theorem run_under (ω : Ω) (σ : Sig) (p : Plan Γ A) (γ : Env Γ) :
    Plan.run ω (Plan.under σ p) γ = Plan.run (fun c q => ω c (σ.onQ c q)) p γ :=
  Agentic.Core.run_under ω σ p γ

/-- **Scope is reindexing, on transcripts** — and the transcript half is *not*
the same statement as the value half, because the events recorded name the
relabelled questions:

```
trace ω (⟦under σ p⟧ γ) = (trace (ω ∘ σ) (⟦p⟧ γ)).map (Event.relabel σ)
```

The bill of a scoped plan is therefore the bill of the unscoped plan at the
relabelled prices, which is what a per-model price list means. -/
theorem trace_under (ω : Ω) (σ : Sig) (p : Plan Γ A) (γ : Env Γ) :
    Plan.trace ω (Plan.under σ p) γ
      = (Plan.trace (fun c q => ω c (σ.onQ c q)) p γ).map (Event.relabel σ) := by
  show Dlg.trace ω (denote (Plan.under σ p) γ) = _
  rw [Agentic.Core.denote_under, Dlg.trace_under]
  rfl

/-- Scope does not move the rung: `under` relabels questions and leaves the
shape of the term alone, so every analysis licensed at a level survives every
change of scope. The square above and this one together are the whole content of
"`under` is a fold, not a constructor". -/
theorem level_under (σ : Sig) (p : Plan Γ A) : level (Plan.under σ p) = level p :=
  Agentic.Core.level_under σ p

/-! ## Grafting: `denote` is a monad morphism from substitution to `bind`

`Plan` is a syntax and not a monad, so what has to be proved instead is that its
*sequencing* — grafting a continuation into the `ret` leaves — is carried to
`Dlg`'s `bind`. That is a monad-morphism statement in two halves: the unit law
(grafting onto a leaf is application, `graft_ret`) and the multiplication law
(`denote_graft`), with associativity and the two unit laws for the derived
`bindP` following as corollaries. -/

/-- **Left unit, at the syntax.** Grafting onto a `ret` leaf is application of
the continuation, with the identity context morphism: there is nothing between
the root and the leaf to reach past. -/
theorem graft_ret (e : Expr Γ A) (k : Cont Γ A B) :
    Plan.graft (Plan.ret e) k = k Γ Sub.id e := Plan.graft_ret e k

/-- **Right unit, at the syntax.** Grafting the leaf-preserving continuation
changes nothing: `graft p ret = p`. -/
theorem graft_pure : ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A),
    Plan.graft p (fun _ _ e => Plan.ret e) = p := by
  intro Γ A p
  induction p with
  | ret e => rfl
  | askC c q p ih => simp only [Plan.graft_askC]; exact congrArg _ ih
  | ask c s d p ih => simp only [Plan.graft_ask]; exact congrArg _ ih
  | case t d arms ih => simp only [Plan.graft_case]; exact congrArg _ (funext fun x => ih x)
  | dyn b d f ih => simp only [Plan.graft_dyn]; exact congrArg _ (funext fun x => ih x)

/-- **Associativity, at the syntax — and it holds on the nose.** Grafting twice
is grafting once with the composed continuation, as an equality of *terms*, with
no hypothesis on either continuation and no appeal to the meaning.

Worth stating separately from `denote_graft_assoc` below: the three monad laws
(`graft_ret`, `graft_pure`, `graft_assoc`) hold of the syntax itself, so
`Plan`'s sequencing is a genuine monad structure relative to `Expr` — which is
why `denote` can be a monad *morphism* rather than merely a map that happens to
satisfy one equation. The `Sub.comp σ τ` in the statement is the whole of the
bookkeeping: a continuation written against `Γ` reaches a leaf two graftings
deep by composing the two context morphisms. -/
theorem graft_assoc {B D : Type} : ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A)
    (k : Cont Γ A B) (k' : Cont Γ B D),
    Plan.graft (Plan.graft p k) k'
      = Plan.graft p (fun Δ σ e =>
          Plan.graft (k Δ σ e) (fun Θ τ e' => k' Θ (Sub.comp σ τ) e')) := by
  intro Γ A p
  induction p with
  | ret e => intro k k'; rfl
  | askC c q p ih => intro k k'; simp only [Plan.graft_askC]; exact congrArg _ (ih _ _)
  | ask c s d p ih => intro k k'; simp only [Plan.graft_ask]; exact congrArg _ (ih _ _)
  | case t d arms ih =>
    intro k k'; simp only [Plan.graft_case]; exact congrArg _ (funext fun x => ih x _ _)
  | dyn b d f ih =>
    intro k k'; simp only [Plan.graft_dyn]; exact congrArg _ (funext fun x => ih x _ _)

/-- **The multiplication law — the master square.** If the continuation means
the semantic continuation `K`, then

```
⟦graft p k⟧ γ = ⟦p⟧ γ >>= fun a => K a γ
```

The `Denotes` hypothesis is the other half of the equation rather than a
weakening of it: a `Cont` is an arbitrary context-indexed family, so one that
behaves differently in different contexts denotes nothing uniform, and
`Denotes k K` is exactly the naturality that makes grafting *be* binding. Every
derived form below is a two-line instantiation of this. -/
theorem denote_graft (p : Plan Γ A) (K : A → Env Γ → Dlg B) (k : Cont Γ A B)
    (hk : Denotes k K) (γ : Env Γ) :
    denote (Plan.graft p k) γ = denote p γ >>= fun a => K a γ :=
  Agentic.Core.denote_graft p K k hk γ

/-- **Associativity of grafting**, read off the master square and `Dlg`'s own
associativity: grafting twice is grafting once with the composed semantic
continuation. This is the second monad-morphism law, and it needs no induction
of its own — which is the whole return on stating the square with a `Denotes`
hypothesis. -/
theorem denote_graft_assoc (p : Plan Γ A) (K : A → Env Γ → Dlg B) (K' : B → Env Γ → Dlg D)
    (k : Cont Γ A B) (k' : Cont Γ B D) (hk : Denotes k K) (hk' : Denotes k' K')
    (γ : Env Γ) :
    denote (Plan.graft (Plan.graft p k) k') γ
      = denote p γ >>= fun a => K a γ >>= fun b => K' b γ := by
  rw [denote_graft (Plan.graft p k) K' k' hk' γ, denote_graft p K k hk γ]
  exact Dlg.bind_assoc _ _ _

/-- **`run` of a graft**: the answer of a sequence is the answer of the
continuation at the answer of the first part. `run ω` is a monad morphism into
`Id`, transported to plans. -/
theorem run_graft (ω : Ω) (p : Plan Γ A) (K : A → Env Γ → Dlg B) (k : Cont Γ A B)
    (hk : Denotes k K) (γ : Env Γ) :
    Plan.run ω (Plan.graft p k) γ = Dlg.run ω (K (Plan.run ω p γ) γ) := by
  show Dlg.run ω (denote (Plan.graft p k) γ) = _
  rw [Agentic.Core.denote_graft p K k hk γ]
  exact Dlg.run_bind ω _ _

/-- **`trace` of a graft**: the transcript of a sequence is the concatenation of
the transcripts, in order. This is the equation that makes every bill a monoid
morphism out of the meaning — and hence makes cost an invariant of semantic
equality rather than a second semantics. -/
theorem trace_graft (ω : Ω) (p : Plan Γ A) (K : A → Env Γ → Dlg B) (k : Cont Γ A B)
    (hk : Denotes k K) (γ : Env Γ) :
    Plan.trace ω (Plan.graft p k) γ
      = Plan.trace ω p γ ++ Dlg.trace ω (K (Plan.run ω p γ) γ) := by
  show Dlg.trace ω (denote (Plan.graft p k) γ) = _
  rw [Agentic.Core.denote_graft p K k hk γ]
  exact Dlg.trace_bind ω _ _

/-! ### The same four squares with the `Denotes` hypothesis spent

`Cont.denotes_ofPlan` (`Agentic/Core/Denote.lean`) says that a continuation of
the form `Cont.ofPlan q` discharges its coherence obligation for free, and that
its semantic continuation is forced: `fun a γ => denote q (Env.cons a γ)`. So at
an *answer type* — `A = El c`, which is where a context extension lives — each
square below loses its hypothesis and its `K` argument and becomes a statement
with nothing left to check.

**The hypothesis-carrying forms above stay, and must.** Three reasons, each
independently sufficient. `A` there is an arbitrary `Type`, and the four squares
are instantiated at `A = Unit` (`seq`), at `A × B` (`zipWith`, `pairP`) and at
whatever `bindP`'s answer type is; `Cont Γ A B` there is an arbitrary family, and
`sub_graft_not_natural`'s `wobbly` exhibits one that is `ofPlan` of nothing; and
`denote_graft`'s own induction consumes the hypothesis under a binder, where the
`ofPlan` form is not the shape available. These are the author-facing corollaries
of the general theorems, not replacements for them. -/

/-- `denote_graft` at a continuation that comes from a plan: no hypothesis, and
the semantic continuation is read off `q`. -/
theorem denote_graft_ofPlan {c : Code} (p : Plan Γ (El c)) (q : Plan (c :: Γ) B) (γ : Env Γ) :
    denote (Plan.graft p (Cont.ofPlan q)) γ
      = denote p γ >>= fun a => denote q (Env.cons a γ) :=
  Agentic.Core.denote_graft_ofPlan p q γ

/-- `denote_graft_assoc` at two such continuations. Two answer types, two context
extensions, no coherence obligations. -/
theorem denote_graft_assoc_ofPlan {c d : Code} (p : Plan Γ (El c)) (q : Plan (c :: Γ) (El d))
    (r : Plan (d :: Γ) D) (γ : Env Γ) :
    denote (Plan.graft (Plan.graft p (Cont.ofPlan q)) (Cont.ofPlan r)) γ
      = denote p γ >>= fun a => denote q (Env.cons a γ) >>= fun b => denote r (Env.cons b γ) :=
  denote_graft_assoc p _ _ _ _ (Cont.denotes_ofPlan q) (Cont.denotes_ofPlan r) γ

/-- `run_graft` at a continuation that comes from a plan. -/
theorem run_graft_ofPlan {c : Code} (ω : Ω) (p : Plan Γ (El c)) (q : Plan (c :: Γ) B)
    (γ : Env Γ) :
    Plan.run ω (Plan.graft p (Cont.ofPlan q)) γ
      = Dlg.run ω (denote q (Env.cons (Plan.run ω p γ) γ)) :=
  run_graft ω p _ _ (Cont.denotes_ofPlan q) γ

/-- `trace_graft` at a continuation that comes from a plan. -/
theorem trace_graft_ofPlan {c : Code} (ω : Ω) (p : Plan Γ (El c)) (q : Plan (c :: Γ) B)
    (γ : Env Γ) :
    Plan.trace ω (Plan.graft p (Cont.ofPlan q)) γ
      = Plan.trace ω p γ ++ Dlg.trace ω (denote q (Env.cons (Plan.run ω p γ) γ)) :=
  trace_graft ω p _ _ (Cont.denotes_ofPlan q) γ

/-! ### …and the one square that does **not** close: grafting is not natural

The three laws above are unconditional, and the fourth law one would expect of a
presheaf — that grafting commutes with renaming — is **false**, because `Cont`
is an arbitrary context-indexed family and nothing in its type says that what it
builds at `Δ` is what it builds at `Γ`, transported.

This is not a defect of `graft`; it is the reason `Denotes` is a hypothesis and
not bookkeeping, and it is why `denote_graft` is stated the way it is. The
semantic naturality — `⟦sub (graft p k) σ⟧ = ⟦graft p k⟧ ∘ σ` — is free
(`denote_sub`); it is the *syntactic* one that needs the continuation to be
natural, and the counterexample below is compiled rather than argued. -/

/-- `[[wobbly]]` = the continuation that ignores its value and its context
morphism and asks once per binding in scope: a perfectly well-typed `Cont` that
denotes nothing uniform. -/
def wobbly : Cont [] Unit Unit := fun Δ _ _ => ticks Δ.length

/-- `[[σ0]]` = weakening by one `ack`: the smallest context morphism there is. -/
def σ0 : Sub [] [Code.ack] := Sub.wk

/-- **Grafting does not commute with renaming.** The two sides differ already at
a `ret` root and the smallest weakening: on the left the continuation is applied
in the empty context and the *result* is renamed; on the right the continuation
is applied in the bigger context, where `wobbly` asks one more question. They
are not merely unequal as terms — they have transcripts of different lengths, so
no world confuses them.

Hence: a `Cont` carries a coherence obligation, `Denotes k K` is that
obligation, and every equation in this module that grafts states it. -/
theorem sub_graft_not_natural :
    Plan.sub (Plan.graft (Plan.ret (fun _ => ())) wobbly) σ0
      ≠ Plan.graft (Plan.sub (Plan.ret (fun _ => ())) σ0)
          (fun Θ τ e => wobbly Θ (Sub.comp σ0 τ) e) := by
  intro h
  have hlen :=
    congrArg (fun p => (Plan.trace ωDefault p (Env.cons (c := Code.ack) () Env.nil)).length) h
  revert hlen
  decide

/-! ### …and the repair, which makes the pair matched rather than a wart

The square fails because `Cont` is an arbitrary family, and `Cont.Natural`
(`Agentic/Core/Denote.lean`) is exactly the condition that says it is not. With
that hypothesis the fourth law closes, unconditionally in the plan and in the
context morphism, and `sub_graft_not_natural` above stops being an isolated
defect and becomes the witness that the hypothesis is not vacuous:
`wobbly Δ _ _ = ticks Δ.length` reads the *length of the context it lands in*,
which is precisely the data a natural family may not see.

The two together are the house style of this module — a square and its
counterexample, stated side by side — and the classification is the content: the
presheaf `Δ ↦ Sub Γ Δ × Expr Δ A` has non-natural sections, and grafting
commutes with renaming on exactly the natural ones. -/

/-- **Grafting commutes with renaming, for a natural continuation.** The fourth
law of the presheaf, with the hypothesis the counterexample above forces.

Note what the induction needs and does not need: `Cont.reindex k σ` is the
continuation read against the new context, the `askC`/`ask` cases are
`Cont.reindex … Sub.wk` at each binder — which is what `graft`'s own recursion
does to its continuation — and nothing appeals to `denote`. This is a theorem
about the syntax. -/
theorem sub_graft_of_natural {B : Type} :
    ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A) {Δ : Ctx} (σ : Sub Γ Δ) (k : Cont Γ A B),
      Cont.Natural k →
      Plan.sub (Plan.graft p k) σ = Plan.graft (Plan.sub p σ) (Cont.reindex k σ) := by
  intro Γ A p
  induction p with
  | ret e => intro Δ σ k hk; exact hk _ _ Sub.id e σ
  | askC c q k ih =>
      intro Δ σ k₁ hk
      simp only [Plan.graft_askC, Plan.sub_askC]
      exact congrArg _ (ih (Sub.lift σ) _ (fun Θ Ξ τ e ρ => hk Θ Ξ _ e ρ))
  | ask c s e k ih =>
      intro Δ σ k₁ hk
      simp only [Plan.graft_ask, Plan.sub_ask]
      exact congrArg _ (ih (Sub.lift σ) _ (fun Θ Ξ τ e ρ => hk Θ Ξ _ e ρ))
  | case t e arms ih =>
      intro Δ σ k₁ hk
      simp only [Plan.graft_case, Plan.sub_case]
      exact congrArg _ (funext fun t => ih t σ _ hk)
  | dyn b e f ih =>
      intro Δ σ k₁ hk
      simp only [Plan.graft_dyn, Plan.sub_dyn]
      exact congrArg _ (funext fun b => ih b σ _ hk)

/-- **The bifunctor coherence square**, which this package stated nowhere and
which follows in one line: `Plan` is a functor in *both* variables at the syntax,
covariantly in the answer type by `mapP` and contravariantly in the context by
`sub`, and the two actions commute.

The continuation `mapP` grafts is `fun _ _ e => ret (f ∘ e)`, which ignores its
context morphism entirely and is therefore natural by `rfl` — so the one-line
proof is `sub_graft_of_natural` at the trivial naturality witness. Worth having
in its own right: `sub_mapP` is what says a rendering or an analysis may map over
a plan before or after weakening it and get the same *term*, which
`Morphism.mapP_id`/`mapP_comp`'s `≈ᵖ` versions cannot say. -/
theorem sub_mapP {Γ Δ : Ctx} {A B : Type} (f : A → B) (p : Plan Γ A) (σ : Sub Γ Δ) :
    Plan.sub (Plan.mapP f p) σ = Plan.mapP f (Plan.sub p σ) :=
  sub_graft_of_natural p σ _ (fun _ _ _ _ _ => rfl)

/-! ## The derived forms, each against its equation

The asymmetry the whole design turns on is visible in these five statements and
in nothing else: `mapP`, `zipWith`, `pairP` and `seq` get their equations with
no `dyn` in the term, and `bindP` — general value-sequencing — does not. -/

/-- **Functor.** `⟦mapP f p⟧ = f <$> ⟦p⟧`. -/
theorem denote_mapP (f : A → B) (p : Plan Γ A) (γ : Env Γ) :
    denote (Plan.mapP f p) γ = f <$> denote p γ :=
  Agentic.Core.denote_mapP' f p γ

/-- **Applicative.** `⟦zipWith f p q⟧ = f <$> ⟦p⟧ <*> ⟦q⟧`. The `<*>` is
`Dlg`'s, hence sequential in the transcript — correct, because a transcript is
what was actually said and in what order. -/
theorem denote_zipWith (f : A → B → C) (p : Plan Γ A) (q : Plan Γ B) (γ : Env Γ) :
    denote (Plan.zipWith f p q) γ = f <$> denote p γ <*> denote q γ :=
  Agentic.Core.denote_zipWith' f p q γ

/-- `⟦pairP p q⟧ = (·, ·) <$> ⟦p⟧ <*> ⟦q⟧`. -/
theorem denote_pairP (p : Plan Γ A) (q : Plan Γ B) (γ : Env Γ) :
    denote (Plan.pairP p q) γ = Prod.mk <$> denote p γ <*> denote q γ :=
  Agentic.Core.denote_zipWith' Prod.mk p q γ

/-- `⟦seq p q⟧ = ⟦p⟧ >> ⟦q⟧`: the answer is discarded, so no `dyn`. -/
theorem denote_seq (p : Plan Γ A) (q : Plan Γ B) (γ : Env Γ) :
    denote (Plan.seq p q) γ = denote p γ >>= fun _ => denote q γ :=
  Agentic.Core.denote_seq p q γ

/-- **Monad, and the price of it.** `⟦bindP p k⟧ = ⟦p⟧ >>= fun a => ⟦k a⟧` —
the kernel's `den (p ≫= k) γ = den p γ >>= fun a => den (k a) γ`, which holds,
and holds of a term containing a `dyn`. That the equation closes only through
the quarantined former is the honest statement that general value-sequencing is
the dynamic rung. -/
theorem denote_bindP {c : Code} (p : Plan Γ (El c)) (k : El c → Plan Γ B) (γ : Env Γ) :
    denote (Plan.bindP p k) γ = denote p γ >>= fun a => denote (k a) γ :=
  Agentic.Core.denote_bindP p k γ

/-! ## Panels: the convolution law, and the honest order fact -/

/-- **The panel square.** A panel is the `foldr` of the applicative product over
its members' meanings:

```
⟦panel ps⟧ γ = foldr (fun x y => (· * ·) <$> x <*> y) (pure 1) (map ⟦·⟧ ps)
```

There is no `panelT`, no `parT` and no reducer argument: the reducer is the
`Monoid` instance, and the shape of the combination is `Dlg`'s own applicative.
This is the equation the retired panel-convolution stratum wanted reachable
from a written plan — a panel's aggregate as a product in a monoid semiring
`S⟨K⟩`. That stratum is gone (`acat-q1i`; its results are preserved in
`doc/research/term-algebra-results.md` §1.5), and the panel that ships is
this one: the `Monoid` fold, not convolution over an arbitrary key monoid. -/
theorem denote_panel [Monoid (El c)] (ps : List (Plan Γ (El c))) (γ : Env Γ) :
    denote (Plan.panel ps) γ
      = (ps.map (fun p => denote p γ)).foldr (fun x y => (· * ·) <$> x <*> y) (pure 1) := by
  induction ps with
  | nil => rfl
  | cons p ps ih =>
    simp only [Plan.panel_cons, List.map_cons, List.foldr_cons]
    rw [Agentic.Core.denote_zipWith' (· * ·) p (Plan.panel ps) γ, ih]

/-- **On values**: the answer is the `foldMap` of the members' answers into the
monoid. Quorum, "everyone approved" and the objection product are this one
equation at three monoids. -/
theorem run_panel [Monoid (El c)] (ω : Ω) (ps : List (Plan Γ (El c))) (γ : Env Γ) :
    Plan.run ω (Plan.panel ps) γ = (ps.map (fun p => Plan.run ω p γ)).prod :=
  Agentic.Core.run_panel ω ps γ

/-- **On transcripts**: concatenation, in the order the panel was written. -/
theorem trace_panel [Monoid (El c)] (ω : Ω) (ps : List (Plan Γ (El c))) (γ : Env Γ) :
    Plan.trace ω (Plan.panel ps) γ = (ps.map (fun p => Plan.trace ω p γ)).flatten :=
  Agentic.Core.trace_panel ω ps γ

/-- `[[panellistA]]` = a question put to one reviewer. -/
def panellistA : Q .verdict := { addressee := .model "a", scope := 1, prompt := "", draw := 0 }

/-- `[[panellistB]]` = the same question put to a *different* reviewer, so that
the two events differ in shape and a reordering is visible. -/
def panellistB : Q .verdict := { addressee := .model "b", scope := 1, prompt := "", draw := 0 }

/-- **The honest order fact.** A panel's transcript is **never** permutation-
invariant *as a list*: reordering the members reorders the events, in every
world. What is invariant is the transcript as a multiset
(`trace_panel_perm_multiset`), the approval decision
(`approved_panel_perm`) and, in a commutative carrier, the bill
(`billFresh_panel_perm`).

So "parallel" is a fact about a runtime and not about the meaning, and the
licence to reorder is a licence to choose an order — not to change which
consultations happen. That is the correct outcome: were the transcript itself a
multiset, the *order* of a metered conversation would be outside the meaning,
and it is not. -/
theorem trace_panel_not_perm_invariant :
    ∃ (ω : Ω) (ps ps' : List (Plan [] (El .verdict))), ps.Perm ps' ∧
      (Plan.trace ω (Plan.panel ps) Env.nil).map Event.shape
        ≠ (Plan.trace ω (Plan.panel ps') Env.nil).map Event.shape := by
  refine ⟨ωDefault, [Plan.askC1 .verdict panellistA, Plan.askC1 .verdict panellistB],
    [Plan.askC1 .verdict panellistB, Plan.askC1 .verdict panellistA], List.Perm.swap _ _ _, ?_⟩
  decide

/-! ## Bounded revision: the check-then-revise unrolling -/

/-- The unrolling at fuel `0`: **one check and no revision**, and the artefact
comes back either way — marked with whether that check approved it. -/
theorem reviseLoop_zero {Kc : El c → Env Γ → Dlg Verdict}
    {Kr : El c × Verdict → Env Γ → Dlg (El c)} (a : El c) (γ : Env Γ) :
    reviseLoop Kc Kr 0 a γ
      = Kc a γ >>= fun v => pure (a, Verdict.approvedB v) := rfl

/-- The unrolling at fuel `n+1`: **check first**, stop if approved, and only
otherwise revise — with the verdict threaded into the revision — and go again
with one less fuel. `revising … n` therefore *writes* `n + 1` checks and `n`
revisions, and never pays for a revision it does not check; the `if` above is
why a run performs between one and `n + 1` of those checks rather than all of
them. Three independent derivations in the dossier wrote this backwards
(`attack-adequacy` A1); this is the shape the English asks for. -/
theorem reviseLoop_succ {Kc : El c → Env Γ → Dlg Verdict}
    {Kr : El c × Verdict → Env Γ → Dlg (El c)} (n : Nat) (a : El c) (γ : Env Γ) :
    reviseLoop Kc Kr (n + 1) a γ
      = Kc a γ >>= fun v =>
          if Verdict.approvedB v then pure (a, true)
          else Kr (a, v) γ >>= fun a' => reviseLoop Kc Kr n a' γ := rfl

/-- **The revision square.** The unrolled plan means the semantic loop, at every
fuel and at every artefact — two independently written definitions, one a
`Nat.rec` over plans and one a `Nat.rec` over dialogues, agreeing.

Stated at the root (`Sub.id`), which is where an author writes it; the
context-polymorphic form the induction needs is `denotes_revising`.

Its two `Denotes` hypotheses survive the Yoneda collapse, and the reason is
recorded at `denotes_revising`: `check` sits at an answer type and could be
written `Cont.ofPlan`, but `revise` sits at `El c × Verdict`, a *product* of
answer types, and a context extension represents one answer and not two. -/
theorem denote_revising {check : Cont Γ (El c) Verdict} {revise : Cont Γ (El c × Verdict) (El c)}
    {Kc : El c → Env Γ → Dlg Verdict} {Kr : El c × Verdict → Env Γ → Dlg (El c)}
    (hc : Denotes check Kc) (hr : Denotes revise Kr) (n : Nat) (a : Expr Γ (El c))
    (γ : Env Γ) :
    denote (Plan.revising check revise n Γ Sub.id a) γ = reviseLoop Kc Kr n (a γ) γ :=
  denotes_revising hc hr n Γ Sub.id a γ

/-! ## C5: soundness of the level fold

The connection from `Agentic/Core/Level.lean` back to the meaning. Each rung's
claim is a statement about the *transcript* of the denotation, so these are the
theorems that say the syntactic fold is about something. -/

/-- **`batch` is sound**: at the bottom rung the question list is written in the
term — the same list in every world *and* under every environment, because
there is no `ask` node for an answer to flow into. -/
theorem level_sound_batch (p : Plan Γ A) (h : level p ≤ Level.batch)
    (γ γ' : Env Γ) (ω ω' : Ω) :
    (Plan.trace ω p γ).map Event.key = (Plan.trace ω' p γ').map Event.key :=
  Option.some.inj ((asks_eq_of_le_batch p h γ γ ω).symm.trans (asks_eq_of_le_batch p h γ γ' ω'))

/-- **`pipeline` is sound, in the form that is true**: the sequence of answer
codes — hence the number of consultations, hence the *shape of the transcript as
a list* — is fixed by the term. No world changes it, and no hypothesis is
needed.

This is the rung the kernel exists to carry: the prompt may be a function of an
earlier answer and the conversation still has a shape known before it starts. -/
theorem level_sound_pipeline (p : Plan Γ A) (h : level p ≤ Level.pipeline)
    (γ : Env Γ) (ω ω' : Ω) :
    (Plan.trace ω p γ).map Event.c = (Plan.trace ω' p γ).map Event.c :=
  Option.some.inj
    ((codes_eq_of_le_pipeline p h γ ω).symm.trans (codes_eq_of_le_pipeline p h γ ω'))

/-- …and the count, which is what `#asks` means. -/
theorem level_sound_pipeline_count (p : Plan Γ A) (h : level p ≤ Level.pipeline)
    (γ : Env Γ) (ω ω' : Ω) :
    (Plan.trace ω p γ).length = (Plan.trace ω' p γ).length :=
  length_trace_eq_of_le_pipeline p h γ ω ω'

/-- **The kernel's C2, in full and with no hypothesis.** At `level ≤ pipeline`
the sequence of question *shapes* — addressee, scope and draw, all of it — is
fixed by the term, in every world and under every environment.

This is the claim that was false of an earlier representation, in which `ask`
carried an arbitrary `Expr Γ (Q c)` and an answer could therefore choose *whom*
the next question went to. It is true of this one because the choice is not
there to make: an `ask` node writes `s : Q.Shape c` and computes only the words.
The predicate that used to be its hypothesis is deleted rather than discharged —
`shape_projects_from_ask` below is what replaced it. -/
theorem level_sound_pipeline_shape (p : Plan Γ A) (h : level p ≤ Level.pipeline)
    (γ γ' : Env Γ) (ω ω' : Ω) :
    (Plan.trace ω p γ).map Event.shape = (Plan.trace ω' p γ').map Event.shape :=
  shapes_eq_of_le_pipeline p h γ γ' ω ω'

/-- **…and the one-line reason.** The shape of the event an `ask` node records
is the shape written in the node, whatever the environment says. Every world and
every environment sees the same `s`; the induction of
`shapes_eq_of_le_pipeline` is this equation and nothing else.

Stated as a `rfl` on purpose: "the shape is a projection of the syntax" is the
kind of claim that should cost nothing to check. -/
theorem shape_projects_from_ask (ω : Ω) (c : Code) (s : Q.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) (γ : Env Γ) :
    ((Plan.trace ω (Plan.ask c s e k) γ).head?).map Event.shape = some ⟨c, s⟩ := rfl

/-- **`branch` is sound**: the bill of every run is one of the finite bag of
bills the term determines. Both arms are in the term, so the bag exists; the one
hypothesis is the one `pipeline` needs. -/
theorem level_sound_branch [CommMonoid S] {price : Price S} (hp : PricesByShape price)
    (p : Plan Γ A) (h : level p ≤ Level.branch) (γ : Env Γ) (ω : Ω) :
    billFresh price (Plan.trace ω p γ) ∈ costM price p h γ :=
  bill_mem_leaves hp p h γ γ ω

/-- **…and at `dynamic` there is nothing to be sound about**: the rung admits a
plan (`unbounded`) for which no finite set of bills exists, hence no cost tree
of any shape. The level fold's top rung is a non-existence theorem — a witness,
not a universal — which is the honest replacement for a type index that bounds
nothing. -/
theorem level_sound_dynamic :
    ¬ ∃ L : List (Multiplicative Nat),
        ∀ ω : Ω, billFresh tick (Plan.trace ω unbounded Env.nil) ∈ L :=
  no_finite_bill_set_at_dyn

/-! ## The laws of the surface operations

`Dlg` is a `LawfulMonad` with no quotient, and `Plan.Equiv` is the kernel of
`denote`, so each monad law descends to a plan-level equation *for free* — no
congruence obligation, because the kernel of a compositional meaning is a
congruence for every former (§3 q9, consequence 1). What follows is that
descent, written out for the operations an author actually uses. -/

/-! ### Congruence is free

Four congruences, each proved by writing the square twice and using the
hypothesis in between. The incumbent's four *missing* congruences — `retryT`,
`fanT`, `bindT` and `shareT`, the last impossible in kind — are missing because
`WEqR` is an `∃σ. …` and is therefore not the kernel of anything. -/

/-- Scope respects meaning. -/
theorem under_congr (σ : Sig) {p p' : Plan Γ A} (h : p ≈ᵖ p') :
    Plan.under σ p ≈ᵖ Plan.under σ p' := by
  intro γ; rw [denote_under, denote_under, h γ]

/-- The functorial action respects meaning. -/
theorem mapP_congr (f : A → B) {p p' : Plan Γ A} (h : p ≈ᵖ p') :
    Plan.mapP f p ≈ᵖ Plan.mapP f p' := by
  intro γ; rw [denote_mapP, denote_mapP, h γ]

/-- The applicative action respects meaning, in both arguments. -/
theorem zipWith_congr (f : A → B → C) {p p' : Plan Γ A} {q q' : Plan Γ B}
    (hp : p ≈ᵖ p') (hq : q ≈ᵖ q') : Plan.zipWith f p q ≈ᵖ Plan.zipWith f p' q' := by
  intro γ; rw [denote_zipWith, denote_zipWith, hp γ, hq γ]

/-- A panel respects meaning member by member — the congruence the incumbent
could not state at all, because a panel there was a labelled construct and the
labels were not part of the meaning. -/
theorem panel_congr [Monoid (El c)] {ps ps' : List (Plan Γ (El c))}
    (h : List.Forall₂ (· ≈ᵖ ·) ps ps') : Plan.panel ps ≈ᵖ Plan.panel ps' := by
  induction h with
  | nil => intro γ; rfl
  | cons hpq _ ih => exact zipWith_congr _ hpq ih

/-! ### The monad laws of the surface, descended from `Dlg` -/

/-- **Functor identity.** `mapP id ≈ id`. -/
theorem mapP_id (p : Plan Γ A) : Plan.mapP id p ≈ᵖ p := by
  intro γ
  rw [denote_mapP]
  exact id_map _

/-- **Functor composition.** `mapP (g ∘ f) ≈ mapP g ∘ mapP f`. -/
theorem mapP_comp (f : A → B) (g : B → C) (p : Plan Γ A) :
    Plan.mapP (g ∘ f) p ≈ᵖ Plan.mapP g (Plan.mapP f p) := by
  intro γ
  rw [denote_mapP, denote_mapP, denote_mapP, comp_map]

/-! ### …and the same two laws at the syntax, which is strictly stronger

`mapP_id` and `mapP_comp` above are stated up to `≈ᵖ`, i.e. through `denote`, and
they descend from `Dlg`'s `LawfulFunctor` — which is the right way to *derive*
them and the wrong way to *state* them, because they are in fact true on the
nose. The two below are equalities of **terms**.

**Which is stronger, and why both exist.** `≈ᵖ` is the kernel of `denote`
(`Plan.Equiv`), so a term equality implies the `≈ᵖ` version and not conversely,
and the gap is not academic here: `Plan.size`, `Plan.askNodes`,
`Cost.costSummary` and `Explain.planLines` are **not** `≈ᵖ`-invariant
(`level_not_equiv_invariant` below exhibits the failure for `level`), and all
four are pinned by the frozen corpus under `test/corpus/`. A rewriting pass
licensed only by the `≈ᵖ` laws may move a frozen number; one licensed by the
syntactic laws cannot.

The `≈ᵖ` versions stay because they are the ones that sit in the table of
descended monad laws, alongside `bindP_pure` and `bindP_assoc`, which are *only*
true up to `≈ᵖ` — `bindP` inserts a `dyn` node, so no term equality is available
there. Keeping the pair side by side is what makes the asymmetry visible. -/

/-- **Functor identity, at the syntax.** `Morphism.graft_pure` is the whole
proof: `mapP id` grafts the leaf-preserving continuation. -/
theorem mapP_id' (p : Plan Γ A) : Plan.mapP id p = p := graft_pure p

/-- **Functor composition, at the syntax.** `graft_assoc` and `rfl`: the composed
continuation of two leaf rewrites is the leaf rewrite of the composite. -/
theorem mapP_comp' (f : A → B) (g : B → C) (p : Plan Γ A) :
    Plan.mapP g (Plan.mapP f p) = Plan.mapP (g ∘ f) p := by
  rw [Plan.mapP, Plan.mapP, graft_assoc]
  rfl

/-- **Left unit.** Binding a pure leaf applies the continuation at the leaf's
value. Not statable as `≈ᵖ` between two fixed plans, because the continuation's
argument is a function of the environment — which is the syntax being honest
about what a leaf is. -/
theorem bindP_ret {c : Code} (e : Expr Γ (El c)) (k : El c → Plan Γ B) (γ : Env Γ) :
    denote (Plan.bindP (Plan.ret e) k) γ = denote (k (e γ)) γ := by
  rw [denote_bindP, denote_ret]
  exact pure_bind _ _

/-- **Right unit.** `bindP p ret ≈ p`. -/
theorem bindP_pure {c : Code} (p : Plan Γ (El c)) :
    Plan.bindP p (fun a => Plan.ret (fun _ => a)) ≈ᵖ p := by
  intro γ
  rw [denote_bindP]
  exact bind_pure _

/-- **Associativity.** The monad law, descended to plans as a lemma from the
denotation rather than asserted about the syntax. -/
theorem bindP_assoc {c c' : Code} (p : Plan Γ (El c)) (k : El c → Plan Γ (El c'))
    (h : El c' → Plan Γ D) :
    Plan.bindP (Plan.bindP p k) h ≈ᵖ Plan.bindP p (fun a => Plan.bindP (k a) h) :=
  fun γ => denote_bindP_assoc p k h γ

/-- **`seq` is `bindP` at a constant continuation** — in *meaning*. The two
terms are not interchangeable, and the next theorem says why. -/
theorem seq_equiv_bindP {c : Code} (p : Plan Γ (El c)) (q : Plan Γ B) :
    Plan.seq p q ≈ᵖ Plan.bindP p (fun _ => q) := by
  intro γ
  rw [denote_seq, denote_bindP]

/-- **`mapP` is `bindP` at a pure continuation** — again in meaning only. -/
theorem mapP_equiv_bindP {c : Code} (f : El c → B) (p : Plan Γ (El c)) :
    Plan.mapP f p ≈ᵖ Plan.bindP p (fun a => Plan.ret (fun _ => f a)) := by
  intro γ
  rw [denote_mapP, denote_bindP]
  simp only [denote_ret]
  exact map_eq_pure_bind f (denote p γ)

/-- **The level is not an invariant of semantic equality**, and this is the
point rather than a defect.

Two plans with one meaning — `pure a` twice over — sit at opposite ends of the
chain, because one of them writes its sequencing with the quarantined former.
The level classifies **terms**: it reports what an analyser may do with the
*text* the author wrote, and an author who writes `bindP` where `mapP` would
have done has given up the analysis even though the dialogue is unchanged.

This is why every cost theorem in this development is stated about a term, and
why `attack-simplicity`'s Test 3 kills the alternative — a level defined as a
predicate on traces makes the pipeline theorem false. -/
theorem level_not_equiv_invariant :
    ∃ p p' : Plan [] (El .ack), p ≈ᵖ p' ∧ level p ≠ level p' := by
  refine ⟨Plan.ret (fun _ => default), Plan.bindP (c := .ack) (Plan.ret (fun _ => default))
    (fun a => Plan.ret (fun _ => a)), fun γ => ?_, by decide⟩
  rw [(bindP_ret (c := .ack) (fun _ => default) (fun a => Plan.ret (fun _ => a)) γ)]

/-! ## …and the Forcing Lemma fails at the syntax too

`Agentic/Core/Dlg.lean` refutes the kernel's Forcing Lemma: a dialogue that asks
one question *twice* carries a continuation no world can inspect, so `=` on
`Dlg` is strictly finer than indistinguishability. That refutation transports
straight through `denote`, and it is worth having at the syntax because §3 q9
states its equality claim about *plans*: `p ≈ᵖ p'` is the kernel of `denote`,
and the kernel of `denote` is strictly finer than the kernel of
`(run, trace)`. -/

/-- `[[repeatedP]]` = ask the same question twice and report both answers. -/
def repeatedP : Plan [] (Bool × Bool) :=
  .askC .flag Dlg.probe (.askC .flag Dlg.probe (.ret (fun γ => (γ.tail.head, γ.head))))

/-- `[[repeatedP']]` = ask the same question twice and report the first answer
twice. Because a world is a *function*, the second answer is already determined,
so the two plans say the same thing in every world. -/
def repeatedP' : Plan [] (Bool × Bool) :=
  .askC .flag Dlg.probe (.askC .flag Dlg.probe (.ret (fun γ => (γ.tail.head, γ.tail.head))))

/-- The two plans denote the two dialogues of `Dlg.not_forcing` on the nose, so
the refutation transports rather than being rebuilt. -/
theorem denote_repeatedP (γ : Env []) : denote repeatedP γ = Dlg.repeated := rfl

@[inherit_doc denote_repeatedP]
theorem denote_repeatedP' (γ : Env []) : denote repeatedP' γ = Dlg.repeated' := rfl

/-- **Indistinguishable is not the same as equal, at the syntax.** Two plans
with the same answer and the same transcript in every world, whose denotations
differ. So `Plan.Equiv` — equality of denotations — is *not* the kernel of
`(run, trace)`, and the kernel's §3 q9 must be read as the coarser relation
`Dlg.Obs` if it is to be the observational one.

The gap is exactly the repeat-free fragment (`Dlg.forcing_of_fresh`), and a
deliberate resample is a *different question* (§3 q1), so plans in the domain
live where the two relations agree. -/
theorem plan_not_forcing :
    ∃ p p' : Plan [] (Bool × Bool),
      (∀ (γ : Env []) (ω : Ω), Plan.run ω p γ = Plan.run ω p' γ
        ∧ Plan.trace ω p γ = Plan.trace ω p' γ) ∧ ¬ (p ≈ᵖ p') := by
  refine ⟨repeatedP, repeatedP', fun γ ω => ⟨rfl, rfl⟩, fun h => Dlg.repeated_ne ?_⟩
  exact (denote_repeatedP Env.nil).symm.trans ((h Env.nil).trans (denote_repeatedP' Env.nil))

/-! ## The interpreter is the fold

Kernel §5(i). There is no second semantics to reconcile: `Plan.run` and
`Plan.trace` are *defined* as `Dlg.run` and `Dlg.trace` of the denotation, so
the commutation square between the interpreter and the meaning is `rfl` and
these two theorems have no content beyond saying so. Writing the interpreter as
anything other than this fold is what would make the theorem hard. -/

theorem run_eq_run_denote (ω : Ω) (p : Plan Γ A) (γ : Env Γ) :
    Plan.run ω p γ = Dlg.run ω (denote p γ) := rfl

theorem trace_eq_trace_denote (ω : Ω) (p : Plan Γ A) (γ : Env Γ) :
    Plan.trace ω p γ = Dlg.trace ω (denote p γ) := rfl

end Morphism

end Agentic.Core
