import Agentic.Core.HardenPatch
import Agentic.Core.Report
import Agentic.Core.Artifact

/-!
# The workflow, run for real: `hardenPatch` end to end against an adapter

Run from the repository root:

```
lake exe harden_demo                        # the stub consents: seven consultations
lake exe harden_demo --refuse               # the stub refuses:  six, and no act
lake exe harden_demo --sloppy-apply         # the stub applies the WRONG patch,
                                            #   and the harness must catch it
printf 'yes\n' | lake exe harden_demo --adapter claude   # the real thing
printf 'no\n'  | lake exe harden_demo --adapter codex
```

**The two modes differ in three ways, and each is a discipline rather than a
convenience.** Against the stub everything is canned and the run is CI-safe;
live (`--adapter claude`, `--adapter codex`, or a path):

1. the workflow's *person* — the owner, who is asked to consent — is asked at
   the keyboard, not the adapter: the question goes to **stderr** and the answer
   is read from **stdin**, so a supervised run and `printf 'yes\n' | …` are the
   same run and stdout stays the transcript alone;
2. **a fresh session per question** (`Exec.Settings.freshSessionPerQuestion`):
   `Ω` is a function of the question and nothing else
   (`Agentic/Core/World.lean`), and one session carrying the whole workflow
   would be an answerer whose reply depends on what was asked before it. The
   memo table, not the agent's memory, is where this runtime keeps what was
   said;
3. the exact bill is *not* asserted. A live reviewer may object, and a revise
   round is one of the seven worlds `Harden.length_trace_hardenPatch` proves
   reachable — 10, 11, 13, 14 and 15 are runs, not failures. What is still
   asserted live is everything the theorems quantify over worlds about: the bill
   is one of the seven, the guide was read once, at most three drafts were
   asked for, consent holds if and only if the act was put, and the act applied
   the patch that was consented to.

*Every* run — stub or live — happens in a fresh `mktemp -d` holding a seed file,
because the workflow ends in an act that writes: `Acp.Permission.grant`
authorizes tool calls *in the session's working directory*, so that directory
had better be one nobody minds, and a harness that reads the file back needs
somewhere to read it from.

`test/AcpSmoke.lean` checks the wire and `test/ExecSmoke.lean` checks the
interpreter on a three-node plan. This runs the same stack (`Plan` → `denote` →
`Dlg.execM` → `Exec.oracle` → ACP → a child process) on the **flagship
workload**: `Agentic.Core.Harden.demo`, which is `hardenPatch "harden the
parser"`, the term the six kernel theorems and all seven bills are about.

**What is general is not here.** The report a run produces — its transcript, its
two bills, its coverage verdict, the rendering of all three — is
`Agentic/Core/Report.lean`, and the artifact check is
`Agentic/Core/Artifact.lean`. What is left in this file is what is *about this
workload*: the seven bills as a list, the two constants tied to the two proved
bills, the strengthening of `Harden.consent_of_ack` that the wire is checked
against, the seeded scratch directory, the words the act's prompt wraps a patch
in, and the command line. Everything else is a call into the library, which is
the test that the library object is the right one.

**What is checked, and which theorem each check shadows.** Every assertion below
is a *theorem* on the meaning side and a *check* on the `IO` side; the pairing is
the point, because the theorems are stated at `Id` and this run is not.

| check                                 | the theorem it shadows            |
| ------------------------------------- | --------------------------------- |
| every replayed event is in the log    | `Plan.certify_sound_of_covered`   |
| the bill is one of seven numbers      | `Harden.length_trace_hardenPatch` |
| the bill is 7 when consent is given   | `Harden.bill_apply_demo` (stub)   |
| the bill is 6 when it is refused      | `Harden.bill_refuse_demo` (stub)  |
| no `.ack` event when refused          | `Harden.no_ack_of_refused` (stub) |
| consent ⇔ the act was put             | `Harden.consent_of_ack`           |
| the act was handed the consented patch| `ack_quotes_consented_patch`      |
| the guide is asked exactly once       | `Harden.guide_once`               |
| at most three drafts                  | `Harden.draft_count_le_three`     |
| the table holds the memo bill         | `Dlg.execM_ask_hit`               |
| the run certifies                     | `Plan.runCertified_certified`     |
| the printed yes/no reads back         | *(no theorem — String primitives)*|
| the file on disk is that patch        | *(no theorem — see below)*        |

The three rows marked `(stub)` are the ones whose *hypothesis* is a fact about
the answering program — "this adapter approves and then consents" — and they are
checked only where the harness supplies it. Every other row is a statement about
every world, and is checked on every run.

**The last two rows have no theorem and cannot have one.** `Decode .ack _ =
some ()`: an acknowledgement carries nothing, so every proposition in this
package about the act is a proposition about the *question that was put*, and
the file the agent wrote is outside the language entirely. The check that reads
it back is the only thing standing between "the workflow applied the patch it
consented to" and "somebody said DONE" — and it is exercised in both directions
in CI, since `--sloppy-apply` is a run this harness is required to reject. The
row above it is smaller and has the same shape: `String` operations do not
reduce in this Lean, so `Decode .flag (sayFlag b) = some b` — that the words the
transcript prints are the words the trusted base reads — is checked here rather
than proved anywhere.

The two constants this file names are *tied to the proofs*, not written beside
them: `bill_apply_eq` and `bill_refuse_eq` are the proved theorems restated at
`expectedApply`/`expectedRefuse`, so editing either number stops the build.

**The transcript printed is the semantic one.** It is not a log the runtime kept
on the side: it is `Plan.trace (worldOf t) demo Env.nil`, the transcript the
*meaning* has in the world the run's own memo table denotes, and
`RunReport.of` computes it from the plan and the table so that no caller can
report a transcript the log does not denote. `Plan.adequacy` — at `Id`, where
such a thing can be proved — says every world extending `t` gives that same
transcript, so printing the replay is printing what happened, provided the table
really covers it. That proviso is `Plan.Covered`.

**What `certify` is worth here, honestly.** `Harden.demo` returns `Unit`, and
`Plan.run ω demo Env.nil = ()` holds in every world (`Harden.run_terminates`) —
so `certify demo t ()` is `true` for *any* table, the empty one included, which
`certify_demo_vacuous` below records as the instance it is of the library's
`certify_unit_vacuous`: *every* closed unit-valued plan certifies against every
table. The certificate is not lying; it is vacuous, because a `Unit`-valued plan
has no value for a world to disagree about. That is why this demo does not stop
at the certificate. Coverage is the check that carries content on this workload:
every event of the replayed transcript must be *recorded in the table*, with the
answer the replay reads. Without it a run in which the oracle answered nothing at
all would still certify, because `worldOf` defaults — and the default at
`.verdict` is approval. With it, `Plan.certify_sound_of_covered` turns the
certificate's *some* world into *every* world extending the log. What makes that
pinning worth having is the other half of the rule, and it lives in
`Exec.oracle`: an answer the trusted base could not read aborts the run rather
than entering the table, so a covered event is an event somebody actually
answered.
-/

open Agentic.Core

/-! ## The bills this workload can run up -/

/-- `[[bills]]` = the seven bills a run of this workload can produce.

**The theorem** (`Harden.length_trace_hardenPatch`, restated at this list):
every world's transcript has one of these lengths, so the runtime check against
it can only fail if the `IO` layer produced a transcript no world can. -/
def bills : List Nat := [6, 7, 10, 11, 13, 14, 15]

theorem bills_eq (ω : Ω) (spec : String) :
    (Plan.trace ω (Harden.hardenPatch spec) Env.nil).length ∈ bills :=
  Harden.length_trace_hardenPatch ω spec

/-- …and the library's membership check at this workload: whatever table a run
leaves behind, the replay's bill is one of the seven (`Plan.billIn_replay`). The
`IO` check below is this equation, computed. -/
theorem billIn_bills (t : Table) :
    Trace.billIn bills (Plan.trace (worldOf t) Harden.demo Env.nil) = true :=
  Plan.billIn_replay Harden.demo bills (fun ω => bills_eq ω "harden the parser") t

/-- `[[expectedApply]]` = the bill when the panel approves at once and the owner
consents: guide, draft, three reviewers, the owner, the act. -/
def expectedApply : Nat := 7

/-- **The theorem** (`Harden.bill_apply_demo`, restated at `expectedApply`):
change the constant and this stops compiling. -/
theorem bill_apply_eq :
    billFresh tick (Plan.trace Harden.ωApply Harden.demo Env.nil)
      = Multiplicative.ofAdd expectedApply :=
  Harden.bill_apply_demo

/-- `[[expectedRefuse]]` = the bill when the owner refuses: the same, without the
act. -/
def expectedRefuse : Nat := 6

/-- **The theorem** (`Harden.bill_refuse_demo`, restated at `expectedRefuse`). -/
theorem bill_refuse_eq :
    billFresh tick (Plan.trace Harden.ωRefuse Harden.demo Env.nil)
      = Multiplicative.ofAdd expectedRefuse :=
  Harden.bill_refuse_demo

/-! ## What the run must show -/

/-- **The certificate is vacuous on this workload, and this is the instance.**
`certify demo t ()` is `true` for every table — the empty one included — because
`Unit` has one inhabitant and `Plan.run` therefore cannot disagree with the run.

Recorded as a theorem rather than a caveat because it is the honest reading of
the `ok   the run certifies` line the demo prints: on a `Unit`-valued plan that
line is a check that the wrapper ran, and `Plan.Covered` is what checks the log.
The general fact — every closed `Plan [] Unit`, every table — is
`certify_unit_vacuous` in `Agentic/Core/Report.lean`, together with
`not_covered_nil_ticks`, which exhibits a certified run nobody answered. -/
theorem certify_demo_vacuous (t : Table) : certify Harden.demo t () = true :=
  certify_unit_vacuous Harden.demo t

/-! ### The act is the *consented* act

`Harden.consent_of_ack` says an `.ack` event implies *some* patch was consented
to. That is one existential short of what the workflow claims, and the gap is
not academic: a run whose act applied something other than what the owner saw
would satisfy it. The theorem below closes it — the patch the act was handed is
the patch the owner said yes to, in every world — and the checks in `main`
carry the same sentence to the `IO` layer, where the only evidence is bytes. -/

/-- **The act quotes the consented patch.** Strengthening of
`Harden.consent_of_ack`: an `.ack` event in any world is *the* apply question at
some patch `p`, and the owner's answer at that same `p` was yes. The two
occurrences of `p` are the content; `consent_of_ack` binds them separately and
so permits an act on a patch nobody was shown.

Proved here rather than in `Agentic/Core/HardenPatch.lean` because it is what
this demo checks against the wire, and because the six kernel theorems there are
stated as they were asked for. -/
theorem ack_quotes_consented_patch (ω : Ω) (spec : String) (e : Event)
    (he : e ∈ Plan.trace ω (Harden.hardenPatch spec) Env.nil) (hc : e.c = Code.ack) :
    ∃ p : El .text,
      e = ⟨.ack, Harden.applyQ p, ω .ack (Harden.applyQ p)⟩ ∧
        ω .flag (Harden.consentQ p) = true := by
  rw [Harden.trace_hardenPatch, Harden.trace_hardenD] at he
  simp only [List.mem_cons] at he
  rcases he with rfl | rfl | he
  · exact absurd hc (by simp)
  · exact absurd hc (by simp)
  rcases List.mem_append.mp he with h | h
  · exact absurd hc (Harden.loopD_code_ne_ack ω _ 2 _ e h)
  · revert h
    rcases hfin : Dlg.run ω (Harden.loopD (ω .text Harden.guideQ) 2
        (ω .text (Harden.deep.onQ .text (Harden.draftQ spec)))) with _ | p
    · intro h; exact absurd h (by simp)
    · intro h
      rw [Harden.trace_finishD_some] at h
      simp only [List.mem_cons] at h
      rcases h with rfl | h
      · exact absurd hc (by simp)
      · by_cases hok : ω .flag (Harden.consentQ p) = true
        · rw [if_pos hok] at h
          simp only [List.mem_cons, List.not_mem_nil, or_false] at h
          exact ⟨p, h, hok⟩
        · rw [if_neg hok] at h
          exact absurd h (by simp)

/-- `Harden.demo` is the workflow at the owner's specification, by `rfl`. -/
theorem demo_eq : Harden.demo = Harden.hardenPatch "harden the parser" := rfl

/-! ## The questions say what the header says

`Agentic/Core/HardenPatch.lean` writes the answer format into the *questions*,
because a live model reads the words it was sent and not the doctrine; and
`Exec.answerSpec` writes it into the header of every question, because a
question that forgot is still owed the instruction. Two places, one sentence,
and this is the one module that imports both — so the agreement is a theorem
rather than a comment, and a drift in either file stops the build. -/

/-- **The reviewers' instruction is the trusted base's own.** -/
theorem verdictSpec_eq : Harden.verdictSpec = Exec.answerSpec .verdict := rfl

/-- **…and the owner's.** -/
theorem flagSpec_eq : Harden.flagSpec = Exec.answerSpec .flag := rfl

/-- **…and the workload's verdict projection is the library's.** The transcript
is rendered by `sayVerdict`, which reads a verdict's objections with
`Verdict.objections`; the revision prompts quote them with `Harden.objections`.
One function, written twice because the workload predates the report, and `rfl`
here is what keeps them one function. -/
theorem objections_eq (v : Verdict) : Harden.objections v = Verdict.objections v := rfl

/-! ## Where a live run happens -/

/-- `[[seedText]]` = the parser `Harden.demo`'s specification is about.

**Why the scratch directory is not empty.** `demo` is `hardenPatch "harden the
parser"`, and the first live run of this file was made in an empty directory:
the author answered, correctly, that a diff against files that do not exist
would be fiction; the three reviewers then approved that explanation; the owner
consented to it; and the act reported `DONE` having written nothing. Every check
passed, because every check is about the *shape* of a run and that run had the
right shape — which is the sharpest available demonstration that the theorems
are about worlds and not about whether an agent did anything useful.

A demo should nevertheless be about something, so the directory gets a parser
with an unbounded `strcpy` in it: a thing "harden" has a meaning for, small
enough that a live turn reads it in one look. -/
def seedText : String :=
  "#include <stdio.h>\n\
   #include <string.h>\n\
   \n\
   /* Parse one line of the form NAME=VALUE into name and value. */\n\
   int parse_line(const char *line, char *name, char *value) {\n\
   \x20 const char *eq = strchr(line, '=');\n\
   \x20 if (!eq) return -1;\n\
   \x20 memcpy(name, line, eq - line);\n\
   \x20 name[eq - line] = '\\0';\n\
   \x20 strcpy(value, eq + 1);\n\
   \x20 return 0;\n\
   }\n"

/-- `[[scratchDir]]` = `Artifact.mkScratchDir` with `parse.c` in it: the fresh
directory every run of this file is given, seeded with the thing the
specification is about.

The general half — why a run that acts is given a directory nobody minds at all
— is `mkScratchDir`'s docstring in `Agentic/Core/Artifact.lean`. What is here is
the seed, which is a fact about this workload. -/
def scratchDir : IO String := do
  let dir ← mkScratchDir
  IO.FS.writeFile (System.FilePath.mk dir / "parse.c") seedText
  return dir

/-! ### What the act left on disk, checked against what was consented to

`Decode .ack _ = some ()`: an acknowledgement carries no information, so `DONE`
is evidence that something replied and not that the consented patch was applied.
`ack_quotes_consented_patch` pins what the act was *asked* to do; nothing in the
semantics can pin what it did, because what it did is a fact about a file. So
the file is read back here, in `IO` (`ArtifactCheck.of`), and compared with the
patch — and the run fails if they disagree.

**Why this is not decoration.** The live run that preceded this section applied
a patch that reintroduced the exact defect the panel had objected to (`return
-2;` where the approved diff added `return -1;`), *after* consent, and every
check printed `ok`, because the only thing checked about the act was that a
`.ack` event existed and the only thing printed about the directory was a list
of filenames. The limits of the comparison that replaced it are stated where it
is defined. -/

/-- The words `Harden.applyText` wraps a patch in, on the left… -/
def actPrefix : String := "Apply:\n"

/-- …and on the right. -/
def actSuffix : String := "\nWrite the patched file here, then reply DONE."

/-- **The extractor is pinned to the constructor.** `Harden.applyText` is these
two constants around the patch, by `rfl`, so rewording the act's prompt breaks
this build rather than quietly making the artifact check unfalsifiable — the
same discipline as `verdictSpec_eq` above. That `stripAffix` inverts it is a
fact about `String.startsWith` and friends, which this Lean cannot reduce; it is
checked at runtime instead, on every run, before the check that depends on it. -/
theorem actText_eq (p : String) : Harden.applyText p = actPrefix ++ p ++ actSuffix := rfl

/-! ## The harness

`check` and `checkTrue` are this file's exit protocol and not a library object: a
failing check throws, so that `lake exe harden_demo` ends nonzero, and a passing
one prints `ok` to the transcript. A consumer that has to *return* a failure —
the run report over a wire, say — reads `RunReport` and needs none of this. -/

/-- Fail loudly, with both sides quoted. -/
def check (what expected actual : String) : IO Unit :=
  if expected == actual then
    IO.println s!"ok   {what}"
  else
    throw <| IO.userError s!"FAIL {what}\n  expected: {expected}\n  actual:   {actual}"

/-- Fail loudly on a claim that is simply supposed to hold. -/
def checkTrue (what : String) (b : Bool) : IO Unit :=
  if b then IO.println s!"ok   {what}" else throw <| IO.userError s!"FAIL {what}"

/-- The argument after `flag`, if the command line gave one. -/
def valueOf (argv : List String) (flag : String) : Option String :=
  match argv.dropWhile (· != flag) with
  | _ :: v :: _ => some v
  | _ => none

/-- Run the workflow against an adapter and check the run against the theorems.

`--refuse` starts the stub in the variant that answers *no* to the consent
question, which is `Harden.no_ack_of_refused`'s hypothesis made of bytes; live,
the owner answers for themselves and the flag is refused as meaningless.
`--sloppy-apply` starts it in the variant whose act writes the lines the patch
*removes* instead of the ones it adds — a consented patch and a different file
on disk, which is the measured live failure in its smallest form, and which this
harness must therefore *fail to accept*. `--adapter NAME` (`stub`, `claude`,
`codex`, or a path) chooses the answering program; `--cwd DIR` overrides the
scratch directory a run is otherwise given. Live runs bill real money, which is
why the stub is the default.

**Every run gets a directory made for it**, stub included, and not only a live
one. The workflow ends in an act that writes a file; a harness that checks what
was written needs somewhere to look, and the repository is not it. The stub's
script is resolved to an absolute path first, because the child is spawned in
that directory and a relative path would no longer name it.

**Latency and stop reasons are printed, and no theorem mentions them.** `Ω` is a
function of the question, so how long an answer took and how its turn ended are
not part of what a run *means* — which is exactly why they belong in the report:
they are what the semantic transcript cannot hold, and they are what an operator
watching a live agent needs. They are `RunReport.turns`, which is the field of
the report marked observation rather than meaning.

**Warnings are printed as they happen** (`acat-fuk`, LOW #3): a run that ends
`0` with a scope the adapter refused, a reply that had to be re-asked or a turn
that did not complete should not look identical to one where none of that
occurred, so `Settings.log` goes to stdout here and the count is part of the
report. -/
def main (argv : List String) : IO UInt32 := do
  let refusing := argv.contains "--refuse"
  let sloppy := argv.contains "--sloppy-apply"
  let adapterName := (valueOf argv "--adapter").getD "stub"
  let stubbed := adapterName == "stub"
  -- The stub is started *in the run's directory*, so the path to it has to be
  -- one that does not depend on where anybody stands.
  let stubPath ← if stubbed then
      (fun p => p.toString) <$> IO.FS.realPath Acp.stubScript
    else pure ""
  let adapter := if stubbed then Acp.Adapter.stub stubPath
    else Acp.Adapter.ofName adapterName
  if (refusing || sloppy) && !stubbed then
    IO.eprintln "harden_demo: --refuse and --sloppy-apply are stub flags; \
                 a live agent answers, and acts, for itself"
    return 1
  -- The run acts on the world, so it acts in a directory made for it.
  let dir ← match valueOf argv "--cwd" with
    | some d => pure d
    | none => scratchDir
  let cfg : Acp.Config :=
    { adapter
    , args := (if refusing then #["--refuse"] else #[])
                ++ (if sloppy then #["--sloppy-apply"] else #[])
    , cwd := dir
      -- The stub answers instantly; a live agent is given the generous
      -- defaults, which are what they are for.
    , readTimeoutMs := if stubbed then some 20000 else ({} : Acp.Config).readTimeoutMs
    , turnTimeoutMs := if stubbed then some 60000 else ({} : Acp.Config).turnTimeoutMs }
  let warnings ← IO.mkRef 0
  let turns ← IO.mkRef (#[] : Array Turn)
  let st : Exec.Settings :=
    { -- Live, the owner is the owner: the consent question goes to the keyboard
      -- (stderr and stdin, so the run pipes), and the adapter never answers for
      -- a person. Against the stub the stub answers, which is what makes an
      -- unattended CI run possible at all.
      askPersonOnStdin := !stubbed
      -- One session per question, live: a world is a function of the question
      -- (`Agentic/Core/World.lean`), and a session is a memory of the ones
      -- before it. See `Exec.Settings.freshSessionPerQuestion`.
      freshSessionPerQuestion := !stubbed
      -- A live reviewer objects in prose; two attempts before a flag is called
      -- unreadable is the difference between a run and a lost run.
    , retries := if stubbed then 1 else 2
    , log := fun msg => do
        warnings.modify (· + 1)
        IO.println s!"warn {msg}"
    , onTurn := fun c a r ms => turns.modify (·.push ⟨c, a, r, ms⟩) }
  let expected := if refusing then expectedRefuse else expectedApply
  try
    let argsShown := String.intercalate " " cfg.args.toList
    IO.println s!"harden_demo: {adapterName} {argsShown} (cwd {dir})"
    IO.println "plan: hardenPatch \"harden the parser\" (level = branch)"
    -- The one line that runs everything: denote, fold, oracle, wire, child.
    let res ← execCertifiedIO (st := st) (cfg := cfg) Harden.demo
    let turnLog ← turns.get
    -- The run, as a value: the transcript the meaning has in the world the run's
    -- own memo table denotes, the two bills, the coverage verdict, and the half
    -- no theorem can hold — how each turn ended and what it cost in wall-clock
    -- time.
    let report := RunReport.of Harden.demo res.1 res.2.1 res.2.2 turnLog.toList
    let tr : Trace := report.transcript
    for l in report.render do IO.println l
    -- The transcript above prints answers in the words the addressee was told to
    -- use. That the printed word is the one the trusted base reads back is a
    -- fact about String primitives, which do not reduce in this Lean, so it is
    -- checked here rather than proved anywhere.
    checkTrue "the yes/no this run prints is what Decode reads back"
      (Decode .flag (sayFlag true) == some true && Decode .flag (sayFlag false) == some false)
    -- Every event of the replay is in the log, with the answer the replay reads:
    -- without this the certificate below is satisfied by a defaulted world
    -- (`certify_unit_vacuous`), and with it the certificate's *some* world
    -- becomes *every* world extending the log (`Plan.certify_sound_of_covered`).
    checkTrue "every replayed event is recorded in the run's table" report.covered
    check "table size = billMemo tick (one entry per distinct question)"
      (toString report.billMemo) (toString report.tableSize)
    -- Harden.length_trace_hardenPatch, as a runtime check on the IO layer
    -- (`billIn_bills`).
    checkTrue s!"bill ∈ {bills}" (Trace.billIn bills tr)
    -- Harden.bill_apply_demo / Harden.bill_refuse_demo, likewise — and only
    -- against the stub, whose answers are the two paths those theorems price.
    -- A live reviewer may object, and a revise round is a *proved-reachable
    -- world* (`Harden.length_trace_hardenPatch` lists all seven), not a
    -- failure; pinning a live run to 7 would be pinning the agent's opinion.
    if stubbed then
      check "bill (against the proved bill of this path)" (toString expected)
        (toString report.billFresh)
    -- Harden.guide_once: sharing is a variable used twice and costs one event.
    check "the guide was read exactly once" "1"
      (toString (tr.countP Harden.isGuide))
    -- Harden.draft_count_le_three.
    checkTrue "the author was asked for a patch at most three times"
      (tr.countP Harden.isDraft ≤ 3)
    -- Harden.consent_of_ack / no_ack_of_refused: the gate, observed. Stated as
    -- the equivalence, because live the owner answers for themselves and the
    -- harness does not get to say in advance which side of it the run is on.
    check "consent ⇔ the apply question was put"
      (toString (Trace.anyFlagTrue tr)) (toString (tr.any (Event.hasCode .ack)))
    if stubbed then
      if refusing then
        checkTrue "consent refused: the apply question was never put"
          (!tr.any (Event.hasCode .ack))
      else
        checkTrue "consent given: the apply question was put" (tr.any (Event.hasCode .ack))
    -- Plan.runCertified_certified, in IO where it is a check and not a theorem.
    check "the run certifies" "true" (toString report.certified)
    -- The act, against the artifact. `ack_quotes_consented_patch` says the plan
    -- can only hand the act the patch the owner approved; these checks are what
    -- a run can observe of that, and the last of them is the only statement in
    -- this file about the world outside the process.
    match tr.find? (Event.hasCode .ack) with
    | none =>
      checkTrue "no act was put, and the transcript agrees nobody consented"
        (!Trace.anyFlagTrue tr)
      -- Nothing was authorized, so nothing should have been written. Asserted
      -- only against the stub: a live agent may write while it reads.
      if stubbed then
        check "consent refused: the directory still holds only the seed" "parse.c"
          (String.intercalate " " (← listDir dir))
      else
        IO.println s!"{dir}: {String.intercalate " " (← listDir dir)}"
    | some e =>
      -- The extractor inverts `Harden.applyText` (pinned to it by `actText_eq`);
      -- that it does is a fact about String primitives, so it is checked and not
      -- assumed — and checked before the check that rests on it.
      check "the patch is recovered from the act's prompt" "the patch"
        ((stripAffix actPrefix actSuffix (Harden.applyText "the patch")).getD "<not recovered>")
      match stripAffix actPrefix actSuffix e.q.prompt with
      | none =>
        throw <| IO.userError s!"FAIL the act's prompt does not quote a patch\n  \
          prompt: {head 200 e.q.prompt}"
      | some patch =>
        -- ack_quotes_consented_patch, read off the bytes: the act was handed the
        -- patch the owner was shown and said yes to, and not another one.
        checkTrue "the act was handed the very patch the owner consented to"
          (tr.any fun e' => match e' with
            | ⟨.flag, q, ok⟩ => ok && q.prompt == Harden.consentText patch
            | _ => false)
        -- …and the file on disk is that patch and not some other work.
        let art ← ArtifactCheck.of dir (addedLines patch)
        for l in art.render do IO.println l
        if sloppy then
          checkTrue "an act that wrote something else is caught (--sloppy-apply)"
            (!art.ok)
        else
          checkTrue "the act wrote the consented patch: every added line is on disk"
            art.ok
    -- Read off the transcript, not off the command line: `--refuse` is a fact
    -- about how the *stub* was started, and live the owner decides at the
    -- keyboard, so a summary that named the flag would misreport every live
    -- refusal as a consent. (It did, once, before this line was written.)
    let variant := if Trace.anyFlagTrue tr then "consent given" else "consent withheld"
    IO.println s!"harden_demo: all checks passed ({variant}, \
                  {← warnings.get} warnings)"
    -- Ascribed: the `for` above leaves the block's type a metavariable, and an
    -- unascribed `0` would default to `Nat`.
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"harden_demo: {e}"
    return 1
