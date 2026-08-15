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
checks the things no proof in the package makes a statement about.

* **The parser.** Kernel reduction of the lexer is quadratic in the character
  count, so `parse flagshipSource = .ok flagshipRaw` is not a theorem;
  `native_decide` would close it and is forbidden, because it puts
  `Lean.ofReduceBool` into the axiom set `Agentic/Core/Certify.lean` pins. It is
  therefore checked *here*, by `decide` at run time on `DecidableEq Raw`, and
  `Dsl.parseAndCheck_flagship` is the theorem that takes it as a hypothesis.

* **Every rejection.** A checker is only as good as what it refuses, and what it
  refuses is not visible in the type of `check`. Each case below is one clause
  of the judgment, checked by its message and its position — the inference
  refusal for a name nothing grounds, the hole and branching kind mismatches,
  the define hygiene (duplicate, missing sigil, unknown sigil, an answer hole in
  a define, a binder that spells one), no-shadowing, the pending-result
  discipline, the panel's kind, the `served by` restriction, the `amend` head,
  the unit/numeral agreement, and the text-block refusals (mixed indentation,
  an unclosed fence).

* **The `case` arms reach distinct arms.** The verdict arm mapping
  (`approved`/`objected`/`no answer` → `VTag`) is constrained by no theorem — a
  permutation type-checks — so it is pinned here by running one plan under
  three worlds and asserting the arm-identifying act of each.

* **What a hostile source costs.** `revising … at most n amendments` is the one
  construct whose *numeral* is a size: it elaborates to `Plan.revising … n`.
  The checker refuses any `n` above `Dsl.maxRevisions`; the section below
  checks the refusal's diagnosis and then prices, folds and *runs* a program at
  the bound, with a wall clock.
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

/-- A name nothing binds, inside a prompt. -/
def srcUnbound : String :=
  r#"workflow { g : text <- ask tool "cat" "read {nowhere}" }"#

/-- A bound name with no ground use and no annotation: the kind of a question
is an observable of the question, and it has to come from somewhere. -/
def srcNoInfer : String :=
  r#"workflow { g <- ask tool "cat" "hi" }"#

/-- A conflict between the first ground use (a hole: text) and a later one
(an `if`: flag). The first use fixes the kind; the later one is refused by the
ordinary mismatch diagnosis. -/
def srcIfOnText : String :=
  r#"workflow { g <- ask tool "cat" "hi""# ++ "\n" ++
  r#"           n : text <- ask tool "t" "{g}""# ++ "\n" ++
  r#"           if g { stop } else { stop } }"#

/-- An interpolation of a flag, which has no canonical text. (A verdict does —
its objections — so `{v}` at a verdict is *accepted*; the render test below
pins what it splices.) -/
def srcInterpFlag : String :=
  r#"workflow { ok : flag <- ask person "o" "hi""# ++ "\n" ++
  r#"           g : text <- ask tool "cat" "quoting {ok}" }"#

/-- A verdict spliced into a prompt: the plan the render test runs to pin that
`{v}` at a verdict splices the objections, joined by `"; "`. -/
def srcInterpRender : String :=
  r#"workflow { v : verdict <- ask model "m" "judge this""# ++ "\n" ++
  r#"           ask tool "log" "said: {v}" }"#

/-- A panel bound at `text`: only `verdict` carries the monoid. -/
def srcPanelText : String :=
  r#"workflow { p : text <- panel, all must approve [ ask model "a" "x" ] }"#

/-- A panel without its rule phrase: once a menu exists, a bare `panel` is a
silent default, and the language refuses defaults. -/
def srcPanelBare : String :=
  r#"workflow { p <- panel [ ask model "a" "x" ] }"#

/-- A review binding annotated at something other than `verdict`. -/
def srcReviewText : String :=
  r#"workflow { d : text <- ask model "a" "draft""# ++ "\n" ++
  r#"           r <- revising d as c, at most 1 amendment {"# ++ "\n" ++
  r#"             v : text <- ask model "m" "{c}""# ++ "\n" ++
  r#"             amend c { ask model "a" "{c}" } }"# ++ "\n" ++
  r#"           case r { settled x { stop } unsettled { stop } } }"#

/-- A revising result nothing consumes. -/
def srcPendingUnconsumed : String :=
  r#"workflow { d : text <- ask model "a" "draft""# ++ "\n" ++
  r#"           r <- revising d as c, at most 1 amendment {"# ++ "\n" ++
  r#"             v <- ask model "m" "{c}""# ++ "\n" ++
  r#"             amend c { ask model "a" "{c} {v}" } } }"#

/-- A settled/unsettled `case` on a name that is not a revising result. -/
def srcCaseNotPending : String :=
  r#"workflow { g : text <- ask tool "cat" "hi""# ++ "\n" ++
  r#"           case g { settled x { stop } unsettled { stop } } }"#

/-- `{ }`: a path that does nothing says so. -/
def srcEmptyBraces : String := "workflow { }"

/-- Define hygiene, all five refusals. -/
def srcDupDefine : String := "define a = \"x\"\ndefine a = \"y\"\nworkflow { stop }"
def srcDefineNoSigil : String := "define spec = \"x\"\nworkflow { ask tool \"t\" \"do {spec}\" }"
def srcUnknownSigil : String := "workflow { ask tool \"t\" \"do {$spec}\" }"
def srcDefineAnswerHole : String := "define a = \"x {later}\"\nworkflow { stop }"
def srcBinderSpellsDefine : String :=
  "define a = \"x\"\nworkflow { a : text <- ask tool \"t\" \"hi\" }"

/-- No shadowing: a live name is not introduced twice. -/
def srcShadow : String :=
  r#"workflow { g : text <- ask tool "c" "a""# ++ "\n" ++
  r#"           g : text <- ask tool "c" "b" }"#

/-- A `known here` that asserts the wrong scope is refused, naming the truth. -/
def srcKnownWrong : String :=
  r#"workflow { g : text <- ask tool "c" "a""# ++ "\n" ++
  r#"           known here: nothing"# ++ "\n" ++
  r#"           stop }"#

/-- `served by` on a tool: only a model addressee is served by a model. -/
def srcServedOnTool : String :=
  r#"workflow { g : text <- ask tool "cat" served by "deep" "hi" }"#

/-- An `amend` head that does not name the loop's carrier. -/
def srcAmendWrongName : String :=
  r#"workflow { d : text <- ask model "a" "draft""# ++ "\n" ++
  r#"           r <- revising d as c, at most 1 amendment {"# ++ "\n" ++
  r#"             v <- ask model "m" "{c}""# ++ "\n" ++
  r#"             amend d { ask model "a" "{c} {v}" } }"# ++ "\n" ++
  r#"           case r { settled x { stop } unsettled { stop } } }"#

/-- The unit agrees with its numeral, in both directions. -/
def srcPluralOne : String :=
  r#"workflow { d : text <- ask model "a" "draft""# ++ "\n" ++
  r#"           r <- revising d as c, at most 1 amendments {"# ++ "\n" ++
  r#"             v <- ask model "m" "{c}""# ++ "\n" ++
  r#"             amend c { ask model "a" "{c} {v}" } }"# ++ "\n" ++
  r#"           case r { settled x { stop } unsettled { stop } } }"#
def srcSingularTwo : String :=
  r#"workflow { d : text <- ask model "a" "draft""# ++ "\n" ++
  r#"           r <- revising d as c, at most 2 amendment {"# ++ "\n" ++
  r#"             v <- ask model "m" "{c}""# ++ "\n" ++
  r#"             amend c { ask model "a" "{c} {v}" } }"# ++ "\n" ++
  r#"           case r { settled x { stop } unsettled { stop } } }"#

/-- The old flag spelling of `case`, which is `if … else` now. -/
def srcOldCase : String :=
  r#"workflow { ok : flag <- ask person "o" "yes?""# ++ "\n" ++
  r#"           case ok { yes { stop } no { stop } } }"#

/-- Text blocks: mixed indentation, and a fence nothing closes. -/
def srcMixedTabs : String :=
  "workflow {\n  g : text <- ask tool \"t\" ```\n    a\n\tb\n  ```\n}"
def srcUnclosedFence : String :=
  "workflow {\n  g : text <- ask tool \"t\" ```\n    a\n}"

/-- A bounded revision whose bound is chosen by whoever wrote the source. -/
def srcRevising (n : Nat) : String :=
  "workflow { d : text <- ask model \"a\" \"draft\"\n" ++
  s!"           r <- revising d as c, at most {n} amendments " ++ "{\n" ++
  "             v <- ask model \"m\" \"review {c}\"\n" ++
  "             amend c { ask model \"a\" \"fix {c} {v}\" }\n" ++
  "           }\n" ++
  "           case r { settled x { ask tool \"t\" \"apply {x}\" }\n" ++
  "                    unsettled { stop } } }"

/-! ## The programs that must be accepted -/

/-- Branching on a verdict's finite classifier, with an arm-identifying act in
each arm — the plan the arm-distinctness section below runs. -/
def srcCaseVerdict : String :=
  r#"workflow { v <- ask model "r" "is it ok?""# ++ "\n" ++
  r#"           case v { approved { ask tool "t" "went-approved" }"# ++ "\n" ++
  r#"                    objected { ask tool "t" "went-objected" }"# ++ "\n" ++
  r#"                    no answer { ask tool "t" "went-noanswer" } } }"#

/-- `independent draw`, comments, an annotation on an unused name, and a
trailing act. -/
def srcCorners : String :=
  r#"-- a resampled question, an annotation, and a trailing act"# ++ "\n" ++
  r#"workflow {"# ++ "\n" ++
  r#"  a : text <- ask model "m" independent draw 1 "say something""# ++ "\n" ++
  r#"  ask tool "t" "done here""# ++ "\n" ++
  r#"}"#

/-- A `known here` that asserts the right scope. -/
def srcKnownRight : String :=
  r#"workflow { g : text <- ask tool "c" "a""# ++ "\n" ++
  r#"           known here: g"# ++ "\n" ++
  r#"           stop }"#

/-- The block corners the flagship does not reach: an escalated fence around an
inner three-backtick fence, a `\{` literal brace, a blank content line, a
quoted word, and a define-hole beside an answer-hole downstream. -/
def srcBlockCorners : String :=
  "define spec = \"S\"\nworkflow {\n  g <- ask tool \"t\" ````\n    a \\{brace} \"quoted\"\n\n" ++
  "    ```\n    fenced\n    ```\n    {$spec}\n  ````\n  ask tool \"log\" \"{g}\"\n}"

/-- One program, two prompt spellings: a text block and a quoted string. The
chunk identity — a block is the string its dedented join spells — is pinned by
the traces agreeing in a prompt-reading world. -/
def srcBlockSpelling : String :=
  "workflow {\n  g : text <- ask tool \"t\" ```\n    line one\n    line two\n  ```\n" ++
  "  ask tool \"log\" \"{g}\"\n}"
def srcStringSpelling : String :=
  "workflow {\n  g : text <- ask tool \"t\" \"line one\\nline two\"\n" ++
  "  ask tool \"log\" \"{g}\"\n}"

def main : IO UInt32 := do
  IO.println "dsl smoke: the parser against the flagship, and every rejection"
  try
    -- 1. The parser reads the flagship source as the raw syntax
    -- `Agentic/Core/DslFlagship.lean` proves about.
    match Dsl.parse flagshipSource with
    | .error e => throw <| IO.userError s!"FAIL the flagship does not parse: {e}"
    | .ok r =>
      checkTrue "the flagship parses to Dsl.flagshipRaw" (decide (r = flagshipRaw))
    check "the flagship checks" "ok" (outcome flagshipSource)
    let rung : String :=
      match parseAndCheck flagshipSource with
      | .error e => s!"did not check: {e}"
      | .ok p => toString (repr (level p))
    check "…and the parsed flagship is at the branch rung"
      "Agentic.Core.Level.branch" rung

    -- 2. Every rejection the judgment owes, by its exact diagnosis.
    rejects "an unbound name is refused" srcUnbound
      "1:24: unbound name; nothing in scope answers to it at `nowhere`"
    rejects "a name with nothing to infer from is refused, naming the annotation" srcNoInfer
      "1:12: nothing fixes what kind of answer `g` names: use it (a hole, an `if`, a \
       `case`), or annotate it — `g : text <- …` at `g`"
    rejects "the first use fixes the kind; a later `if` disagrees and is refused" srcIfOnText
      "3:12: an `if` branches on a flag, but `g` answers `text` at `g`"
    rejects "interpolating a flag is refused; it has no text of its own" srcInterpFlag
      "2:24: only a text or a verdict answer interpolates into a prompt — a verdict \
       splices as its objections — but `ok` answers `flag`, which has no text of its \
       own at `ok`"
    -- …and a verdict interpolates as its objections: the one canonical rendering,
    -- pinned by running the program in an objecting world.
    match parseAndCheckE srcInterpRender with
    | .error e => throw <| IO.userError s!"FAIL the render program does not check: {e}"
    | .ok p =>
      let ωObj : Ω := fun c => match c with
        | .text => fun _ => "" | .verdict => fun _ => Verdict.object ["too long", "unsafe"]
        | .flag => fun _ => true | .ack => fun _ => ()
      check "a verdict splices as its objections, joined"
        "said: too long; unsafe"
        (match (Plan.trace ωObj p Env.nil).getLast? with
         | some e => e.q.prompt
         | none => "no events")
    rejects "a panel bound at `text` is refused" srcPanelText
      "1:24: this binding: a panel combines its members in the verdict monoid, so it \
       answers `verdict`, not `text` at `panel`"
    rejects "a panel without its rule phrase is refused" srcPanelBare
      "1:23: expected `,` at `[`"
    rejects "a review annotated off `verdict` is refused" srcReviewText
      "2:17: a review answers `verdict`, not `text`: the loop settles when it approves \
       at `v`"
    rejects "an unconsumed revising result is refused" srcPendingUnconsumed
      "1:10: the revising result `r` is not yet consumed: `case r { settled … \
       unsettled … }` is the next statement, and nothing else touches it at `r`"
    rejects "a settled/unsettled case on a non-result is refused" srcCaseNotPending
      "2:12: `case g { settled … }` consumes a revising result, and `g` is not one: it \
       is bound by `g <- revising …` as the statement before its `case` at `g`"
    rejects "`{ }` is refused; doing nothing says so" srcEmptyBraces
      "1:10: a path that does nothing says so: write `stop` at `{`"
    rejects "a duplicate define is refused" srcDupDefine
      "2:1: this name is already defined, and the earlier body would silently win; one \
       define per name at `a`"
    rejects "a define holed without its sigil is refused" srcDefineNoSigil
      "2:25: `spec` is a define, and a define's hole carries the sigil: write it with \
       `$` after the opening brace at `spec`"
    rejects "a sigil hole with no define is refused" srcUnknownSigil
      "1:25: no define answers to this hole; a `{$name}` names an earlier `define` at \
       `spec`"
    rejects "an answer hole inside a define is refused" srcDefineAnswerHole
      "1:12: a define is literal text: only `{$name}` holes of earlier defines are \
       legal in one at `a`"
    rejects "a binder that spells a define is refused" srcBinderSpellsDefine
      "2:12: a binder may not spell a define; one of the two must be renamed at `a`"
    rejects "shadowing a live name is refused" srcShadow
      "2:12: this name is already in scope, and a live name is not introduced twice; \
       rename one of the two at `g`"
    rejects "a wrong `known here` is refused, naming the truth" srcKnownWrong
      "2:12: `known here` asserts the names in scope, innermost first, and they are: g"
    rejects "`served by` on a tool is refused" srcServedOnTool
      "1:39: `served by` names the model that serves a model addressee; a tool or a \
       person is not served by one at `served`"
    rejects "an `amend` head off the carrier is refused" srcAmendWrongName
      "2:54: the `amend` head names the loop's carrier: write `amend c` at `d`"
    rejects "`at most 1 amendments` is refused; the unit agrees with its numeral" srcPluralOne
      "2:44: one amendment: the unit agrees with its numeral at `amendments`"
    rejects "…and `at most 2 amendment` likewise" srcSingularTwo
      "2:44: 2 amendments: the unit agrees with its numeral at `amendment`"
    rejects "`case` on a flag is refused, and says where the branching went" srcOldCase
      "2:22: expected an arm: `approved` (a verdict's three) or `settled` (a \
       revision's two); a flag branches with `if … else` at `yes`"
    rejects "a block mixing tabs and spaces is refused" srcMixedTabs
      "2:28: this block mixes tabs and spaces in its indentation"
    rejects "a fence nothing closes is refused, at the fence" srcUnclosedFence
      "2:28: this fence of 3 backticks is never closed"

    -- 3. A source-chosen recursion depth is refused above the bound, and
    -- affordable at it.
    rejects "an amendment bound above `maxRevisions` is refused"
      (srcRevising (maxRevisions + 1))
      s!"2:17: a bounded revision is unrolled into the term it writes, so its bound may \
         name at most {maxRevisions} amendments at `at most {maxRevisions + 1} amendments`"
    rejects "…and the numeral that killed the server is refused the same way"
      (srcRevising 1000000000)
      s!"2:17: a bounded revision is unrolled into the term it writes, so its bound may \
         name at most {maxRevisions} amendments at `at most 1000000000 amendments`"
    check "…and the bound itself is accepted" "ok" (outcome (srcRevising maxRevisions))

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

    -- 4. The verdict arms reach distinct arms: the mapping to `VTag` is pinned
    -- by running the plan, because no theorem constrains it.
    match parseAndCheckE srcCaseVerdict with
    | .error e => throw <| IO.userError s!"FAIL the case program does not check: {e}"
    | .ok p =>
      let armOf (v : Verdict) : String :=
        let ω : Ω := fun c => match c with
          | .text => fun _ => "" | .verdict => fun _ => v
          | .flag => fun _ => true | .ack => fun _ => ()
        match (Plan.trace ω p Env.nil).getLast? with
        | some e => e.q.prompt
        | none => "no events"
      check "an approval reaches the `approved` arm" "went-approved" (armOf Verdict.approve)
      check "an objection reaches the `objected` arm" "went-objected"
        (armOf (Verdict.object ["no"]))
      check "a decline reaches the `no answer` arm" "went-noanswer"
        (armOf Verdict.declined)

    -- 5. The corners the flagship does not reach.
    check "comments, `independent draw` and an annotation are accepted" "ok"
      (outcome srcCorners)
    check "a right `known here` is accepted" "ok" (outcome srcKnownRight)
    check "the block corners are accepted (escalated fence, \\{, blank line, {$…})" "ok"
      (outcome srcBlockCorners)

    -- …and `independent draw n` reaches the question, which is what makes
    -- resampling a different question rather than a stateful operation.
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

    -- 6. A block is the string its dedented join spells: the two spellings of
    -- one program put the same questions in a world that reads prompts.
    let ωEchoish : Ω := fun c => match c with
      | .text => fun q => q.prompt | .verdict => fun _ => Verdict.approve
      | .flag => fun _ => true | .ack => fun _ => ()
    let traceOf (src : String) : Trace :=
      match parseAndCheck src with
      | .error _ => []
      | .ok p => Plan.trace ωEchoish p Env.nil
    checkTrue "a block prompt and its quoted spelling are one program"
      (decide (traceOf srcBlockSpelling = traceOf srcStringSpelling)
        && (traceOf srcBlockSpelling).length == 2)

    IO.println "dsl smoke: all checks passed"
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"dsl smoke: {e}"
    return 1
