import Agentic.Core.Certify

/-!
# The interpreter, driven end to end against the stub adapter

Run from the repository root:

```
lake exe exec_smoke
```

`test/AcpSmoke.lean` checks the wire; this checks the layer above it — the one
`Agentic/Core/Exec.lean` says is definitions rather than theorems. Three things
are asserted, and each is a claim about the `IO` layer that no proof in the
package makes:

* `Decode` reads the stub's bytes as the answers intended: a `text` verbatim, a
  `flag` from the word "yes";
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
  and it is therefore checked here, where the exception is visible.

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

/-- Fail loudly, with both sides quoted. -/
def check (what expected actual : String) : IO Unit :=
  if expected == actual then
    IO.println s!"ok   {what}"
  else
    throw <| IO.userError s!"FAIL {what}\n  expected: {expected}\n  actual:   {actual}"

def main : IO UInt32 := do
  let cfg : Acp.Config :=
    { cmd := "python3", args := #["test/stub_adapter.py"], cwd := ".",
      timeoutMs := some 20000 }
  let guide :=
    "House style: two-space indent, no tabs, every public name documented, " ++
      "and failures returned rather than raised."
  try
    let res ← execCertifiedIO (st := {}) (cfg := cfg) smoke
    let table : Table := res.2.1
    let certified : Bool := res.2.2
    let g₁ : String := res.1.1
    let consent : Bool := res.1.2.1
    let g₂ : String := res.1.2.2
    check "guide (first ask)" guide g₁
    check "guide (second ask, from the table)" guide g₂
    check "consent" "yes" (if consent then "yes" else "no")
    -- The whole point: three `askC` nodes, two questions, two table entries.
    check "table size (memoized)" "2"
      (toString (List.length (table : List ((c : Code) × Q c × El c))))
    -- …and the table answers what the run heard.
    match lookup table .text guideQ with
    | some g => let gs : String := g; check "table records the guide" guide gs
    | none => throw <| IO.userError "FAIL the table has no entry for the guide question"
    -- The warrant: replaying the log reproduces the answer this run returned.
    check "run certifies" "true" (toString certified)
    -- An answer that cannot be read must not become a recorded one. `retries :=
    -- 0` is one attempt, and the log is silenced because the re-ask warnings are
    -- not what is under test here; the outcome is.
    let quiet : Exec.Settings := { retries := 0, log := fun _ => pure () }
    let bad ← (execCertifiedIO (st := quiet) (cfg := cfg) unreadable).toBaseIO
    check "an unreadable flag abandons the run" "abandoned"
      (match bad with
       | .ok r =>
         let answered : Bool := r.1
         let entries := List.length (r.2.1 : List ((c : Code) × Q c × El c))
         s!"recorded {answered} in a table of {entries}"
       | .error _ => "abandoned")
    IO.println "exec smoke: all checks passed"
    return 0
  catch e =>
    IO.eprintln s!"exec smoke: {e}"
    return 1
