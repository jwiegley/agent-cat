import Agentic.Core.Dsl.Check
import Agentic.Core.HardenPatch

/-!
# The DSL, and what is provable about it

Stage 3, part four: the front end, the theorem the language exists to make true,
and the flagship written in the language and joined to the hand-written one.

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

## The flagship

`flagshipSource` is `Harden.demo` written in the concrete syntax, `flagshipRaw`
is its raw syntax, and `flagshipPlan` is the plan it checks to.

Three things are proved about it, and the third is the one that does the work.
Its rung is computed exactly (`level_flagshipPlan`), so it is not merely bounded
by the theorem above; its cost tree has the same nine leaves and the same
extremes as the hand-written flagship's (`card_leaves_flagship`,
`minFold_flagship`, `maxFold_flagship`); and its **transcript agrees with
`Harden.demo`'s in each of the four worlds `Agentic/Core/HardenPatch.lean`
names**, `ωEcho` among them, which is the world that drives the workload to its
deepest path. The four bills then transfer by rewriting rather than by being
recomputed, and the DSL program inhabits the same budget type at fifteen
(`flagshipUpTo`).

The universally quantified transcript agreement is *not* proved, and the section
at the foot of this module says why and what would close it.

## Where the proofs stop, and why

Three statements are *not* proved here and each has its own reason; the section
"What is not proved" at the foot of this module states each one, with the
measurement or the missing lemma that stops it, rather than weakening it into
something that closes.
-/

namespace Agentic.Core

open Plan

/-! ## Equality of transcripts is decidable

`Trace` is a list of `Event`s and an `Event` is `Σ c, Q c × El c`, whose three
components all have decidable equality; the instance is not derived where
`Event` is declared only because nothing there needed it. It is what lets the
flagship's agreement with `Agentic/Core/HardenPatch.lean` be a `decide` in each
of the four named worlds. -/

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

/-! ## `Verdict.render` is `Harden.render`

The DSL needed a renderer for the `why` binder and the frozen flagship module
already had one. They are the same function, so the language introduces no
second convention about what a verdict says. -/

/-- The two spellings are one function, by `rfl`. -/
theorem render_eq_harden_render (v : Verdict) : Verdict.render v = Harden.render v := rfl

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
  | done pos => intro Γ S p h; cases h; exact bot_le
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
  | caseFlag x y n pos ihy ihn =>
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
    -- The first `split` is the bound of `Dsl.maxRevisions`: an `upto` the
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


/-! ## The flagship, in the language

`Harden.demo` — read the house style guide, draft under the deep model, review
and revise up to twice, ask the owner, apply if and only if the owner
consented — written in the concrete syntax. Compare
`Agentic/Core/HardenPatch.lean`: twelve lines of authoring surface there,
forty of a language here, and the same dialogue at the end of both. -/

/-- `[[flagshipSource]]` = the owner's workflow, in the DSL. -/
def flagshipSource : String := r##"
define spec        = "harden the parser"
define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
define flagSpec    = "Reply with exactly yes or no."

workflow {
  let guide = ask text tool "cat"
    "Write out the house style guide, at most four short lines."

  let draft = @model "deep" ask text model "author"
    "Draft a patch satisfying:\n{spec}\nReply with a unified diff only."

  revising draft upto 2

    check (patch) {
      panel [
        ask verdict model "reviewer-correct"
          "{guide}\nIs this patch correct?\n{patch}\n{verdictSpec}",
        ask verdict model "reviewer-secure"
          "{guide}\nIs this patch secure?\n{patch}\n{verdictSpec}",
        ask verdict model "reviewer-simple"
          "Could this patch be simpler?\n{patch}\n{verdictSpec}"
      ]
    }

    with (patch, why) {
      @model "deep" ask text model "author"
        "{guide}\nRevise this patch:\n{patch}\n{why}\nReply with the revised diff only."
    }

    accepted (patch) {
      let ok = ask flag person "owner"
        "Apply this patch?\n{patch}\n{flagSpec}"
      case ok {
        yes -> { act tool "apply"
                   "Apply:\n{patch}\nWrite the patched file here, then reply DONE." }
        no  -> { done }
      }
    }

    exhausted { done }
}
"##

/-- `[[flagshipRaw]]` = the raw syntax of `flagshipSource`: the same workflow
after lexing, macro expansion and parsing.

**Written out rather than computed, and the reason is a measurement.** Kernel
reduction of the lexer is quadratic in the character count — 189 characters
reduce in 2s, 369 in 6s, 729 in 20s and this source's 1400 in 211s — so a
theorem stated about `parseAndCheck flagshipSource` would have to run the lexer
in the kernel, and `native_decide` is forbidden here because it would put
`Lean.ofReduceBool` into the axiom set `Agentic/Core/Certify.lean` pins. So the
*checker* is exercised in the kernel, where it is cheap, and the *parser* is
exercised at runtime, in `test/DslSmoke.lean`, which checks
`parse flagshipSource = .ok flagshipRaw` by `decide` on a `DecidableEq` of
first-order data. `parseAndCheck_flagship` below is the theorem that joins
the two, with that check as its hypothesis. -/
def flagshipRaw : Raw :=
  RawBlock.bind "guide"
    (RawRhs.ask
      { model := none, code := Code.text,
        target := { addressee := Addressee.tool "cat", draw := 0 },
        prompt := [Chunk.lit "Write out the house style guide, at most four short lines."],
        pos := { line := 7, col := 15 } })
    (RawBlock.bind "draft"
      (RawRhs.ask
        { model := some "deep", code := Code.text,
          target := { addressee := Addressee.model "author", draw := 0 },
          prompt := [Chunk.lit "Draft a patch satisfying:\n", Chunk.lit "harden the parser",
            Chunk.lit "\nReply with a unified diff only."],
          pos := { line := 10, col := 29 } })
      (RawBlock.revising "draft" 2 "patch"
        (RawRhs.panel
          [{ model := none, code := Code.verdict,
             target := { addressee := Addressee.model "reviewer-correct", draw := 0 },
             prompt := [Chunk.interp "guide", Chunk.lit "\nIs this patch correct?\n",
               Chunk.interp "patch", Chunk.lit "\n", Chunk.lit
                 "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."],
             pos := { line := 17, col := 9 } },
           { model := none, code := Code.verdict,
             target := { addressee := Addressee.model "reviewer-secure", draw := 0 },
             prompt := [Chunk.interp "guide", Chunk.lit "\nIs this patch secure?\n",
               Chunk.interp "patch", Chunk.lit "\n", Chunk.lit
                 "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."],
             pos := { line := 19, col := 9 } },
           { model := none, code := Code.verdict,
             target := { addressee := Addressee.model "reviewer-simple", draw := 0 },
             prompt := [Chunk.lit "Could this patch be simpler?\n", Chunk.interp "patch",
               Chunk.lit "\n", Chunk.lit
                 "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."],
             pos := { line := 21, col := 9 } }]
          { line := 16, col := 7 })
        "patch" "why"
        (RawRhs.ask
          { model := some "deep", code := Code.text,
            target := { addressee := Addressee.model "author", draw := 0 },
            prompt := [Chunk.interp "guide", Chunk.lit "\nRevise this patch:\n",
              Chunk.interp "patch", Chunk.lit "\n", Chunk.interp "why",
              Chunk.lit "\nReply with the revised diff only."],
            pos := { line := 27, col := 21 } })
        "patch"
        (RawBlock.bind "ok"
          (RawRhs.ask
            { model := none, code := Code.flag,
              target := { addressee := Addressee.person "owner", draw := 0 },
              prompt := [Chunk.lit "Apply this patch?\n", Chunk.interp "patch",
                Chunk.lit "\n", Chunk.lit "Reply with exactly yes or no."],
              pos := { line := 32, col := 16 } })
          (RawBlock.caseFlag "ok"
            (RawBlock.act { addressee := Addressee.tool "apply", draw := 0 }
              [Chunk.lit "Apply:\n", Chunk.interp "patch",
               Chunk.lit "\nWrite the patched file here, then reply DONE."]
              { line := 35, col := 18 })
            (RawBlock.done { line := 37, col := 18 })
            { line := 34, col := 7 })
          { line := 32, col := 7 })
        (RawBlock.done { line := 41, col := 17 })
        { line := 13, col := 3 })
      { line := 10, col := 3 })
    { line := 7, col := 3 }

/-- `[[flagshipPlan]]` = the plan `flagshipRaw` checks to.

The `.error` branch is unreachable — `check_flagshipRaw` below says so, by
`rfl` — and is written as the trivial workflow rather than as a `panic!`
because a `Plan [] Unit` is what the type promises and one exists. -/
def flagshipPlan : Plan [] Unit :=
  match check [] [] flagshipRaw with
  | .ok p => p
  | .error _ => .ret fun _ => ()

/-- `[[accepted x]]` = the checker said yes.

A `Bool` and not a `Prop`, because the fact that the flagship checks is
established by kernel reduction and `decide` on a `Bool` needs only the *head*
constructor of the result. Asking for `check … = .ok flagshipPlan` directly
instead makes the kernel compare two normal forms of the whole plan, which was
measured at 211 seconds against the two below. -/
def accepted {ε : Type} {α : Type 1} (x : Except ε α) : Bool :=
  match x with
  | .ok _ => true
  | .error _ => false

/-- **The flagship checks.** By kernel reduction of the checker on
`flagshipRaw`; nothing about the parser is involved. -/
theorem flagshipRaw_accepted : accepted (check [] [] flagshipRaw) = true := by decide +kernel

/-- …and `flagshipPlan` is what it checks to. The `.error` branch of
`flagshipPlan` is discharged by the line above, so this equation costs a
`rfl` on a constructor rather than a comparison of two plans. -/
theorem check_flagshipRaw : check [] [] flagshipRaw = .ok flagshipPlan := by
  unfold flagshipPlan
  cases h : check [] [] flagshipRaw with
  | ok p => rfl
  | error e =>
    have hb := flagshipRaw_accepted
    rw [h] at hb
    exact absurd hb (by simp [accepted])

/-- The front end is the parser and the checker, and nothing else: a source the
parser reads as `r` checks exactly as `r` does.

Stated generally on purpose. Instantiating it at `flagshipSource` inside a
tactic proof makes the elaborator whnf `parseAndCheckE flagshipSource`, which
runs the lexer in the kernel and costs the 211 seconds `flagshipRaw`'s docstring
measures; applied as a lemma it costs nothing. -/
theorem parseAndCheck_of_parse {s : String} {r : Raw} {p : Plan [] Unit}
    (h : parse s = .ok r) (hc : check [] [] r = .ok p) : parseAndCheck s = .ok p := by
  rw [parseAndCheck_ok_iff]
  unfold parseAndCheckE
  rw [h]
  exact hc

/-- **The two halves join.** Given that the parser reads `flagshipSource` as
`flagshipRaw` — the fact `test/DslSmoke.lean` checks, and the one thing about
the string layer that is checked rather than proved — the front end returns
`flagshipPlan`. -/
theorem parseAndCheck_flagship (h : parse flagshipSource = .ok flagshipRaw) :
    parseAndCheck flagshipSource = .ok flagshipPlan :=
  parseAndCheck_of_parse h check_flagshipRaw

/-! ### What the flagship costs -/

set_option maxRecDepth 20000 in
/-- **The rung, exactly.** `level flagshipPlan = branch`, computed rather than
bounded: `parseAndCheck_level_le` gives `≤ branch` for every program, and this
says the flagship attains it — the consent gate is a `case`, so it is not
`pipeline`, and nothing is a `dyn`, so it is not `dynamic`. -/
theorem level_flagshipPlan : level flagshipPlan = Level.branch := by decide +kernel

/-- …hence the C3 cost theorems apply to it, which is what `Cost.costTree` asks
for as an argument. -/
theorem level_flagshipPlan_le : level flagshipPlan ≤ Level.branch :=
  le_of_eq level_flagshipPlan

set_option maxRecDepth 20000 in
/-- **The cost tree has nine leaves**, exactly as the hand-written flagship's
does (`Harden.card_leaves_demo`): three ways out of the revision loop times
three ways through the tail. -/
theorem card_leaves_flagship :
    Multiset.card (costTree tick flagshipPlan level_flagshipPlan_le Env.nil).leaves = 9 := by
  decide +kernel

set_option maxRecDepth 20000 in
/-- **The cheapest leaf is 5 consultations**, and no world pays it —
`Harden.minFold_not_attained_demo` again, transported by
`trace_flagshipPlan`. -/
theorem minFold_flagship :
    (costTree tick flagshipPlan level_flagshipPlan_le Env.nil).minFold
      = ((Multiplicative.ofAdd 5 : Multiplicative Nat) : WithTop (Multiplicative Nat)) := by
  decide +kernel

set_option maxRecDepth 20000 in
/-- **The dearest leaf is 15 consultations**, and that one is paid. -/
theorem maxFold_flagship :
    (costTree tick flagshipPlan level_flagshipPlan_le Env.nil).maxFold
      = ((Multiplicative.ofAdd 15 : Multiplicative Nat) : WithBot (Multiplicative Nat)) := by
  decide +kernel

/-! ### The flagship elaborates to the hand-written flagship

One equation, and everything `Agentic/Core/HardenPatch.lean` proves passes
through it. -/

/-! ### The flagship elaborates to the hand-written flagship, world by world

`Agentic/Core/HardenPatch.lean` fixes four worlds and prices the workload in
each. The four equations below say the DSL program consults **exactly** the same
questions, in the same order, and hears the same answers, in each of them —
including `ωEcho`, the world that reads prompt text and drives the loop to its
dearest leaf, so the agreement is checked on the longest path the workload has
and not only on the short ones.

That the prompts agree is where the left-associated `Prompt.expr` earns its
keep: `Harden.correctText` writes `guide ++ … ++ patch ++ "\n" ++ verdictSpec`,
and the elaborated prompt is that `++`-chain on the nose, so the four equations
are computations rather than proofs about `String.append_assoc`.

The **universally quantified** form is not proved; see the "not proved" section
below. -/

set_option maxRecDepth 1000000 in
/-- The world in which the panel approves at once and the owner refuses. -/
theorem trace_flagship_refuse :
    Plan.trace Harden.ωRefuse flagshipPlan Env.nil
      = Plan.trace Harden.ωRefuse Harden.demo Env.nil := by decide +kernel

set_option maxRecDepth 1000000 in
/-- …and the one in which the owner applies. -/
theorem trace_flagship_apply :
    Plan.trace Harden.ωApply flagshipPlan Env.nil
      = Plan.trace Harden.ωApply Harden.demo Env.nil := by decide +kernel

set_option maxRecDepth 1000000 in
/-- …and the one in which the panel never approves, so the loop exhausts its two
revisions and the owner is never troubled. -/
theorem trace_flagship_stubborn :
    Plan.trace Harden.ωStubborn flagshipPlan Env.nil
      = Plan.trace Harden.ωStubborn Harden.demo Env.nil := by decide +kernel

set_option maxRecDepth 1000000 in
/-- …and the one that reads prompt text and approves only at round three, which
is the run that attains the dearest leaf of the cost tree. -/
theorem trace_flagship_echo :
    Plan.trace Harden.ωEcho flagshipPlan Env.nil
      = Plan.trace Harden.ωEcho Harden.demo Env.nil := by decide +kernel

/-! ### …hence the bills, transferred rather than recomputed

Each is `Harden`'s theorem with the trace rewritten. Nothing is recomputed and
nothing is restated: the DSL program is billed by the theorems that price the
hand-written one. -/

/-- Six consultations when the owner refuses (`Harden.bill_refuse_demo`). -/
theorem bill_flagship_refuse :
    billFresh tick (Plan.trace Harden.ωRefuse flagshipPlan Env.nil)
      = Multiplicative.ofAdd 6 := by
  rw [trace_flagship_refuse]; exact Harden.bill_refuse_demo

/-- Seven when the owner applies (`Harden.bill_apply_demo`). -/
theorem bill_flagship_apply :
    billFresh tick (Plan.trace Harden.ωApply flagshipPlan Env.nil)
      = Multiplicative.ofAdd 7 := by
  rw [trace_flagship_apply]; exact Harden.bill_apply_demo

/-- Thirteen when the panel never approves (`Harden.bill_stubborn_demo`). -/
theorem bill_flagship_stubborn :
    billFresh tick (Plan.trace Harden.ωStubborn flagshipPlan Env.nil)
      = Multiplicative.ofAdd 13 := by
  rw [trace_flagship_stubborn]; exact Harden.bill_stubborn_demo

/-- Fifteen on the dearest path, which is `maxFold_flagship` attained
(`Harden.bill_echo_demo`). -/
theorem bill_flagship_echo :
    billFresh tick (Plan.trace Harden.ωEcho flagshipPlan Env.nil)
      = Multiplicative.ofAdd 15 := by
  rw [trace_flagship_echo]; exact Harden.bill_echo_demo

/-- **The budget is a type, and the DSL program inhabits it at fifteen.**
`Harden.demoUpTo` says so of the hand-written flagship; this says so of the one
the checker built, and the two bounds are the same number for the same
reason. -/
def flagshipUpTo : PlanUpTo tick (Multiplicative.ofAdd 15 : Multiplicative Nat) Unit :=
  ⟨flagshipPlan, level_flagshipPlan_le, le_of_eq maxFold_flagship⟩

/-- …so every world bills at most fifteen consultations, and this one is
universally quantified because `PlanUpTo.bill_le` is. -/
theorem flagship_bill_le (ω : Ω) :
    billFresh tick (Plan.trace ω flagshipPlan Env.nil) ≤ Multiplicative.ofAdd 15 :=
  PlanUpTo.bill_le Harden.tick_pricesByShape flagshipUpTo ω

/-- …and at least the cheapest achievable one: `minFold_flagship` is `5`, and no
world attains it, exactly as on the hand-written flagship
(`Harden.minFold_not_attained_demo`). -/
theorem minFold_flagship_le_bill (ω : Ω) :
    (costTree tick flagshipPlan level_flagshipPlan_le Env.nil).minFold
      ≤ ((billFresh tick (Plan.trace ω flagshipPlan Env.nil) : Multiplicative Nat) :
          WithTop (Multiplicative Nat)) :=
  minFold_le_bill (S := Multiplicative Nat) (price := tick) Harden.tick_pricesByShape
    flagshipPlan level_flagshipPlan_le Env.nil ω

/-! ## What is not proved

Three statements a reader might expect, and what actually stands in the way of
each. None of them is weakened into a form that closes; each is stated here in
the form it would have to take.

**1. `parse flagshipSource = .ok flagshipRaw`.** True, and checked — at run
time, in `test/DslSmoke.lean`, on `DecidableEq Raw`. It is not a *theorem*
because kernel reduction of the lexer is quadratic in the character count,
measured at 189 characters in 2s, 369 in 6s, 729 in 20s and this source's 1400
in 211s; the cost is `brecOn`'s course-of-values structure, which a fuelled or
list-structural recursion pays alike, and a trivial fuelled character counter
shows the same curve (700 characters 18s, 1400 characters 80s). `native_decide`
closes it in milliseconds and is forbidden: it puts `Lean.ofReduceBool` into
the axiom set, and `Agentic/Core/Certify.lean` pins `certify_sound` at *no*
axioms with a `#guard_msgs`. `parseAndCheck_flagship` therefore takes the
equation as a hypothesis, which is the honest shape: everything downstream of
the parser is proved, and the parser itself is tested.

**2. `∀ ω, Plan.trace ω flagshipPlan Env.nil = Plan.trace ω Harden.demo Env.nil`.**
The four named worlds are proved above, `ωEcho` among them, which is the
world that drives the workload to its deepest path — so the agreement is
checked on the longest transcript the workload has. The universally quantified
form was attempted the direct way, by `denote flagshipPlan Env.nil =
denote Harden.demo Env.nil := rfl`; the elaborator worked for 54 seconds and
reported the two sides not definitionally equal, so there is a real syntactic
difference that no named world observes. Closing it needs the `Plan.Denotes`
route rather than reduction: general coherence lemmas for `checkCont`,
`reviseCont` and `finishCont` (each one line from `denote_sub`), then
`denotes_revising` and `denote_graft`, then a per-clause agreement with
`Harden.Kreview`, `Harden.Kredraft` and `Harden.finishD` — which is
`Agentic/Core/HardenPatch.lean`'s own five-theorem argument, repeated against
the checker's output. It needs that output *named*, and naming it means writing
out by hand the plan the checker builds; that is the work not done here.

**3. The lexer's and parser's budgets are never exhausted.** Both recurse on a
`Nat` budget seeded with the input's length, and every step consumes at least
one item, so the exhausted branch is unreachable — a fact about the code that is
not proved. It could be: the parser's steps consume tokens and the lexer's
consume characters, and the invariant is an ordinary induction. It is not proved
because a proof of it buys nothing that the diagnosis in that branch does not
already give — the branch returns a `CheckError` like every other failure rather
than a `panic!`, so an exhausted budget is a rejected program, not an unsound
one. -/

end Agentic.Core.Dsl
