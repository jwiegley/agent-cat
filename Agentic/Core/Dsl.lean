import Agentic.Core.Dsl.Check

/-!
# The DSL, and what is provable about it

Stage 3, part four: the front end and the theorem the language exists to make
true.

## Where the flagship went

This module is the *cheap* half, and deliberately so. It proves things about the
**checker** — ordinary structural inductions over `checkBlock`, no kernel
reduction of any particular program — and it elaborates in a second or two.
Everything about the flagship program itself (`flagshipSource`, `flagshipRaw`,
`flagshipPlan`, and the nineteen `decide +kernel` proofs that price it) lives in
`Agentic/Core/DslFlagship.lean`, which imports this module and takes about five
minutes to elaborate.

The division is not tidiness. `Cost.costTree` takes `level p ≤ Level.branch` as
an *argument*, so `parseAndCheck_level_le` below is the term that makes every
tool over source files compile: `Agentic/Core/Explain.lean`, and through it
`cli/AgentCat.lean` and `Agentic/Core/Mcp.lean`. Those three want the theorem
and have no use whatever for the flagship, so they import this file and not the
other one, and `lake exe agent-cat` costs seconds rather than minutes.

## What "well-typed by construction" is and is not

`Dsl.check : (Γ : Ctx) → Bindings Γ → Raw → Except CheckError (Plan Γ Unit)` and
`Dsl.parseAndCheck : String → Except String (Plan [] Unit)` state their own
soundness *in their types*. A checker that returned an ill-typed plan would have
to inhabit `Plan [] Unit` with something that is not one, and there is no such
thing; a checker that returned an open plan would have to inhabit `Plan [] Unit`
with a term mentioning a variable, and `Var [] c` is empty. So neither
"the result type-checks" nor "the result is closed" is a theorem here — both are
readings of the signature, and there is nothing that could drift out of date.

What is **not** free, and is proved below, is the fact that makes the language
worth having: `parseAndCheck_level_le` — *every* program in the language sits at
or below the branch rung. `Harden.level_hardenPatch` says the hand-written
flagship does; this says the language cannot express a term that does not.
`Cost.costTree` takes `level p ≤ Level.branch` **as an argument**, so this
theorem is the term that makes a cost tool over DSL sources compile.

## Where the proofs stop, and why

Three statements are *not* proved about this language, and each has its own
reason; the section "What is not proved" at the foot of
`Agentic/Core/DslFlagship.lean` states each one, with the measurement or the
missing lemma that stops it, rather than weakening it into something that
closes. Two of the three are about the flagship, and the third — that the
lexer's and the parser's fuel is never exhausted — is about the code in
`Agentic/Core/Dsl/Parse.lean`.
-/

namespace Agentic.Core

open Plan

/-! ## Equality of transcripts is decidable

`Trace` is a list of `Event`s and an `Event` is `Σ c, Q c × El c`, whose three
components all have decidable equality; the instance is not derived where
`Event` is declared only because nothing there needed it. It is what lets the
flagship's agreement with `Agentic/Core/HardenPatch.lean` be a `decide` in each
of the four named worlds (`Agentic/Core/DslFlagship.lean`), and it is what lets
`Mcp.reportJson` decide whether the transcript it heard is the one the replay
reconstructs — so it stays on the cheap side of the split, where the server can
reach it without the flagship. -/

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

/-! ## Level, at the derived forms the checker emits

`Agentic/Core/Level.lean` proves the elimination lemmas and the graft bound;
these four are the remaining forms a DSL program is built out of, each stated at
an arbitrary bound `ℓ` because the induction below carries one. -/

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

/-- A panel is at the join of its members' rungs — `Level.level_panel_le` in the
form an induction over a checker can use, where the members are known one at a
time rather than as a `foldr`. -/
theorem level_panel_le' {c : Code} [Monoid (El c)] (ps : List (Plan Γ (El c)))
    (h : ∀ p ∈ ps, level p ≤ ℓ) : level (Plan.panel ps) ≤ ℓ := by
  induction ps with
  | nil => exact bot_le
  | cons p ps ih =>
    refine le_trans (level_zipWith_le _ p (Plan.panel ps))
      (max_le (h p (List.mem_cons_self ..)) (ih fun q hq => h q (List.mem_cons_of_mem _ hq)))

/-- **Bounded revision does not leave the branch rung.** `Plan.revising` is
`Nat.rec` over `graft` and `caseB`, so this is those two bounds iterated; it is
stated at every fuel, every leaf context and every context morphism because that
is the shape `Plan.Cont` has. -/
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

/-! ## Every program of the language sits at or below the branch rung

The one theorem the language exists to make true, by induction over the
elaborator. Each clause is a bound on the former it emits, and the `dyn` case is
absent from the proof because it is absent from the checker. -/

/-- One question is at `pipeline` at worst: `askC1` is `batch` and `ask1` is
`pipeline`, and neither can be anything else. -/
theorem checkAsk_level_le {Γ : Ctx} (S : Bindings Γ) (a : RawAsk) (v : Checked Γ)
    (h : checkAsk S a = .ok v) : level v.plan ≤ Level.pipeline := by
  unfold checkAsk at h
  split at h
  · cases h; exact le_trans (le_of_eq (level_askC1 ..)) bot_le
  · split at h
    · exact absurd h (by simp)
    · cases h; exact le_of_eq (level_ask1 ..)

/-- Panel members, one at a time: each is a question, so each is at `pipeline`
at worst. -/
theorem checkMembers_level_le {Γ : Ctx} (c : Code) (S : Bindings Γ) :
    ∀ (l : List RawAsk) (ps : List (Plan Γ (El c))),
      checkMembers c S l = .ok ps → ∀ p ∈ ps, level p ≤ Level.pipeline := by
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
        · unfold checkAskAt at hq
          split at hq
          · exact absurd hq (by simp)
          · rename_i w hw
            split at hq
            · rename_i hcode
              cases hq
              subst hcode
              exact checkAsk_level_le S a w hw
            · exact absurd hq (by simp)
        · exact ih qs hqs p hp'

/-- A right-hand side likewise: a panel of `pipeline` members is `pipeline`, so
nothing in the language's expression layer reaches the branch rung at all — the
branching does that, and only the branching. -/
theorem checkRhs_level_le {Γ : Ctx} (S : Bindings Γ) (r : RawRhs) (v : Checked Γ)
    (h : checkRhs S r = .ok v) : level v.plan ≤ Level.pipeline := by
  cases r with
  | ask a => exact checkAsk_level_le S a v h
  | panel ms pos =>
    simp only [checkRhs] at h
    split at h
    · exact absurd h (by simp)
    · rename_i m rest
      split at h
      · split at h
        · exact absurd h (by simp)
        · rename_i ps hps
          cases h
          exact level_panel_le' _ (checkMembers_level_le Code.verdict S (m :: rest) ps hps)
      · exact absurd h (by simp)

/-- The `at`-flavoured form carries the bound through the transport that a code
comparison introduces. -/
theorem checkRhsAt_level_le {Γ : Ctx} (c : Code) (S : Bindings Γ) (r : RawRhs) (what : String)
    (p : Plan Γ (El c)) (h : checkRhsAt c S r what = .ok p) : level p ≤ Level.pipeline := by
  unfold checkRhsAt at h
  split at h
  · exact absurd h (by simp)
  · rename_i v hv
    split at h
    · rename_i hcode
      cases h
      subst hcode
      exact checkRhs_level_le S r v hv
    · exact absurd h (by simp)

/-- A `let`'s former does not move the rung of what it is given: an `ask` node
adds `pipeline`, and a panel's graft adds the panel's own rung. -/
theorem checkBinder_level_le {Γ : Ctx} (S : Bindings Γ) (r : RawRhs) (bd : Binder Γ)
    (h : checkBinder S r = .ok bd) (k : Plan (bd.code :: Γ) Unit) (hk : level k ≤ Level.branch) :
    level (bd.form k) ≤ Level.branch := by
  cases r with
  | ask a =>
    simp only [checkBinder] at h
    split at h
    · cases h
      exact le_trans (le_of_eq (level_askC ..)) hk
    · split at h
      · exact absurd h (by simp)
      · cases h
        exact le_trans (le_of_eq (level_ask ..)) (max_le (by decide) hk)
  | panel ms pos =>
    simp only [checkBinder] at h
    split at h
    · exact absurd h (by simp)
    · rename_i v hv
      cases h
      refine le_trans (level_graft_le (ℓ₀ := Level.branch) _ _ fun _ σ e => ?_)
        (max_le (le_trans (checkRhs_level_le S (.panel ms pos) v hv) (by decide)) le_rfl)
      exact le_trans (le_of_eq (level_sub _ _)) hk

/-- **The flagship claim.** Every block the checker accepts is at or below the
branch rung — no clause emits `Plan.dyn`, and the language has no syntax that
could.

Not decoration: `Cost.costTree` takes this bound as an argument, so a cost
report over a source file is not writable without it. -/
theorem checkBlock_level_le : ∀ (b : RawBlock) (Γ : Ctx) (S : Bindings Γ) (p : Plan Γ Unit),
    checkBlock Γ S b = .ok p → level p ≤ Level.branch := by
  intro b
  induction b with
  | empty pos => intro Γ S p h; cases h; exact bot_le
  | act t pr pos =>
    intro Γ S p h
    simp only [checkBlock] at h
    split at h
    · cases h; exact le_trans (le_of_eq (level_askC ..)) bot_le
    · split at h
      · exact absurd h (by simp)
      · cases h
        exact le_trans (le_of_eq (level_ask ..)) (max_le (by decide) bot_le)
  | bind x rhs rest pos ih =>
    intro Γ S p h
    simp only [checkBlock] at h
    split at h
    · exact absurd h (by simp)
    · rename_i bd hbd
      split at h
      · exact absurd h (by simp)
      · rename_i k hk
        cases h
        exact checkBinder_level_le S rhs bd hbd k (ih _ _ k hk)
  | ifFlag x y n pos ihy ihn =>
    intro Γ S p h
    simp only [checkBlock] at h
    split at h
    · exact absurd h (by simp)
    · split at h
      · exact absurd h (by simp)
      · rename_i y' hy'
        split at h
        · exact absurd h (by simp)
        · rename_i n' hn'
          split at h
          · cases h
            exact level_caseB_le _ _ _ le_rfl (ihy _ _ y' hy') (ihn _ _ n' hn')
          · exact absurd h (by simp)
  | caseVerdict x a o d pos iha iho ihd =>
    intro Γ S p h
    simp only [checkBlock] at h
    split at h
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
            split at h
            · cases h
              refine level_caseV_le _ _ le_rfl fun t => ?_
              cases t
              · exact iha _ _ a' ha'
              · exact iho _ _ o' ho'
              · exact ihd _ _ d' hd'
            · exact absurd h (by simp)
  | revising subj n cv chk av wv rev pv acc exh pos iha ihe =>
    intro Γ S p h
    simp only [checkBlock] at h
    -- The first `split` is the bound of `Dsl.maxRevisions`: a numeral the
    -- checker refuses writes no plan, so there is nothing to price.
    split at h
    · exact absurd h (by simp)
    · split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · rename_i chkP hchk
          split at h
          · exact absurd h (by simp)
          · rename_i revP hrev
            split at h
            · exact absurd h (by simp)
            · rename_i accP hacc
              split at h
              · exact absurd h (by simp)
              · rename_i exhP hexh
                cases h
                have hchk' := checkRhsAt_level_le _ _ chk _ chkP hchk
                have hrev' := checkRhsAt_level_le _ _ rev _ revP hrev
                have haccP := iha _ _ accP hacc
                have hexhP := ihe _ _ exhP hexh
                refine le_trans (level_graft_le (ℓ₀ := Level.branch) _ _ fun _ σ e => ?_) ?_
                · exact level_caseB_le _ _ _ le_rfl
                    (le_trans (le_of_eq (level_sub _ _)) haccP)
                    (le_trans (le_of_eq (level_sub _ _)) hexhP)
                · refine max_le (level_revising_le le_rfl (fun _ _ _ => ?_) (fun _ _ _ => ?_) n _ _ _)
                    le_rfl
                  · exact le_trans (le_of_eq (level_sub _ _)) (le_trans hchk' (by decide))
                  · exact le_trans (le_of_eq (level_sub _ _)) (le_trans hrev' (by decide))

/-- …and hence of every source text the front end accepts. -/
theorem parseAndCheck_level_le (s : String) (p : Plan [] Unit) (h : parseAndCheck s = .ok p) :
    level p ≤ Level.branch := by
  rw [parseAndCheck_ok_iff] at h
  unfold parseAndCheckE at h
  split at h
  · exact absurd h (by simp)
  · exact checkBlock_level_le _ [] [] p h

end Agentic.Core.Dsl
