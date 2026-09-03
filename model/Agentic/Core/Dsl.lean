import Agentic.Core.Dsl.Check

/-!
# The elaboration, and what is provable about it

Stage 3, part four: the checker's front end (`checkProgram`) and the theorem
the elaboration exists to make true.

## Where the parser went

There is no parser here any more, and there is no concrete syntax: the
conformance boundary is `RawProgram`-in
(`doc/research/connection.md`, D10), and the authoring surface
that builds a `RawProgram` is the Haskell one. What survives in Lean is the
*verification spine* — the `Raw` types, this elaboration, and what is proved
about it — which is exactly the half every statement below was ever about:
none of these inductions ever mentioned a character of source text.

## Where the flagship went

This module is the *cheap* half, and deliberately so. It proves things about the
**checker** — ordinary structural inductions over `checkBlock`, no kernel
reduction of any particular program — and it elaborates in a second or two.
Everything about the flagship program itself lives in
`Agentic/Core/DslFlagship.lean`, which imports this module and dominates the
build.

The division is not tidiness. `Cost.costM` takes `level p ≤ Level.branch` as
an *argument*, so `checkProgram_level_le` below is the term that makes every
tool over programs compile: `Agentic/Core/Explain.lean`, and through it
`bisim/lean/Conformance.lean`. Those want the theorem and have no use whatever
for the flagship, so they import this file and not the other one.

## What "well-typed by construction" is and is not

`Dsl.check` and `Dsl.checkProgram` state their own soundness *in their types*:
neither "the result type-checks" nor "the result is closed" is a theorem here —
both are readings of the signature. What is **not** free, and is proved below,
is the fact that makes the elaboration worth having: `checkProgram_level_le` —
*every* program the checker accepts sits at or below the branch rung, so every
program has a finite cost tree. The induction carries one extra invariant the
redesigned checker introduced: a pending loop result's plan is itself at or
below the branch rung (`PendLevel`), which is exactly what the consuming
`case`'s graft needs.
-/

namespace Agentic.Core

open Plan

/-! ## Equality of transcripts is decidable

What lets the flagship's agreement with `Agentic/Core/HardenPatch.lean` be a
`decide` in each of the named worlds, and what lets a harness decide whether
the transcript it heard is the one the replay reconstructs — so it stays on the
cheap side of the split. -/

/-- An `Event` as the dependent pair it is. -/
def Event.toSigma (e : Event) : (c : Code) × (Q c × El c) :=
  ⟨e.c, e.q, e.a⟩

/-- …and back. -/
def Event.ofSigma (s : (c : Code) × (Q c × El c)) : Event :=
  ⟨s.1, s.2.1, s.2.2⟩

/-- **Morphism equation.** The two are inverse, on the nose: `Event` *is* the
`Σ`-type, and the pair of definitions is a change of spelling. -/
@[simp] theorem Event.ofSigma_toSigma (e : Event) : Event.ofSigma (Event.toSigma e) = e := rfl

instance instDecidableEqEvent : DecidableEq Event := fun e₁ e₂ =>
  decidable_of_iff (Event.toSigma e₁ = Event.toSigma e₂)
    ⟨fun h => by rw [← Event.ofSigma_toSigma e₁, ← Event.ofSigma_toSigma e₂, h], fun h => by rw [h]⟩

/-! ## Level, at the derived forms the checker emits -/

variable {Γ Δ : Ctx} {A B : Type} {ℓ : Level}

/-- A two-armed branch is at the branch rung together with its arms. -/
theorem level_caseB_le (e : Expr Γ Bool) (t f : Plan Γ A)
    (hb : Level.branch ≤ ℓ) (ht : level t ≤ ℓ) (hf : level f ≤ ℓ) :
    level (Plan.caseB e t f) ≤ ℓ := by
  simp only [Plan.caseB, level_case]
  refine max_le hb (Finset.sup_le fun b _ => ?_)
  cases b
  · exact hf
  · exact ht

/-- …and so is a branch on a verdict's finite classifier. -/
theorem level_caseV_le (e : Expr Γ Verdict) (arms : VTag → Plan Γ A)
    (hb : Level.branch ≤ ℓ) (ha : ∀ t, level (arms t) ≤ ℓ) :
    level (Plan.caseV e arms) ≤ ℓ := by
  simp only [Plan.caseV, level_case]
  exact max_le hb (Finset.sup_le fun t _ => ha t)

/-- A panel is at the join of its members' rungs, in the form an induction over
a checker can use. -/
theorem level_panel_le' {c : Code} [Monoid (El c)] (ps : List (Plan Γ (El c)))
    (h : ∀ p ∈ ps, level p ≤ ℓ) : level (Plan.panel ps) ≤ ℓ := by
  induction ps with
  | nil => exact bot_le
  | cons p ps ih =>
    refine le_trans (level_zipWith_le _ p (Plan.panel ps))
      (max_le (h p (List.mem_cons_self ..)) (ih fun q hq => h q (List.mem_cons_of_mem _ hq)))

/-- …and so is a text panel, for the same reason and by the same fold: the fence
lives in the `Expr` at the leaf and never in a node. -/
theorem level_panelText_le' (ps : List (String × Plan Γ (El .text)))
    (h : ∀ p ∈ ps, level p.2 ≤ ℓ) : level (Plan.panelText ps) ≤ ℓ := by
  induction ps with
  | nil => exact bot_le
  | cons p ps ih =>
    rw [Plan.panelText_cons]
    refine le_trans (level_zipWith_le _ p.2 (Plan.panelText ps))
      (max_le (h p (List.mem_cons_self ..)) (ih fun q hq => h q (List.mem_cons_of_mem _ hq)))

/-- **Bounded revision does not leave the branch rung.** `Plan.revising` is
`Nat.rec` over `graft` and `caseB`, so this is those two bounds iterated. -/
theorem level_revising_le {c : Code} {check : Cont Γ (El c) Verdict}
    {revise : Cont Γ (El c × Verdict) (El c)} (hb : Level.branch ≤ ℓ)
    (hc : ∀ (Θ : Ctx) (τ : Sub Γ Θ) (a : Expr Θ (El c)), level (check Θ τ a) ≤ ℓ)
    (hr : ∀ (Θ : Ctx) (τ : Sub Γ Θ) (a : Expr Θ (El c × Verdict)), level (revise Θ τ a) ≤ ℓ) :
    ∀ (n : Nat) (Θ : Ctx) (τ : Sub Γ Θ) (a : Expr Θ (El c)),
      level (Plan.revising check revise n Θ τ a) ≤ ℓ := by
  intro n
  induction n with
  | zero =>
    intro Θ τ a
    refine le_trans (level_graft_le (ℓ₀ := ℓ) _ _ fun _ _ _ => ?_) (max_le (hc Θ τ a) le_rfl)
    exact le_trans (le_of_eq (level_ret _)) bot_le
  | succ n ih =>
    intro Θ τ a
    refine le_trans (level_graft_le (ℓ₀ := ℓ) _ _ fun Ξ ρ v => ?_) (max_le (hc Θ τ a) le_rfl)
    refine level_caseB_le _ _ _ hb (le_trans (le_of_eq (level_ret _)) bot_le) ?_
    refine le_trans (level_graft_le (ℓ₀ := ℓ) _ _ fun _ _ _ => ih _ _ _)
      (max_le (hr Ξ _ _) le_rfl)

/-- **Nor does the three-way bounded revision.** `Plan.revisingOn` is the same
`Nat.rec` over `graft` with a three-armed `caseV` in place of the `caseB`, so
this is those bounds iterated one arm wider. -/
theorem level_revisingOn_le {c : Code} {check : Cont Γ (El c) Verdict}
    {revise : Cont Γ (El c × Verdict) (El c)} (hb : Level.branch ≤ ℓ)
    (hc : ∀ (Θ : Ctx) (τ : Sub Γ Θ) (a : Expr Θ (El c)), level (check Θ τ a) ≤ ℓ)
    (hr : ∀ (Θ : Ctx) (τ : Sub Γ Θ) (a : Expr Θ (El c × Verdict)), level (revise Θ τ a) ≤ ℓ) :
    ∀ (n : Nat) (Θ : Ctx) (τ : Sub Γ Θ) (a : Expr Θ (El c)),
      level (Plan.revisingOn check revise n Θ τ a) ≤ ℓ := by
  intro n
  induction n with
  | zero =>
    intro Θ τ a
    refine le_trans (level_graft_le (ℓ₀ := ℓ) _ _ fun _ _ _ => ?_) (max_le (hc Θ τ a) le_rfl)
    exact le_trans (le_of_eq (level_ret _)) bot_le
  | succ n ih =>
    intro Θ τ a
    refine le_trans (level_graft_le (ℓ₀ := ℓ) _ _ fun Ξ ρ v => ?_) (max_le (hc Θ τ a) le_rfl)
    refine level_caseV_le _ _ hb fun t => ?_
    cases t
    · exact le_trans (le_of_eq (level_ret _)) bot_le
    · refine le_trans (level_graft_le (ℓ₀ := ℓ) _ _ fun _ _ _ => ih _ _ _)
        (max_le (hr Ξ _ _) le_rfl)
    · exact le_trans (le_of_eq (level_ret _)) bot_le

end Agentic.Core

namespace Agentic.Core.Dsl

open Agentic.Core

/-! ## Every program of the language sits at or below the branch rung -/

/-- One explicit-intent ask former adds at most the pipeline rung. -/
theorem askForm_level_le {A : Type} {Γ : Ctx} {ℓ : Level}
    (hp : Level.pipeline ≤ ℓ) (c : Code) (intent : Intent c)
    (S : Bindings Γ) (a : RawAsk)
    (form : Plan (c :: Γ) A → Plan Γ A) (h : askForm c intent S a = .ok form)
    (k : Plan (c :: Γ) A) (hk : level k ≤ ℓ) : level (form k) ≤ ℓ := by
  unfold askForm at h
  split at h
  · exact absurd h (by simp)
  · split at h
    · cases h
      exact le_trans (le_of_eq (level_askC ..)) hk
    · split at h
      · exact absurd h (by simp)
      · cases h
        exact le_trans (le_of_eq (level_ask ..)) (max_le hp hk)

/-- One value-position request, at whatever kind was imposed, is at `pipeline`
at worst. -/
theorem askPlan_level_le {Γ : Ctx} (c : Code) (S : Bindings Γ) (a : RawAsk)
    (p : Plan Γ (El c)) (h : askPlan c S a = .ok p) : level p ≤ Level.pipeline := by
  unfold askPlan at h
  split at h
  · exact absurd h (by simp)
  · rename_i form hform
    cases h
    exact askForm_level_le le_rfl c (valueIntent c a.target) S a form hform _
      (le_trans (le_of_eq (level_ret _)) bot_le)

/-- Panel members, one at a time: each is a question, so each is at `pipeline`
at worst. -/
theorem checkMembers_level_le {Γ : Ctx} (S : Bindings Γ) :
    ∀ (l : List RawAsk) (ps : List (Plan Γ (El .verdict))),
      checkMembers S l = .ok ps → ∀ p ∈ ps, level p ≤ Level.pipeline := by
  intro l
  induction l with
  | nil => intro ps hps p hp; cases hps; exact absurd hp (by simp)
  | cons a as ih =>
    intro ps hps p hp
    simp only [checkMembers] at hps
    split at hps
    · exact absurd hps (by simp)
    · rename_i q hq
      split at hps
      · exact absurd hps (by simp)
      · rename_i qs hqs
        cases hps
        rcases List.mem_cons.mp hp with rfl | hp'
        · exact askPlan_level_le _ S a p hq
        · exact ih qs hqs p hp'

/-- Text-panel members, one at a time: each is a question, so each is at
`pipeline` at worst. -/
theorem checkMembersText_level_le {Γ : Ctx} (S : Bindings Γ) :
    ∀ (l : List TextMember) (seen : List String)
      (ps : List (String × Plan Γ (El .text))),
      checkMembersText S seen l = .ok ps → ∀ p ∈ ps, level p.2 ≤ Level.pipeline := by
  intro l
  induction l with
  | nil => intro seen ps hps p hp; cases hps; exact absurd hp (by simp)
  | cons m as ih =>
    intro seen ps hps p hp
    simp only [checkMembersText] at hps
    split at hps
    · exact absurd hps (by simp)
    · split at hps
      · exact absurd hps (by simp)
      · split at hps
        · exact absurd hps (by simp)
        · rename_i q hq
          split at hps
          · exact absurd hps (by simp)
          · rename_i qs hqs
            cases hps
            rcases List.mem_cons.mp hp with rfl | hp'
            · exact askPlan_level_le _ S m.ask q hq
            · exact ih _ qs hqs p hp'

/-- The invariant of the function table: every entry's plan is at or below the
pipeline rung — a body is a sequence of questions, and a call's rung is the
function's by `level_sub`. -/
def FnLevel (fns : Fns) : Prop :=
  ∀ fe ∈ fns, level fe.plan ≤ Level.pipeline

/-- A call is `Plan.sub` of a table entry, so its rung is the entry's. -/
theorem callPlan_level_le {Δ : Ctx} (S : Bindings Δ) {fns : Fns}
    (hf : FnLevel fns) (f : String) (args : List RawArg) (pos : Pos)
    {c : Code} {p : Plan Δ (El c)}
    (h : callPlan S fns f args pos = .ok ⟨c, p⟩) : level p ≤ Level.pipeline := by
  unfold callPlan at h
  split at h
  · exact absurd h (by simp)
  · rename_i fe hfe
    split at h
    · exact absurd h (by simp)
    · rename_i σ hσ
      cases h
      exact le_trans (le_of_eq (level_sub _ _)) (hf fe (List.mem_of_find?_eq_some hfe))

/-- A clause-position source likewise: a panel of `pipeline` members is
`pipeline`, and a call is its function's plan, so nothing in the language's
expression layer reaches the branch rung at all — the branching does that, and
only the branching. -/
theorem rhsPlan_level_le {Γ : Ctx} {fns : Fns} (hf : FnLevel fns)
    (c : Code) (S : Bindings Γ) (r : RawRhs) (what : String)
    (p : Plan Γ (El c)) (h : rhsPlan fns c S r what = .ok p) :
    level p ≤ Level.pipeline := by
  cases r with
  | ask a =>
    simp only [rhsPlan] at h
    exact askPlan_level_le c S a p h
  | panel ms pos =>
    simp only [rhsPlan] at h
    split at h
    · exact absurd h (by simp)
    · split at h
      · rename_i hc
        split at h
        · exact absurd h (by simp)
        · rename_i ps hps
          cases h
          exact level_panel_le' _ (checkMembers_level_le S ms ps hps)
      · exact absurd h (by simp)
  | panelText ms pos =>
    simp only [rhsPlan] at h
    split at h
    · exact absurd h (by simp)
    · split at h
      · rename_i hc
        split at h
        · exact absurd h (by simp)
        · rename_i ps hps
          cases h
          exact level_panelText_le' _ (checkMembersText_level_le S ms [] ps hps)
      · exact absurd h (by simp)
  | decide d x ws pos =>
    -- A decider is a `.ret`: it reaches no rung at all.
    simp only [rhsPlan] at h
    split at h
    · exact absurd h (by simp)
    · split at h
      · exact absurd h (by simp)
      · split at h
        · split at h
          · exact absurd h (by simp)
          · split at h
            · rename_i e he
              cases h
              exact le_trans (le_of_eq (level_ret _)) bot_le
            · exact absurd h (by simp)
        · exact absurd h (by simp)
  | call f args pos =>
    simp only [rhsPlan] at h
    split at h
    · exact absurd h (by simp)
    · rename_i rc q hq
      split at h
      · rename_i hrc
        cases h
        subst hrc
        exact callPlan_level_le S hf f args pos hq
      · exact absurd h (by simp)

/-- A binding's former does not move the rung of what it is given, at any rung
from `pipeline` up: an `ask` node adds `pipeline`, and a panel's or a call's
graft adds the source's own rung. Stated at an arbitrary bound so bodies can
use it at `pipeline` and blocks at `branch`. -/
theorem bindForm_level_le {A : Type} {Γ : Ctx} {fns : Fns} (hf : FnLevel fns)
    {ℓ : Level} (hp : Level.pipeline ≤ ℓ)
    (c : Code) (S : Bindings Γ) (r : RawRhs)
    (form : Plan (c :: Γ) A → Plan Γ A) (h : bindForm fns c S r = .ok form)
    (k : Plan (c :: Γ) A) (hk : level k ≤ ℓ) :
    level (form k) ≤ ℓ := by
  cases r with
  | ask a =>
    simp only [bindForm] at h
    exact askForm_level_le hp c (valueIntent c a.target) S a form h k hk
  | panel ms pos =>
    simp only [bindForm] at h
    split at h
    · exact absurd h (by simp)
    · rename_i v hv
      cases h
      refine le_trans (level_graft_le (ℓ₀ := ℓ) _ _ fun _ σ e => ?_)
        (max_le (le_trans (rhsPlan_level_le hf c S (.panel ms pos) _ v hv) hp) le_rfl)
      exact le_trans (le_of_eq (level_sub _ _)) hk
  | panelText ms pos =>
    simp only [bindForm] at h
    split at h
    · exact absurd h (by simp)
    · rename_i v hv
      cases h
      refine le_trans (level_graft_le (ℓ₀ := ℓ) _ _ fun _ σ e => ?_)
        (max_le (le_trans (rhsPlan_level_le hf c S (.panelText ms pos) _ v hv) hp) le_rfl)
      exact le_trans (le_of_eq (level_sub _ _)) hk
  | decide d x ws pos =>
    simp only [bindForm] at h
    split at h
    · exact absurd h (by simp)
    · rename_i v hv
      cases h
      refine le_trans (level_graft_le (ℓ₀ := ℓ) _ _ fun _ σ e => ?_)
        (max_le (le_trans (rhsPlan_level_le hf c S (.decide d x ws pos) _ v hv) hp) le_rfl)
      exact le_trans (le_of_eq (level_sub _ _)) hk
  | call f args pos =>
    simp only [bindForm] at h
    split at h
    · exact absurd h (by simp)
    · rename_i v hv
      cases h
      refine le_trans (level_graft_le (ℓ₀ := ℓ) _ _ fun _ σ e => ?_)
        (max_le (le_trans (rhsPlan_level_le hf c S (.call f args pos) _ v hv) hp) le_rfl)
      exact le_trans (le_of_eq (level_sub _ _)) hk
/-- The exit continuation of a bounded revision is at the branch rung together
with its arms — at **either** tag, which is what lets `revising`'s two-armed
exit and `revising on`'s three-armed one share one lemma as they share one
definition. -/
theorem level_exitCont_le {A : Type} {Γ Δ : Ctx} {c : Code} {ℓ : Level} (t : Tag)
    (arms : t.El → Plan (c :: Γ) A) (hb : Level.branch ≤ ℓ)
    (ha : ∀ x, level (arms x) ≤ ℓ) (σ : Sub Γ Δ) (final : Expr Δ (El c × t.El)) :
    level (exitCont t arms Δ σ final) ≤ ℓ := by
  show level (Plan.case t _ _) ≤ ℓ
  rw [level_case]
  exact max_le hb (Finset.sup_le fun x _ => le_trans (le_of_eq (level_sub _ _)) (ha x))

/-- The prologue a bounded revision's two forms share leaves both clauses at the
pipeline rung: each is a `rhsPlan`, and nothing in the language's expression
layer reaches the branch rung. -/
theorem checkLoopParts_level {fns : Fns} (hf : FnLevel fns) {Γ : Ctx} {S : Bindings Γ}
    {x : String} {ann : Option Code} {subj carrier : String} {n : Nat}
    {rname : String} {rann : Option Code} {review amend : RawRhs} {rpos pos : Pos}
    {lp : LoopParts Γ}
    (h : checkLoopParts fns S x ann subj carrier n rname rann review amend rpos pos = .ok lp) :
    level lp.review ≤ Level.pipeline ∧ level lp.amend ≤ Level.pipeline := by
  simp only [checkLoopParts] at h
  split at h
  · exact absurd h (by simp)
  · split at h
    · exact absurd h (by simp)
    · split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · split at h
          · exact absurd h (by simp)
          · split at h
            · exact absurd h (by simp)
            · split at h
              · exact absurd h (by simp)
              · rename_i b hb
                split at h
                · exact absurd h (by simp)
                · rename_i reviewP hreview
                  split at h
                  · exact absurd h (by simp)
                  · rename_i amendP hamend
                    cases h
                    exact ⟨rhsPlan_level_le hf _ _ review _ reviewP hreview,
                           rhsPlan_level_le hf _ _ amend _ amendP hamend⟩

/-- The invariant the pending loop result carries through the induction: its
plan is at or below the branch rung, which is what the consuming `case`'s
graft needs. -/
def PendLevel {Γ : Ctx} : Option (Pend Γ) → Prop
  | none => True
  | some pd => level pd.plan ≤ Level.branch

/-- **The flagship claim.** Every block the checker accepts is at or below the
branch rung — no clause emits `Plan.dyn`, and the language has no syntax that
could.

Not decoration: `Cost.costM` takes this bound as an argument, so a cost
report over a source file is not writable without it. -/
theorem checkBlockResult_level_le {result : Code} {fns : Fns} (hf : FnLevel fns) :
    ∀ (b : RawBlock) (Γ : Ctx) (S : Bindings Γ) (pend : Option (Pend Γ)),
      PendLevel pend → ∀ (p : Plan Γ (El result)),
        checkBlockResult result fns Γ S pend b = .ok p → level p ≤ Level.branch := by
  intro b
  induction b with
  | empty pos =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      revert p
      cases result <;> intro p h <;> simp only [checkBlockResult] at h
      case ack =>
        cases h
        exact bot_le
      all_goals cases h
    | some pd => simp only [checkBlockResult] at h; exact absurd h (by simp)
  | answer x pos =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      simp only [checkBlockResult] at h
      split at h
      · cases h
      · rename_i b hb
        split at h
        · rename_i e he
          cases h
          exact bot_le
        · cases h
    | some pd => simp only [checkBlockResult] at h; exact absurd h (by simp)
  | knownHere names rest pos ih =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      simp only [checkBlockResult] at h
      split at h
      · exact ih _ _ none trivial p h
      · exact absurd h (by simp)
    | some pd => simp only [checkBlockResult] at h; exact absurd h (by simp)
  | act a rest pos ih =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      simp only [checkBlockResult] at h
      split at h
      · exact absurd h (by simp)
      · rename_i form hform
        split at h
        · exact absurd h (by simp)
        · rename_i k hk
          cases h
          exact askForm_level_le (by decide) Code.ack .effect S a form hform _
            (le_trans (le_of_eq (level_sub _ _)) (ih _ _ none trivial k hk))
    | some pd => simp only [checkBlockResult] at h; exact absurd h (by simp)
  | callStmt f args rest pos ih =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      simp only [checkBlockResult] at h
      split at h
      · exact absurd h (by simp)
      · rename_i rc q hq
        split at h
        · split at h
          · exact absurd h (by simp)
          · rename_i k hk
            cases h
            refine le_trans (level_graft_le (ℓ₀ := Level.branch) _ _ fun _ σ _ => ?_)
              (max_le (le_trans (callPlan_level_le S hf f args pos hq) (by decide)) le_rfl)
            exact le_trans (le_of_eq (level_sub _ _)) (ih _ _ none trivial k hk)
        · exact absurd h (by simp)
    | some pd => simp only [checkBlockResult] at h; exact absurd h (by simp)
  | bind x ann src rest pos ih =>
    intro Γ S pend hpend p h
    cases pend with
    | some pd =>
      cases src with
      | rhs r =>
        simp only [checkBlockResult] at h
        exact absurd h (by simp)
      | revising subj carrier n rname rann review amend rpos =>
        simp only [checkBlockResult] at h
        exact absurd h (by simp)
      | revisingOn subj carrier n rname rann review amend rpos =>
        simp only [checkBlockResult] at h
        exact absurd h (by simp)
    | none =>
      cases src with
      | rhs r =>
        simp only [checkBlockResult] at h
        split at h
        · exact absurd h (by simp)
        · split at h
          · exact absurd h (by simp)
          · rename_i c hc
            split at h
            · exact absurd h (by simp)
            · rename_i form hform
              split at h
              · exact absurd h (by simp)
              · rename_i k hk
                cases h
                exact bindForm_level_le hf (by decide) c S r form hform k
                  (ih _ _ none trivial k hk)
      | revising subj carrier n rname rann review amend rpos =>
        simp only [checkBlockResult] at h
        split at h
        · exact absurd h (by simp)
        · rename_i lp hlp
          obtain ⟨hrev, ham⟩ := checkLoopParts_level hf hlp
          refine ih _ _ _ ?_ p h
          show level _ ≤ Level.branch
          refine level_revising_le le_rfl (fun _ _ _ => ?_) (fun _ _ _ => ?_) n _ _ _
          · exact le_trans (le_of_eq (level_sub _ _)) (le_trans hrev (by decide))
          · exact le_trans (le_of_eq (level_sub _ _)) (le_trans ham (by decide))
      | revisingOn subj carrier n rname rann review amend rpos =>
        simp only [checkBlockResult] at h
        split at h
        · exact absurd h (by simp)
        · rename_i lp hlp
          obtain ⟨hrev, ham⟩ := checkLoopParts_level hf hlp
          refine ih _ _ _ ?_ p h
          show level _ ≤ Level.branch
          refine level_revisingOn_le le_rfl (fun _ _ _ => ?_) (fun _ _ _ => ?_) n _ _ _
          · exact le_trans (le_of_eq (level_sub _ _)) (le_trans hrev (by decide))
          · exact le_trans (le_of_eq (level_sub _ _)) (le_trans ham (by decide))
  | ifFlag x y n pos ihy ihn =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      simp only [checkBlockResult] at h
      split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · split at h
          · exact absurd h (by simp)
          · rename_i y' hy'
            split at h
            · exact absurd h (by simp)
            · rename_i n' hn'
              cases h
              exact level_caseB_le _ _ _ le_rfl (ihy _ _ none trivial y' hy')
                (ihn _ _ none trivial n' hn')
    | some pd => simp only [checkBlockResult] at h; exact absurd h (by simp)
  | caseVerdict x a o d pos iha iho ihd =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      simp only [checkBlockResult] at h
      split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · split at h
          · exact absurd h (by simp)
          · rename_i a' ha'
            split at h
            · exact absurd h (by simp)
            · rename_i o' ho'
              split at h
              · exact absurd h (by simp)
              · rename_i d' hd'
                cases h
                refine level_caseV_le _ _ le_rfl fun t => ?_
                cases t
                · exact iha _ _ none trivial a' ha'
                · exact iho _ _ none trivial o' ho'
                · exact ihd _ _ none trivial d' hd'
    | some pd => simp only [checkBlockResult] at h; exact absurd h (by simp)
  | caseResult x sname uname settled unsettled pos ihs ihu =>
    intro Γ S pend hpend p h
    cases pend with
    | none => simp only [checkBlockResult] at h; exact absurd h (by simp)
    | some pd =>
      simp only [checkBlockResult] at h
      split at h
      · exact absurd h (by simp)
      · split at h
        · rename_i pc pplan
          split at h
          · exact absurd h (by simp)
          · split at h
            · exact absurd h (by simp)
            · split at h
              · exact absurd h (by simp)
              · rename_i settledP hsettled
                split at h
                · exact absurd h (by simp)
                · rename_i unsettledP hunsettled
                  cases h
                  refine le_trans (level_graft_le (ℓ₀ := Level.branch) _ _ fun _ σ e => ?_)
                    (max_le hpend le_rfl)
                  refine level_exitCont_le _ _ le_rfl (fun b => ?_) _ _
                  cases b
                  · exact ihu _ _ none trivial unsettledP hunsettled
                  · exact ihs _ _ none trivial settledP hsettled
        · exact absurd h (by simp)
  | caseEnding x sname uname aname settled unsettled abandoned pos ihs ihu iha =>
    intro Γ S pend hpend p h
    cases pend with
    | none => simp only [checkBlockResult] at h; exact absurd h (by simp)
    | some pd =>
      simp only [checkBlockResult] at h
      split at h
      · exact absurd h (by simp)
      · split at h
        · rename_i pc pplan
          split at h
          · exact absurd h (by simp)
          · split at h
            · exact absurd h (by simp)
            · split at h
              · exact absurd h (by simp)
              · split at h
                · exact absurd h (by simp)
                · rename_i settledP hsettled
                  split at h
                  · exact absurd h (by simp)
                  · rename_i unsettledP hunsettled
                    split at h
                    · exact absurd h (by simp)
                    · rename_i abandonedP habandoned
                      cases h
                      refine le_trans (level_graft_le (ℓ₀ := Level.branch) _ _ fun _ σ e => ?_)
                        (max_le hpend le_rfl)
                      refine level_exitCont_le _ _ le_rfl (fun t => ?_) _ _
                      cases t
                      · exact ihs _ _ none trivial settledP hsettled
                      · exact ihu _ _ none trivial unsettledP hunsettled
                      · exact iha _ _ none trivial abandonedP habandoned
        · exact absurd h (by simp)

/-- The legacy receipt-valued block theorem, at the public type every existing
caller uses. -/
theorem checkBlock_level_le {fns : Fns} (hf : FnLevel fns)
    (b : RawBlock) (Γ : Ctx) (S : Bindings Γ) (pend : Option (Pend Γ))
    (hpend : PendLevel pend) (p : Plan Γ Unit)
    (h : checkBlock fns Γ S pend b = .ok p) : level p ≤ Level.branch :=
  checkBlockResult_level_le (result := Code.ack) hf b Γ S pend hpend p h

/-! ## Function bodies stay at the pipeline rung

A body is a sequence of questions — asks, panels, calls — and a result, so its
plan never reaches `branch`: the loop and the branchings are unwritable in one,
by type and by refusal respectively. -/

theorem checkBody_level_le {k : Code} {fns : Fns} (hf : FnLevel fns)
    (answer : Option String) (result : Code) :
    ∀ (stmts : List RawBodyStmt) (Γ : Ctx) (S : Bindings Γ)
      (fin : (Δ : Ctx) → Bindings Δ → Except CheckError (Plan Δ (El k)))
      (_ : ∀ (Δ : Ctx) (SΔ : Bindings Δ) (q : Plan Δ (El k)),
        fin Δ SΔ = .ok q → level q ≤ Level.pipeline)
      (p : Plan Γ (El k)),
      checkBody fns answer result Γ S stmts fin = .ok p →
      level p ≤ Level.pipeline := by
  intro stmts
  induction stmts with
  | nil =>
    intro Γ S fin hfin p h
    simp only [checkBody] at h
    exact hfin Γ S p h
  | cons st rest ih =>
    intro Γ S fin hfin p h
    cases st with
    | bind x ann rhs pos =>
      simp only [checkBody] at h
      split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · rename_i c hc
          split at h
          · exact absurd h (by simp)
          · rename_i form hform
            split at h
            · exact absurd h (by simp)
            · rename_i k' hk'
              cases h
              exact bindForm_level_le hf le_rfl c S rhs form hform k'
                (ih _ _ fin hfin k' hk')
    | act a pos =>
      simp only [checkBody] at h
      split at h
      · exact absurd h (by simp)
      · rename_i form hform
        split at h
        · exact absurd h (by simp)
        · rename_i k' hk'
          cases h
          exact askForm_level_le le_rfl Code.ack .effect S a form hform _
            (le_trans (le_of_eq (level_sub _ _)) (ih _ _ fin hfin k' hk'))
    | callS f args pos =>
      simp only [checkBody] at h
      split at h
      · exact absurd h (by simp)
      · rename_i rc q hq
        split at h
        · split at h
          · exact absurd h (by simp)
          · rename_i k' hk'
            cases h
            refine le_trans (level_graft_le (ℓ₀ := Level.pipeline) _ _ fun _ σ _ => ?_)
              (max_le (callPlan_level_le S hf f args pos hq) le_rfl)
            exact le_trans (le_of_eq (level_sub _ _)) (ih _ _ fin hfin k' hk')
        · exact absurd h (by simp)

/-- One checked function's plan is at or below `pipeline`. -/
theorem checkFn_level_le {fns : Fns} (hf : FnLevel fns) (f : RawFn) (fe : FnEntry)
    (h : checkFn fns f = .ok fe) : level fe.plan ≤ Level.pipeline := by
  simp only [checkFn] at h
  split at h
  · rename_i x hx
    split at h
    · exact absurd h (by simp)
    · rename_i p hp
      cases h
      refine checkBody_level_le hf _ _ _ _ _ _ ?_ p hp
      intro Δ SΔ q hq
      simp only at hq
      split at hq
      · exact absurd hq (by simp)
      · split at hq
        · rename_i e he
          cases hq
          exact le_trans (le_of_eq (level_ret _)) bot_le
        · exact absurd hq (by simp)
  · split at h
    · rename_i hres
      split at h
      · exact absurd h (by simp)
      · rename_i p hp
        cases h
        refine checkBody_level_le hf _ _ _ _ _ _ ?_ p hp
        intro Δ SΔ q hq
        simp only at hq
        cases hq
        exact le_trans (le_of_eq (level_ret _)) bot_le
    · exact absurd h (by simp)

/-- The whole table stays at `pipeline`, entry by entry. -/
theorem checkFnsList_fnLevel :
    ∀ (l : List RawFn) (acc : Fns), FnLevel acc → ∀ (fns : Fns),
      checkFnsList acc l = .ok fns → FnLevel fns := by
  intro l
  induction l with
  | nil =>
    intro acc hacc fns h
    simp only [checkFnsList] at h
    cases h
    exact hacc
  | cons f rest ih =>
    intro acc hacc fns h
    simp only [checkFnsList] at h
    split at h
    · exact absurd h (by simp)
    · split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · rename_i fe hfe
          refine ih _ ?_ fns h
          intro g hg
          rcases List.mem_append.mp hg with hg | hg
          · exact hacc g hg
          · rcases List.mem_singleton.mp hg with rfl
            exact checkFn_level_le hacc f fe hfe

/-- **The result-valued program claim.** Everything `checkProgramResult` accepts
is at or below the branch rung: the table is at `pipeline`, the result terminal
is a pure `ret`, and the spliced block is bounded by
`checkBlockResult_level_le` over it. -/
theorem checkProgramResult_level_le (result : Code) (prog : RawProgram)
    (p : Plan [] (El result)) (h : checkProgramResult result prog = .ok p) :
    level p ≤ Level.branch := by
  simp only [checkProgramResult] at h
  split at h
  · exact absurd h (by simp)
  · rename_i fns hfns
    split at h
    · exact absurd h (by simp)
    · split at h
      · exact absurd h (by simp)
      · exact checkBlockResult_level_le (result := result)
          (checkFnsList_fnLevel prog.fns [] (fun _ hg => absurd hg (by simp)) fns hfns)
          _ [] [] none trivial p h

/-- The frozen receipt-valued specialization, retained at its original type. -/
theorem checkProgram_level_le (prog : RawProgram) (p : Plan [] Unit)
    (h : checkProgram prog = .ok p) : level p ≤ Level.branch :=
  checkProgramResult_level_le Code.ack prog p h

/-! ## The guards of the front end, as theorems

The battery reaches each of these at fixtures; the statements below hold them
for every program. They complement the battery's string pins rather than
replace them: a mutation that swaps two diagnoses or moves a position survives
any ∀-statement that does not spell the strings, and spelling the strings is
what the pins already do. What a theorem adds is the ∀ — no fixture, and no
future surface change, can make one of these guards silently dead. -/

/-- What the pre-scan reports really is over the bound: `overRevised` never
invents a hostile numeral. -/
theorem overRevised_sound :
    ∀ (r : Raw) {pos : Pos} {n : Nat},
      overRevised r = some (pos, n) → maxRevisions < n := by
  intro r
  induction r with
  | empty p =>
    intro pos n h
    simp [overRevised] at h
  | answer x p =>
    intro pos n h
    simp [overRevised] at h
  | knownHere names rest p ih =>
    intro pos n h
    simp only [overRevised] at h
    exact ih h
  | act a rest p ih =>
    intro pos n h
    simp only [overRevised] at h
    exact ih h
  | callStmt f args rest p ih =>
    intro pos n h
    simp only [overRevised] at h
    exact ih h
  | bind x ann src rest p ih =>
    intro pos n h
    cases src with
    | rhs r' =>
      simp only [overRevised] at h
      exact ih h
    | revising subj carrier m rname rann review amend rpos =>
      simp only [overRevised] at h
      split at h
      · rename_i hlt
        simp only [Option.some.injEq, Prod.mk.injEq] at h
        exact h.2 ▸ hlt
      · exact ih h
    | revisingOn subj carrier m rname rann review amend rpos =>
      simp only [overRevised] at h
      split at h
      · rename_i hlt
        simp only [Option.some.injEq, Prod.mk.injEq] at h
        exact h.2 ▸ hlt
      · exact ih h
  | ifFlag x yb nb p ihy ihn =>
    intro pos n h
    simp only [overRevised] at h
    cases hy : overRevised yb with
    | some v =>
      rw [hy] at h
      simp only [Option.orElse, Option.some.injEq] at h
      exact ihy (h ▸ hy)
    | none =>
      rw [hy] at h
      simp only [Option.orElse] at h
      exact ihn h
  | caseVerdict x ab ob db p iha iho ihd =>
    intro pos n h
    simp only [overRevised] at h
    cases ha : overRevised ab with
    | some v =>
      rw [ha] at h
      simp only [Option.orElse, Option.some.injEq] at h
      exact iha (h ▸ ha)
    | none =>
      rw [ha] at h
      simp only [Option.orElse] at h
      cases ho : overRevised ob with
      | some v =>
        rw [ho] at h
        simp only [Option.some.injEq] at h
        exact iho (h ▸ ho)
      | none =>
        rw [ho] at h
        exact ihd h
  | caseResult x sname uname sb ub p ihs ihu =>
    intro pos n h
    simp only [overRevised] at h
    cases hs : overRevised sb with
    | some v =>
      rw [hs] at h
      simp only [Option.orElse, Option.some.injEq] at h
      exact ihs (h ▸ hs)
    | none =>
      rw [hs] at h
      simp only [Option.orElse] at h
      exact ihu h
  | caseEnding x sname uname aname sb ub ab p ihs ihu iha =>
    intro pos n h
    simp only [overRevised] at h
    cases hs : overRevised sb with
    | some v =>
      rw [hs] at h
      simp only [Option.orElse, Option.some.injEq] at h
      exact ihs (h ▸ hs)
    | none =>
      rw [hs] at h
      simp only [Option.orElse] at h
      cases hu : overRevised ub with
      | some v =>
        rw [hu] at h
        simp only [Option.some.injEq] at h
        exact ihu (h ▸ hu)
      | none =>
        rw [hu] at h
        exact iha h

/-- A hostile revising bound is refused at its own line, with exactly this
diagnosis — for every program whose table checks, not just the battery's. -/
theorem checkProgram_overRevised {prog : RawProgram} {fns : Fns} {rpos : Pos} {n : Nat}
    (hf : checkFnsList [] prog.fns = .ok fns)
    (h : overRevised prog.main = some (rpos, n)) :
    checkProgram prog
      = .error ⟨rpos, s!"a bounded revision is unrolled into the term it writes, \
                        so its bound may name at most {maxRevisions} amendments",
                s!"at most {n} amendments"⟩ := by
  simp only [checkProgram, checkProgramResult, hf, h]
  rfl

/-- An elaboration over the question budget is refused with the actual count —
likewise for every program. -/
theorem checkProgram_oversized {prog : RawProgram} {fns : Fns}
    (hf : checkFnsList [] prog.fns = .ok fns)
    (hr : overRevised prog.main = none)
    (h : maxQuestions < blockAsks fns prog.main) :
    checkProgram prog
      = .error ⟨⟨0, 0⟩, s!"this program elaborates to \
                          {blockAsks fns prog.main} questions, and the bound \
                          is {maxQuestions}", ""⟩ := by
  simp only [checkProgram, checkProgramResult, hf, hr]
  rw [if_pos h]
  rfl

/-- …and within both bounds, the program front end **is** the block checker:
the guards decide, they never distort. -/
theorem checkProgram_of_within {prog : RawProgram} {fns : Fns}
    (hf : checkFnsList [] prog.fns = .ok fns)
    (hr : overRevised prog.main = none)
    (h : ¬ maxQuestions < blockAsks fns prog.main) :
    checkProgram prog = checkBlock fns [] [] none prog.main := by
  simp only [checkProgram, checkProgramResult, hf, hr]
  rw [if_neg h]
  rfl

/-- **A checked `case` lands each verdict on its own arm.** The term is
`Plan.caseV` of exactly the three checked blocks, approve to the `approved`
text, object to `objected`, declined to `no answer` — so the `VTag` mapping is
constrained by theorem, and a permutation no longer type-checks silently. -/
theorem checkBlock_caseVerdict_arms {fns : Fns} {Γ : Ctx} {S : Bindings Γ}
    {x : String} {a o d : RawBlock} {pos : Pos} {p : Plan Γ Unit}
    (h : checkBlock fns Γ S none (.caseVerdict x a o d pos) = .ok p) :
    ∃ (e : Expr Γ Verdict) (a' o' d' : Plan Γ Unit),
      checkBlock fns Γ S none a = .ok a' ∧
      checkBlock fns Γ S none o = .ok o' ∧
      checkBlock fns Γ S none d = .ok d' ∧
      p = Plan.caseV e (fun t => match t with
            | .approve => a' | .object => o' | .declined => d') := by
  simp only [checkBlock, checkBlockResult] at h
  split at h
  · exact absurd h (by simp)
  · split at h
    · exact absurd h (by simp)
    · rename_i e _
      split at h
      · exact absurd h (by simp)
      · rename_i a' ha'
        split at h
        · exact absurd h (by simp)
        · rename_i o' ho'
          split at h
          · exact absurd h (by simp)
          · rename_i d' hd'
            cases h
            exact ⟨e, a', o', d', ha', ho', hd', rfl⟩

/-- **A checked three-way exit lands each ending on its own arm.** The term is
`Plan.graft` of the loop onto `exitCont .ending` of exactly the three checked
blocks — settled to the `settled` text, unsettled to `unsettled`, abandoned to
`abandoned` — so the `Ending` mapping is constrained by theorem and a permuted
arm list no longer type-checks silently. `checkBlock_caseVerdict_arms`'s sibling,
for the same reason. -/
theorem checkBlock_caseEnding_arms {fns : Fns} {Γ : Ctx} {S : Bindings Γ} {pd : Pend Γ}
    {x sname uname aname : String} {settled unsettled abandoned : RawBlock}
    {pos : Pos} {p : Plan Γ Unit}
    (h : checkBlock fns Γ S (some pd)
          (.caseEnding x sname uname aname settled unsettled abandoned pos) = .ok p) :
    ∃ (pplan : Plan Γ (El pd.code × Ending)) (s' u' a' : Plan (pd.code :: Γ) Unit),
      checkBlock fns (pd.code :: Γ) (Bindings.push sname pd.code S) none settled = .ok s' ∧
      checkBlock fns (pd.code :: Γ) (Bindings.push uname pd.code S) none unsettled = .ok u' ∧
      checkBlock fns (pd.code :: Γ) (Bindings.push aname pd.code S) none abandoned = .ok a' ∧
      p = Plan.graft pplan (exitCont .ending (fun e => match e with
            | .settled => s' | .unsettled => u' | .abandoned => a')) := by
  simp only [checkBlock, checkBlockResult] at h
  split at h
  · exact absurd h (by simp)
  · split at h
    · rename_i _ _ pplan _
      split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · split at h
          · exact absurd h (by simp)
          · split at h
            · exact absurd h (by simp)
            · rename_i s' hs'
              split at h
              · exact absurd h (by simp)
              · rename_i u' hu'
                split at h
                · exact absurd h (by simp)
                · rename_i a' ha'
                  cases h
                  exact ⟨pplan, s', u', a', hs', hu', ha', rfl⟩
    · exact absurd h (by simp)

/-- The source-written draw index survives shape elaboration: `served by`
relabels the server and touches nothing else. -/
theorem askShape_draw (c : Code) (intent : Intent c) (m : Option String)
    (t : RawTarget) :
    (askShape c intent m t).draw = t.draw := by
  cases m <;> rfl

end Agentic.Core.Dsl
