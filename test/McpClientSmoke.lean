import Agentic.Core.Mcp

/-!
# The server, driven by a real client over a real pipe

Run from the repository root:

```
lake exe mcp_client_smoke                 # all five modes
lake exe mcp_client_smoke -- --mode refuse --verbose
```

It exits non-zero on the first mode that fails and prints everything the client
printed otherwise.

**This is the other half of `test/McpSmoke.lean`, and it is a different test.**
That one drives `Mcp.serve` in this process over a list of lines, which is a
test of the dispatcher; this one starts `.lake/build/bin/workflow_mcp` as a
child, speaks JSON-RPC 2.0 to it down a pipe, and answers its questions the way
a calling agent would. What it adds is everything the scripted stream cannot
reach: that the built binary starts, that stdout carries protocol and stderr
carries diagnostics, that the framing survives a real pipe and a real flush,
that an `elicitation/create` written mid-`tools/call` is answered by a peer
that is genuinely concurrent with it, and that closing stdin is a clean
shutdown.

The client is `test/mcp_client.py`, which is where the assertions live; this
file is the target that puts it in the build and pins the identity of the
server it is talking to. `--expect-server` is `Mcp.serverName`,
`Mcp.serverVersion` and `Mcp.protocolVersion` **read from the module the binary
is built from**, so a rename or a revision bump that the client was not told
about fails here rather than passing quietly against whatever is on disk.

The five modes are described at the head of `test/mcp_client.py`: `consent` and
`refuse` are the two ends of the flagship's consent question, billing seven and
six (`Dsl.bill_flagship_apply`, `Dsl.bill_flagship_refuse`); `undecodable`
answers it in words the trusted base cannot read and checks that nothing was
recorded; `elicit` advertises the elicitation capability so that the person's
question is put to the client's own dialog instead of being relayed; and
`revise` objects once, turning the revision loop and reaching a different leaf
of the same cost tree at eleven.
-/

open Agentic.Core.Mcp

/-- Where the built server is, relative to the repository root — which is
therefore where this must be run from, exactly as `test/stub_adapter.py` is
found by `lake exe acp_smoke`. -/
def serverPath : String := ".lake/build/bin/workflow_mcp"

/-- Where the client is. -/
def clientPath : String := "test/mcp_client.py"

/-- What the client is told the server must call itself: the three constants
this module imports from the server's own source. A binary that answers
anything else is a binary built from something other than this. -/
def expectServer : String := s!"{serverName} {serverVersion} {protocolVersion}"

/-- The modes, in the order they are run. -/
def modes : List String := ["consent", "refuse", "undecodable", "elicit", "revise"]

/-- Run the client once, in one mode; the child inherits this process's stdio,
so its output is this target's output. -/
def runMode (mode : String) (extra : Array String) : IO Unit := do
  -- `spawn` forks, and a fork inherits the parent's unflushed buffer; without
  -- this the banner above can appear after the child's first line.
  (← IO.getStdout).flush
  let child ← IO.Process.spawn
    { cmd := "python3"
    , args := #[clientPath, "--mode", mode, "--server", serverPath,
                "--expect-server", expectServer] ++ extra }
  let code ← child.wait
  if code != 0 then
    throw <| IO.userError s!"mcp_client_smoke: mode '{mode}' failed (exit {code})"

def main (argv : List String) : IO Unit := do
  if !(← System.FilePath.pathExists (System.FilePath.mk serverPath)) then
    throw <| IO.userError
      s!"mcp_client_smoke: no server at '{serverPath}' — run `lake build` from \
         the repository root first"
  let extra : Array String := if argv.contains "--verbose" then #["--verbose"] else #[]
  let chosen := match argv.dropWhile (· != "--mode") with
    | _ :: m :: _ => [m]
    | _ => modes
  for m in chosen do
    IO.println s!"=== mcp_client.py --mode {m} (server {expectServer}) ==="
    runMode m extra
  IO.println s!"mcp_client_smoke: {chosen.length} mode(s) passed"
