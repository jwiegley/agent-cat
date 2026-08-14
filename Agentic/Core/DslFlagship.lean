import Agentic.Core.Dsl
import Agentic.Core.HardenPatch

/-!
# The flagship program, and what kernel reduction proves about it

Stage 3, part four (b): `example/harden.wf` — `Harden.demo` written in the
language — together with everything that is true of *that one program* rather
than of the language. `Agentic/Core/Dsl.lean` holds part four (a), the theorems
about the checker, and is imported here; nothing in this module is needed to
state or prove any of them.

## What this module costs, and why it is worth paying

**This module takes on the order of five minutes of wall clock to elaborate, and
several gigabytes of memory.** Almost all of it is nineteen `decide +kernel`
proofs, four of them at `maxRecDepth 1000000`. That is not accidental
expense and it is not a proof-engineering failure: it is the price of the
statements being true *by computation* rather than by assertion. `level
flagshipPlan = Level.branch`, `Multiset.card … .leaves = 9`, `minFold = 5`,
`maxFold = 15` and the four `Plan.trace … flagshipPlan = Plan.trace …
Harden.demo` equations are not proved by a general argument about programs of
this shape; they are proved by the kernel running the checker, the cost
algebra, and the interpreter on this concrete program in these concrete worlds,
and reporting the answer. A cheaper proof would be a weaker one — it would say
something about a class of programs, and the point here is the specific claim
that the DSL program and the hand-written flagship consult exactly the same
questions in exactly the same order, including on `ωEcho`, the longest path the
workload has. Nothing about the flagship is asserted; it is all computed, and
computation costs what it costs.

**What the split buys.** Because this module is separate, that cost is paid only
by the things that actually want the flagship: `test/DslSmoke.lean`,
`test/CliSmoke.lean` and the `Agentic` aggregate. The three executables
(`agent-cat`, `workflow_mcp`, `harden_demo`) reach `Dsl.parseAndCheck_level_le`
through `Agentic/Core/Dsl.lean` and never import this file, so `lake exe
agent-cat` builds in seconds and editing `example/harden.wf` does not invalidate
it. Keep it that way: if a binary comes to need something proved here, prefer
moving the *statement* it needs into the cheap half over importing this module
into the binary's path.

## What is here

* `flagshipSource`, the text of `example/harden.wf`, included rather than
  copied; `flagshipRaw`, its raw syntax written out; `flagshipPlan`, the plan it
  checks to.
* `render_eq_harden_render`, the one-line `rfl` that says the language
  introduced no second convention for what a verdict says.
* The rung computed exactly (`level_flagshipPlan`), the cost tree
  (`card_leaves_flagship`, `minFold_flagship`, `maxFold_flagship`), the four
  transcript agreements, the four bills transferred rather than recomputed, and
  the budget type the program inhabits at fifteen (`flagshipUpTo`).
* The section "What is not proved" at the foot, which states three claims a
  reader might expect and the measurement or missing lemma that stops each,
  rather than weakening them into something that closes.

The `DecidableEq Event` instance that makes the four transcript agreements a
`decide` at all is deliberately *not* here: it lives in `Agentic/Core/Dsl.lean`,
because `Mcp.reportJson` decides an equality of transcripts too and must not
have to import this module to do it.
-/

namespace Agentic.Core.Dsl

open Agentic.Core

/-! ## `Verdict.render` is `Harden.render`

The DSL needed a renderer for the `why` binder and the frozen flagship module
already had one. They are the same function, so the language introduces no
second convention about what a verdict says. -/

/-- The two spellings are one function, by `rfl`. -/
theorem render_eq_harden_render (v : Verdict) : Verdict.render v = Harden.render v := rfl

/-! ## The flagship, in the language

`Harden.demo` — read the house style guide, draft under the deep model, review
and revise up to twice, ask the owner, apply if and only if the owner
consented — written in the concrete syntax. Compare
`Agentic/Core/HardenPatch.lean`: twelve lines of authoring surface there,
forty of a language here, and the same dialogue at the end of both. -/

/-- `[[flagshipSource]]` = the owner's workflow, in the DSL — **the file
`example/harden.wf`**, included here rather than copied.

One text in one place, and the place is the file: `agent-cat run
example/harden.wf` and every theorem below are about the same characters, so
there is no second copy to drift. `include_str` elaborates to a string literal,
exactly as the `r##"…"##` it replaced did, so nothing about the kernel
reductions the proofs below perform changes — and nothing about them touches this
constant anyway, which is the point of `flagshipRaw` being written out (see its
docstring for the measurement that forces that).

**What the inclusion cannot do, and where that is caught.** Lake's build trace
records the module's imports and its own source, not the files a term elaborator
reads, so editing `example/harden.wf` alone does not rebuild this module: the
`.olean` would then hold a text that is no longer on disk. `test/CliSmoke.lean`
reads the file at run time and compares it with this constant, which is the check
the inclusion cannot arrange for itself. The file begins with a newline because
this literal did, and `flagshipRaw`'s positions count lines from it. -/
def flagshipSource : String := include_str "../../example/harden.wf"

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
