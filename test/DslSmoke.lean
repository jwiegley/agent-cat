import Agentic.Core.DslFlagship
import DslCases

/-!
# The DSL, driven end to end: the complete battery

Run from the repository root:

```
lake exe dsl_smoke
```

Two layers, and what "complete" means for each.

The case tables themselves — `batteryCases`, `batteryCasesM`, the `semSrc*`
sources and their shared preludes — live in `test/DslCases.lean`, imported
here and by the corpus generator (`test/CorpusGen.lean`), which freezes their
observations under `test/corpus/`.

* **`batteryCases`** — one case per behavior of the surface: every grammar
  production accepted by a program that uses it, and every refusal site in
  `Agentic/Core/Dsl/{Parse,Check}.lean` reached by a program that trips it,
  checked against its *whole* rendered diagnosis, position included, because a
  message that moves is a message a reader cannot act on. The case list was
  cross-checked mechanically against the refusal-site inventory of both
  modules: every `.error` in the parser and the checker is hit, with two
  classes of exception named below rather than hidden.

  1. *The six fuel branches* (`internal: … budget exhausted`) are unreachable
     by the budget invariant — every recursion is seeded with the input's
     length and every step consumes at least one item — which is documented,
     not proved, in `Agentic/Core/DslFlagship.lean`'s "What is not proved".
  2. *`a panel needs at least one member`* is unreachable from source text —
     the parser cannot produce an empty member list — and guards the
     hand-built-`Raw` entry point, so it is tested here against a hand-built
     `Raw`.

* **The semantic sections** — what a table of sources cannot say: that the
  flagship parses to the `Raw` the kernel proofs are about; that the verdict
  arms reach *distinct* arms through parsed source (the ∀-statement is
  `Dsl.checkBlock_caseVerdict_arms`; this is its fixture witness, and the one
  that would catch the arms' *words* drifting); what a `{v}` hole splices in each of a verdict's
  three states; that an `--define` override changes exactly the words it names
  and refuses a name the program never defined; that a source-chosen recursion
  depth is affordable at the bound (with a wall clock, because the exponential
  it guards against was real); that `independent draw` reaches the question;
  and that a text block and its quoted spelling are one program.
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

/-- …and the same reading, with modules handed over the way the CLI hands
them. -/
def outcomeM (mods : List (String × String)) (src : String) : String :=
  match parseAndCheckProgramWith [] mods src with
  | .ok _ => "ok"
  | .error e => e.render


/-! ## The discovery pins (round fourteen): what a run must observe

Each expectation below was stated independently of the implementation — by the
discovery pass, from the grammar's rules — and is NOT regenerated from observed
output, so a failure here is a bug or a wrong reading of the rules, never a
baseline to refresh. -/

/-- The events of a source under a world, or `[]` where it does not check. -/
def evsOf (ω : Ω) (src : String) : List Event :=
  match parseAndCheckE src with
  | .error _ => []
  | .ok p => Plan.trace ω p Env.nil

/-- …and with overrides and modules, for the pins that need either. -/
def evsOfM (ω : Ω) (ov : List (String × Prompt)) (mods : List (String × String))
    (src : String) : List Event :=
  match parseAndCheckProgramWith ov mods src with
  | .error _ => []
  | .ok p => Plan.trace ω p Env.nil

def promptAt (evs : List Event) (i : Nat) : String :=
  match evs.drop i with | e :: _ => e.q.prompt | [] => "<none>"

def codesOf (evs : List Event) : String :=
  String.intercalate "," (evs.map fun e => codeName e.c)

def drawsOf (evs : List Event) : String :=
  String.intercalate "," (evs.map fun e => toString e.q.draw)

/-- A world from one function per kind, echoing prompts by default. -/
def world (t : Q .text → String := fun q => q.prompt)
    (v : Q .verdict → Verdict := fun _ => Verdict.approve)
    (f : Q .flag → Bool := fun _ => true) : Ω := fun c =>
  match c with
  | .text => t | .verdict => v | .flag => f | .ack => fun _ => ()


/-! ## What a table of sources cannot say -/

/-- Branching on a verdict, with an arm-identifying act in each arm. -/
def srcCaseVerdict : String :=
  r#"workflow { v <- ask model "r" "is it ok?""# ++ "\n" ++
  r#"           case v { approved { ask tool "t" "went-approved" }"# ++ "\n" ++
  r#"                    objected { ask tool "t" "went-objected" }"# ++ "\n" ++
  r#"                    no answer { ask tool "t" "went-noanswer" } } }"#

/-- A verdict spliced into a prompt, for the render pins. -/
def srcInterpRender : String :=
  r#"workflow { v : verdict <- ask model "m" "judge this""# ++ "\n" ++
  r#"           ask tool "log" "said: {v}" }"#

/-- `independent draw`, an annotation, and a trailing act. -/
def srcCorners : String :=
  r#"workflow {"# ++ "\n" ++
  r#"  a : text <- ask model "m" independent draw 1 "say something""# ++ "\n" ++
  r#"  ask tool "t" "done here""# ++ "\n" ++
  r#"}"#

/-- One program, two prompt spellings. -/
def srcBlockSpelling : String :=
  "workflow {\n  g : text <- ask tool \"t\" ```\n    line one\n    line two\n  ```\n" ++
  "  ask tool \"log\" \"{g}\"\n}"
def srcStringSpelling : String :=
  "workflow {\n  g : text <- ask tool \"t\" \"line one\\nline two\"\n" ++
  "  ask tool \"log\" \"{g}\"\n}"

/-- An overridable program, for the `--define` path. -/
def srcOverridable : String :=
  "define spec = \"old words\"\nworkflow { ask tool \"t\" \"do {spec}\" }"

/-- A bounded revision at the checker's own bound. -/
def srcAtBound : String :=
  "workflow { d : text <- ask model \"a\" \"draft\"\n" ++
  s!"           r <- revising d as c, at most {maxRevisions} amendments " ++ "{\n" ++
  "             v <- ask model \"m\" \"review {c}\"\n" ++
  "             amend c { ask model \"a\" \"fix {c} {v}\" }\n" ++
  "           }\n" ++
  "           case r { settled x { ask tool \"t\" \"apply {x}\" }\n" ++
  "                    unsettled { stop } } }"

def main : IO UInt32 := do
  IO.println "dsl smoke: the battery, the flagship, and the semantics"
  try
    -- 0. Every construction, and every mistaken use of one.
    for (what, src, want) in batteryCases do
      check what want (outcome src)
    for (what, mods, src, want) in batteryCasesM do
      check what want (outcomeM mods src)
    IO.println s!"battery: {batteryCases.length + batteryCasesM.length} cases"

    -- 1. The parser reads the flagship source as the raw syntax the kernel
    -- proofs are about — the hypothesis of `Dsl.parseAndCheck_flagship`.
    match Dsl.parseProgramWith [] [] flagshipSource with
    | .error e => throw <| IO.userError s!"FAIL the flagship does not parse: {e}"
    | .ok prog =>
      checkTrue "the flagship parses to Dsl.flagshipProgram"
        (decide (prog = flagshipProgram))
    check "the flagship checks" "ok" (outcome flagshipSource)
    let rung : String :=
      match parseAndCheck flagshipSource with
      | .error e => s!"did not check: {e}"
      | .ok p => toString (repr (level p))
    check "…and the parsed flagship is at the branch rung"
      "Agentic.Core.Level.branch" rung

    -- 2. The one refusal no source text can reach: a hand-built `Raw` with an
    -- empty panel, at the entry point that exists for hand-built `Raw`s.
    let emptyPanel : Raw :=
      RawBlock.bind "p" none
        (RawSource.rhs (RawRhs.panel [] { line := 1, col := 1 }))
        (RawBlock.empty { line := 1, col := 1 }) { line := 1, col := 1 }
    check "an empty panel is refused at the hand-built entry point"
      "1:1: a panel needs at least one member at `panel`"
      (match Dsl.check [] [] emptyPanel with
       | .ok _ => "ok"
       | .error e => toString e)

    -- 3. The verdict arms reach distinct arms — `Dsl.checkBlock_caseVerdict_arms`
    -- is the ∀-statement; running the plan here is the fixture witness through
    -- the parser, which the theorem does not touch.
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

    -- 4. What a `{v}` hole splices, in each of a verdict's three states.
    match parseAndCheckE srcInterpRender with
    | .error e => throw <| IO.userError s!"FAIL the render program does not check: {e}"
    | .ok p =>
      let saidOf (v : Verdict) : String :=
        let ω : Ω := fun c => match c with
          | .text => fun _ => "" | .verdict => fun _ => v
          | .flag => fun _ => true | .ack => fun _ => ()
        match (Plan.trace ω p Env.nil).getLast? with
        | some e => e.q.prompt
        | none => "no events"
      check "objections splice joined by \"; \"" "said: too long; unsafe"
        (saidOf (Verdict.object ["too long", "unsafe"]))
      check "an approval splices as nothing" "said: " (saidOf Verdict.approve)
      check "a decline splices as nothing" "said: " (saidOf Verdict.declined)

    -- 5. An override changes exactly the words it names; a name the program
    -- never defined is refused.
    match parseWith [("spec", [Chunk.lit "NEW WORDS"])] srcOverridable with
    | .error e => throw <| IO.userError s!"FAIL the override does not parse: {e}"
    | .ok r =>
      match check [] [] r with
      | .error e => throw <| IO.userError s!"FAIL the override does not check: {e}"
      | .ok p =>
        let ω : Ω := fun c => match c with
          | .text => fun _ => "" | .verdict => fun _ => Verdict.approve
          | .flag => fun _ => true | .ack => fun _ => ()
        check "an override replaces the define's words" "do NEW WORDS"
          (match (Plan.trace ω p Env.nil).head? with
           | some e => e.q.prompt
           | none => "no events")
    check "…and an override nobody asked for is refused"
      "2:1: this program has no `define nosuch` to override at `nosuch`"
      (match parseWith [("nosuch", [Chunk.lit "x"])] srcOverridable with
       | .ok _ => "ok"
       | .error e => toString e)

    -- 6. A source-chosen recursion depth is affordable at the bound. The wall
    -- clock is a guard against the exponential coming back, not a benchmark.
    match hb : parseAndCheckE srcAtBound with
    | .error e => throw <| IO.userError s!"FAIL the bound does not check: {e}"
    | .ok p =>
      let h := parseAndCheck_level_le _ p ((parseAndCheck_ok_iff _ p).mpr hb)
      let t0 ← IO.monoMsNow
      let τ := costM tick p h Env.nil
      let leaves := Multiset.card τ
      let priced := decide (maxFold τ ≠ ⊥)
      let t1 ← IO.monoMsNow
      check s!"the cost tree has 2n+2 leaves at n={maxRevisions}"
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

    -- 7. `independent draw n` reaches the question, which is what makes
    -- resampling a different question rather than a stateful operation.
    let ω : Ω := fun c => match c with
      | .text => fun _ => "" | .verdict => fun _ => Verdict.approve
      | .flag => fun _ => true | .ack => fun _ => ()
    let tr : Trace :=
      match parseAndCheck srcCorners with
      | .error _ => []
      | .ok p => Plan.trace ω p Env.nil
    check "a resampled question carries its draw" "1"
      (match tr with | e :: _ => toString e.q.draw | [] => "no events")
    check "…and the act is the second and last event" "2" (toString tr.length)

    -- 8. A block is the string its dedented join spells: the two spellings of
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


    -- 9. The discovery pins.
    -- 9a. Sharing: one binding, holed three times, asked once.
    let evs := evsOf (world) semSrc0
    check "sharing: three consumptions are three events, one text question" "3"
      (toString evs.length)
    check "sharing: the doubled hole splices one answer twice"
      "read the file||read the file" (promptAt evs 1)
    check "sharing: the third consumption reads the same answer"
      "seen: read the file" (promptAt evs 2)

    -- 9b. A loop that settles at round two of four.
    let evs := evsOf (world (v := fun q =>
      if q.prompt == "review draft" then Verdict.object ["too short"] else Verdict.approve))
      semSrc1
    check "early settlement: five events, not the nine of exhaustion"
      "text,verdict,text,verdict,receipt" (codesOf evs)
    check "…the amend is told the candidate and the objections"
      "amend draft given too short" (promptAt evs 2)
    check "…round two reviews the AMENDED candidate"
      "review amend draft given too short" (promptAt evs 3)
    check "…and the settled arm receives it"
      "apply amend draft given too short" (promptAt evs 4)

    -- 9c. Three panel members, answered differently: the fold is a read-out.
    let mixed : Ω := world (v := fun q =>
      if q.addressee = Addressee.model "alpha" then Verdict.object ["A"]
      else if q.addressee = Addressee.model "beta" then Verdict.approve
      else Verdict.object ["C"])
    let evs := evsOf mixed semSrc2
    check "a mixed panel is five events" "5" (toString evs.length)
    check "…objections concatenate in member order" "objections: A; C" (promptAt evs 3)
    check "…and the mixed panel objects" "went-objected" (promptAt evs 4)
    let evs := evsOf (world) semSrc2
    check "…while a unanimous one approves" "went-approved" (promptAt evs 4)

    -- 9d. A revising subject of kind verdict: the carrier splices rendered.
    let evs := evsOf (world (v := fun _ => Verdict.object ["too long"])) semSrc3
    check "a verdict carrier splices as its objections"
      "Is this judgment fair?\ntoo long" (promptAt evs 1)
    -- j itself answers a verdict, so all four events are verdicts: the bind,
    -- round one's review, the amend, and round two's review of an identical
    -- question, which the world (a function) must answer identically.
    check "…and a constant objection exhausts the loop"
      "verdict,verdict,verdict,verdict" (codesOf evs)
    let evs := evsOf (world) semSrc3
    check "…an approving world settles at once and cases the verdict"
      "went-approved" (promptAt evs 2)

    -- 9e. Names straddling an act: the act's weakening moves no index.
    let evs := evsOf (world) semSrc4
    check "an act between two bindings shifts neither" "AAA|BBB" (promptAt evs 3)

    -- 9f. The four kinds, as the codes actually asked.
    let evs := evsOf (world (t := fun _ => "TXT") (v := fun _ => Verdict.object ["OBJ"])) semSrc5
    check "the trace's codes are the annotations' kinds"
      "text,verdict,flag,receipt,receipt" (codesOf evs)
    check "…text and a verdict splice by kind" "record TXT and OBJ" (promptAt evs 3)
    check "…a true flag takes the yes arm" "went-yes" (promptAt evs 4)
    let evs := evsOf (world (f := fun _ => false)) semSrc5
    check "…a false flag takes the no arm, five events still" "went-no" (promptAt evs 4)

    -- 9g. Two draws of one prompt are two questions; one draw is one.
    let evs := evsOf (world (t := fun q => "draw" ++ toString q.draw)) semSrc6
    check "two identical asks are two events" "4" (toString evs.length)
    checkTrue "…of the same question"
      (match evs with | e0 :: e1 :: _ => decide (e0 = e1) | _ => false)
    checkTrue "…and the fresh draw is a different question"
      (match evs with | e0 :: _ :: e2 :: _ => decide (e2 ≠ e0) | _ => false)
    check "…whose answers the world keys on the draw" "draw0|draw0|draw1" (promptAt evs 3)

    -- 9h. A define-holed prompt is a closed question: same event in every world.
    let t1 := evsOf (world (t := fun _ => "AAA")) semSrc7
    let t2 := evsOf (world (t := fun _ => "BBB")) semSrc7
    checkTrue "a define-holed question is the same event in disagreeing worlds"
      (match t1, t2 with
       | [a1, b1], [a2, b2] => decide (b1 = b2) && decide (a1 ≠ a2)
       | _, _ => false)
    check "…and the program sits at the batch rung" "Agentic.Core.Level.batch"
      (match parseAndCheckE semSrc7 with
       | .ok p => toString (repr (level p))
       | .error e => s!"did not check: {e}")

    -- 9i. A revision bounded at zero amendments: the amend is written, never asked.
    let evs := evsOf (world (v := fun _ => Verdict.object ["no"])) semSrc8
    check "zero amendments, objecting: draft, one review, the unsettled act"
      "text,verdict,receipt" (codesOf evs)
    check "…which says so" "unsettled" (promptAt evs 2)
    checkTrue "…and no amend question was ever put"
      (!evs.isEmpty && evs.all (fun e => !(e.q.prompt.startsWith "fix")))
    let evs := evsOf (world) semSrc8
    check "zero amendments, approving: settled with the original" "settled draft"
      (promptAt evs 2)

    -- 9j. A loop at a flag carrier: settled receives the candidate, at a kind
    -- no prompt can show. (A closed review is one question, so its answer is
    -- one answer: the loop settles at once or exhausts — that is the world
    -- being a function, not a gap.)
    let evs := evsOf (world (f := fun q => q.prompt == "is it ready now?")) semSrc9
    check "an approving world settles with the original flag, which is false"
      "flag,verdict" (codesOf evs)
    let evs := evsOf (world (v := fun _ => Verdict.object ["not ready"])
                            (f := fun q => q.prompt == "is it ready now?")) semSrc9
    check "an objecting world exhausts through two flag amendments"
      "flag,verdict,flag,verdict,flag,verdict" (codesOf evs)
    checkTrue "…and ships nothing"
      (!evs.isEmpty && evs.all (fun e => e.q.prompt != "ship it"))

    -- 9k. Two define holes in one prompt splice in place.
    let evs := evsOf (world) semSrc10
    check "two define holes, spliced where they stand" "A and B" (promptAt evs 0)

    -- 9l. An override reaches a later define that holes it.
    check "an override is seen by later defines" "Harden the CSV reader, briefly."
      (match parseWith [("target", [Chunk.lit "the CSV reader"])] semSrc11 with
       | .error e => s!"did not parse: {e}"
       | .ok r =>
         match Dsl.check [] [] r with
         | .error e => s!"did not check: {e}"
         | .ok p => promptAt (Plan.trace (world) p Env.nil) 0)

    -- 9m. Adjacent holes, and escapes against holes.
    let evs := evsOf (world (t := fun q => q.prompt)) semSrc12
    check "adjacent holes and brace escapes around a hole" "AB{A}B" (promptAt evs 2)

    -- 9n. A backslash in a block is not a string escape.
    let evs := evsOf (world (t := fun _ => "A")) semSrc13
    let bs := "\\"
    check "block backslashes are literal; the brace escapes are not"
      ("C:" ++ bs ++ "path and " ++ bs ++ "{a} and {a} and A and a trailing " ++ bs)
      (promptAt evs 1)

    -- 9o. CRLF block content equals its LF spelling.
    checkTrue "CRLF and LF spell one program"
      (decide (evsOf (world) semSrc14 ≠ [] ∧
        evsOf (world) semSrc14 = evsOf (world) (semSrc14.replace "\r" "")))
    check "…with no carriage return in the prompt" "line one\nline two"
      (promptAt (evsOf (world) semSrc14) 0)

    -- 9p. A block whose lines are not uniformly indented: the dedent is a meet.
    let evs := evsOf (world) semSrc15
    check "the dedent strips the COMMON indent and empties blank lines"
      "  alpha\nbeta\n" (promptAt evs 0)

    -- 9q. Empty prompts, and an empty define.
    let evs := evsOf (world) semSrc16
    check "an empty prompt asks with no words" "" (promptAt evs 0)
    check "…an empty define splices nothing" "" (promptAt evs 1)
    check "…and vanishes between its neighbours" "prepost" (promptAt evs 2)

    -- 9r. A fence closed by a comma, a bracket and a brace.
    let evs := evsOf (world) semSrc17
    check "fences close before , ] and }" "is this ok,and this,approved"
      (String.intercalate "," (evs.map fun e => e.q.prompt))

    -- 9s. A closing fence indented other than its content.
    let evs := evsOf (world) semSrc18
    check "the closing fence's indent is not content" "line one\nline two"
      (promptAt evs 0)
    check "…even shallower than the content" "line three" (promptAt evs 1)

    IO.println "discovery pins: done"

    -- 10. Round sixteen: functions and imports, as a run observes them. The
    -- expectations below were argued from the design (fn-import-design.md)
    -- before being run: a call is `Plan.sub`, so a call and its hand-inlining
    -- are one trace; an import is a plan prefix, so the priming leads; the
    -- three argument spellings normalize to one prompt; sharing is by the
    -- question, so one call twice is one answer twice.
    let wEcho : Ω := world (t := fun q => s!"<{q.prompt}>")

    -- 10a. The priming runs first; a dotted define expands; a dotted binding
    -- splices.
    let s16a := "import lib\nworkflow { ask tool \"t\" \"use {lib.guide} {lib.greeting}\" }"
    let e16a := evsOfM wEcho [] [("lib", libOk)] s16a
    check "priming first: the library's question leads the trace"
      "text,receipt" (codesOf e16a)
    check "…worded by the library" "style guide" (promptAt e16a 0)
    check "…and the program's act splices the answer and the dotted define"
      "use <style guide> hello" (promptAt e16a 1)

    -- 10b. A call is its inlining: `Plan.sub`, not a new former.
    let callSrc := fnsPre ++ "workflow { x <- mk \"the goal\"\n ask tool \"t\" \"use {x}\" }"
    let inlSrc := "workflow { x <- ask model \"author\" \"draft: the goal\"\n ask tool \"t\" \"use {x}\" }"
    checkTrue "a call and its hand-inlining are one trace"
      (decide (evsOf wEcho callSrc ≠ [] ∧ evsOf wEcho callSrc = evsOf wEcho inlSrc))

    -- 10c. Three spellings of one argument are one program.
    let trailSrc := fnsPre ++ "workflow {\n  x <- mk ```\n      the goal\n  ```\n  ask tool \"t\" \"use {x}\"\n}"
    let lblSrc := fnsPre ++ "workflow {\n  x <- mk $goal\n  ```goal\n      the goal\n  ```\n  ask tool \"t\" \"use {x}\"\n}"
    checkTrue "a short argument, a trailing block and a $label are one trace"
      (decide (evsOf wEcho callSrc ≠ [] ∧ evsOf wEcho callSrc = evsOf wEcho trailSrc
        ∧ evsOf wEcho trailSrc = evsOf wEcho lblSrc))

    -- 10d. A procedure's acts run in order, between the caller's statements.
    let procSrc := fnsPre ++
      "workflow { d : text <- ask tool \"cat\" \"the patch\"\n applied d\n ask tool \"log\" \"done\" }"
    let e16d := evsOf wEcho procSrc
    check "a procedure's acts, in order" "text,receipt,receipt" (codesOf e16d)
    check "…the first act reads the argument" "apply: <the patch>" (promptAt e16d 1)

    -- 10e. Same call, same answer: sharing survives inlining, because the
    -- inlined asks are the same question.
    let shareSrc := fnsPre ++
      "workflow { x <- mk \"g\"\n y <- mk \"g\"\n ask tool \"t\" \"cmp {x} :: {y}\" }"
    let e16e := evsOf wEcho shareSrc
    check "two calls with one argument are one question twice, one answer"
      "cmp <draft: g> :: <draft: g>" (promptAt e16e 2)

    -- 10f. `--define` reaches through the module prefix.
    let e16f := evsOfM wEcho [("lib.greeting", Prompt.normalize [.lit "swapped"])]
      [("lib", libOk)] s16a
    check "an override through the module prefix changes exactly those words"
      "use <style guide> swapped" (promptAt e16f 1)

    -- 10g. The examples on disk.
    let libFile ← try
        IO.FS.readFile "example/library.wf"
      catch e =>
        throw <| IO.userError s!"FAIL example/library.wf is not readable — \
                                run from the repository root: {e}"
    let progFile ← try
        IO.FS.readFile "example/harden-imported.wf"
      catch e =>
        throw <| IO.userError s!"FAIL example/harden-imported.wf is not readable — \
                                run from the repository root: {e}"
    check "example/harden-imported.wf checks against example/library.wf" "ok"
      (outcomeM [("library", libFile)] progFile)
    let e16g := evsOfM wEcho [] [("library", libFile)] progFile
    check "…and its consenting trace is priming, draft, review panel, judge, consent, apply"
      "text,receipt,text,verdict,verdict,verdict,flag,receipt,receipt" (codesOf e16g)
    check "example/library.wf runs alone: its priming, then nothing" "ok"
      (outcomeM [] libFile)

    -- 10h. The two resource bounds of the elaboration, at chain-built sources:
    -- `f n` inlines to 2^(n-1) questions and its header sits at line 5n-5.
    check "a function over the question budget is refused with the count"
      "65:1: `f14` elaborates to 8192 questions, and the bound is 4096 at `f14`"
      (outcome (chain 14 ++ "workflow { stop }"))
    check "a program over the question budget is refused with the count"
      "0:0: this program elaborates to 8193 questions, and the bound is 4096"
      (outcome (chain 13 ++ "workflow { a <- f13 \"x\"\n b <- f13 \"y\"\n ask tool \"t\" \"{a} {b}\" }"))

    -- 10i. The refusals no source text reaches, at the hand-built entry point
    -- (the parser is arity-directed and resolves every call head, so only a
    -- hand-built `RawProgram` can present these to the checker).
    let hbFn : RawFn :=
      { name := "f", params := [("p", Code.text), ("q", Code.text)], result := Code.text
      , body := [], answer := some "p", answerPos := { line := 1, col := 1 }
      , pos := { line := 1, col := 1 } }
    let hbOutcome (main : Raw) : String :=
      match checkProgram ⟨[hbFn], main⟩ with
      | .ok _ => "ok"
      | .error e => e.render
    check "a hand-built call with too few arguments is refused"
      "0:0: `f` is applied to too few arguments at `f`"
      (hbOutcome (RawBlock.bind "x" none
        (RawSource.rhs (RawRhs.call "f" [] { line := 2, col := 3 }))
        (RawBlock.empty { line := 3, col := 1 }) { line := 2, col := 1 }))
    check "…and with too many"
      "0:0: `f` is applied to too many arguments at `f`"
      (hbOutcome (RawBlock.bind "x" none
        (RawSource.rhs (RawRhs.call "f"
          [RawArg.lit (Prompt.normalize [.lit "a"]) { line := 2, col := 5 },
           RawArg.lit (Prompt.normalize [.lit "b"]) { line := 2, col := 7 },
           RawArg.lit (Prompt.normalize [.lit "c"]) { line := 2, col := 9 }]
          { line := 2, col := 3 }))
        (RawBlock.empty { line := 3, col := 1 }) { line := 2, col := 1 }))
    check "…and a call of a name no function answers"
      "2:1: no function answers to this name (functions are declared above their first use) at `nosuch`"
      (hbOutcome (RawBlock.callStmt "nosuch" []
        (RawBlock.empty { line := 3, col := 1 }) { line := 2, col := 1 }))
    -- The parser refuses a duplicate function name at its declaration;
    -- `checkFnsList` is the same refusal for a hand-built table, because
    -- `Fns.find?` answers with the first match and a silent first-wins
    -- resolution runs the wrong body (acat-dup-function-check-gap-kys).
    check "…and two functions answering one name"
      "1:1: two functions answer to one name; rename one at `f`"
      (match checkProgram ⟨[hbFn, hbFn], RawBlock.empty { line := 1, col := 1 }⟩ with
       | .ok _ => "ok"
       | .error e => e.render)
    -- The parser refuses `served by` on a tool; `askGuard` is the same refusal
    -- at the checker, so a hand-built `Raw` cannot smuggle a serving model
    -- onto an addressee that is not one (acat-served-by-check-gap-i5d).
    check "…and a hand-built `served by` on a tool"
      "2:3: `served by` names the model that serves a model addressee; a tool or a person is not served by one at `served`"
      (match Dsl.check [] [] (RawBlock.act
          ⟨some "deep", ⟨Addressee.tool "t", 0⟩, Prompt.normalize [.lit "w"],
           { line := 2, col := 3 }⟩
          (RawBlock.empty { line := 3, col := 1 }) { line := 2, col := 1 }) with
       | .ok _ => "ok"
       | .error e => e.render)

    IO.println "round sixteen pins: done"

    IO.println "dsl smoke: all checks passed"
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"dsl smoke: {e}"
    return 1
