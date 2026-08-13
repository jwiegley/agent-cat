import Agentic.Core.HardenPatch
import Agentic.Core.Certify

/-!
# The workflow, run for real: `hardenPatch` end to end against an adapter

Run from the repository root:

```
lake exe harden_demo              # the adapter consents: seven consultations
lake exe harden_demo --refuse     # the adapter refuses:  six, and no act
```

`test/AcpSmoke.lean` checks the wire and `test/ExecSmoke.lean` checks the
interpreter on a three-node plan. This runs the same stack (`Plan` → `denote` →
`Dlg.execM` → `Exec.oracle` → ACP → a child process) on the **flagship
workload**: `Agentic.Core.Harden.demo`, which is `hardenPatch "harden the
parser"`, the term the six kernel theorems and all seven bills are about.

**What is checked, and which theorem each check shadows.** Every assertion below
is a *theorem* on the meaning side and a *check* on the `IO` side; the pairing is
the point, because the theorems are stated at `Id` and this run is not.

| check                               | the theorem it shadows            |
| ----------------------------------- | --------------------------------- |
| the bill is one of seven numbers    | `Harden.length_trace_hardenPatch` |
| the bill is 7 when consent is given | `Harden.bill_apply_demo`          |
| the bill is 6 when it is refused    | `Harden.bill_refuse_demo`         |
| no `.ack` event when refused        | `Harden.no_ack_of_refused`        |
| an `.ack` event means consent       | `Harden.consent_of_ack`           |
| the guide is asked exactly once     | `Harden.guide_once`               |
| at most three drafts                | `Harden.draft_count_le_three`     |
| the table holds the memo bill       | `Dlg.execM_ask_hit`               |
| the run certifies                   | `Plan.runCertified_certified`     |

The two constants this file names are *tied to the proofs*, not written beside
them: `bill_apply_eq` and `bill_refuse_eq` are the proved theorems restated at
`expectedApply`/`expectedRefuse`, so editing either number stops the build.

**The transcript printed is the semantic one.** It is not a log the runtime kept
on the side: it is `Plan.trace (worldOf t) demo Env.nil`, the transcript the
*meaning* has in the world the run's own memo table denotes. `Plan.adequacy` —
at `Id`, where such a thing can be proved — says every world extending `t` gives
that same transcript, so printing the replay is printing what happened, provided
the table really covers it. That proviso is `covered` below.

**What `certify` is worth here, honestly.** `Harden.demo` returns `Unit`, and
`Plan.run ω demo Env.nil = ()` holds in every world (`Harden.run_terminates`) —
so `certify demo t ()` is `true` for *any* table, the empty one included, which
`certify_demo_vacuous` below proves rather than alleges. The certificate is not
lying; it is vacuous, because a `Unit`-valued plan has no value for a world to
disagree about. That is why this demo does not stop at the certificate.
`covered` is the check that carries content on this workload: every event of the
replayed transcript must be *recorded in the table*, with the answer the replay
reads. Without it a run in which the oracle answered nothing at all would still
certify, because `worldOf` defaults — and the default at `.verdict` is approval.
With it, the replay is pinned to the log at every step. What makes that pinning
worth having is the other half of the rule, and it lives in `Exec.oracle`: an
answer the trusted base could not read aborts the run rather than entering the
table, so a covered event is an event somebody actually answered.
-/

open Agentic.Core

/-! ## Rendering: a transcript a human can read -/

/-- `[[pad n s]]` = `s` in a field at least `n` characters wide, so the columns
line up. Presentation only; nothing downstream reads it. -/
def pad (n : Nat) (s : String) : String := s ++ "".pushn ' ' (n - s.length)

/-- `[[head n s]]` = the first `n` characters of `s` flattened onto one line,
with `…` if there was more. One event is one line, so a prompt quoting a whole
patch has to be cut somewhere. -/
def head (n : Nat) (s : String) : String :=
  let flat := s.replace "\n" "\\n"
  if flat.length ≤ n then flat else (flat.take n).toString ++ "…"

/-- `[[sayFlag b]]` = a yes/no answer in the words `Exec.answerSpec` asked for,
so that what is printed is what the addressee was told to say. Separate from
`sayAnswer` only because `El .flag` is `Bool` by unfolding and an `if` will not
unfold it. -/
def sayFlag (b : Bool) : String := if b then "yes" else "no"

/-- `[[sayAnswer c a]]` = the answer `Decode` read, written back out in the
vocabulary of its code — for a reader, not for the interpreter, which is why it
is here and not in `Agentic/Core/Exec.lean`.

`.verdict` prints in the three cases `Plan.caseV` branches on (`declined`,
`approve`, the objections), because those are the only three there are
(`Exec.tag_decodeVerdict`). -/
def sayAnswer : (c : Code) → El c → String
  | .text, s => s
  | .verdict, v =>
      if Verdict.approvedB v then "approve"
      else if v = Verdict.declined then "declined"
      else Harden.render v
  | .flag, b => sayFlag b
  | .ack, _ => "ok"

/-- `[[axes q]]` = the question's scope, as the two axes the interpreter reads
off it: the model axis (which rides in the prompt header, ACP v1 having no call
for it) and the mode axis (which rides on the protocol). `-` is an axis the
author left silent. -/
def axes {c : Code} (q : Q c) : String :=
  let m := match Exec.modelAxis q with | some m => m | none => "-"
  let d := match Exec.modeAxis q with | some d => d | none => "-"
  s!"model={m} mode={d}"

/-- `[[line e]]` = one event as one line: who was asked, under what scope, the
head of what was said to them, and the head of what came back. -/
def line (e : Event) : String :=
  s!"  {pad 24 (Exec.Addressee.render e.q.addressee)}{pad 20 (axes e.q)}\
     {pad 10 s!"({Exec.Code.name e.c})"}{pad 46 (head 44 e.q.prompt)} -> \
     {head 40 (sayAnswer e.c e.a)}"

/-! ## The bill, as a number -/

/-- `[[billNat tr]]` = what the transcript comes to under `tick`, as a `Nat`.

**Equation** (`billNat_eq`, proved adjacent): `ofAdd (billNat tr) = billFresh tick tr`
— this is the bill of `Agentic/Core/Cost.lean` and not a second count, read
through the isomorphism `Multiplicative Nat ≅ Nat` so that it can be printed. -/
def billNat (tr : Trace) : Nat := Multiplicative.toAdd (billFresh tick tr)

/-- **The equation.** The number printed *is* the bill. -/
theorem billNat_eq (tr : Trace) : Multiplicative.ofAdd (billNat tr) = billFresh tick tr := rfl

/-- …and `tick` charges one per consultation, so the bill is the length of the
transcript (`billFresh_tick`). -/
theorem billNat_eq_length (tr : Trace) : billNat tr = tr.length := by
  simp [billNat, billFresh_tick]

/-- **The counting price at a list of keys**: `tick` charges one per question,
so a bill is a length. `billFresh_tick` of `Agentic/Core/Cost.lean` is this at
`t.map Event.key`; the memo bill needs it at the deduplicated list, which is
`memoNat_eq_dedup` below. -/
theorem billOfKeys_tick (ks : List Key) :
    billOfKeys tick ks = Multiplicative.ofAdd ks.length := by
  induction ks with
  | nil => rfl
  | cons k ks ih =>
    rw [billOfKeys_cons, ih, List.length_cons]
    show Multiplicative.ofAdd 1 * Multiplicative.ofAdd ks.length = _
    rw [← ofAdd_add, Nat.add_comm]

/-- `[[memoNat tr]]` = what the transcript comes to when each **distinct**
question is charged once: `Cost.billMemo` at `tick`, as a number.

**Equation** (`memoNat_eq_dedup`, proved adjacent): it is the number of distinct
questions in the transcript — hence exactly the number of entries a memoizing
run's table must hold. Checking it against the table's length is how this demo
observes `Dlg.execM`'s look-up-before-asking, and it is the honest form of that
check: `billMemo ∣ billFresh` in general (`billMemo_dvd_billFresh`), so "table
length = transcript length" would be a claim about this workload — where every
question happens to be distinct — rather than about the interpreter. -/
def memoNat (tr : Trace) : Nat := Multiplicative.toAdd (billMemo tick tr)

/-- **The equation.** The number checked *is* the memo bill. -/
theorem memoNat_eq (tr : Trace) : Multiplicative.ofAdd (memoNat tr) = billMemo tick tr := rfl

/-- …and it counts the distinct questions. -/
theorem memoNat_eq_dedup (tr : Trace) : memoNat tr = ((tr.map Event.key).dedup).length := by
  simp [memoNat, billMemo, billOfKeys_tick]

/-- `[[bills]]` = the seven bills a run of this workload can produce.

**The theorem** (`Harden.length_trace_hardenPatch`, restated at this list):
every world's transcript has one of these lengths, so the runtime check against
it can only fail if the `IO` layer produced a transcript no world can. -/
def bills : List Nat := [6, 7, 10, 11, 13, 14, 15]

theorem bills_eq (ω : Ω) (spec : String) :
    (Plan.trace ω (Harden.hardenPatch spec) Env.nil).length ∈ bills :=
  Harden.length_trace_hardenPatch ω spec

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

/-- `[[covered t e]]` = the table records this event, with this answer.

The check that makes the certificate non-vacuous on a `Unit`-valued plan: a cell
the run never asked about is answered by `worldOf`'s `Inhabited` default, so a
replay can be reproduced by a table that never saw it. Requiring coverage is the
honest form of "the log warrants this transcript"; it closes the gap `certify`'s
docstring names, and it says nothing about *who* put an entry in the table,
which is why `Exec.oracle` has to refuse to put an unread answer there at all. -/
def covered (t : Table) (e : Event) : Bool :=
  match lookup t e.c e.q with
  | some a => a = e.a
  | none => false

/-- **The certificate is vacuous on this workload, and this is the proof.**
`certify demo t ()` is `true` for every table — the empty one included — because
`Unit` has one inhabitant and `Plan.run` therefore cannot disagree with the run.

Recorded as a theorem rather than a caveat because it is the honest reading of
the `ok   the run certifies` line the demo prints: on a `Unit`-valued plan that
line is a check that the wrapper ran, and `covered` above is what checks the
log. A workload whose answer is *observable* — a plan returning the patch, say —
would make the certificate bite; this one does not, and saying so in Lean is
cheaper than saying so in a comment. -/
theorem certify_demo_vacuous (t : Table) : certify Harden.demo t () = true := rfl

/-- `[[isAck e]]` = this event put an `.ack` question — and `applyQ` is the only
one in the workflow, so an `.ack` in the transcript *is* the act
(`Harden.consent_of_ack`). -/
def isAck (e : Event) : Bool := e.c = Code.ack

/-- `Harden.demo` is the workflow at the owner's specification, by `rfl`. -/
theorem demo_eq : Harden.demo = Harden.hardenPatch "harden the parser" := rfl

/-! ## The harness -/

/-- Fail loudly, with both sides quoted. -/
def check (what expected actual : String) : IO Unit :=
  if expected == actual then
    IO.println s!"ok   {what}"
  else
    throw <| IO.userError s!"FAIL {what}\n  expected: {expected}\n  actual:   {actual}"

/-- Fail loudly on a claim that is simply supposed to hold. -/
def checkTrue (what : String) (b : Bool) : IO Unit :=
  if b then IO.println s!"ok   {what}" else throw <| IO.userError s!"FAIL {what}"

/-- Run the workflow against the stub adapter and check the run against the
theorems. `--refuse` starts the stub in the variant that answers *no* to the
consent question, which is `Harden.no_ack_of_refused`'s hypothesis made of
bytes. -/
def main (argv : List String) : IO UInt32 := do
  let refusing := argv.contains "--refuse"
  let cfg : Acp.Config :=
    { cmd := "python3"
    , args := if refusing then #["test/stub_adapter.py", "--refuse"]
              else #["test/stub_adapter.py"]
    , cwd := "."
    , timeoutMs := some 20000 }
  let expected := if refusing then expectedRefuse else expectedApply
  try
    let argsShown := String.intercalate " " cfg.args.toList
    IO.println s!"harden_demo: {cfg.cmd} {argsShown}"
    IO.println "plan: hardenPatch \"harden the parser\" (level = branch)"
    -- The one line that runs everything: denote, fold, oracle, wire, child.
    let res ← execCertifiedIO (st := {}) (cfg := cfg) Harden.demo
    let table : Table := res.2.1
    let certified : Bool := res.2.2
    -- The transcript the meaning has in the world the run's own table denotes.
    let tr : Trace := Plan.trace (worldOf table) Harden.demo Env.nil
    IO.println "--- transcript (addressee | scope | code | prompt | answer) ---"
    for e in tr do IO.println (line e)
    IO.println "---"
    let bill := billNat tr
    IO.println s!"bill: {bill} consultations fresh, {memoNat tr} memoized \
                 (tick: one unit per consultation)"
    -- Every event of the replay is in the log, with the answer the replay reads:
    -- without this the certificate below is satisfied by a defaulted world.
    checkTrue "every replayed event is recorded in the run's table"
      (tr.all (covered table))
    check "table size = billMemo tick (one entry per distinct question)"
      (toString (memoNat tr))
      (toString (List.length (table : List ((c : Code) × Q c × El c))))
    -- Harden.length_trace_hardenPatch, as a runtime check on the IO layer.
    checkTrue s!"bill ∈ {bills}" (bills.contains bill)
    -- Harden.bill_apply_demo / Harden.bill_refuse_demo, likewise.
    check "bill (against the proved bill of this path)" (toString expected) (toString bill)
    -- Harden.guide_once: sharing is a variable used twice and costs one event.
    check "the guide was read exactly once" "1"
      (toString (tr.countP Harden.isGuide))
    -- Harden.draft_count_le_three.
    checkTrue "the author was asked for a patch at most three times"
      (tr.countP Harden.isDraft ≤ 3)
    -- Harden.consent_of_ack / no_ack_of_refused: the gate, observed.
    if refusing then
      checkTrue "consent refused: the apply question was never put" (!tr.any isAck)
    else
      checkTrue "consent given: the apply question was put" (tr.any isAck)
    -- Plan.runCertified_certified, in IO where it is a check and not a theorem.
    check "the run certifies" "true" (toString certified)
    let variant := if refusing then "refusing" else "consenting"
    IO.println s!"harden_demo: all checks passed ({variant} adapter)"
    -- Ascribed: the `for` above leaves the block's type a metavariable, and an
    -- unascribed `0` would default to `Nat`.
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"harden_demo: {e}"
    return 1
