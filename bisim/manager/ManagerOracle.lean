import ManagerConformance.Codec

/-!
# The manager oracle

`lake --dir bisim exe manager-oracle` reads one request per line on standard
input and writes one response per line on standard output. A request is
`{version, state, evidence, entry}` in the encoding of
`ManagerConformance.Codec`. An accepted entry receives
`{"accepted": true, "state": ...}`, a refused entry receives
`{"accepted": false}`, and a malformed request receives `{"error": ...}`.
The oracle ignores an empty line and stops at the end of its input.

The oracle evaluates only `ManagerConformance.step`: the executable deciders
of the coordination transitions, `Coordination.delivery`, and the identity
effect of an observation. It reads no clock, file or environment variable.
-/

namespace ManagerConformance.Oracle

/-- The loop. It ends at the end of the input. -/
partial def serve (stdin stdout : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then
    return ()
  unless line.trimAscii.isEmpty do
    stdout.putStrLn (respondLine line).compress
    stdout.flush
  serve stdin stdout

end ManagerConformance.Oracle

def main : IO Unit := do
  ManagerConformance.Oracle.serve (← IO.getStdin) (← IO.getStdout)
