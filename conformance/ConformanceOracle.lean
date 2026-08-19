import Conformance

/-!
# The conformance oracle — the executable

`lake exe conformance-oracle`. The library half (codecs, worlds, the
observation record, the refusal classifier) is `conformance/Conformance.lean`,
importable by the corpus generator; this file is the stdin/stdout loop.
-/

namespace Agentic.Core.Conformance

open Lean (Json toJson fromJson?)
open Agentic.Core.Dsl

/-- Poll a task to completion or a deadline. Partial: an IO polling loop in a
test executable, outside every theorem. -/
partial def waitBudget (task : Task (Except IO.Error Json)) (t0 budget : Nat) :
    IO Json := do
  if ← IO.hasFinished task then
    match task.get with
    | .ok r => return r
    | .error e => return Json.mkObj [("error", Json.str (toString e))]
  else
    let now ← IO.monoMsNow
    if now - t0 ≥ budget then
      return Json.mkObj [("timeout", Json.mkObj [("ms", toJson budget)])]
    else
      IO.sleep 5
      waitBudget task t0 budget

/-- One request, dispatched. Pure except for the clock. -/
def answer (j : Json) : IO Json := do
  if (j.getObjVal? "ping").toOption.isSome then
    return Json.mkObj [("pong", Json.bool true)]
  else if let .ok sj := j.getObjVal? "string" then
    return stringOpOf sj
  else if let .ok pj := j.getObjVal? "program" then
    match fromJson? (α := RawProgram) pj with
    | .error e => return Json.mkObj [("error", Json.str s!"bad program: {e}")]
    | .ok prog =>
      let worlds : List WorldSpec :=
        match j.getObjVal? "worlds" with
        | .ok wj =>
          match fromJson? (α := List WorldSpec) wj with
          | .ok ws => ws
          | .error _ => [{}]
        | .error _ => [{}]
      let budget : Nat :=
        match (j.getObjVal? "budgetMs").toOption.bind (·.getNat?.toOption) with
        | some n => n
        | none => 30000
      let t0 ← IO.monoMsNow
      let task ← IO.asTask (pure (observe prog worlds))
      waitBudget task t0 budget
  else
    return Json.mkObj [("error", Json.str "a request is {program, worlds?}, {string: {op, code?, text}}, or {ping}")]

/-- The loop. Partial: it ends when stdin does. -/
partial def serve (stdin : IO.FS.Stream) (stdout : IO.FS.Stream) : IO Unit := do
  let line ← stdin.getLine
  if line.isEmpty then
    return ()   -- EOF: the clean shutdown closing stdin is
  else
    let trimmed := line.trimAscii.toString
    if trimmed.isEmpty then serve stdin stdout
    else do
      let reply ←
        match Json.parse trimmed with
        | .error e => pure (Json.mkObj [("error", Json.str s!"not JSON: {e}")])
        | .ok j => do
          let r ← answer j
          -- Echo the id, so a client may pipeline.
          pure (match j.getObjVal? "id" with
            | .ok idj => match r with
              | .obj kvs => Json.obj (kvs.insert "id" idj)
              | other => other
            | .error _ => r)
      stdout.putStrLn reply.compress
      stdout.flush
      serve stdin stdout

def main : IO Unit := do
  serve (← IO.getStdin) (← IO.getStdout)

end Agentic.Core.Conformance

def main : IO Unit := Agentic.Core.Conformance.main
