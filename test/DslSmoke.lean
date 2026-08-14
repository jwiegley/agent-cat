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
  a panel at a kind that carries no monoid, and a block that ends with an answer
  a closed workflow has nowhere to return.

* **What a hostile source costs.** `revising a upto n` is the one construct
  whose *numeral* is a size: it elaborates to `Plan.revising … n`, an unrolling
  `n` deep. `Dsl.checkBlock_bounded` proves that the checker names no `n` above
  `Dsl.maxRevisions`; what a proof cannot say is how long the bound it allows
  actually takes, so the last section here checks the refusal's diagnosis and
  then prices, folds and *runs* a program at the bound, with a wall clock. The
  numbers are the point: before the delayed tail of `Env`, `Mcp.costSummary` on
  `upto 24` took 122 s and `upto 1000000000` aborted the process with a stack
  overflow in 0.3 s.
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
  r#"workflow { let g = ask text tool "cat" "read {nowhere}" done }"#

/-- A branching on something that is not a flag. `case`'s arms *are* the
branching, so `yes`/`no` on a text answer is a kind error and not a missing
arm. -/
def srcWrongKind : String :=
  r#"workflow { let g = ask text tool "cat" "hi"
           case g { yes -> { done } no -> { done } } }"#

/-- An interpolation of a verdict. `El .text = String` and nothing else embeds
in a string without a choice of renderer. -/
def srcInterpNonText : String :=
  r#"workflow { let v = ask verdict model "m" "hi"
           let g = ask text tool "cat" "quoting {v}"
           done }"#

/-- A panel whose second member answers a different kind from its first. -/
def srcPanelDisagrees : String :=
  r#"workflow { let g = ask text tool "cat" "hi"
           let p = panel [ ask verdict model "a" "x",
                           ask text model "b" "y" ]
           done }"#

/-- A panel of flags. Nothing installs a monoid on `El .flag = Bool`, and a
panel is a fold in the monoid of its members' kind. -/
def srcPanelNoMonoid : String :=
  r#"workflow { let g = ask text tool "cat" "hi"
           let p = panel [ ask flag person "o" "x" ]
           done }"#

/-- A workflow that ends with an answer. A closed program is a `Plan [] Unit`,
so there is nowhere for a value to go. -/
def srcNonUnit : String :=
  r#"workflow { let g = ask text tool "cat" "hi"
           ask text tool "cat" "and again" }"#

/-- A `check` clause that does not produce a verdict: `Plan.revising` reviews
with a `Cont … Verdict` and nothing else. -/
def srcCheckNotVerdict : String :=
  r#"workflow { let d = ask text model "a" "draft"
           revising d upto 1
             check (p) { ask text model "r" "look at {p}" }
             with (p, why) { ask text model "a" "fix {p} {why}" }
             accepted (p) { done }
             exhausted { done } }"#

/-- A source that is not syntax at all, to check that a parse failure reports a
position and an expected token like every other failure. -/
def srcParseError : String :=
  r#"workflow { let g = ask text tool "cat" "hi" }"#

/-- A bounded revision whose bound is chosen by whoever wrote the source. The
one construct whose numeral is a recursion depth. -/
def srcRevising (n : Nat) : String :=
  "workflow { let d = ask text model \"a\" \"draft\"\n" ++
  s!"           revising d upto {n}\n" ++
  "             check (p) { ask verdict model \"r\" \"review {p}\" }\n" ++
  "             with (p, why) { ask text model \"a\" \"fix {p} {why}\" }\n" ++
  "             accepted (p) { act tool \"t\" \"apply {p}\" }\n" ++
  "             exhausted { done } }"

/-! ## The programs that must be accepted -/

/-- Branching on a verdict's finite classifier, which the flagship does not
use and the language has. -/
def srcCaseVerdict : String :=
  r#"workflow { let v = ask verdict model "r" "is it ok?"
           case v { approve -> { act tool "t" "go" }
                    object  -> { done }
                    declined -> { done } } }"#

/-- `draw`, comments, and a closed act — the corners the flagship does not
reach. -/
def srcCorners : String :=
  r#"-- a resampled question, and a closed terminal act
workflow {
  let a = ask text model "m" draw 1 "say something"
  act tool "t" "done here"
}"#

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
    rejects "a flag branching on a text answer is refused" srcWrongKind
      "2:12: the arms `yes` and `no` branch on a `flag`, but `g` answers `text` at `g`"
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
      "2:12: a block ends in `done` or `act`; this one ends with an answer, and a closed \
       workflow has nowhere to return one at `ask`"
    rejects "a `check` clause that is not a verdict is refused" srcCheckNotVerdict
      "3:26: the `check` clause of a bounded revision: expected an answer of kind `verdict`, \
       but this one produces `text` at `text`"
    rejects "an unfinished block is refused, with a position" srcParseError
      "1:45: expected a statement (`let`) or a tail (`done`, `act`, `case`, `revising`) \
       at `}`"

    -- 3. A source-chosen recursion depth is refused above the bound, and
    -- affordable at it. `Dsl.checkBlock_bounded` proves the first half in the
    -- kernel; the wall clock below is the half no theorem states.
    rejects "a revision bound above `maxRevisions` is refused"
      (srcRevising (maxRevisions + 1))
      s!"2:12: a bounded revision is unrolled into the term it writes, so its bound may \
         name at most {maxRevisions} revisions at `upto {maxRevisions + 1}`"
    rejects "…and the numeral that killed the server is refused the same way"
      (srcRevising 1000000000)
      s!"2:12: a bounded revision is unrolled into the term it writes, so its bound may \
         name at most {maxRevisions} revisions at `upto 1000000000`"
    check "…and the bound itself is accepted" "ok" (outcome (srcRevising maxRevisions))

    -- The three folds a client can provoke with one `workflow_check`, at the
    -- worst bound the checker allows, against a clock. The budget is loose on
    -- purpose — it is a guard against the exponential coming back, not a
    -- benchmark — and the exponential it guards against needed 122 s at
    -- `upto 24`, which is a third of this bound.
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
      -- …and running it to the exhausted arm, which is the deepest path there
      -- is: every check objects, so every revision is bought.
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
