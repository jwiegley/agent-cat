import Agentic.Core.Explain

/-!
# The command line, driven end to end

Run from the repository root, after `lake build`:

```
lake exe cli_smoke
```

`Agentic/Core/Explain.lean` proves what is provable about the two analyses a
reader sees — that the pipeline count is the bill in every world
(`Plan.length_trace_eq_askNodes`), that the front end with the raw syntax kept is
the front end (`Dsl.parseAndCheckRaw_eq`), that a printed revision bound is one the
checker allowed (`Dsl.revisionBounds_le_of_bounded`). This checks the four things
no proof in the package can make a statement about.

* **That the file and the module are the same text.** `Dsl.flagshipSource` is
  `include_str "../../examples/harden.wf"`, so the module and the file are one text
  by construction — at the moment the module is elaborated. Lake's build trace does
  not know about the `.wf` file, so an edit to it does not by itself rebuild
  `Agentic/Core/Dsl.lean`, and a stale `.olean` would be a module compiled from a
  text that is no longer on disk. That is checked here, by reading the file at run
  time and comparing, which is the check `include_str` cannot arrange for itself.

* **That the binary prints the library's folds and not its own.** The `plan` and
  `cost` output of the built `agent-cat`, line for line, against
  `Explain.planLines` and `Explain.costLines` applied to `Dsl.flagshipPlan` — the
  very plan `Dsl.level_flagshipPlan`, `Dsl.card_leaves_flagship`,
  `Dsl.minFold_flagship` and `Dsl.maxFold_flagship` are about. A CLI that computed
  anything of its own would differ here.

* **That a run of a source file bills what the source file's plan is proved to
  bill.** Seven when the owner consents and six when the owner refuses, and the two
  numbers are `Dsl.bill_flagship_apply` and `Dsl.bill_flagship_refuse` restated at
  the constants below, so editing either stops this file compiling.

* **That the two rungs a report cannot price the same way are printed differently.**
  `Explain.costLines` at `Cost.unbounded` prints the non-existence statement of
  `Cost.no_finite_bill_set_at_dyn` and no number. No `.wf` file can reach that rung
  (`Dsl.parseAndCheck_level_le`), so the branch is checked here against the library
  or it is never run at all.

* **That the three subcommands refuse an ill-typed program identically.** Byte for
  byte on stderr, and `2` from all three — which is what "one front end" means
  observationally. `Agentic/Core/Explain.lean` proves the front end is one
  function; this checks that all three subcommands go through it.
-/

open Agentic.Core

/-- One assertion, reported the way the other smoke tests report theirs. -/
def check (what want got : String) : IO Unit :=
  if want == got then pure () else
    throw <| IO.userError s!"FAIL {what}\n  want: {want}\n  got:  {got}"

/-- …and one that only has to hold. -/
def checkTrue (what : String) (b : Bool) : IO Unit :=
  if b then pure () else throw <| IO.userError s!"FAIL {what}"

/-- Where the built command line is, relative to the repository root — which is
therefore where this must be run from, exactly as `test/stub_adapter.py` is found
by `lake exe acp_smoke`. -/
def cliPath : String := ".lake/build/bin/agent-cat"

/-- The flagship, as a file. `Dsl.flagshipSource` is this file's contents, and
that is checked below rather than assumed. -/
def hardenPath : String := "examples/harden.wf"

/-- The small program, which exists so that the command line has a subject that is
not the flagship: three questions, no branching, and therefore a bill the analysis
knows exactly rather than bounds. -/
def helloPath : String := "examples/hello.wf"

/-- …and the one that must be refused. -/
def illPath : String := "examples/ill-typed.wf"

/-- `[[expectedApply]]` = what a run of the flagship bills when the owner consents:
guide, draft, three reviewers, the owner, the act. -/
def expectedApply : Nat := 7

/-- **The theorem** (`Dsl.bill_flagship_apply`, restated at `expectedApply`):
change the constant and this stops compiling. -/
theorem bill_apply_eq :
    billFresh tick (Plan.trace Harden.ωApply Dsl.flagshipPlan Env.nil)
      = Multiplicative.ofAdd expectedApply :=
  Dsl.bill_flagship_apply

/-- `[[expectedRefuse]]` = the same run when the owner refuses: no act. -/
def expectedRefuse : Nat := 6

/-- **The theorem** (`Dsl.bill_flagship_refuse`, restated at `expectedRefuse`). -/
theorem bill_refuse_eq :
    billFresh tick (Plan.trace Harden.ωRefuse Dsl.flagshipPlan Env.nil)
      = Multiplicative.ofAdd expectedRefuse :=
  Dsl.bill_flagship_refuse

/-- What one invocation produced: the three things a caller can observe. -/
structure Ran where
  /-- The exit code. -/
  code : UInt32
  /-- Everything on stdout, as lines, the trailing newline dropped. -/
  out : List String
  /-- Everything on stderr, verbatim. -/
  err : String

/-- Run the built command line once. -/
def cli (args : List String) : IO Ran := do
  let r ← IO.Process.output { cmd := cliPath, args := args.toArray }
  let out := (r.stdout.splitOn "\n").filter (fun l => !l.isEmpty)
  return ⟨r.exitCode, out, r.stderr⟩

/-- The library's own rendering, as the lines the binary should have printed. -/
def rendered (banner : String) (ls : List String) : List String :=
  (banner :: ls).flatMap fun l => (l.splitOn "\n").filter (fun x => !x.isEmpty)

def main : IO UInt32 := do
  IO.println "cli smoke: the three subcommands, against the library and against the stub"
  try
    if !(← System.FilePath.pathExists (System.FilePath.mk cliPath)) then
      throw <| IO.userError
        s!"cli_smoke: no binary at '{cliPath}' — run `lake build` from the repository root first"

    -- 1. The file the module compiled in is the file on disk. `include_str` makes
    -- them one text when `Agentic/Core/Dsl.lean` is elaborated; nothing makes lake
    -- re-elaborate it when only the `.wf` changes, so this is where a stale
    -- `.olean` is caught.
    let onDisk ← IO.FS.readFile hardenPath
    check "examples/harden.wf is byte-for-byte Dsl.flagshipSource"
      (toString Dsl.flagshipSource.length) (toString onDisk.length)
    checkTrue "…and not merely the same length" (onDisk == Dsl.flagshipSource)

    -- …and the parser reads it as the raw syntax the flagship theorems are about,
    -- which is what makes the plan the binary works on `Dsl.flagshipPlan` and not
    -- merely a plan.
    match Dsl.parse onDisk with
    | .error e => throw <| IO.userError s!"FAIL the file does not parse: {e}"
    | .ok r => checkTrue "…and parses to Dsl.flagshipRaw" (decide (r = Dsl.flagshipRaw))

    -- 2. `plan` and `cost` print the library's folds, line for line. The numbers in
    -- them are `Dsl.level_flagshipPlan`, `Dsl.card_leaves_flagship`,
    -- `Dsl.minFold_flagship` and `Dsl.maxFold_flagship`, because the plan is the
    -- one those theorems are about.
    let hlv := Dsl.level_flagshipPlan_le
    let planRan ← cli ["plan", hardenPath]
    check "plan exits 0" "0" (toString planRan.code)
    check "plan prints exactly Explain.planLines ++ Explain.revisionLines"
      (String.intercalate "\n"
        (rendered s!"plan: {hardenPath}"
          (Explain.planLines Dsl.flagshipPlan ++ Explain.revisionLines Dsl.flagshipRaw)))
      (String.intercalate "\n" planRan.out)
    checkTrue "…including the revision bound the term does not hold"
      (planRan.out.any fun l => (l.splitOn "upto 2").length > 1)

    let costRan ← cli ["cost", hardenPath]
    check "cost exits 0" "0" (toString costRan.code)
    check "cost prints exactly Explain.costLines"
      (String.intercalate "\n" (rendered s!"cost: {hardenPath}" (Explain.costLines Dsl.flagshipPlan)))
      (String.intercalate "\n" costRan.out)
    -- The three numbers, read out of the fold the theorems are about.
    let (lo, hi, paths) := Explain.costSummary Dsl.flagshipPlan hlv
    check "…and the cheapest leaf is the one minFold_flagship proves" "5" (sayNat? lo)
    check "…and the dearest is maxFold_flagship's" "15" (sayNat? hi)
    check "…over card_leaves_flagship's nine paths" "9" (toString paths)

    -- 3. The two example programs, run against the stub. The flagship's two bills
    -- are the two theorems restated above; hello's is exact at the pipeline rung,
    -- which is the one case in which the analysis promises a bill rather than a
    -- bound.
    let hello ← cli ["run", helloPath, "--quiet"]
    check "run hello exits 0" "0" (toString hello.code)
    checkTrue "…and bills the three consultations the term writes"
      (hello.out.any fun l => (l.splitOn "agent-cat: 3 consultations").length > 1)

    let apply ← cli ["run", hardenPath, "--quiet"]
    check "run harden (the stub consents) exits 0" "0" (toString apply.code)
    checkTrue s!"…and bills {expectedApply}, which is Dsl.bill_flagship_apply"
      (apply.out.any fun l => (l.splitOn s!"agent-cat: {expectedApply} consultations").length > 1)
    checkTrue "…and every check of the run passed"
      (apply.out.all fun l => (l.splitOn "FAIL").length == 1)

    let refuse ← cli ["run", hardenPath, "--adapter-arg", "--refuse", "--quiet"]
    check "run harden (the stub refuses) exits 0" "0" (toString refuse.code)
    checkTrue s!"…and bills {expectedRefuse}, which is Dsl.bill_flagship_refuse"
      (refuse.out.any fun l => (l.splitOn s!"agent-cat: {expectedRefuse} consultations").length > 1)

    -- 4. One front end: the same diagnosis and the same exit code from all three
    -- subcommands, byte for byte.
    let illPlan ← cli ["plan", illPath]
    let illCost ← cli ["cost", illPath]
    let illRun ← cli ["run", illPath]
    check "plan refuses an ill-typed program with 2" "2" (toString illPlan.code)
    check "cost refuses it with 2" "2" (toString illCost.code)
    check "run refuses it with 2" "2" (toString illRun.code)
    check "…and cost's diagnosis is plan's, byte for byte" illPlan.err illCost.err
    check "…and run's is too" illPlan.err illRun.err
    checkTrue "…and it says where, what and which fragment"
      ((illPlan.err.splitOn "examples/ill-typed.wf:10:14:").length > 1
        && (illPlan.err.splitOn "only a text answer interpolates").length > 1
        && (illPlan.err.splitOn "at `review`").length > 1)
    check "…and nothing was printed on stdout" "" (String.intercalate "\n" illPlan.out)

    -- 5. The rung at which there is no number. `Cost.unbounded` is the `dyn` plan
    -- `Cost.no_finite_bill_set_at_dyn` is about; `Explain.costLines` prints the
    -- non-existence statement for it instead of a bound. Checked against the
    -- library rather than through the binary because no source text reaches this
    -- rung — `Dsl.parseAndCheck_level_le` is the theorem that says the language
    -- cannot write a `dyn`, so this branch of the report is unreachable from a
    -- file and would otherwise be written and never run.
    check "a `dyn` plan's rung is dynamic" "dynamic" (levelName (level unbounded))
    checkTrue "…and it is priced with the non-existence statement and no number"
      ((Explain.costLines unbounded).any fun l =>
        (l.splitOn "no cost report exists at this rung").length > 1)

    -- …and a file that is not there is refused the same way, because "there is no
    -- workflow here" is what both answers say.
    let missing ← cli ["plan", "examples/there-is-no-such-file.wf"]
    check "a missing program exits 2" "2" (toString missing.code)

    IO.println "cli smoke: all checks passed"
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"cli smoke: {e}"
    return 1
