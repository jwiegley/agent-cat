import Agentic.Core.Explain
import Agentic.Core.Artifact
import Agentic.Core.DslFlagship

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
  `include_str "../../example/harden.wf"`, so the module and the file are one text
  by construction — at the moment the module is elaborated. Lake's build trace does
  not know about the `.wf` file, so an edit to it does not by itself rebuild
  `Agentic/Core/DslFlagship.lean`, and a stale `.olean` would be a module compiled
  from a text that is no longer on disk. That is checked here, by reading the file
  at run time and comparing, which is the check `include_str` cannot arrange for
  itself.

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

* **That a run of the flagship has a parser to harden.** The failure that made
  `Agentic/Core/Artifact.lean`'s workspace necessary was a run in an empty
  directory that passed every check; the check against a repeat is that
  `agent-cat run example/harden.wf`, with no flag at all, prints
  `example/harden.d` and `parse.c` in its header. Also that `--no-workspace`
  says the directory is empty rather than saying nothing, and that a symbolic
  link in a workspace is refused with a reason instead of followed.

* **That an ask cannot write, and that a run notices when something wrote
  anyway.** Three runs of the refusing flagship, which is the run that puts no
  act and is therefore permitted to write nothing at all. Against the ordinary
  stub it passes and reports an unchanged workspace. Against
  `--write-on-ask` — an adapter that asks permission to edit `parse.c` while
  merely *answering* — it still passes and is still unchanged, because
  `Exec.permissionByCode` denies every request that did not arrive during an
  act; the report names the denials. Against `--write-anyway` — an adapter that
  edits without asking, which no permission policy can prevent — it **fails**,
  naming the file, which is the only evidence that the fingerprint check has
  teeth. The measured defect (`acat-08l`) is the middle case with the denial
  removed: a refusing run whose `parse.c` was replaced during the author's draft
  turn while every semantic check passed.

* **That `--define` changes what it says it changes and nothing else.** Two
  statements, and the second is the load-bearing one: overriding a `define` with
  *the same words the program wrote* produces output byte-identical to giving no
  option at all, so the no-override path is not merely similar to the pinned
  program but equal to it. (The pinned text itself is checked above, where
  `plan` is compared against `Explain.planLines Dsl.flagshipPlan`.)
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
def hardenPath : String := "example/harden.wf"

/-- The small program, which exists so that the command line has a subject that is
not the flagship: three questions, no branching, and therefore a bill the analysis
knows exactly rather than bounds. -/
def helloPath : String := "example/hello.wf"

/-- …and the one that must be refused. -/
def illPath : String := "example/ill-typed.wf"

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
    -- them one text when `Agentic/Core/DslFlagship.lean` is elaborated; nothing
    -- makes lake re-elaborate it when only the `.wf` changes, so this is where a
    -- stale `.olean` is caught.
    let onDisk ← IO.FS.readFile hardenPath
    check "example/harden.wf is byte-for-byte Dsl.flagshipSource"
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
      ((illPlan.err.splitOn "example/ill-typed.wf:10:14:").length > 1
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
    let missing ← cli ["plan", "example/there-is-no-such-file.wf"]
    check "a missing program exits 2" "2" (toString missing.code)

    -- 6. The workspace. `agent-cat run example/harden.wf` with no flag must find
    -- `example/harden.d/` beside the program and say so: the measured failure
    -- this guards against is a run of the flagship in an empty directory, where
    -- the author correctly refused to write a diff, the reviewers approved the
    -- refusal, and every check printed `ok`.
    check "the convention names the directory beside the program"
      "example/harden.d" (conventionalWorkspace hardenPath)
    let seedPath := "example/harden.d/parse.c"
    checkTrue s!"{seedPath} is on disk"
      (← System.FilePath.pathExists (System.FilePath.mk seedPath))
    let seedText ← IO.FS.readFile seedPath
    let seeded ← cli ["run", hardenPath]
    check "a seeded run exits 0" "0" (toString seeded.code)
    checkTrue "…and its header names the workspace the convention found"
      (seeded.out.any fun l => (l.splitOn "workspace: example/harden.d").length > 1)
    checkTrue "…and names the file the agent was given, with its size"
      (seeded.out.any fun l =>
        (l.splitOn "parse.c").length > 1 && (l.splitOn s!"{seedText.length} bytes").length > 1)

    -- An empty run is a legitimate run and a silent one is not: `Seeded.render`
    -- always emits a line (`Seeded.render_ne_nil`), and this is that line.
    let bare ← cli ["run", hardenPath, "--no-workspace"]
    check "--no-workspace exits 0" "0" (toString bare.code)
    checkTrue "…and the header says the directory is empty, in words"
      (bare.out.any fun l => (l.splitOn "starts in an empty directory").length > 1)

    -- A symbolic link is refused with a reason rather than followed, and the
    -- workspace itself is not written to. Built here with `ln` because Lean core
    -- has no symlink call, which is also why this is a test and not a theorem.
    let tmp := (← IO.Process.run { cmd := "mktemp", args := #["-d"] }).trimAscii.toString
    IO.FS.writeFile (System.FilePath.mk tmp / "given.txt") "four\n"
    discard <| IO.Process.run { cmd := "ln", args := #["-s", "/etc/hosts", tmp ++ "/link.txt"] }
    let linked ← cli ["run", helloPath, "--workspace", tmp]
    check "a workspace with a symlink in it still runs" "0" (toString linked.code)
    checkTrue "…the ordinary file arrived"
      (linked.out.any fun l =>
        (l.splitOn "given.txt").length > 1 && (l.splitOn "5 bytes").length > 1)
    checkTrue "…and the link was refused, with the reason given"
      (linked.out.any fun l =>
        (l.splitOn "refused link.txt").length > 1
          && (l.splitOn "copied and not followed").length > 1)
    checkTrue "…and the workspace itself still holds exactly what it held"
      ((← listDir tmp).length == 2)

    -- 7. Runtime parameters. The flagship's `spec` is the thing the whole
    -- workflow is about, so this is the one `define` worth naming from outside.
    let asWritten ← cli ["plan", hardenPath, "--define", "spec=harden the parser"]
    check "--define with the program's own words exits 0" "0" (toString asWritten.code)
    check "…and prints byte-for-byte what no --define prints"
      (String.intercalate "\n" planRan.out) (String.intercalate "\n" asWritten.out)
    let retargeted ← cli ["plan", hardenPath, "--define", "spec=harden the CSV reader"]
    check "--define with other words exits 0" "0" (toString retargeted.code)
    checkTrue "…and the plan now names the target the caller gave"
      (retargeted.out.any fun l => (l.splitOn "harden the CSV reader").length > 1)
    checkTrue "…and no longer the one the file wrote"
      (retargeted.out.all fun l => (l.splitOn "harden the parser").length == 1)
    let unknown ← cli ["cost", hardenPath, "--define", "nosuchmacro=x"]
    check "--define of a name the program never defined exits 2" "2" (toString unknown.code)
    checkTrue "…saying which name"
      ((unknown.err.splitOn "no `define nosuchmacro` to override").length > 1)
    -- …and a run option handed to `plan` is still a mistake, which is the half of
    -- "plan takes only --define" that the line above does not check.
    let misplaced ← cli ["plan", hardenPath, "--quiet"]
    check "plan still refuses a run option" "1" (toString misplaced.code)

    -- 8. The model axis. An alias is accepted and changes nothing against the
    -- stub, which advertises `deep` itself: `Acp.resolveValue_exact` says a value
    -- the adapter advertises resolves to itself, so the stub's runs are the runs
    -- they were.
    let aliased ← cli ["run", hardenPath, "--model", "deep=deep", "--quiet"]
    check "--model NAME=REAL is accepted" "0" (toString aliased.code)
    checkTrue s!"…and the run still bills {expectedApply}"
      (aliased.out.any fun l => (l.splitOn s!"agent-cat: {expectedApply} consultations").length > 1)
    let badPair ← cli ["run", hardenPath, "--model", "deep"]
    check "…and --model without an `=` is refused" "1" (toString badPair.code)

    -- 9. What a question is allowed to write. The refusing flagship puts no act
    -- (`Dsl.bill_flagship_refuse` is six consultations and none of them an
    -- `.ack`), so nothing it asked for was permitted to write, and a workspace
    -- that changed anyway was changed by something nobody authorized.
    let quiet ← cli ["run", hardenPath, "--adapter-arg", "--refuse"]
    check "a refusing run against the well-behaved stub exits 0" "0" (toString quiet.code)
    checkTrue "…and reports the workspace unchanged"
      (quiet.out.any fun l => (l.splitOn "the workspace after the run: unchanged").length > 1)
    checkTrue "…and says so as a check, not only as a heading"
      (quiet.out.any fun l =>
        (l.splitOn "the run performed no act, and the workspace is unchanged").length > 1)
    checkTrue "…and nothing asked it for permission to act"
      (quiet.out.any fun l => (l.splitOn "none: no tool call asked").length > 1)

    -- An adapter that asks to edit the workspace while answering a *text*
    -- question. This is the measured defect's shape; the client denies it
    -- because the question under way was an ask (`Exec.permissionByCode`), so
    -- the run is unchanged and passes — and the denials are in the report,
    -- because a denial is what the run paid for its safety.
    let asked ← cli ["run", hardenPath, "--adapter-arg", "--refuse",
                     "--adapter-arg", "--write-on-ask"]
    check "a refusing run against a stub that asks to write during an ask exits 0" "0"
      (toString asked.code)
    checkTrue "…with every request denied, named in the report"
      (asked.out.any fun l =>
        (l.splitOn "permission DENIED").length > 1
          && (l.splitOn "edit parse.c while answering").length > 1)
    checkTrue "…and nothing was granted"
      (asked.out.all fun l => (l.splitOn "permission granted").length == 1)
    checkTrue "…so the workspace is unchanged, which is the whole of the fix"
      (asked.out.any fun l => (l.splitOn "the workspace after the run: unchanged").length > 1)

    -- …and an adapter that writes without asking at all, which no permission
    -- policy can stop. The run must fail, naming the file: without this the
    -- fingerprint check is a claim rather than a test.
    let wrote ← cli ["run", hardenPath, "--adapter-arg", "--refuse",
                     "--adapter-arg", "--write-anyway"]
    check "a refusing run whose workspace was written to anyway exits 1" "1"
      (toString wrote.code)
    checkTrue "…saying plainly that something wrote without authorisation"
      ((wrote.err.splitOn "without authorisation").length > 1)
    checkTrue "…and naming the file it wrote"
      ((wrote.err.splitOn "the workspace changed: parse.c").length > 1)
    checkTrue "…and the run's own checks are not what failed"
      (wrote.out.all fun l => (l.splitOn "FAIL").length == 1)

    IO.println "cli smoke: all checks passed"
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"cli smoke: {e}"
    return 1
