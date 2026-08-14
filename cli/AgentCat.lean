import Agentic.Core.Explain
import Agentic.Core.Artifact

/-!
# `agent-cat`: run a workflow, price it, or print it

The command line over `Agentic/Core/Dsl.lean`. Three subcommands, one front end,
and no analysis of its own:

```
agent-cat plan example/harden.wf
agent-cat cost example/harden.wf
agent-cat run  example/harden.wf
agent-cat run  example/harden.wf --adapter-arg --refuse       # the stub refuses
printf 'yes\n' | agent-cat run example/harden.wf --adapter claude
```

**One front end, and it is one function.** `withProgram` reads the file, calls
`Dsl.parseAndCheckRaw`, and on failure prints the `Dsl.CheckError` — path, line,
column, message, the source line with a caret under it, and the offending
fragment — to stderr and exits `2`. All three subcommands call it and none of them
can diagnose a program differently from the others, because there is only the one
place where a program is diagnosed. That the front end it calls is the front end
everything else calls is `Dsl.parseAndCheckRaw_eq`: forgetting the raw syntax
gives `Dsl.parseAndCheckE` back on the nose, so `agent-cat`, `workflow_check` over
MCP and `test/DslSmoke.lean` accept and refuse the same texts with the same
messages.

**Nothing here computes anything about a program.** `plan` is
`Explain.planLines`, `cost` is `Explain.costLines`, and `run` is
`execCertifiedIO` followed by `RunReport.of` — the same folds the theorems are
about, in the library, called from here. The only things this file owns are the
command line, the scratch directory, the exit protocol, and the checks a run is
subjected to; each of the latter names the theorem it shadows, exactly as
`demo/Main.lean` does for the flagship workload.

**Five decisions about the command line, and the reason for each.**

* **A run is given something to act on.** `--workspace DIR` copies `DIR`'s
  contents into the run's fresh directory before the first question, and never
  writes to `DIR`; with no flag, a directory named after the program with a `.d`
  suffix (`example/harden.wf` → `example/harden.d/`) is used, and
  `--no-workspace` opts out. The header says what was seeded, or that the
  directory is empty. The mechanism, and the live run that made it necessary, are
  in `Agentic/Core/Artifact.lean`; what is here is the flag.

* **`--define NAME=VALUE` is accepted by all three subcommands, and nothing
  else is.** An option that changes the *program* must be available wherever a
  program is read, or `plan` and `cost` would be describing a different program
  from the one `run` runs. Options that describe a *run* remain `run`'s alone,
  and one handed to `plan` is a mistake reported rather than ignored.

* **There is no `--refuse`.** It is not a CLI concern: it is a fact about how one
  particular answering program, `test/stub_adapter.py`, is started, and it means
  nothing to `--adapter claude`, where the owner answers for themselves. What
  `agent-cat` has instead is `--adapter-arg ARG`, which appends to the child's
  argv and knows nothing about what any argument means; the refusing path is
  `--adapter-arg --refuse`. `demo/Main.lean` keeps its own `--refuse` because it
  *asserts* against the stub's behaviour — `Harden.no_ack_of_refused`'s hypothesis
  made out of bytes — and an assertion about an answering program belongs with the
  harness that makes it.

* **There is no `--json`.** `workflow_check` over MCP already serialises the cost
  analysis (`Agentic/Core/Mcp.lean`), through the same `Explain.costSummary` this
  file's `cost` prints, so a JSON surface exists and adding a second one here
  would be a second encoder to keep true. The renderings here are for a reader.

* **The person is asked at the keyboard only where a person is answering.**
  Against the stub the stub answers every addressee, which is what makes an
  unattended run possible at all; live, `Exec.Settings.askPersonOnStdin` sends a
  `person` question to stderr and reads the reply from stdin, so a supervised run
  and `printf 'yes\n' | agent-cat run …` are the same run and stdout stays the
  report. This is `demo/Main.lean`'s rule, and it is the same rule because it is
  the same `Exec.Settings`.

**What a run checks, and which theorem each check shadows.** Every one of these is
a statement about *any* program, unlike `demo/Main.lean`'s, which are about the
flagship workload:

| check                                  | the theorem it shadows          |
| -------------------------------------- | ------------------------------- |
| every replayed event is in the log     | `Plan.certify_sound_of_covered` |
| the table holds one entry per question | `Dlg.execM_ask_hit`             |
| the run certifies                      | `Plan.runCertified_certified`   |
| the bill is a leaf of the cost tree    | `Cost.bill_mem_leaves`          |
| no act ran, and nothing was written    | *none — it is not a theorem*    |

The fourth is the cost report, checked: `agent-cat cost` prints the leaves of
`Cost.costTree`, and `Cost.bill_mem_leaves` says the bill of every run is one of
them, so a run whose bill is not one of them is a run the `IO` layer produced and
no world can.

**The fifth shadows nothing, and that is the point.** A theorem says a refused
run puts no apply question (`Harden.no_ack_of_refused`); no theorem says the
workspace is unchanged, and none can, because bytes on a disk are not in the
semantics. So the run's directory is fingerprinted after seeding and again when
the run ends (`Agentic/Core/Artifact.lean`), the difference is printed either
way, and a run whose transcript holds no `.ack` event and whose workspace changed
anyway exits `1` naming the files. When an act *did* run, the difference is
printed as information: an act is a question whose point is an effect, and what
it wrote is `ArtifactCheck`'s business. The check is evidence about one run and
not a theorem, it is defeated by a write outside the run's directory, and a run
that aborted before finishing is not compared at all — it exits nonzero for the
abort.

**Exit codes.** `0` if the run and its checks passed; `1` if a check failed or the
run aborted; `2` if the program could not be read or does not check. `plan` and
`cost` exit `0` or `2` and nothing else — they run nothing.
-/

open Agentic.Core

/-! ## Usage -/

/-- `[[usage]]` = what the three subcommands are and what they take. -/
def usage : String :=
  "agent-cat — run, price and print workflows written in the checked DSL\n\
   \n\
   usage:\n\
   \x20 agent-cat plan <program.wf>            print the checked term, node by node\n\
   \x20 agent-cat cost <program.wf>            price it without running it\n\
   \x20 agent-cat run  <program.wf> [options]  run it against an agent\n\
   \x20 agent-cat --help\n\
   \n\
   load options (all three subcommands):\n\
   \x20 --define NAME=VALUE                give a `define` the program wrote these words\n\
   \x20                                    instead; repeatable, and taken literally\n\
   \n\
   run options:\n\
   \x20 --adapter stub|claude|codex|PATH   the answering program (default: stub)\n\
   \x20 --adapter-arg ARG                  one argument for the adapter's argv; repeatable.\n\
   \x20                                    `--adapter-arg --refuse` is how the stub is told\n\
   \x20                                    to answer *no* to a person's yes/no question\n\
   \x20 --workspace DIR                    copy DIR's contents into the run's directory\n\
   \x20                                    first; DIR itself is never written to\n\
   \x20 --no-workspace                     start empty, ignoring the `.d` convention\n\
   \x20 --model NAME=REAL                  what a scope's `model \"NAME\"` means to this\n\
   \x20                                    adapter, e.g. `--model deep=opus`; repeatable\n\
   \x20 --scratch DIR                      run in DIR instead of a fresh mktemp directory\n\
   \x20 --quiet                            print the verdict and what failed, and no more\n\
   \n\
   without --workspace, a directory named after the program with a `.d` suffix\n\
   (example/harden.wf → example/harden.d/) is the workspace, and the run header\n\
   says either what was seeded from it or that the directory is empty.\n\
   \n\
   exit: 0 the run passed its checks, 1 a check failed or the run aborted,\n\
   \x20     2 the program could not be read or does not check\n"

/-! ## Options -/

/-- `[[splitPair what s]]` = `NAME=VALUE` read as a pair, cut at the **first**
`=` so that a value may contain one. An empty name is refused: `--define =x`
names nothing. -/
def splitPair (what : String) (s : String) : Except String (String × String) :=
  match s.splitOn "=" with
  | [] | [_] => .error s!"{what} takes NAME=VALUE, and there is no `=` in `{s}`"
  | k :: rest =>
    if k.isEmpty then .error s!"{what} takes NAME=VALUE, and the name is empty in `{s}`"
    else .ok (k, String.intercalate "=" rest)

/-- `[[Options]]` = everything the command line can say about a run.

`defines` is the only field the *loader* reads; the rest describe a run. That is
why `plan` and `cost` accept `--define` and nothing else — the three subcommands
must be talking about the same program, and an option that changes the program
belongs to all three or to none. -/
structure Options where
  /-- The answering program: `stub`, a known name, or a path. -/
  adapter : String := "stub"
  /-- Arguments appended to the adapter's argv, in the order given. -/
  adapterArgs : Array String := #[]
  /-- Where the run happens; a fresh directory when absent. -/
  scratch : Option String := none
  /-- What the run is given to act on: the `.d` convention unless told
  otherwise. -/
  workspace : WorkspaceChoice := .auto
  /-- What a scope's model name means to this adapter. -/
  modelAliases : List (String × String) := []
  /-- `define`s the caller replaced, as name and the literal words. -/
  defines : List (String × String) := []
  /-- Print the verdict and the failures, and nothing else. -/
  quiet : Bool := false

/-- The options a `run` was given, or the first thing on the command line that is
not one. -/
def parseOptions : List String → Except String Options
  | [] => .ok {}
  | "--adapter" :: a :: rest => (parseOptions rest).map ({ · with adapter := a })
  | "--adapter-arg" :: a :: rest =>
      (parseOptions rest).map (fun o => { o with adapterArgs := #[a] ++ o.adapterArgs })
  | "--scratch" :: d :: rest => (parseOptions rest).map ({ · with scratch := some d })
  | "--workspace" :: d :: rest => (parseOptions rest).map ({ · with workspace := .dir d })
  | "--no-workspace" :: rest => (parseOptions rest).map ({ · with workspace := .off })
  | "--model" :: a :: rest => do
      let kv ← splitPair "--model" a
      (parseOptions rest).map (fun o => { o with modelAliases := kv :: o.modelAliases })
  | "--define" :: a :: rest => do
      let kv ← splitPair "--define" a
      (parseOptions rest).map (fun o => { o with defines := kv :: o.defines })
  | "--quiet" :: rest => (parseOptions rest).map ({ · with quiet := true })
  | a :: _ => .error s!"unknown option or missing argument: {a}"

/-- The `--define`s of a `plan` or `cost`, which take no other option. -/
def parseDefineOptions : List String → Except String (List (String × String))
  | [] => .ok []
  | "--define" :: a :: rest => do
      let kv ← splitPair "--define" a
      return kv :: (← parseDefineOptions rest)
  | a :: _ => .error s!"plan and cost take only --define: {a}"

/-- `[[overrides ds]]` = the command line's `--define`s as the parser's macro
bodies.

**Taken literally.** A value from a shell is words a person typed, so `{x}` in
one is the two characters and not an interpolation: a runtime parameter that
could quietly name a binding would be a way to rewrite a program's dataflow from
outside it, and what `--define` is for is naming a real target. -/
def overrides (ds : List (String × String)) : List (String × Dsl.Prompt) :=
  ds.map fun d => (d.1, Dsl.Prompt.normalize [.lit d.2])

/-! ## The one front end -/

/-- The source line a diagnosis points at, with a caret under the column. -/
def caretLines (src : String) (pos : Dsl.Pos) : List String :=
  if pos.line == 0 then [] else
  match (src.splitOn "\n")[pos.line - 1]? with
  | none => []
  | some l => [s!"  {l}", "  " ++ "".pushn ' ' (pos.col - 1) ++ "^"]

/-- `[[withProgram path k]]` = the program at `path`, checked, handed to `k`; or a
diagnosis on stderr and exit `2`.

**The only place a program is read, and the only place one is refused.** All three
subcommands go through this, so their diagnoses are identical by construction
rather than by three sites agreeing — which is what the parity requirement asks
for. The message is `Dsl.CheckError`'s own, prefixed with the path and shown
against the offending line with a caret, so a reader is told where, what, and in
what words.

A file that cannot be read is refused the same way and with the same code: the
question `agent-cat` answers is "is there a workflow here", and "there is no file"
is one of the ways the answer is no.

Continuation-passing, and not by taste: `Plan [] Unit` is a `Type 1` and `IO` is a
`Type`-valued monad, so a checked plan cannot be *returned* from `IO` — it is
passed to what needs it. What `k` is handed with it is the proof
`level p ≤ Level.branch`, which `Dsl.parseAndCheckRawWith_level_le` produces from
the very equation this match established, so the cost analysis a subcommand runs
is justified by the load that produced its plan and by nothing else. That the
bound survives `--define` is the point of proving it about the overriding front
end rather than inheriting it: an overridden program is a different term, and it
is bounded because *every* term the checker accepts is.

With no `--define`, `parseAndCheckRawWith []` is `parseAndCheckRaw`
(`Dsl.parseAndCheckRaw_eq_with_nil`) is `parseAndCheckE` up to the raw syntax
(`Dsl.parseAndCheckRaw_eq`), so the default path reads exactly the program the
theorems are about. -/
def withProgram (path : String) (ds : List (String × String))
    (k : Dsl.Raw → (p : Plan [] Unit) → level p ≤ Level.branch → IO UInt32) : IO UInt32 := do
  let src ← try
      IO.FS.readFile path
    catch e =>
      IO.eprintln s!"agent-cat: {path}: {e}"
      IO.Process.exit 2
  match h : Dsl.parseAndCheckRawWith (overrides ds) src with
  | .ok (r, p) => k r p (Dsl.parseAndCheckRawWith_level_le _ src r p h)
  | .error e =>
    IO.eprintln s!"{path}:{e.pos.line}:{e.pos.col}: {e.message}"
    for l in caretLines src e.pos do IO.eprintln l
    unless e.excerpt.isEmpty do IO.eprintln s!"  at `{e.excerpt}`"
    IO.eprintln "agent-cat: this program does not check, so there is nothing to plan, \
                 price or run"
    IO.Process.exit 2

/-! ## `plan` and `cost` -/

/-- `agent-cat plan`: the checked term, and the revision bounds the term does not
hold. Both renderings are `Agentic/Core/Explain.lean`'s; this prints them. -/
def planCmd (path : String) (ds : List (String × String)) : IO UInt32 :=
  withProgram path ds fun raw p _ => do
    IO.println s!"plan: {path}"
    for l in Explain.planLines p do IO.println l
    for l in Explain.revisionLines raw do IO.println l
    return 0

/-- `agent-cat cost`: what the program costs, without running it. -/
def costCmd (path : String) (ds : List (String × String)) : IO UInt32 :=
  withProgram path ds fun _ p _ => do
    IO.println s!"cost: {path}"
    for l in Explain.costLines p do IO.println l
    return 0

/-! ## `run`

The harness's exit protocol, as in `demo/Main.lean`: a failing check throws, so
that the process ends nonzero, and a passing one says so. -/

/-- Fail loudly, with both sides quoted. -/
def check (what expected actual : String) : IO Unit :=
  if expected == actual then
    IO.println s!"ok   {what}"
  else
    throw <| IO.userError s!"FAIL {what}\n  expected: {expected}\n  actual:   {actual}"

/-- Fail loudly on a claim that is simply supposed to hold. -/
def checkTrue (what : String) (b : Bool) : IO Unit :=
  if b then IO.println s!"ok   {what}" else throw <| IO.userError s!"FAIL {what}"

/-- `agent-cat run`: the program against a live agent, and the run against the
theorems.

`h : level p ≤ Level.branch` is not decoration: it is what
`Explain.leafBills` needs, and the bill check below is `Cost.bill_mem_leaves` made
out of bytes. It comes from `Dsl.parseAndCheckRaw_level_le`, so a program that
reached this function has it. -/
def runCmd (path : String) (p : Plan [] Unit) (h : level p ≤ Level.branch) (o : Options) :
    IO UInt32 := do
  let stubbed := o.adapter == "stub"
  -- The child is spawned in the run's own directory, so a relative path to the
  -- stub would no longer name it.
  let stubPath ← if stubbed then (fun q => q.toString) <$> IO.FS.realPath Acp.stubScript
    else pure ""
  let adapter := if stubbed then Acp.Adapter.stub stubPath else Acp.Adapter.ofName o.adapter
  -- Every run acts in a directory made for it: a workflow may end in an act that
  -- writes, and `Acp.Permission.grant` authorizes tool calls in the session's
  -- working directory.
  let dir ← match o.scratch with
    | some d => pure d
    | none => mkScratchDir
  -- …and every run is given something to act on, before the first question is
  -- put. A workflow whose questions are about files and whose directory holds
  -- none is a workflow every check passes and nothing happens in; that run was
  -- measured, and `Agentic/Core/Artifact.lean` records it.
  let seeded ← try
      seedWorkspace o.workspace path dir
    catch e =>
      IO.eprintln s!"agent-cat: {e}"
      IO.Process.exit 2
  let cfg : Acp.Config :=
    { adapter
    , args := o.adapterArgs
    , cwd := dir
    , readTimeoutMs := if stubbed then some 20000 else ({} : Acp.Config).readTimeoutMs
    , turnTimeoutMs := if stubbed then some 60000 else ({} : Acp.Config).turnTimeoutMs
      -- What a permission request arriving while *no question is under way*
      -- gets. Nothing this run asked for is outstanding then, so nothing is
      -- authorized; the per-question policy is `Exec.Settings.permission`, which
      -- `Exec.say` sets before every prompt.
    , permission := .cancel }
  -- What the run was given, stamped, before the first question is put. The
  -- comparison at the end of the run is against exactly this.
  let before ← fingerprint dir
  let warnings ← IO.mkRef 0
  let turns ← IO.mkRef (#[] : Array Turn)
  let permissions ← IO.mkRef (#[] : Array Acp.PermissionDecision)
  let st : Exec.Settings :=
    { -- Live, a person is asked at the keyboard and the adapter never answers for
      -- them; against the stub the stub answers, which is what makes an
      -- unattended run possible.
      askPersonOnStdin := !stubbed
      -- One session per question, live: a world is a function of the question
      -- (`Agentic/Core/World.lean`), and a session is a memory of the ones before
      -- it.
      freshSessionPerQuestion := !stubbed
    , retries := if stubbed then 1 else 2
      -- What the author's model names mean to *this* adapter. Empty unless
      -- `--model NAME=REAL` was given, and empty is the identity
      -- (`Exec.Settings.aliasFor_nil`).
    , modelAliases := o.modelAliases
    , log := fun msg => do
        warnings.modify (· + 1)
        unless o.quiet do IO.println s!"warn {msg}"
    , onTurn := fun c a r ms => turns.modify (·.push ⟨c, a, r, ms⟩)
      -- A permission decision is not a warning — granting an act is the run
      -- working — so it is printed as itself and counted as itself, and it is
      -- kept for the report (`RunReport.permissions`).
    , onPermission := fun d => do
        permissions.modify (·.push d)
        unless o.quiet do IO.println s!"perm {d.render}" }
  try
    unless o.quiet do
      let argsShown := String.intercalate " " cfg.args.toList
      IO.println s!"run: {path} against {o.adapter} {argsShown} (cwd {dir})"
      -- What the agent can see, named and sized. `Seeded.render_ne_nil`: this
      -- always says something, so an empty directory is a stated fact and not
      -- an omission.
      for l in seeded.render do IO.println l
      -- What the analysis quoted, before anything is spent. The check after the
      -- run is against these very numbers.
      for l in Explain.costLines p do IO.println l
    let res ← execCertifiedIO (st := st) (cfg := cfg) p
    let report :=
      RunReport.of p res.1 res.2.1 res.2.2 (← turns.get).toList (← permissions.get).toList
    unless o.quiet do for l in report.render do IO.println l
    -- What is on disk now, against what was on disk when the run started. An
    -- observation about this run and not a theorem — `WorkspaceDiff`'s docstring
    -- says what it is defeated by — and the one statement `agent-cat` makes
    -- about the world outside the process.
    let diff := WorkspaceDiff.of before (← fingerprint dir)
    -- Did the run *act*? Read off the replayed transcript, because whether an
    -- act ran is a fact about what the run meant; a run with no `.ack` event in
    -- it asked nothing that was permitted to write (`Exec.permissionByCode`).
    let acted := report.transcript.any (Event.hasCode .ack)
    unless o.quiet do for l in diff.render do IO.println l
    -- Every event of the replay is in the log, with the answer the replay reads.
    -- Without this the certificate is satisfied by a defaulted world
    -- (`certify_unit_vacuous`); with it, `Plan.certify_sound_of_covered` turns the
    -- certificate's *some* world into *every* world extending the log.
    checkTrue "every replayed event is recorded in the run's table" report.covered
    -- Dlg.execM_ask_hit: the interpreter looks up before it asks.
    check "table size = billMemo tick (one entry per distinct question)"
      (toString report.billMemo) (toString report.tableSize)
    -- Cost.bill_mem_leaves, as a runtime check on the IO layer: the bill of every
    -- run is a leaf of the tree `agent-cat cost` prints.
    checkTrue s!"the bill ({report.billFresh}) is one of the cost tree's leaves"
      ((Explain.leafBills p h).contains report.billFresh)
    -- Plan.runCertified_certified, in IO where it is a check and not a theorem.
    check "the run certifies" "true" (toString report.certified)
    -- No theorem, and no theorem is possible: bytes on a disk are not in the
    -- semantics. A run with no `.ack` event in it asked nothing that was
    -- permitted to write (`Exec.permissionByCode`), so a workspace that changed
    -- anyway was written to by something nobody authorized.
    match diff.unauthorised acted with
    | some complaint => throw <| IO.userError s!"FAIL {complaint}"
    | none =>
      IO.println <|
        if acted then
          s!"ok   the run acted, so a change in the workspace is information and not a \
             fault ({diff.paths.length} \
             {if diff.paths.length == 1 then "path differs" else "paths differ"})"
        else "ok   the run performed no act, and the workspace is unchanged"
    IO.println s!"agent-cat: {report.billFresh} consultations, {report.turns.length} turns, \
                  {report.totalMs}ms, {← warnings.get} warnings (cwd {dir})"
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"agent-cat: {e}"
    return 1

/-! ## The command line -/

/-- The three subcommands, `--help`, and a bare invocation that prints the usage.

A subcommand and a program, and then whatever the subcommand takes: `plan` and
`cost` take `--define` and nothing else, because a rendering has nothing to
configure but the program it renders, and an option handed to one is a mistake
reported rather than ignored. -/
def main (argv : List String) : IO UInt32 := do
  match argv with
  | [] =>
    IO.eprint usage
    return 1
  | "--help" :: _ | "-h" :: _ | "help" :: _ =>
    IO.print usage
    return 0
  | cmd :: path :: rest =>
    match cmd with
    | "plan" =>
      match parseDefineOptions rest with
      | .error m => do
        IO.eprintln s!"agent-cat: {m}"
        IO.eprint usage
        return 1
      | .ok ds => planCmd path ds
    | "cost" =>
      match parseDefineOptions rest with
      | .error m => do
        IO.eprintln s!"agent-cat: {m}"
        IO.eprint usage
        return 1
      | .ok ds => costCmd path ds
    | "run" =>
      match parseOptions rest with
      | .error m => do
        IO.eprintln s!"agent-cat: {m}"
        IO.eprint usage
        return 1
      | .ok o => withProgram path o.defines fun _ p h => runCmd path p h o
    | _ => do
      IO.eprintln s!"agent-cat: unknown subcommand `{cmd}`"
      IO.eprint usage
      return 1
  | _ :: [] =>
    IO.eprintln "agent-cat: a subcommand needs a program to work on"
    IO.eprint usage
    return 1
