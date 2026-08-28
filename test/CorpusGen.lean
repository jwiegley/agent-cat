import Conformance

/-!
# The corpus generator, v2: re-observe what is frozen

`lake exe corpus-gen`, from the repository root.

## What changed, and why the discipline survived the parser

Version one built the corpus *from sources*: it parsed the battery's string
table, the module cases, the semantic pins and `example/*.wf`, and wrote a
request/reply pair per case. There is no parser and there are no `.wf` files any
more, so a generator that starts from characters cannot exist.

What can exist — and is the whole of the regeneration discipline that mattered —
is this: **the requests are the specification, and the replies are recomputed
from them.** Every file under `test/corpus/` already holds a `request` that is
`RawProgram`-in (the conformance boundary, `doc/research/connection.md` D10) or
a string-layer operation. This generator reads each file, takes its request
*verbatim*, puts it back through `Conformance.observe` or
`Conformance.stringOp` — the same two functions `conformance-oracle` serves —
and rewrites the file with the fresh reply under the same name, the same
request and the same schema.

So the gate is unchanged and is now sharper than it was: **regenerating must be
a no-op.** `lake exe corpus-gen` followed by `git status --short test/corpus`
printing nothing is the statement that the elaboration, the cost algebra, the
interpreter and the trusted base all still say exactly what the frozen
specification says they say. A diff here is a change to the specification and is
reviewed as one — and during an excision, a diff here means the excision cut
semantics rather than surface.

## What a request may be

Exactly what `conformance-oracle` accepts, minus `ping`:

* `{"program": <RawProgram>, "worlds": [<WorldSpec>]}` → `observe`;
* `{"string": {"op": …, "code"?: …, "text": …}}` → `stringOp`.

A file whose request is neither is an error and not a skip: the corpus is
curated, and a vector nothing can re-observe is a vector nothing is checking.

Requests are never touched. The generator re-emits the parsed `request` value
unchanged, so a hand-built vector (the empty panel, the duplicate function
table — shapes no surface would ever write) stays exactly as it was written.
-/

namespace CorpusGen

open Agentic.Core
open Agentic.Core.Dsl
open Agentic.Core.Conformance
open Lean (Json toJson fromJson?)

/-- One corpus entry, in the field order v1 wrote and every frozen file holds. -/
def entry (name : String) (request : Json) (reply : Json) (oracleVersion : Json) : Json :=
  Json.mkObj
    [ ("name", Json.str name)
    , ("request", request)
    , ("reply", reply)
    , ("oracleVersion", oracleVersion) ]

/-- The reply a request earns, recomputed. `Except` rather than a default,
because a request this cannot read is a corpus file nothing is checking. -/
def replyFor (request : Json) : Except String Json := do
  if let .ok sj := request.getObjVal? "string" then
    let _ ← (getStr? sj "op").elim (.error "a string request needs an `op`") .ok
    .ok (stringOpOf sj)
  else if let .ok pj := request.getObjVal? "program" then
    match fromJson? (α := RawProgram) pj with
    | .error e => .error s!"bad program: {e}"
    | .ok prog =>
      let worlds : List WorldSpec ←
        match request.getObjVal? "worlds" with
        | .error _ => .ok [{}]
        | .ok wj =>
          match fromJson? (α := List WorldSpec) wj with
          | .ok ws => .ok ws
          | .error e => .error s!"bad worlds: {e}"
      let version : Nat :=
        match request.getObjVal? "version" with
        | .ok v => (v.getNat?).toOption.getD 2
        | .error _ => 2
      match version with
      | 2 => .ok (observe prog worlds)
      | 3 => .ok (observeV3 prog worlds)
      | 4 =>
        match request.getObjVal? "result" with
        | .error _ => .error "version 4 requires a result code"
        | .ok rj =>
          match fromJson? (α := Code) rj with
          | .error e => .error s!"bad result code: {e}"
          | .ok result => .ok (observeResult result prog worlds)
      | _ => .error "program observation version must be 2, 3 or 4"
  else
    .error "a request is {program, worlds?} or {string: {op, code?, text}}"

/-- Re-observe one file in place. Returns whether the bytes moved. -/
def regenerate (path : System.FilePath) : IO Bool := do
  let old ← IO.FS.readFile path
  let j ← match Json.parse old with
    | .error e => throw <| IO.userError s!"{path}: not JSON: {e}"
    | .ok j => pure j
  let name ← match getStr? j "name" with
    | some n => pure n
    | none => throw <| IO.userError s!"{path}: no `name`"
  let request ← match j.getObjVal? "request" with
    | .ok r => pure r
    | .error _ => throw <| IO.userError s!"{path}: no `request`"
  let version := (j.getObjVal? "oracleVersion").toOption.getD (toJson (1 : Nat))
  let reply ← match replyFor request with
    | .ok r => pure r
    | .error e => throw <| IO.userError s!"{path}: {e}"
  let new := (entry name request reply version).pretty ++ "\n"
  if new == old then
    return false
  else
    IO.FS.writeFile path new
    return true

def main : IO Unit := do
  let dir : System.FilePath := "test/corpus"
  let entries ← dir.readDir
  -- Sorted, so the report reads in the order the directory is committed in and
  -- two runs on two machines print the same lines.
  let paths := (entries.toList.map (·.path)).filter
      (fun p => p.extension == some "json")
    |>.toArray.qsort (fun a b => a.toString < b.toString) |>.toList
  if paths.isEmpty then
    throw <| IO.userError s!"{dir} holds no corpus files; refusing to write a corpus from nothing"
  let mut moved : List String := []
  for p in paths do
    if ← regenerate p then
      moved := p.toString :: moved
  if moved.isEmpty then
    IO.println s!"corpus: {paths.length} entries re-observed, all byte-identical"
  else
    IO.println s!"corpus: {paths.length} entries re-observed, {moved.length} rewritten:"
    for m in moved.reverse do
      IO.println s!"  {m}"

end CorpusGen

def main : IO Unit := CorpusGen.main
