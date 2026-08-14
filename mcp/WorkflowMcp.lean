import Agentic.Core.Mcp

/-!
# `workflow_mcp`: the server as a program

An MCP server over this process's stdio, offering the four tools of
`Agentic/Core/Mcp.lean` — `workflow_check`, `workflow_start`,
`workflow_answer`, `workflow_transcript` — over workflows written in the DSL of
`Agentic/Core/Dsl.lean`.

Registered with a client, from the repository root:

```
claude mcp add --scope local workflows -- .lake/build/bin/workflow_mcp
```

or driven by hand, one JSON value per line, which is the whole protocol:

```
lake exe workflow_mcp
{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"by-hand","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
```

**stdout is the protocol and stderr is the diagnostics**, so nothing here prints
to stdout: a stray line on that stream is a corrupt frame. Shutdown is the
client closing stdin; there is no shutdown method, and the exit is clean.

`test/McpSmoke.lean` drives the same `serve` over a list of lines instead of a
pipe, which is why this file is three lines of argument parsing and nothing
else.
-/

open Agentic.Core.Mcp

/-- Usage, on stderr, for a human who ran the binary by hand. -/
def usage : List String :=
  [ "workflow_mcp — an MCP server (revision " ++ protocolVersion ++
      ") over the closed-plan DSL."
  , ""
  , "Speaks line-delimited JSON-RPC 2.0 on stdin/stdout; there are no other"
  , "inputs and no other outputs. Options:"
  , ""
  , "  --no-elicitation   never open a dialog on the client; relay every"
  , "                     person-addressed question to the calling agent"
  , "  --version          print the server's name and version"
  , "  --help             this" ]

def main (args : List String) : IO Unit := do
  if args.contains "--help" then
    let err ← IO.getStderr
    for l in usage do err.putStrLn l
  else if args.contains "--version" then
    (← IO.getStderr).putStrLn s!"{serverName} {serverVersion} (MCP {protocolVersion})"
  else
    Agentic.Core.Mcp.main { useElicitation := !args.contains "--no-elicitation" }
