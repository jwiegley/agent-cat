import Agentic.Core.Dsl.Check

/-!
# The DSL, and what is provable about it

Stage 3, part four: the front end and the theorem the language exists to make
true.

## Where the flagship went

This module is the *cheap* half, and deliberately so. It proves things about the
**checker** — ordinary structural inductions over `checkBlock`, no kernel
reduction of any particular program — and it elaborates in a second or two.
Everything about the flagship program itself lives in
`Agentic/Core/DslFlagship.lean`, which imports this module and dominates the
build.

The division is not tidiness. `Cost.costTree` takes `level p ≤ Level.branch` as
an *argument*, so `parseAndCheck_level_le` below is the term that makes every
tool over source files compile: `Agentic/Core/Explain.lean`, and through it
`cli/AgentCat.lean` and `Agentic/Core/Mcp.lean`. Those three want the theorem
and have no use whatever for the flagship, so they import this file and not the
other one.

## What "well-typed by construction" is and is not

`Dsl.check` and `Dsl.parseAndCheck` state their own soundness *in their types*:
neither "the result type-checks" nor "the result is closed" is a theorem here —
both are readings of the signature. What is **not** free, and is proved below,
is the fact that makes the language worth having: `parseAndCheck_level_le` —
*every* program in the language sits at or below the branch rung, so every
program has a finite cost tree. The induction carries one extra invariant the
redesigned checker introduced: a pending loop result's plan is itself at or
below the branch rung (`PendLevel`), which is exactly what the consuming
`case`'s graft needs.
-/

namespace Agentic.Core

open Plan

/-! ## Equality of transcripts is decidable

What lets the flagship's agreement with `Agentic/Core/HardenPatch.lean` be a
`decide` in each of the named worlds, and what lets `Mcp.reportJson` decide
whether the transcript it heard is the one the replay reconstructs — so it
stays on the cheap side of the split. -/

/-- An `Event` as the dependent pair it is. -/
def Event.toSigma (e : Event) : (c : Code) × (Q c × El c) := ⟨e.c, e.q, e.a⟩

/-- …and back. -/
def Event.ofSigma (s : (c : Code) × (Q c × El c)) : Event := ⟨s.1, s.2.1, s.2.2⟩

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

end Agentic.Core

namespace Agentic.Core.Dsl

open Agentic.Core

/-! ## Every program of the language sits at or below the branch rung -/

/-- One question, at whatever kind was imposed, is at `pipeline` at worst:
`askC1` is `batch` and `ask1` is `pipeline`, and neither can be anything
else. -/
theorem askPlan_level_le {Γ : Ctx} (c : Code) (S : Bindings Γ) (a : RawAsk)
    (p : Plan Γ (El c)) (h : askPlan c S a = .ok p) : level p ≤ Level.pipeline := by
  unfold askPlan at h
  split at h
  · cases h; exact le_trans (le_of_eq (level_askC1 ..)) bot_le
  · split at h
    · exact absurd h (by simp)
    · cases h; exact le_of_eq (level_ask1 ..)

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

/-- A clause-position source likewise: a panel of `pipeline` members is
`pipeline`, so nothing in the language's expression layer reaches the branch
rung at all — the branching does that, and only the branching. -/
theorem rhsPlan_level_le {Γ : Ctx} (c : Code) (S : Bindings Γ) (r : RawRhs) (what : String)
    (p : Plan Γ (El c)) (h : rhsPlan c S r what = .ok p) : level p ≤ Level.pipeline := by
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

/-- A binding's former does not move the rung of what it is given: an `ask`
node adds `pipeline`, and a panel's graft adds the panel's own rung. -/
theorem bindForm_level_le {Γ : Ctx} (c : Code) (S : Bindings Γ) (r : RawRhs)
    (form : Plan (c :: Γ) Unit → Plan Γ Unit) (h : bindForm c S r = .ok form)
    (k : Plan (c :: Γ) Unit) (hk : level k ≤ Level.branch) :
    level (form k) ≤ Level.branch := by
  cases r with
  | ask a =>
    simp only [bindForm] at h
    split at h
    · cases h
      exact le_trans (le_of_eq (level_askC ..)) hk
    · split at h
      · exact absurd h (by simp)
      · cases h
        exact le_trans (le_of_eq (level_ask ..)) (max_le (by decide) hk)
  | panel ms pos =>
    simp only [bindForm] at h
    split at h
    · exact absurd h (by simp)
    · rename_i v hv
      cases h
      refine le_trans (level_graft_le (ℓ₀ := Level.branch) _ _ fun _ σ e => ?_)
        (max_le (le_trans (rhsPlan_level_le c S (.panel ms pos) _ v hv) (by decide)) le_rfl)
      exact le_trans (le_of_eq (level_sub _ _)) hk

/-- The invariant the pending loop result carries through the induction: its
plan is at or below the branch rung, which is what the consuming `case`'s
graft needs. -/
def PendLevel {Γ : Ctx} : Option (Pend Γ) → Prop
  | none => True
  | some pd => level pd.plan ≤ Level.branch

/-- **The flagship claim.** Every block the checker accepts is at or below the
branch rung — no clause emits `Plan.dyn`, and the language has no syntax that
could.

Not decoration: `Cost.costTree` takes this bound as an argument, so a cost
report over a source file is not writable without it. -/
theorem checkBlock_level_le :
    ∀ (b : RawBlock) (Γ : Ctx) (S : Bindings Γ) (pend : Option (Pend Γ)),
      PendLevel pend → ∀ (p : Plan Γ Unit),
        checkBlock Γ S pend b = .ok p → level p ≤ Level.branch := by
  intro b
  induction b with
  | empty pos =>
    intro Γ S pend hpend p h
    cases pend with
    | none => simp only [checkBlock] at h; cases h; exact bot_le
    | some pd => simp only [checkBlock] at h; exact absurd h (by simp)
  | knownHere names rest pos ih =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      simp only [checkBlock] at h
      split at h
      · exact ih _ _ none trivial p h
      · exact absurd h (by simp)
    | some pd => simp only [checkBlock] at h; exact absurd h (by simp)
  | act a rest pos ih =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      simp only [checkBlock] at h
      split at h
      · exact absurd h (by simp)
      · rename_i form hform
        split at h
        · exact absurd h (by simp)
        · rename_i k hk
          cases h
          exact bindForm_level_le _ S _ form hform _
            (le_trans (le_of_eq (level_sub _ _)) (ih _ _ none trivial k hk))
    | some pd => simp only [checkBlock] at h; exact absurd h (by simp)
  | bind x ann src rest pos ih =>
    intro Γ S pend hpend p h
    cases pend with
    | some pd =>
      cases src with
      | rhs r =>
        simp only [checkBlock] at h
        exact absurd h (by simp)
      | revising subj carrier n rname rann review amend rpos =>
        simp only [checkBlock] at h
        exact absurd h (by simp)
    | none =>
      cases src with
      | rhs r =>
        simp only [checkBlock] at h
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
                exact bindForm_level_le c S r form hform k (ih _ _ none trivial k hk)
      | revising subj carrier n rname rann review amend rpos =>
        simp only [checkBlock] at h
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
                          refine ih _ _ _ ?_ p h
                          show level _ ≤ Level.branch
                          refine level_revising_le le_rfl (fun _ _ _ => ?_) (fun _ _ _ => ?_)
                            n _ _ _
                          · exact le_trans (le_of_eq (level_sub _ _))
                              (le_trans (rhsPlan_level_le _ _ review _ reviewP hreview)
                                (by decide))
                          · exact le_trans (le_of_eq (level_sub _ _))
                              (le_trans (rhsPlan_level_le _ _ amend _ amendP hamend)
                                (by decide))
  | ifFlag x y n pos ihy ihn =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      simp only [checkBlock] at h
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
    | some pd => simp only [checkBlock] at h; exact absurd h (by simp)
  | caseVerdict x a o d pos iha iho ihd =>
    intro Γ S pend hpend p h
    cases pend with
    | none =>
      simp only [checkBlock] at h
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
    | some pd => simp only [checkBlock] at h; exact absurd h (by simp)
  | caseResult x sname settled unsettled pos ihs ihu =>
    intro Γ S pend hpend p h
    cases pend with
    | none => simp only [checkBlock] at h; exact absurd h (by simp)
    | some pd =>
      simp only [checkBlock] at h
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
              exact level_caseB_le _ _ _ le_rfl
                (le_trans (le_of_eq (level_sub _ _)) (ihs _ _ none trivial settledP hsettled))
                (le_trans (le_of_eq (level_sub _ _)) (ihu _ _ none trivial unsettledP hunsettled))

/-- …and hence of every source text the front end accepts. -/
theorem parseAndCheck_level_le (s : String) (p : Plan [] Unit) (h : parseAndCheck s = .ok p) :
    level p ≤ Level.branch := by
  rw [parseAndCheck_ok_iff] at h
  unfold parseAndCheckE at h
  split at h
  · exact absurd h (by simp)
  · exact checkBlock_level_le _ [] [] none trivial p h

end Agentic.Core.Dsl
