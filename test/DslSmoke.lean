import Agentic.Core.DslFlagship

/-!
# The DSL, driven end to end

Run from the repository root:

```
lake exe dsl_smoke
```

`Agentic/Core/Dsl.lean` proves what is provable about the checker: that every
program it accepts sits at or below the branch rung.
`Agentic/Core/DslFlagship.lean` proves that the flagship's elaboration agrees
with `Agentic/Core/HardenPatch.lean` in each of the four named worlds. This
checks the two things no proof in the package makes a statement about.

* **The parser.** Kernel reduction of the lexer is quadratic in the character
  count — 189 characters in 2s, 369 in 6s, 729 in 20s, and the flagship's 1400
  in 211s — so `parse flagshipSource = .ok flagshipRaw` is not a theorem here;
  `native_decide` would close it and is forbidden, because it puts
  `Lean.ofReduceBool` into the axiom set `Agentic/Core/Certify.lean` pins. It is
  therefore checked *here*, by `decide` at run time on `DecidableEq Raw`, and
  `Dsl.parseAndCheck_flagship` is the theorem that takes it as a hypothesis. A
  drift between the source text and the raw syntax written out in
  `Agentic/Core/DslFlagship.lean` fails this check and nothing else, which is
  exactly where it should fail.

* **Every rejection.** A checker is only as good as what it refuses, and what it
  refuses is not visible in the type of `check`: the type says an accepted
  program is well-typed, not that an ill-typed one is rejected. Each case below
  is one clause of the typing judgment, checked by its message and its
  position — an unbound name, a construct handed the wrong kind of answer, an
  interpolation of something that is not text, a panel whose members disagree,
  a panel at a kind that carries no monoid, a block that ends with an answer a
  closed workflow has nowhere to return, and the four mistakes the braced
  grammar newly makes it possible to write.

* **What a hostile source costs.** `revising a up to n revisions` is the one
  construct whose *numeral* is a size: it elaborates to `Plan.revising … n`, an
  unrolling `n` deep. `Dsl.checkBlock_bounded` proves that the checker names no `n` above
  `Dsl.maxRevisions`; what a proof cannot say is how long the bound it allows
  actually takes, so the last section here checks the refusal's diagnosis and
  then prices, folds and *runs* a program at the bound, with a wall clock. The
  numbers are the point: before the delayed tail of `Env`, `Mcp.costSummary` at
  `up to 24 revisions` took 122 s and at a billion aborted the process with a
  stack overflow in 0.3 s.
-/

open Agentic.Core
open Agentic.Core.Dsl

/-- One assertion, reported the way the other smoke tests report theirs. -/
def check (what want got : String) : IO Unit :=
  if want == got then pure () else
    throw <| IO.userError s!"FAIL {what}\n  want: {want}\n  got:  {got}"

/-- …and one that only has to hold. -/
def checkTrue (what : String) (b : Bool) : IO Unit :=
  if b then pure () else throw <| IO.userError s!"FAIL {what}"

/-- The outcome of a source text, as one line: `ok` or the diagnosis. -/
def outcome (src : String) : String :=
  match parseAndCheck src with
  | .ok _ => "ok"
  | .error e => e

/-- A rejection is checked by its *whole* rendered diagnosis, position included,
because a message that moves is a message a reader cannot act on. -/
def rejects (what src want : String) : IO Unit := check what want (outcome src)

/-! ## The programs that must be refused -/

/-- A name nothing binds. -/
def srcUnbound : String :=
  r#"workflow { let g = ask tool "cat" for text "read {nowhere}" }"#

/-- A branching on something that is not a flag. `if` is the two-valued
branching, so `if` on a text answer is a kind error and not a missing arm. -/
def srcWrongKind : String :=
  r#"workflow { let g = ask tool "cat" for text "hi"
           if g { } else { } }"#

/-- An interpolation of a verdict. `El .text = String` and nothing else embeds
in a string without a choice of renderer. -/
def srcInterpNonText : String :=
  r#"workflow { let v = ask model "m" for verdict "hi"
           let g = ask tool "cat" for text "quoting {v}" }"#

/-- A panel whose second member answers a different kind from its first. -/
def srcPanelDisagrees : String :=
  r#"workflow { let g = ask tool "cat" for text "hi"
           let p = panel [ ask model "a" for verdict "x",
                           ask model "b" for text "y" ] }"#

/-- A panel of flags. Nothing installs a monoid on `El .flag = Bool`, and a
panel is a fold in the monoid of its members' kind. -/
def srcPanelNoMonoid : String :=
  r#"workflow { let g = ask tool "cat" for text "hi"
           let p = panel [ ask person "o" for flag "x" ] }"#

/-- A workflow that ends with an answer. A closed program is a `Plan [] Unit`,
so there is nowhere for a value to go — and a block that wanted nothing further
would have said so by ending. -/
def srcNonUnit : String :=
  r#"workflow { let g = ask tool "cat" for text "hi"
           ask tool "cat" for text "and again" }"#

/-- A `check` clause that does not produce a verdict: `Plan.revising` reviews
with a `Cont … Verdict` and nothing else. -/
def srcCheckNotVerdict : String :=
  r#"workflow { let d = ask model "a" for text "draft"
           revising d up to 1 revisions {
             check given p { ask model "r" for text "look at {p}" }
             revise given p, why { ask model "a" for text "fix {p} {why}" }
           }
           approved given p { }
           never approved { } }"#

/-- A source that is not syntax at all, to check that a parse failure reports a
position and an expected token like every other failure. -/
def srcParseError : String :=
  r#"workflow { let g = ask tool "cat" for text "hi" oops }"#

/-! ### …and the five the *new* grammar makes newly expressible

Braced blocks with an optional tail, a bounded revision whose outcomes are
written after its braces, and an `ask` whose three prepositions come in a fixed
order are each a thing a reader may reasonably write wrongly. Each has a refusal
of its own, and each refusal names the construct. -/

/-- Binding a bounded revision. It produces an `Option (El c)`, and `Ctx = List
Code` has no room for one, so it is not an answer to bind. -/
def srcBindRevising : String :=
  r#"workflow { let d = ask model "a" for text "draft"
           let p = revising d up to 1 revisions { } }"#

/-- A statement after a tail. A tail is the last thing in its block: each arm
and each outcome *is* the rest of the workflow. -/
def srcAfterTail : String :=
  r#"workflow { act tool "t" "go"
           let g = ask tool "cat" for text "hi" }"#

/-- A bounded revision with only one outcome written. -/
def srcNoApproved : String :=
  r#"workflow { let d = ask model "a" for text "draft"
           revising d up to 1 revisions {
             check given p { ask model "r" for verdict "review {p}" }
             revise given p, why { ask model "a" for text "fix {p} {why}" }
           }
           never approved { } }"#

/-- …and one with the other outcome missing. -/
def srcNoNeverApproved : String :=
  r#"workflow { let d = ask model "a" for text "draft"
           revising d up to 1 revisions {
             check given p { ask model "r" for verdict "review {p}" }
             revise given p, why { ask model "a" for text "fix {p} {why}" }
           }
           approved given p { } }"#

/-- `using model` written after the kind rather than beside the addressee. The
one word order the grammar fixes, and the one it exists to fix: written here it
would put two string literals side by side. -/
def srcUsingAfterFor : String :=
  r#"workflow { let d = ask model "a" for text using model "deep" "draft" }"#

/-- The old flag spelling of `case`, which is now `if … else`. -/
def srcCaseYesNo : String :=
  r#"workflow { let ok = ask person "o" for flag "yes?"
           case ok { yes { } no { } } }"#

/-- A bounded revision whose bound is chosen by whoever wrote the source. The
one construct whose numeral is a recursion depth. -/
def srcRevising (n : Nat) : String :=
  "workflow { let d = ask model \"a\" for text \"draft\"\n" ++
  s!"           revising d up to {n} revisions " ++ "{\n" ++
  "             check given p { ask model \"r\" for verdict \"review {p}\" }\n" ++
  "             revise given p, why { ask model \"a\" for text \"fix {p} {why}\" }\n" ++
  "           }\n" ++
  "           approved given p { act tool \"t\" \"apply {p}\" }\n" ++
  "           never approved { } }"

/-! ## The programs that must be accepted -/

/-- Branching on a verdict's finite classifier, which the flagship does not
use and the language has. -/
def srcCaseVerdict : String :=
  r#"workflow { let v = ask model "r" for verdict "is it ok?"
           case v { approve { act tool "t" "go" }
                    object  { }
                    declined { } } }"#

/-- `draw`, comments, and a closed act — the corners the flagship does not
reach. -/
def srcCorners : String :=
  r#"-- a resampled question, and a closed terminal act
workflow {
  let a = ask model "m" draw 1 for text "say something"
  act tool "t" "done here"
}"#

/-- The empty workflow, which the language can now write and which is exactly
`Plan.ret`. There is no word for it, because a list that runs out is over. -/
def srcEmpty : String := "workflow { }"

/-- The singular spelling of the unit, so that `up to 1 revision` is English. It
is the only word in the language with two spellings, and both denote the same
numeral. -/
def srcSingularRevision : String :=
  r#"workflow { let d = ask model "a" for text "draft"
           revising d up to 1 revision {
             check given p { ask model "r" for verdict "review {p}" }
             revise given p, why { ask model "a" for text "fix {p} {why}" }
           }
           approved given p { act tool "t" "apply {p}" }
           never approved { } }"#

def main : IO UInt32 := do
  IO.println "dsl smoke: the parser against the flagship, and every rejection"
  try
    -- 1. The parser reads the flagship source as the raw syntax
    -- `Agentic/Core/DslFlagship.lean` proves about. This is the hypothesis of
    -- `Dsl.parseAndCheck_flagship`, and the only thing in the DSL that is
    -- checked rather than proved.
    match Dsl.parse flagshipSource with
    | .error e => throw <| IO.userError s!"FAIL the flagship does not parse: {e}"
    | .ok r =>
      checkTrue "the flagship parses to Dsl.flagshipRaw" (decide (r = flagshipRaw))
    -- …and therefore the front end returns `flagshipPlan`.
    check "the flagship checks" "ok" (outcome flagshipSource)
    -- The rung, at run time, against the theorem that says it in the kernel.
    let rung : String :=
      match parseAndCheck flagshipSource with
      | .error e => s!"did not check: {e}"
      | .ok p => toString (repr (level p))
    check "…and the parsed flagship is at the branch rung"
      "Agentic.Core.Level.branch" rung

    -- 2. Every rejection the typing judgment owes, by its exact diagnosis.
    rejects "an unbound name is refused" srcUnbound
      "1:20: unbound name; nothing in scope answers to it at `nowhere`"
    rejects "an `if` on a text answer is refused" srcWrongKind
      "2:12: an `if` branches on a flag, but `g` answers `text` at `g`"
    rejects "interpolating a verdict is refused" srcInterpNonText
      "2:20: only a text answer interpolates into a prompt, but `v` answers `verdict` at `v`"
    rejects "a panel whose members disagree is refused" srcPanelDisagrees
      "3:28: the members of a panel must agree in answer kind, and this one disagrees with \
       the first: expected an answer of kind `verdict`, but this question asks for `text` \
       at `text`"
    rejects "a panel at a kind with no monoid is refused" srcPanelNoMonoid
      "2:20: a panel combines its members' answers in the monoid of their kind, and only \
       `verdict` carries one; these answer `flag` at `panel`"
    rejects "a workflow that ends with an answer is refused" srcNonUnit
      "2:12: a question here has nowhere to put its answer: write `let x = ask …`, or \
       `act` if the point is the doing at `ask`"
    rejects "a `check` clause that is not a verdict is refused" srcCheckNotVerdict
      "3:30: the `check` clause of a bounded revision: expected an answer of kind `verdict`, \
       but this one produces `text` at `text`"
    rejects "an unfinished block is refused, with a position" srcParseError
      "1:49: expected a statement (`let`), a tail (`act`, `if`, `case`, `revising`), or `}` \
       at `oops`"

    -- …and the five the braced grammar makes newly expressible. Each names the
    -- construct it is about; none of them is a bare "syntax error".
    rejects "binding a bounded revision is refused, by name" srcBindRevising
      "2:20: a bounded revision has two outcomes and is not an answer to bind: write its \
       `approved given …` and `never approved` clauses after its braces at `revising`"
    rejects "a statement after a tail is refused" srcAfterTail
      "2:12: expected `}`: `act`, `if`, `case` and `revising` are tails, and a tail ends \
       its block — each arm and each outcome is the rest of the workflow at `let`"
    rejects "a bounded revision missing its `approved` outcome is refused" srcNoApproved
      "6:12: expected `approved given <name> { … }`: a bounded revision writes both of its \
       outcomes at `never`"
    rejects "…and one missing `never approved` likewise" srcNoNeverApproved
      "6:33: expected `never approved { … }`: a bounded revision writes both of its \
       outcomes, and this is the one in which there is no artefact to hand over at `}`"
    rejects "`using model` after the kind is refused, and says where it goes" srcUsingAfterFor
      "1:43: `using model` says which model serves the addressee, so it is written beside \
       the addressee and before `for`: `ask <addressee> \"name\" using model \"m\" for \
       <kind> \"words\"` at `using`"
    rejects "`case` on a flag is refused, and says where the branching went" srcCaseYesNo
      "2:22: expected the arms of a verdict branching, all three: `approve`, `object` and \
       `declined` (a two-way branching on a flag is `if … else`) at `yes`"

    -- 3. A source-chosen recursion depth is refused above the bound, and
    -- affordable at it. `Dsl.checkBlock_bounded` proves the first half in the
    -- kernel; the wall clock below is the half no theorem states.
    rejects "a revision bound above `maxRevisions` is refused"
      (srcRevising (maxRevisions + 1))
      s!"2:12: a bounded revision is unrolled into the term it writes, so its bound may \
         name at most {maxRevisions} revisions at `up to {maxRevisions + 1} revisions`"
    rejects "…and the numeral that killed the server is refused the same way"
      (srcRevising 1000000000)
      s!"2:12: a bounded revision is unrolled into the term it writes, so its bound may \
         name at most {maxRevisions} revisions at `up to 1000000000 revisions`"
    check "…and the bound itself is accepted" "ok" (outcome (srcRevising maxRevisions))

    -- The three folds a client can provoke with one `workflow_check`, at the
    -- worst bound the checker allows, against a clock. The budget is loose on
    -- purpose — it is a guard against the exponential coming back, not a
    -- benchmark — and the exponential it guards against needed 122 s at
    -- `up to 24 revisions`, which is a third of this bound.
    match hb : parseAndCheckE (srcRevising maxRevisions) with
    | .error e => throw <| IO.userError s!"FAIL the bound does not check: {e}"
    | .ok p =>
      let h := parseAndCheck_level_le _ p ((parseAndCheck_ok_iff _ p).mpr hb)
      let t0 ← IO.monoMsNow
      let τ := costTree tick p h Env.nil
      let leaves := Multiset.card τ.leaves
      let priced := decide (τ.maxFold ≠ ⊥)
      let t1 ← IO.monoMsNow
      check s!"…and its cost tree has 2n+2 leaves at n={maxRevisions}"
        (toString (2 * maxRevisions + 2)) (toString leaves)
      checkTrue "…and the worst path is priced" priced
      checkTrue s!"…and pricing it took under a second (took {t1 - t0} ms)"
        (t1 - t0 < 1000)
      -- …and running it to the `never approved` arm, which is the deepest path
      -- there is: every check objects, so every revision is bought.
      let ωObject : Ω := fun c => match c with
        | .text => fun _ => "a patch" | .verdict => fun _ => Verdict.object ["no"]
        | .flag => fun _ => false | .ack => fun _ => ()
      let t2 ← IO.monoMsNow
      let tr := Plan.trace ωObject p Env.nil
      let t3 ← IO.monoMsNow
      check s!"…and the deepest run asks 2n+2 questions at n={maxRevisions}"
        (toString (2 * maxRevisions + 2)) (toString tr.length)
      checkTrue s!"…and running it took under a second (took {t3 - t2} ms)"
        (t3 - t2 < 1000)

    -- 4. The corners the flagship does not reach.
    check "branching on a verdict's classifier is accepted" "ok" (outcome srcCaseVerdict)
    check "comments, `draw` and a closed act are accepted" "ok" (outcome srcCorners)
    check "the empty workflow is accepted" "ok" (outcome srcEmpty)
    check "`up to 1 revision` is accepted, spelled in the singular" "ok"
      (outcome srcSingularRevision)
    -- …and both spellings of the unit denote the same numeral, which is what
    -- makes the second spelling a spelling rather than a second construct.
    checkTrue "…and the two spellings of the unit parse to one term"
      (match parse srcSingularRevision, parse (srcRevising 1) with
       | .ok a, .ok b => decide (a = b)
       | _, _ => false)

    -- …and `draw n` reaches the question, which is what makes resampling a
    -- different question rather than a stateful operation.
    let ω : Ω := fun c => match c with
      | .text => fun _ => "" | .verdict => fun _ => Verdict.approve
      | .flag => fun _ => true | .ack => fun _ => ()
    let tr : Trace :=
      match parseAndCheck srcCorners with
      | .error _ => []
      | .ok p => Plan.trace ω p Env.nil
    check "…and a resampled question carries its draw" "1"
      (match tr with | e :: _ => toString e.q.draw | [] => "no events")
    check "…and the act is the second and last event" "2" (toString tr.length)

    IO.println "dsl smoke: all checks passed"
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"dsl smoke: {e}"
    return 1
