import Agentic.Core.Certify

/-!
# The interpreter, driven end to end against the stub adapter

Run from the repository root:

```
lake exe exec_smoke
```

`test/AcpSmoke.lean` checks the wire; this checks the layer above it — the one
`Agentic/Core/Exec.lean` says is definitions rather than theorems. Each
assertion is a claim about the `IO` layer that no proof in the package makes:

* `Decode` reads the stub's bytes as the answers intended: a `text` verbatim, a
  `flag` from the word "yes";
* **the trusted base reads measured sentences the way it claims to**: a table of
  replies taken off a live adapter, each with the reading `Exec.decodeFlag` and
  `Exec.decodeVerdict` must give it. The theorems about those functions are
  stated through `Exec.words` because `String` does not reduce in the kernel, so
  how a particular sentence tokenizes is precisely the part that has to be run
  rather than proved — and three of the sentences are ones an earlier parser
  read as consent that nobody gave;
* the routing rule fires — the consent question is addressed to a
  `person`, and with `askPersonOnStdin := false` it goes to the adapter rather
  than blocking on a keyboard;
* **the memo table works in `IO`**: the plan below asks the *same* question
  twice, and the table the run leaves behind has two entries, not three. That
  is `Dlg.execM`'s look-up-before-asking in the only place it can actually be
  observed, since every theorem about it is stated at `Id`;
* **the run certifies**: `Agentic.Core.certify` replays the logged table as a
  world and re-evaluates the plan purely, and the two agree. At `Id` that is a
  theorem (`Plan.runCertified_certified`); in `IO` it is a check, and it is the
  only place the trust boundary of `Agentic/Core/Exec.lean` is observed holding;
* **an unreadable answer abandons the run**: asked a `flag` the stub has no
  canned answer for, the oracle raises rather than recording
  `Inhabited.default`. This is the one behaviour no downstream check could
  observe if it were wrong — a defaulted cell is definitionally identical to a
  genuine one, so `certify` and coverage would both pass on a `no` nobody said —
  and it is therefore checked here, where the exception is visible;
* **an unfinished turn abandons the run when what it would record is an act**
  (`Exec.requiresCompletedTurn`, ticket `acat-fuk`). Three checks, because the
  rule has three cases and they disagree on purpose: a `cancelled` turn
  answering an `.ack` aborts, a `cancelled` turn answering a `.flag` *put to a
  person* aborts, and a `cancelled` turn answering a `.text` from a model is
  read as given — refusal is an answer — while its stop reason is logged.

The prompts embed the stub's keys ("style guide", "Apply this patch?"); the
question header `Exec.renderQ` prepends does not disturb them, because the stub
matches on substrings.
-/

open Agentic.Core
open Agentic.Core.Plan

/-- The guide question: asked twice by the plan, answered once by the adapter. -/
def guideQ : Q .text :=
  { addressee := .model "author", scope := 1, prompt := "Write out the house style guide.",
    draw := 0 }

/-- The consent question: addressed to a **person**, and therefore the test of
the routing rule. -/
def consentQ : Q .flag :=
  { addressee := .person "owner", scope := 1, prompt := "Apply this patch?", draw := 0 }

/-- The act: an `.ack` addressed to a tool, which is the one code that requires
the turn to have completed. -/
def actQ : Q .ack :=
  { addressee := .tool "apply", scope := 1, prompt := "Apply:\nthe patch", draw := 0 }

/-- Ask the guide, ask for consent, then ask the guide **again** — the same
question, so the second occurrence must be a table hit and not a second prompt.
De Bruijn `0` is the most recent answer, so the triple reads the three binders
outermost-first. -/
def smoke : Plan [] (El .text × El .flag × El .text) :=
  .askC .text guideQ <|
    .askC .flag consentQ <|
      .askC .text guideQ <|
        .ret (fun γ =>
          (Var.get (.there (.there .here)) γ, Var.get (.there .here) γ, Var.get .here γ))

/-- A question the stub has no canned answer for: it replies with its refusal
line, which `Decode .flag` cannot read (`Exec.decodeFlag_eq_none_iff`). The one
input whose old handling was to record `false` — a *no* nobody said. -/
def unreadableQ : Q .flag :=
  { addressee := .model "author", scope := 1,
    prompt := "Is this something the stub has canned?", draw := 0 }

/-- One question, whose answer cannot be read. The plan's value is irrelevant:
what is being observed is that there is no value at all. -/
def unreadable : Plan [] (El .flag) :=
  .askC .flag unreadableQ (.ret (fun γ => Var.get .here γ))

/-- One act, and nothing else. -/
def act : Plan [] (El .ack) :=
  .askC .ack actQ (.ret (fun γ => Var.get .here γ))

/-- One question put to a person, and nothing else. -/
def consent : Plan [] (El .flag) :=
  .askC .flag consentQ (.ret (fun γ => Var.get .here γ))

/-- One question put to a model, and nothing else. -/
def guide : Plan [] (El .text) :=
  .askC .text guideQ (.ret (fun γ => Var.get .here γ))

/-- Fail loudly, with both sides quoted. -/
def check (what expected actual : String) : IO Unit :=
  if expected == actual then
    IO.println s!"ok   {what}"
  else
    throw <| IO.userError s!"FAIL {what}\n  expected: {expected}\n  actual:   {actual}"

/-- Fail loudly on a claim that is simply supposed to hold. -/
def checkTrue (what : String) (b : Bool) : IO Unit :=
  if b then IO.println s!"ok   {what}" else throw <| IO.userError s!"FAIL {what}"

/-- A directory for the stub to act in, and the path to the stub made absolute.

The stub's `Apply:` turn writes a file — an act that only says `DONE` is an act
nothing can be checked against — and it writes it in the session's working
directory, which had therefore better not be the repository. The absolute script
path is the other half: the child is started in that directory, where
`test/stub_adapter.py` names nothing. -/
def stubScratch : IO (String × String) := do
  let dir := (← IO.Process.run { cmd := "mktemp", args := #["-d"] }).trimAscii.toString
  return (dir, (← IO.FS.realPath Acp.stubScript).toString)

/-- The stub, in the directory it is allowed to act in, with whatever extra
arguments a case needs. The timeouts are short because the stub answers
instantly: the generous defaults are for an agent that thinks, and a test that
hangs for five minutes is a test nobody runs. -/
def stubCfg (dir script : String) (extra : Array String := #[]) : Acp.Config :=
  { adapter := .stub script, args := extra, cwd := dir
  , readTimeoutMs := some 20000, turnTimeoutMs := some 60000 }

/-- Settings that keep their warnings instead of printing them, so a test can
assert that the runtime said what it was supposed to say. -/
def recording (warnings : IO.Ref (Array String)) (retries : Nat := 1) : Exec.Settings :=
  { retries, log := fun msg => warnings.modify (·.push msg) }

/-! ## The trusted base, on replies that were actually said

`Exec.decodeFlag` and `Exec.decodeVerdict` are the only decisions in the package
about what bytes mean. Their theorems are stated through `Exec.words`, because
`String` operations do not reduce in this Lean's kernel, so what a *particular
sentence* tokenizes to is exactly the part no proof can carry. It is checked
here instead, where a `String` is a runtime value, against replies measured from
`claude-agent-acp` and the canned answers of the stub.

**Four of these are a regression test.** A parser that took the first recognized
token anywhere in a reply read `I cannot approve this patch.`, `Ok. Actually,
no — do not apply this.` and `Ok, I'll take a look at the working directory
first.` all as **yes**, and `I approve of nothing here. OBJECTION: unsafe.` as
**approval**. The rule is now: a *no* counts anywhere, a *yes* has to be the
whole reply, and anything else is unreadable — which costs a re-ask on
`Yes, apply it.` and cannot cost an unearned consent on any of them. -/

/-- How a `flag` reading prints. `unreadable` is `Exec.oracle`'s re-ask, and
after the last attempt it is an abandoned run — never a defaulted `no`. -/
def sayFlagOpt : Option Bool → String
  | some true => "yes"
  | some false => "no"
  | none => "unreadable"

/-- How a `verdict` reading prints, in the three cases `Plan.caseV` branches
on. -/
def sayTag : VTag → String
  | .approve => "approve"
  | .object => "object"
  | .declined => "declined"

/-- Measured replies to "Reply with exactly yes or no.", and the reading the
trusted base is claimed to give them. -/
def flagCases : List (String × Option Bool) :=
  [ ("yes", some true)
  , ("Yes.", some true)
  , ("**yes**", some true)
  , ("no", some false)
  , ("I cannot approve this patch.", none)
  , ("Ok, I'll take a look at the working directory first.", none)
  , ("Yes, apply it.", none)
  , ("Ok. Actually, no — do not apply this.", some false)
  , ("I have nothing canned for that.", none) ]

/-- The same for "Reply with exactly APPROVE … or OBJECTION: …". Every reading
but a lone approve word is an objection, and an empty turn declined. -/
def verdictCases : List (String × VTag) :=
  [ ("APPROVE", .approve)
  , ("Approve.", .approve)
  , ("**LGTM**", .approve)
  , ("OBJECTION: returning -2 for overflow violates the guide", .object)
  , ("I approve of nothing here. OBJECTION: unsafe.", .object)
  , ("The patch is fine. APPROVE", .object)
  , ("", .declined) ]

def main : IO UInt32 := do
  let guideText :=
    "House style: two-space indent, no tabs, every public name documented, " ++
      "and failures returned rather than raised."
  let (dir, script) ← stubScratch
  try
    -- The trusted base first, and without a process: these need no adapter,
    -- and a run whose parser is wrong has nothing else worth checking.
    for (reply, want) in flagCases do
      check s!"decodeFlag '{reply}'" (sayFlagOpt want) (sayFlagOpt (Exec.decodeFlag reply))
    for (reply, want) in verdictCases do
      check s!"decodeVerdict '{reply}'" (sayTag want)
        (sayTag (Verdict.tag (Exec.decodeVerdict reply)))
    let res ← execCertifiedIO (st := {}) (cfg := stubCfg dir script) smoke
    let table : Table := res.2.1
    let certified : Bool := res.2.2
    let g₁ : String := res.1.1
    let consented : Bool := res.1.2.1
    let g₂ : String := res.1.2.2
    check "guide (first ask)" guideText g₁
    check "guide (second ask, from the table)" guideText g₂
    check "consent" "yes" (if consented then "yes" else "no")
    -- The whole point: three `askC` nodes, two questions, two table entries.
    check "table size (memoized)" "2"
      (toString (List.length (table : List ((c : Code) × Q c × El c))))
    -- …and the table answers what the run heard.
    match lookup table .text guideQ with
    | some g => let gs : String := g; check "table records the guide" guideText gs
    | none => throw <| IO.userError "FAIL the table has no entry for the guide question"
    -- The warrant: replaying the log reproduces the answer this run returned.
    check "run certifies" "true" (toString certified)
    -- An answer that cannot be read must not become a recorded one. `retries :=
    -- 0` is one attempt, and the log is silenced because the re-ask warnings are
    -- not what is under test here; the outcome is.
    let quiet : Exec.Settings := { retries := 0, log := fun _ => pure () }
    let bad ← (execCertifiedIO (st := quiet) (cfg := stubCfg dir script) unreadable).toBaseIO
    check "an unreadable flag abandons the run" "abandoned"
      (match bad with
       | .ok r =>
         let answered : Bool := r.1
         let entries := List.length (r.2.1 : List ((c : Code) × Q c × El c))
         s!"recorded {answered} in a table of {entries}"
       | .error _ => "abandoned")
    -- acat-fuk. An act whose turn did not complete is an act that did not
    -- happen: `Decode .ack` is total, so nothing downstream could tell.
    let warnings ← IO.mkRef (#[] : Array String)
    let cancelledAct ←
      (execCertifiedIO (st := recording warnings) (cfg := stubCfg dir script #["--cancel=Apply:"]) act).toBaseIO
    check "a cancelled turn answering an act abandons the run" "abandoned"
      (match cancelledAct with
       | .ok r => s!"recorded an ack in a table of \
                     {List.length (r.2.1 : List ((c : Code) × Q c × El c))}"
       | .error _ => "abandoned")
    checkTrue "…and the stop reason was logged before it was enforced"
      ((← warnings.get).any (fun m => (m.splitOn "cancelled").length > 1))
    -- …and the same for a question put to a person: nobody answered.
    let cancelledPerson ←
      (execCertifiedIO (st := recording warnings)
        (cfg := stubCfg dir script #["--cancel=Apply this patch?"]) consent).toBaseIO
    check "a cancelled turn answering a person abandons the run" "abandoned"
      (match cancelledPerson with
       | .ok r => let b : Bool := r.1; s!"recorded {b}"
       | .error _ => "abandoned")
    -- …but refusal is still an answer for a model's `text`: the run completes,
    -- the bytes are recorded as given, and the stop reason is a warning.
    let quiet₂ ← IO.mkRef (#[] : Array String)
    let cancelledText ←
      execCertifiedIO (st := recording quiet₂) (cfg := stubCfg dir script #["--cancel=style guide"]) guide
    check "a cancelled turn answering a model's text is read as given"
      guideText (cancelledText.1 : String)
    checkTrue "…and that turn's stop reason reached Settings.log"
      ((← quiet₂.get).any (fun m => (m.splitOn "cancelled").length > 1))
    IO.println "exec smoke: all checks passed"
    -- Ascribed: the `for` loops above leave the block's type a metavariable,
    -- and an unascribed `0` would default to `Nat`.
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"exec smoke: {e}"
    return 1
  finally
    discard <| IO.Process.run { cmd := "rm", args := #["-rf", dir] }
