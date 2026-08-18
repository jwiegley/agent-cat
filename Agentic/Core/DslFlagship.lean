import Agentic.Core.Dsl
import Agentic.Core.HardenPatch

/-!
# The flagship program, and what kernel reduction proves about it

Stage 3, part four (b): the flagship workload as a `RawProgram` — together with
everything that is true of *that one program* rather than of the elaboration.
`Agentic/Core/Dsl.lean` holds part four (a), the theorems about the checker, and
is imported here; nothing in this module is needed to state or prove any of them.

## The term of record, and the parser that is gone

`flagshipRaw` used to be a *frozen copy* of what a parser read out of
`example/harden.wf`, checked against the file at run time. There is no parser and
no `.wf` file any more: the conformance boundary is `RawProgram`-in
(`doc/research/connection.md`, D10), so the term below **is** the
flagship, and the file it agrees with is `test/corpus/example-000-the-flagship-
single-file.json` — whose `request.program` is `flagshipProgram` and whose
`reply` carries the very numbers proved here (`level = branch`, `paths = 9`,
`minFold = 5`, `maxFold = 15`). That agreement is not asserted in this module: it
is the corpus's, re-observed by `lake exe corpus-gen` and reproduced by the
Haskell implementation with no Lean in the loop. What died with the parser is
exactly one theorem, `parseAndCheck_flagship`, whose hypothesis was that a parser
read a string as this term.

## The transcript agreements survive

`Agentic/Core/HardenPatch.lean` is **kept**. It is not `.wf` machinery: it
imports `Agentic.Core.Morphism` and nothing of the DSL, it is the root module's
Stage-5 worked example of the meaning space (consent gates the act, the guide is
read once, the level is `branch`, at most three drafts, nine leaves with min 5
and max 15, `run` total), and it predates the language whose flagship agrees with
it. Nothing in the elaboration imports it, so it was free to go by import graph
alone — and it stays because the four `Plan.trace … flagshipPlan = Plan.trace …
Harden.demo` equations below are the *strongest* anchor the `Raw` term has: they
say this program consults exactly the same questions, in the same order, hearing
the same answers, as a workload whose properties are proved in the meaning space.
Those equations never mentioned the parser.

## What this module costs, and why it is worth paying

**This module takes minutes of wall clock to elaborate, and several gigabytes of
memory.** Almost all of it is nine `decide +kernel` proofs, four of them at
`maxRecDepth 1000000`. That is not accidental expense and it is not a
proof-engineering failure: it is the price of the statements being true *by
computation* rather than by assertion. `level flagshipPlan = Level.branch`,
`Multiset.card (costM …) = 9`, `minFold = 5`, `maxFold = 15` and the four
`Plan.trace` equations are proved by the kernel running the checker, the cost
algebra and the interpreter on this concrete program in these concrete worlds,
and reporting the answer — including on `ωEcho`, the longest path the workload
has.

**What the split buys.** Because this module is separate, that cost is paid only
by things that actually want the flagship. `Agentic/Core/Explain.lean` and
`conformance/Conformance.lean` reach `Dsl.checkProgram_level_le` through
`Agentic/Core/Dsl.lean` and never import this file, so `lake exe
conformance-oracle` builds in seconds. Keep it that way.

## What is here

* `flagshipRaw`, the term of record; `flagshipProgram`, it with an empty function
  table; `flagshipPlan`, the plan it checks to.
* `render_eq_harden_render`, the one-line `rfl` that says the elaboration
  introduced no second convention for what a verdict says.
* The checker's acceptance (`flagshipRaw_accepted`, `checkProgram_flagship`), the
  rung computed exactly (`level_flagshipPlan`), the cost tree
  (`card_leaves_flagship`, `minFold_flagship`, `maxFold_flagship`), the four
  transcript agreements, the four bills transferred rather than recomputed, and
  the budget type the program inhabits at fifteen (`flagshipUpTo`).
* The section "What is not proved" at the foot.
-/

namespace Agentic.Core.Dsl

open Agentic.Core

/-! ## `Verdict.render` is `Harden.render`

The elaboration needed a renderer for a verdict spliced into a prompt and the
frozen flagship module already had one. They are the same function, so the
elaboration introduces no second convention about what a verdict says. -/

/-- The two spellings are one function, by `rfl`. -/
theorem render_eq_harden_render (v : Verdict) : Verdict.render v = Harden.render v := rfl

/-! ## The flagship, as raw syntax

`Harden.demo` — read the house style guide, draft under the deep model, review
and amend up to twice, ask the owner, apply if and only if the owner consented —
written as the first-order syntax the checker takes. -/

/-- `[[flagshipRaw]]` = **the flagship, and the definition of record**: read the
house style guide, draft under the deep model, review by a panel and amend up to
twice, ask the owner, apply if and only if the owner consented.

This term is corpus entry `test/corpus/example-000-the-flagship-single-file.json`
— it is that file's `request.program.main`, position for position, and the file's
`request.program.fns` is the empty table `flagshipProgram` writes. The corpus
entry's `reply` is `Conformance.observe` of exactly this program, so every number
proved below is also a byte the Haskell implementation must reproduce.

**Why it is written out rather than computed.** It always was, and the reason
outlived the parser it was written for: kernel reduction of a lexer is quadratic
in the character count, and `native_decide` is forbidden here because it would put
`Lean.ofReduceBool` into the axiom set `Agentic/Core/Certify.lean` pins at
*empty*. The checker, the cost algebra and the interpreter are cheap in the
kernel; a front end over characters is not. So the term is the artifact and the
theorems reduce on it. -/
def flagshipRaw : Raw :=
  RawBlock.bind
    "guide"
    none
    (RawSource.rhs
      (RawRhs.ask
        { model := none,
          target := { addressee := Addressee.tool "cat", draw := 0 },
          prompt := [Chunk.lit "Write out the house style guide, at most four short lines."],
          pos := { line := 7, col := 12 } }))
    (RawBlock.bind
      "draft"
      none
      (RawSource.rhs
        (RawRhs.ask
          { model := some "deep",
            target := { addressee := Addressee.model "author", draw := 0 },
            prompt := [Chunk.lit "Draft a patch satisfying:\n",
                       Chunk.lit "harden the parser",
                       Chunk.lit "\nReply with a unified diff only."],
            pos := { line := 10, col := 12 } }))
      (RawBlock.bind
        "result"
        none
        (RawSource.revising
          "draft"
          "patch"
          2
          "verdict"
          none
          (RawRhs.panel
            [{ model := none,
               target := { addressee := Addressee.model "reviewer-correct", draw := 0 },
               prompt := [Chunk.interp "guide",
                          Chunk.lit "\nIs this patch correct?\n",
                          Chunk.interp "patch",
                          Chunk.lit "\n",
                          Chunk.lit
                            "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."],
               pos := { line := 19, col := 7 } },
             { model := none,
               target := { addressee := Addressee.model "reviewer-secure", draw := 0 },
               prompt := [Chunk.interp "guide",
                          Chunk.lit "\nIs this patch secure?\n",
                          Chunk.interp "patch",
                          Chunk.lit "\n",
                          Chunk.lit
                            "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."],
               pos := { line := 25, col := 7 } },
             { model := none,
               target := { addressee := Addressee.model "reviewer-simple", draw := 0 },
               prompt := [Chunk.lit "Could this patch be simpler?\n",
                          Chunk.interp "patch",
                          Chunk.lit "\n",
                          Chunk.lit
                            "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."],
               pos := { line := 31, col := 7 } }]
            { line := 18, col := 16 })
          (RawRhs.ask
            { model := some "deep",
              target := { addressee := Addressee.model "author", draw := 0 },
              prompt := [Chunk.interp "guide",
                         Chunk.lit "\nRevise this patch:\n",
                         Chunk.interp "patch",
                         Chunk.lit "\n",
                         Chunk.interp "verdict",
                         Chunk.lit "\nReply with the revised diff only."],
              pos := { line := 39, col := 7 } })
          { line := 16, col := 13 })
        (RawBlock.caseResult
          "result"
          "patch"
          (RawBlock.bind
            "ok"
            none
            (RawSource.rhs
              (RawRhs.ask
                { model := none,
                  target := { addressee := Addressee.person "owner", draw := 0 },
                  prompt := [Chunk.lit "Apply this patch?\n",
                             Chunk.interp "patch",
                             Chunk.lit "\n",
                             Chunk.lit "Reply with exactly yes or no."],
                  pos := { line := 52, col := 13 } }))
            (RawBlock.ifFlag
              "ok"
              (RawBlock.act
                { model := none,
                  target := { addressee := Addressee.tool "apply", draw := 0 },
                  prompt := [Chunk.lit "Apply:\n",
                             Chunk.interp "patch",
                             Chunk.lit "\nWrite the patched file here, then reply DONE."],
                  pos := { line := 59, col := 9 } }
                (RawBlock.empty { line := 58, col := 13 })
                { line := 59, col := 9 })
              (RawBlock.empty { line := 64, col := 16 })
              { line := 58, col := 7 })
            { line := 52, col := 7 })
          (RawBlock.empty { line := 67, col := 17 })
          { line := 49, col := 3 })
        { line := 16, col := 3 })
      { line := 10, col := 3 })
    { line := 7, col := 3 }

/-- `[[flagshipPlan]]` = the plan `flagshipRaw` checks to.

The `.error` branch is unreachable — `check_flagshipRaw` below says so — and is
written as the trivial workflow rather than as a `panic!` because a
`Plan [] Unit` is what the type promises and one exists. -/
def flagshipPlan : Plan [] Unit :=
  match check [] [] flagshipRaw with
  | .ok p => p
  | .error _ => .ret fun _ => ()

/-- `[[accepted x]]` = the checker said yes.

A `Bool` and not a `Prop`, because the fact that the flagship checks is
established by kernel reduction and `decide` on a `Bool` needs only the *head*
constructor of the result. -/
def accepted {ε : Type} {α : Type u} (x : Except ε α) : Bool :=
  match x with
  | .ok _ => true
  | .error _ => false

set_option maxRecDepth 20000 in
/-- **The flagship checks.** By kernel reduction of the checker on
`flagshipRaw`. -/
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

/-- The flagship as a whole program: no functions, one block. A program's
function table is part of what it says, so `main` alone would under-pin it — which
is why the corpus freezes the `RawProgram` and not the `RawBlock`. -/
def flagshipProgram : RawProgram := ⟨[], flagshipRaw⟩

/-- The program front end accepts the flagship exactly as the block checker
does: the table is empty, and the affordability guard is arithmetic the
elaborator reduces on the spot (19 questions against a bound of 4096). -/
theorem checkProgram_flagship : checkProgram flagshipProgram = .ok flagshipPlan := by
  have h : checkProgram flagshipProgram = check [] [] flagshipRaw := rfl
  rw [h]
  exact check_flagshipRaw

/-! ### What the flagship costs -/

set_option maxRecDepth 20000 in
/-- **The rung, exactly.** `level flagshipPlan = branch`, computed rather than
bounded: `checkProgram_level_le` gives `≤ branch` for every program, and this
says the flagship attains it — the consent gate and the loop's outcome are
`case`s, so it is not `pipeline`, and nothing is a `dyn`, so it is not
`dynamic`. -/
theorem level_flagshipPlan : level flagshipPlan = Level.branch := by decide +kernel

/-- …hence the C3 cost theorems apply to it, which is what `Cost.costM` asks
for as an argument. -/
theorem level_flagshipPlan_le : level flagshipPlan ≤ Level.branch :=
  le_of_eq level_flagshipPlan

set_option maxRecDepth 20000 in
/-- **The cost tree has nine leaves**, exactly as the hand-written flagship's
does (`Harden.card_leaves_demo`): three ways out of the revision loop times
three ways through the tail. -/
theorem card_leaves_flagship :
    Multiset.card (costM tick flagshipPlan level_flagshipPlan_le Env.nil) = 9 := by
  decide +kernel

set_option maxRecDepth 20000 in
/-- **The cheapest leaf is 5 consultations**, and no world pays it —
`Harden.minFold_not_attained_demo` again, transported by the trace
agreements. -/
theorem minFold_flagship :
    minFold (costM tick flagshipPlan level_flagshipPlan_le Env.nil)
      = ((Multiplicative.ofAdd 5 : Multiplicative Nat) : WithTop (Multiplicative Nat)) := by
  decide +kernel

set_option maxRecDepth 20000 in
/-- **The dearest leaf is 15 consultations**, and that one is paid. -/
theorem maxFold_flagship :
    maxFold (costM tick flagshipPlan level_flagshipPlan_le Env.nil)
      = ((Multiplicative.ofAdd 15 : Multiplicative Nat) : WithBot (Multiplicative Nat)) := by
  decide +kernel

/-! ### The flagship elaborates to the hand-written flagship, world by world

`Agentic/Core/HardenPatch.lean` fixes four worlds and prices the workload in
each. The four equations below say the checked `Raw` term consults **exactly**
the same questions, in the same order, and hears the same answers, in each of
them —
including `ωEcho`, the world that reads prompt text and drives the loop to its
dearest leaf, so the agreement is checked on the longest path the workload has
and not only on the short ones.

That the prompts agree is where the left-associated `Prompt.expr` earns its
keep — the elaborated prompts are `Harden`'s `++`-chains on the nose — and
where the `{verdict}` hole earns its keep: at a verdict binding it elaborates
to the same `Verdict.render ∘ ·` expression the old surface installed at the
binder, so moving the renderer to the use site moved no term.

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
amendments and the owner is never troubled. -/
theorem trace_flagship_stubborn :
    Plan.trace Harden.ωStubborn flagshipPlan Env.nil
      = Plan.trace Harden.ωStubborn Harden.demo Env.nil := by decide +kernel

set_option maxRecDepth 1000000 in
/-- …and the one that reads prompt text and approves only at round three, which
is the run that attains the dearest leaf of the cost tree. -/
theorem trace_flagship_echo :
    Plan.trace Harden.ωEcho flagshipPlan Env.nil
      = Plan.trace Harden.ωEcho Harden.demo Env.nil := by decide +kernel

/-! ### …hence the bills, transferred rather than recomputed -/

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

/-- …so every world bills at most fifteen consultations. -/
theorem flagship_bill_le (ω : Ω) :
    billFresh tick (Plan.trace ω flagshipPlan Env.nil) ≤ Multiplicative.ofAdd 15 :=
  PlanUpTo.bill_le Harden.tick_pricesByShape flagshipUpTo ω

/-- …and at least the cheapest achievable one: `minFold_flagship` is `5`, and no
world attains it, exactly as on the hand-written flagship. -/
theorem minFold_flagship_le_bill (ω : Ω) :
    minFold (costM tick flagshipPlan level_flagshipPlan_le Env.nil)
      ≤ ((billFresh tick (Plan.trace ω flagshipPlan Env.nil) : Multiplicative Nat) :
          WithTop (Multiplicative Nat)) :=
  minFold_le_bill (S := Multiplicative Nat) (price := tick) Harden.tick_pricesByShape
    flagshipPlan level_flagshipPlan_le Env.nil ω

/-! ## What is not proved

Two statements a reader might expect, and what actually stands in the way of
each. Neither is weakened into a form that closes.

**1. `∀ ω, Plan.trace ω flagshipPlan Env.nil = Plan.trace ω Harden.demo Env.nil`.**
The four named worlds are proved above, `ωEcho` among them. The universally
quantified form needs the `Plan.Denotes` route rather than reduction — general
coherence lemmas for `checkCont`, `reviseCont` and `finishCont`, then
`denotes_revising` and `denote_graft`, then a per-clause agreement with
`Harden`'s own continuations — and it needs the checker's output *named*, which
means writing out by hand the plan the checker builds; that is the work not done
here.

**2. That `flagshipRaw` is the term the corpus holds.** It is, and it is checked
rather than proved: `lake exe corpus-gen` re-observes
`test/corpus/example-000-the-flagship-single-file.json`'s frozen request through
`Conformance.observe` and rewrites the reply, so a drift between this term and
that file shows up as a corpus diff on the same commit. A theorem would have to
run a JSON decoder in the kernel, which is the same quadratic bargain the parser
was refused.

**What is no longer here.** `parseAndCheck_flagship` and its hypothesis
`parseProgramWith [] [] flagshipSource = .ok flagshipProgram` — the one thing
about the string layer that was ever checked rather than proved. There is no
string layer. -/

end Agentic.Core.Dsl
