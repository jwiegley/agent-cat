import Agentic.Core.World

/-!
# Dialogues: the coherent world-indexed (answer, transcript) pair

Rederivation kernel §1 (rows `W A`, `Dlg A`, `Event`, `Trace`), §2.2 (the
observations, each a class morphism), §3 q9 (equality), and the Forcing Lemma.
This module is the port of the compiled probe
`attack-realizability-lean/A_dlg_lawful.lean` into this package's `Code`/`Q`/`El`
and namespace, with the observations, the scope action, and one result the
dossier did not have.

**Lead with the observation pair, derive the tree.** What a workflow *means* is
the pair of maps

```
run   : Ω → A            what it answers
trace : Ω → List Event   what it consulted to answer it
```

subject to the coherence condition that `trace` is what `run` consulted and
`run` reads only what `trace` recorded. `Dlg` is that object presented so that
coherence is *structural*: a dialogue cannot read an answer it did not ask for,
because the continuation is a function of the answer.

**And this presentation is not tight.** §1 asserts a Forcing Lemma — that `=` on
`Dlg` is exactly agreement of `run` and `trace` at every world — and it is
**false**. `not_forcing` below is a machine-checked refutation: a dialogue that
asks one question *twice* has a second continuation whose value at every answer
but the first is unobservable, because the world is a function. The lemma is
true, and proved here as `forcing_of_fresh`, exactly on the dialogues that never
repeat a question, where "never repeats" is `Fresh` — the same freshness side
condition that the memo table's `lookup_cons_of` needs. The consequence for the
kernel: `Dlg` is a faithful *representation* of the observation pair
and is not equal to it, so §3 q9's "equality is plain `=` on `Dlg`" must be
weakened to "`≈` is the kernel of `(run, trace)`" — which costs no `Quot`,
because `≈` is only ever used in theorem statements.
-/

namespace Agentic.Core

/-- `[[Dlg A]]` = the coherent world-indexed pair `(run, trace)` of an answer in
`A` and the transcript that produced it, presented as its solved form
`Dlg A = A + Σ (c : Code). Q c × (El c → Dlg A)`.

Least fixed point, so every dialogue is finite along every path: `run` is total,
every transcript is finite, and no `⊥` appears anywhere (§3 q8). The
continuation is a *function*, not a table and not a syntax with binders, which
is what makes names unnecessary and the monad laws hold without a quotient. -/
inductive Dlg (A : Type) : Type where
  /-- The dialogue is over and the answer is this. -/
  | done : A → Dlg A
  /-- Put this question, and continue with whatever comes back. -/
  | ask : (c : Code) → Q c → (El c → Dlg A) → Dlg A
  deriving Inhabited

namespace Dlg

variable {A B C : Type}

/-! ## The monad, with no quotient anywhere -/

/-- Sequencing: continue every leaf with `k`. `[[bind p k]]` is the dialogue that
runs `p`, then runs `k` on its answer — which is the content of `run_bind` and
`trace_bind` below. -/
def bind : Dlg A → (A → Dlg B) → Dlg B
  | .done a, k => k a
  | .ask c q f, k => .ask c q (fun x => bind (f x) k)

instance : Monad Dlg where
  pure := .done
  bind := bind

@[simp] theorem bind_done (a : A) (k : A → Dlg B) : bind (.done a) k = k a := rfl

@[simp] theorem bind_ask (c : Code) (q : Q c) (f : El c → Dlg A) (k : A → Dlg B) :
    bind (.ask c q f) k = .ask c q (fun x => bind (f x) k) := rfl

/-- Right unit, propositionally and with no `Quot`: `p >>= pure = p`. -/
theorem bind_pure (p : Dlg A) : bind p (fun a => .done a) = p := by
  induction p with
  | done a => rfl
  | ask c q f ih => simp only [bind_ask, Dlg.ask.injEq, heq_eq_eq, true_and]; funext x; exact ih x

/-- Associativity, propositionally and with no `Quot`. -/
theorem bind_assoc (p : Dlg A) (k : A → Dlg B) (h : B → Dlg C) :
    bind (bind p k) h = bind p (fun a => bind (k a) h) := by
  induction p with
  | done a => rfl
  | ask c q f ih => simp only [bind_ask, Dlg.ask.injEq, heq_eq_eq, true_and]; funext x; exact ih x

/-- **The monad laws hold as propositional equalities**, by induction plus
`funext`: no `Quot`, no `Classical.choice`, and `bind` stays computable, so the
interpreter can run on the semantic type. (`attack-realizability`
`F_quotient_needs_choice.lean` is what happens to the alternatives.) -/
instance : LawfulMonad Dlg := by
  apply LawfulMonad.mk' (m := Dlg)
  · intro α x
    induction x with
    | done a => rfl
    | ask c q f ih =>
      simp only [Functor.map, bind_ask, Dlg.ask.injEq, heq_eq_eq, true_and]
      funext y; exact ih y
  · intro α β x f; rfl
  · intro α β γ x f g; exact bind_assoc x f g

/-! ## The two observations, which are the meaning -/

end Dlg

/-- `[[Event]]` = one thing said and its reply: `Σ c, Q c × El c`. -/
structure Event where
  /-- The kind of answer asked for. -/
  c : Code
  /-- The question put. -/
  q : Q c
  /-- What came back. -/
  a : El c

/-- `[[Trace]]` = the transcript: the free monoid on `Event`. Concatenation is
`++`, the empty transcript is `[]`, and every bill is a monoid morphism out of
it — which is why a shared read is one event and a duplicated read is two *in
the object that decides equality*. -/
abbrev Trace : Type := List Event

namespace Dlg

variable {A B : Type}

/-- `[[run ω p]]` = what `p` answers in the world `ω`.

**Morphism equation** (`run ω : Dlg ⇒ Id` is a monad morphism):
`run ω (pure a) = a` and `run ω (p >>= k) = run ω (k (run ω p))` — the latter is
`run_bind`. -/
def run (ω : Ω) : Dlg A → A
  | .done a => a
  | .ask c q f => run ω (f (ω c q))

/-- `[[trace ω p]]` = what `p` consulted, in order, in the world `ω`.

**Morphism equation** (`⟨run ω, trace ω⟩ : Dlg ⇒ Writer Trace` is a monad
morphism into the free monoid): `trace ω (pure a) = []` and
`trace ω (p >>= k) = trace ω p ++ trace ω (k (run ω p))` — the latter is
`trace_bind`, and it is what makes the transcript part of the meaning rather
than a log. -/
def trace (ω : Ω) : Dlg A → Trace
  | .done _ => []
  | .ask c q f => ⟨c, q, ω c q⟩ :: trace ω (f (ω c q))

@[simp] theorem run_done (ω : Ω) (a : A) : run ω (.done a) = a := rfl

@[simp] theorem run_ask (ω : Ω) (c : Code) (q : Q c) (f : El c → Dlg A) :
    run ω (.ask c q f) = run ω (f (ω c q)) := rfl

@[simp] theorem trace_done (ω : Ω) (a : A) : trace ω (.done a) = [] := rfl

@[simp] theorem trace_ask (ω : Ω) (c : Code) (q : Q c) (f : El c → Dlg A) :
    trace ω (.ask c q f) = ⟨c, q, ω c q⟩ :: trace ω (f (ω c q)) := rfl

/-- `run ω` preserves `pure`. -/
@[simp] theorem run_pure (ω : Ω) (a : A) : run ω (pure a : Dlg A) = a := rfl

/-- `trace ω` sends `pure` to the empty transcript. -/
@[simp] theorem trace_pure (ω : Ω) (a : A) : trace ω (pure a : Dlg A) = [] := rfl

/-- **`run ω` is a monad morphism into `Id`.** One of the two equations that
make `(run, trace)` the meaning. -/
theorem run_bind (ω : Ω) (p : Dlg A) (k : A → Dlg B) :
    run ω (bind p k) = run ω (k (run ω p)) := by
  induction p with
  | done a => rfl
  | ask c q f ih => simp only [bind_ask, run_ask]; exact ih _

/-- **`⟨run ω, trace ω⟩` is a monad morphism into `Writer Trace`.** The second of
the two equations that make `(run, trace)` the meaning: the transcript of a
sequence is the concatenation of the transcripts, so cost is a monoid morphism
out of the meaning and not a second semantics. -/
theorem trace_bind (ω : Ω) (p : Dlg A) (k : A → Dlg B) :
    trace ω (bind p k) = trace ω p ++ trace ω (k (run ω p)) := by
  induction p with
  | done a => rfl
  | ask c q f ih => simp only [bind_ask, trace_ask, run_ask, List.cons_append]; exact congrArg _ (ih _)

/-- The same two equations written for `>>=`, which is what `do`-notation
elaborates to. -/
theorem run_bind' (ω : Ω) (p : Dlg A) (k : A → Dlg B) :
    run ω (p >>= k) = run ω (k (run ω p)) := run_bind ω p k

theorem trace_bind' (ω : Ω) (p : Dlg A) (k : A → Dlg B) :
    trace ω (p >>= k) = trace ω p ++ trace ω (k (run ω p)) := trace_bind ω p k

/-- One consultation, as a dialogue. `[[ask1 c q]]` = the dialogue that puts `q`
and answers with the reply. -/
def ask1 (c : Code) (q : Q c) : Dlg (El c) := .ask c q .done

@[simp] theorem run_ask1 (ω : Ω) (c : Code) (q : Q c) : run ω (ask1 c q) = ω c q := rfl

@[simp] theorem trace_ask1 (ω : Ω) (c : Code) (q : Q c) :
    trace ω (ask1 c q) = [⟨c, q, ω c q⟩] := rfl

/-! ## Sharing is a variable used twice

`share_ne_dup`, which the incumbent's whole label/site/key apparatus existed to
state, is two lines about transcripts once the transcript is in the meaning
(§3 q2). -/

/-- Consulting once and reading the answer twice records **one** event. -/
theorem trace_share (ω : Ω) (c : Code) (q : Q c) :
    trace ω (do let x ← ask1 c q; pure (x, x)) = [⟨c, q, ω c q⟩] := rfl

/-- Consulting twice records **two** events, even though both consultations have
the same answer. Cost is therefore an invariant of semantic equality, and no
label is needed to tell sharing from duplication. -/
theorem trace_dup (ω : Ω) (c : Code) (q : Q c) :
    trace ω (do let x ← ask1 c q; let y ← ask1 c q; pure (x, y))
      = [⟨c, q, ω c q⟩, ⟨c, q, ω c q⟩] := rfl

/-! ## Scope: the bulk operator is a fold and a monoid action -/

/-- `[[under σ p]]` = `p` with every question relabelled by `σ`: the unique
monad morphism `Dlg ⇒ Dlg` extending `ask ∘ σ` (§2.2, §3 q3). A *fold*, not a
constructor — the incumbent's `scopeT` is condemned by the package's own
no-weakening-constructor rule. -/
def under (σ : Sig) : Dlg A → Dlg A
  | .done a => .done a
  | .ask c q f => .ask c (σ c q) (fun x => under σ (f x))

@[simp] theorem under_done (σ : Sig) (a : A) : under σ (.done a) = .done a := rfl

@[simp] theorem under_ask (σ : Sig) (c : Code) (q : Q c) (f : El c → Dlg A) :
    under σ (.ask c q f) = .ask c (σ c q) (fun x => under σ (f x)) := rfl

/-- **Action law 1** (`under 1 = id`). -/
theorem under_idSig (p : Dlg A) : under idSig p = p := by
  induction p with
  | done a => rfl
  | ask c q f ih =>
    simp only [under_ask, idSig, Dlg.ask.injEq, heq_eq_eq, true_and]
    funext x; exact ih x

/-- **Action law 2** (`under σ ∘ under τ = under (σ ∘ τ)`). Together with
`under_idSig` this says `under` is a monoid action of relabellings on dialogues,
which is `Agentic.actR_compose` at this carrier. -/
theorem under_under (σ τ : Sig) (p : Dlg A) :
    under σ (under τ p) = under (compSig σ τ) p := by
  induction p with
  | done a => rfl
  | ask c q f ih =>
    simp only [under_ask, compSig, Dlg.ask.injEq, heq_eq_eq, true_and]
    funext x; exact ih x

/-- **Innermost wins, at the meaning.** Wrapping a further model scope *outside*
one that is already there changes no question of `p`: the inner `atModel` is the
one in force, which is `Agentic.Scope`'s `innermost_wins` transported through
`under`.

Note which relabelling is applied last. `under_under` composes by `compSig`, so
the outer one is; innermost-wins is therefore a fact about the *side* on which
`atModel` appends its setting, not about the order of application, and this
equation is what pins that side down. -/
theorem under_atModel_atModel (mOuter mInner : String) (p : Dlg A) :
    under (atModel mOuter) (under (atModel mInner) p) = under (atModel mInner) p := by
  rw [under_under, compSig_atModel_atModel]

/-- **Morphism equation for `under`**: relabelling questions is precomposition
on worlds. `[[run ω (under σ p)]] = [[run (ω ∘ σ) p]]` — which is the sense in
which scope is part of the question and not a layer around the meaning. -/
theorem run_under (ω : Ω) (σ : Sig) (p : Dlg A) :
    run ω (under σ p) = run (fun c q => ω c (σ c q)) p := by
  induction p with
  | done a => rfl
  | ask c q f ih => simp only [under_ask, run_ask]; exact ih _

/-- Relabelling one event. -/
def _root_.Agentic.Core.Event.relabel (σ : Sig) (e : Event) : Event := ⟨e.c, σ e.c e.q, e.a⟩

/-- **Morphism equation for `under` on transcripts**: the transcript of a
relabelled dialogue is the relabelled transcript of the dialogue at the
precomposed world. -/
theorem trace_under (ω : Ω) (σ : Sig) (p : Dlg A) :
    trace ω (under σ p) = (trace (fun c q => ω c (σ c q)) p).map (Event.relabel σ) := by
  induction p with
  | done a => rfl
  | ask c q f ih =>
    simp only [under_ask, trace_ask, List.map_cons, Event.relabel]
    exact congrArg _ (ih _)

/-! ## The Forcing Lemma, and the shape it actually has -/

/-- Equality of meanings: `p ≈ p'` iff no world tells them apart, in either
answer or transcript. This is the kernel of `(run, trace)`, and it is what §3 q9
means by semantic equality. Stating it needs no `Quot`; it is a relation used in
theorem statements. -/
def Obs (p p' : Dlg A) : Prop :=
  ∀ ω, run ω p = run ω p' ∧ trace ω p = trace ω p'

/-- The same, relative to a partial world: no world *extending `t`* tells them
apart. This is the shape the induction needs, because at each `ask` the
continuations are compared under one more recorded answer. -/
def ObsOn (t : Table) (p p' : Dlg A) : Prop :=
  ∀ ω, Extends ω t → run ω p = run ω p' ∧ trace ω p = trace ω p'

/-- Indistinguishable everywhere is indistinguishable relative to anything. -/
theorem ObsOn.of_obs {t : Table} {p p' : Dlg A} (h : Obs p p') : ObsOn t p p' :=
  fun ω _ => h ω

/-- The easy direction of forcing: equal dialogues are indistinguishable. -/
theorem obs_of_eq {p p' : Dlg A} (h : p = p') : Obs p p' := by
  subst h; intro ω; exact ⟨rfl, rfl⟩

/-- Semantic equality is an equivalence, because it is the kernel of a
function. -/
theorem Obs.equivalence : Equivalence (@Obs A) :=
  ⟨fun _ _ => ⟨rfl, rfl⟩,
   fun h ω => ⟨(h ω).1.symm, (h ω).2.symm⟩,
   fun h₁ h₂ ω => ⟨(h₁ ω).1.trans (h₂ ω).1, (h₁ ω).2.trans (h₂ ω).2⟩⟩

/-- **Congruence is free.** `Obs` is the kernel of the compositional meaning
`(run, trace)`, so it is a congruence for `bind` with no proof obligation beyond
the two morphism equations — which is the form in which §3 q9's first
consequence survives the failure of the Forcing Lemma below, and it needs no
`Quot` because `Obs` appears only in statements. -/
theorem Obs.bind_congr {p p' : Dlg A} {k k' : A → Dlg B}
    (hp : Obs p p') (hk : ∀ a, Obs (k a) (k' a)) : Obs (bind p k) (bind p' k') := by
  intro ω
  have hr : run ω p = run ω p' := (hp ω).1
  refine ⟨?_, ?_⟩
  · rw [run_bind, run_bind, hr, (hk (run ω p') ω).1]
  · rw [trace_bind, trace_bind, hr, (hp ω).2, (hk (run ω p') ω).2]

/-- `Fresh t p` = along every path of `p`, each question is asked for the first
time relative to what `t` already records.

This is the same discipline as `lookup_cons_of`: prepending an answer preserves
the older lookups exactly when the key was absent. It is the hypothesis under
which a dialogue's continuations are all observable, and hence the hypothesis
the Forcing Lemma actually needs. -/
inductive Fresh {A : Type} : Table → Dlg A → Prop where
  /-- A finished dialogue asks nothing. -/
  | done (t : Table) (a : A) : Fresh t (.done a)
  /-- An `ask` is fresh when its question is unrecorded and each continuation is
  fresh relative to the table extended by that answer. -/
  | ask {t : Table} {c : Code} {q : Q c} {f : El c → Dlg A}
      (hnone : lookup t c q = none)
      (hcont : ∀ x, Fresh (Table.cons c q x t) (f x)) : Fresh t (.ask c q f)

/-- **The Forcing Lemma, in the form that is true.** Relative to a partial world
`t`, two dialogues that never re-ask a question `t` already answers are equal as
soon as no world extending `t` tells them apart.

Proof shape: at each `ask`, `worldOf t` is a world extending `t`, so the two
transcripts have equal heads, which forces the code and the question; and for
each possible answer `x`, the table extended by `⟨c,q,x⟩` is the partial world at
which the continuations must agree — freshness is exactly what lets that
extended table still imply the hypothesis at `t`. -/
theorem forcing_of_fresh {A : Type} (p : Dlg A) :
    ∀ (p' : Dlg A) (t : Table), Fresh t p → Fresh t p' → ObsOn t p p' → p = p' := by
  induction p with
  | done a =>
    intro p' t _ _ h
    cases p' with
    | done a' => exact congrArg _ (h (worldOf t) (worldOf_extends t)).1
    | ask c' q' f' =>
      have hx := (h (worldOf t) (worldOf_extends t)).2
      rw [trace_done, trace_ask] at hx
      exact absurd hx (by simp)
  | ask c q f ih =>
    intro p' t hp hp' h
    cases p' with
    | done a' =>
      have hx := (h (worldOf t) (worldOf_extends t)).2
      rw [trace_done, trace_ask] at hx
      exact absurd hx (by simp)
    | ask c' q' f' =>
      have hx := (h (worldOf t) (worldOf_extends t)).2
      rw [trace_ask, trace_ask] at hx
      injection hx with hhd _
      injection hhd with hc hq _
      subst hc
      have hq' : q = q' := eq_of_heq hq
      subst hq'
      cases hp with
      | ask hnone hcont =>
        cases hp' with
        | ask _ hcont' =>
          refine congrArg _ (funext fun x => ?_)
          refine ih x (f' x) (Table.cons c q x t) (hcont x) (hcont' x) ?_
          intro ω hext
          have hωx : ω c q = x := hext.head
          have hbase : Extends ω t := Extends.mono (le_cons_of_lookup_none x hnone) hext
          obtain ⟨hr, ht⟩ := h ω hbase
          rw [run_ask, run_ask, hωx] at hr
          rw [trace_ask, trace_ask, hωx] at ht
          injection ht with _ httl
          exact ⟨hr, httl⟩

/-- **The Forcing Lemma as the kernel states it, at the empty table**: dialogues
that never repeat a question are equal iff no world tells them apart. -/
theorem forcing {A : Type} (p p' : Dlg A)
    (hp : Fresh Table.nil p) (hp' : Fresh Table.nil p') : p = p' ↔ Obs p p' :=
  ⟨obs_of_eq, fun h => forcing_of_fresh p p' Table.nil hp hp' (ObsOn.of_obs h)⟩

/-- Freshness is not a vacuous hypothesis: one consultation is fresh. -/
theorem fresh_ask1 (c : Code) (q : Q c) : Fresh Table.nil (ask1 c q) :=
  Fresh.ask rfl (fun _ => Fresh.done _ _)

/-- Nor is it vacuous at depth: two consultations with *different* questions are
fresh, and a deliberate resample is a different question (§3 q1), so the
repeat-free fragment is where plans actually live. -/
theorem fresh_two (c : Code) {q q' : Q c} (h : q' ≠ q) :
    Fresh Table.nil (bind (ask1 c q) (fun _ => ask1 c q')) :=
  Fresh.ask rfl (fun x =>
    Fresh.ask (by rw [lookup_cons_of_ne_q Table.nil c x h, lookup_nil])
      (fun _ => Fresh.done _ _))

/-! ## …and the counterexample that says why the hypothesis is there -/

/-- A question, for the counterexample. -/
def probe : Q .flag := { addressee := .model "m", scope := 1, prompt := "?", draw := 0 }

/-- Ask one question twice and report both answers. -/
def repeated : Dlg (Bool × Bool) :=
  .ask .flag probe (fun x => .ask .flag probe (fun y => .done (x, y)))

/-- Ask one question twice and report the first answer twice. Because the world
is a *function*, the second answer is already determined, so the inner
continuation's value at any other answer is unobservable junk. -/
def repeated' : Dlg (Bool × Bool) :=
  .ask .flag probe (fun x => .ask .flag probe (fun _ => .done (x, x)))

/-- The two are indistinguishable: same answer and same transcript in every
world. -/
theorem repeated_obs : Obs repeated repeated' := fun _ => ⟨rfl, rfl⟩

/-- And they are not equal. -/
theorem repeated_ne : repeated ≠ repeated' := by
  intro h
  simp only [repeated, repeated', Dlg.ask.injEq, heq_eq_eq, true_and, funext_iff] at h
  have h3 := h true false
  simp at h3

/-- **The Forcing Lemma of the kernel is false.** `Dlg` over-represents the
observation pair: a repeated question leaves a continuation that no world can
inspect. The freshness hypothesis of `forcing_of_fresh` is therefore not
bookkeeping — it is the exact boundary of the claim.

Recorded here, in code, rather than in prose, because the kernel's §3 q9 rests
on it: semantic equality is `Obs`, and `Obs` coincides with `=` only on the
repeat-free fragment. -/
theorem not_forcing : ∃ (p p' : Dlg (Bool × Bool)), Obs p p' ∧ p ≠ p' :=
  ⟨repeated, repeated', repeated_obs, repeated_ne⟩

end Dlg

end Agentic.Core
