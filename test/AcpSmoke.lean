import Agentic.Core.Acp

/-!
# The transport, driven end to end against the stub adapter

Run from the repository root:

```
lake exe acp_smoke            # or: lake env lean --run test/AcpSmoke.lean
```

The stub is found relative to the working directory, so the root is where this
must be run from. It exits non-zero on the first mismatch and prints what it
checked otherwise.

This is a test of the *wire*, not of a meaning: it asserts that the bytes the
stub was told to say are the bytes that came back. The stub streams every
answer as two chunks and issues one agent-initiated request, so the assertions
below cover chunk concatenation and the `-32601` reply path as well as the four
calls.
-/

open Agentic.Core.Acp

/-- Fail loudly, with both sides quoted. -/
def check (what expected actual : String) : IO Unit :=
  if expected == actual then
    IO.println s!"ok   {what}"
  else
    throw <| IO.userError s!"FAIL {what}\n  expected: {expected}\n  actual:   {actual}"

def main : IO UInt32 := do
  let cfg : Config :=
    { cmd := "python3"
    , args := #["test/stub_adapter.py"]
    , cwd := "."
    , timeoutMs := some 20000 }
  try
    withConn cfg fun conn => do
      let guide ← conn.prompt "Write out the house style guide."
      check "guide"
        ("House style: two-space indent, no tabs, every public name documented, " ++
          "and failures returned rather than raised.")
        guide
      let patch ← conn.prompt s!"Draft a patch satisfying:\nharden the parser"
      check "draft"
        ("--- a/src/parse.c\n+++ b/src/parse.c\n@@\n" ++
          "-  char buf[64]; strcpy(buf, input);\n" ++
          "+  char buf[64]; snprintf(buf, sizeof buf, \"%s\", input);\n")
        patch
      -- The review prompts embed the guide and the patch: the stub must still
      -- key on the question, which is the one ordering fact the harness relies
      -- on.
      check "correct?" "APPROVE" (← conn.prompt s!"{guide}\nIs this patch correct?\n{patch}")
      check "secure?" "APPROVE" (← conn.prompt s!"{guide}\nIs this patch secure?\n{patch}")
      check "simpler?" "APPROVE" (← conn.prompt s!"Could this patch be simpler?\n{patch}")
      check "consent" "yes" (← conn.prompt s!"Apply this patch?\n{patch}")
      -- This turn is the one that sends us `session/request_permission`.
      let act ← conn.promptTurn s!"Apply:\n{patch}"
      check "act" "ok" act.text
      check "stopReason" "end_turn" act.stopReason
      -- Nothing above depends on a mode, but the call must round-trip.
      conn.setMode "default"
      IO.println "ok   session/set_mode"
    IO.println "acp smoke: all checks passed"
    return 0
  catch e =>
    IO.eprintln s!"acp smoke: {e}"
    return 1
