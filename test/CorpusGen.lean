import DslCases
import Conformance

/-!
# The corpus generator

Day three of the connection's week one (`doc/research/dsl-redesign/
connection.md` §7): run the oracle's `observe` once over the curated corpus —
every battery source that parses, the module cases, a handful of
semantically-worlded pins, the three named vectors — and freeze the
request/reply pairs under `test/corpus/`, one pretty-printed JSON file each.

Regenerating the corpus is the explicit, reviewed act of changing the
specification: `lake exe corpus-gen`, then read the diff.

Parse-time refusals are skipped, deliberately: the conformance boundary is
`RawProgram`-in (connection.md D10), so a source the parser refuses never
reaches it — those stay pinned where they always were, in `test/DslSmoke.lean`.
-/

namespace CorpusGen

open Agentic.Core
open Agentic.Core.Dsl
open Agentic.Core.Conformance
open Lean (Json toJson)

/-- A filename from a case name: lowercase alphanumerics and dashes. -/
def slug (s : String) : String :=
  let mapped := s.toList.map fun c =>
    if c.isAlphanum then c.toLower else '-'
  let collapsed := (String.ofList mapped).splitOn "-" |>.filter (!·.isEmpty)
  String.intercalate "-" collapsed

/-- The echo world, spelled fully (a request never relies on decoder
defaults). -/
def echoW : WorldSpec := {}

/-- The angle-bracket echo, which makes splices visible. -/
def wrapW : WorldSpec := { text := .wrap "<" ">" }

/-- Every review objects; every flag refuses. The exhausting world. -/
def objectingW : WorldSpec :=
  { verdict := .const (.object ["not good enough"]), flag := .const false }

/-- One corpus entry. -/
def entry (name : String) (request : Json) (reply : Json) : Json :=
  Json.mkObj
    [ ("name", Json.str name)
    , ("request", request)
    , ("reply", reply)
    , ("oracleVersion", toJson (1 : Nat)) ]

def programEntry (name : String) (prog : RawProgram) (worlds : List WorldSpec) : Json :=
  entry name
    (Json.mkObj
      [ ("program", toJson prog)
      , ("worlds", toJson worlds) ])
    (observe prog worlds)

def stringEntry (name op : String) (code : Option String) (text : String) : Json :=
  entry name
    (Json.mkObj
      [ ("string", Json.mkObj
          ([("op", Json.str op)]
            ++ (match code with | some c => [("code", Json.str c)] | none => [])
            ++ [("text", Json.str text)])) ])
    (stringOp op code text)

def writeEntry (dir : System.FilePath) (idx : Nat) (prefixName : String)
    (e : Json) (name : String) : IO Unit := do
  let n := if idx < 10 then s!"00{idx}" else if idx < 100 then s!"0{idx}" else toString idx
  IO.FS.writeFile (dir / s!"{prefixName}-{n}-{slug name}.json") (e.pretty ++ "\n")

/-- The nested-revising source of the third named vector: the graft arithmetic
`(n+1)*rev + n*am + (n+1)*(st+un)` at two levels. -/
def graftDepthSrc : String :=
  "workflow { d : text <- ask model \"a\" \"draft\"\n" ++
  "  r <- revising d as c, at most 2 amendments {\n" ++
  "    v <- ask model \"m\" \"review {c}\"\n" ++
  "    amend c { ask model \"a\" \"fix {c} {v}\" }\n" ++
  "  }\n" ++
  "  case r { settled x {\n" ++
  "    r2 <- revising x as c2, at most 3 amendments {\n" ++
  "      v2 <- ask model \"m2\" \"review again {c2}\"\n" ++
  "      amend c2 { ask model \"a\" \"refix {c2} {v2}\" }\n" ++
  "    }\n" ++
  "    case r2 { settled y { ask tool \"t\" \"apply {y}\" }\n" ++
  "              unsettled { stop } }\n" ++
  "  } unsettled { stop } }\n}"

/-- The duplicate-function vector, hand-built: the parser refuses this shape,
so only a constructed table can present it to the checker. -/
def dupFnProgram : RawProgram :=
  let f : RawFn :=
    { name := "f", params := [("p", Code.text)], result := Code.text
    , body := [], answer := some "p", answerPos := { line := 1, col := 1 }
    , pos := { line := 1, col := 1 } }
  ⟨[f, f], RawBlock.empty { line := 1, col := 1 }⟩

def main : IO Unit := do
  let dir : System.FilePath := "test/corpus"
  IO.FS.createDirAll dir
  let mut count := 0
  let mut skipped := 0

  -- 1. The battery, single-file: every source the parser accepts.
  let mut i := 0
  for (name, src, _want) in batteryCases do
    match Dsl.parseProgramWith [] [] src with
    | .ok prog =>
      writeEntry dir i "battery" (programEntry name prog [echoW]) name
      count := count + 1
    | .error _ => skipped := skipped + 1
    i := i + 1

  -- 2. The module cases.
  i := 0
  for (name, mods, src, _want) in batteryCasesM do
    match Dsl.parseProgramWith [] mods src with
    | .ok prog =>
      writeEntry dir i "module" (programEntry name prog [echoW]) name
      count := count + 1
    | .error _ => skipped := skipped + 1
    i := i + 1

  -- 3. Semantically-worlded pins: the sources the discovery sections read
  -- through named worlds, frozen under the worlds that discriminate them.
  let semantic : List (String × String × List WorldSpec) :=
    [ ("sharing one binding holed three times", semSrc0, [echoW, wrapW])
    , ("a loop that settles at round two", semSrc1, [echoW, objectingW])
    , ("draws are distinct questions",
        "workflow { a : text <- ask model \"m\" \"one\"\n" ++
        "           b : text <- ask model \"m\" independent draw 1 \"one\"\n" ++
        "           ask tool \"t\" \"{a} {b}\" }",
        [{ text := .byDraw }])
    , ("a flag carrier loop",
        "workflow { d : text <- ask tool \"t\" \"w\"\n" ++
        "  ok <- ask person \"o\" \"go?\"\n" ++
        "  if ok { ask tool \"a\" \"went {d}\" } else { stop } }",
        [echoW, objectingW]) ]
  i := 0
  for (name, src, worlds) in semantic do
    match Dsl.parseProgramWith [] [] src with
    | .ok prog =>
      writeEntry dir i "semantic" (programEntry name prog worlds) name
      count := count + 1
    | .error e => throw <| IO.userError s!"semantic corpus source refused: {name}: {e.render}"
    i := i + 1

  -- 4. The three named vectors of connection.md §7.
  writeEntry dir 0 "vector"
    (entry "duplicate function names, hand-built"
      (Json.mkObj [("program", toJson dupFnProgram), ("worlds", toJson [echoW])])
      (observe dupFnProgram [echoW]))
    "duplicate function names hand-built"
  count := count + 1
  match Dsl.parseProgramWith [] [] semSrc0 with
  | .ok prog =>
    writeEntry dir 1 "vector"
      (programEntry "billMemo strictly below billFresh" prog [echoW])
      "billmemo below billfresh"
    count := count + 1
  | .error e => throw <| IO.userError s!"vector 2 refused: {e.render}"
  match Dsl.parseProgramWith [] [] graftDepthSrc with
  | .ok prog =>
    writeEntry dir 2 "vector"
      (programEntry "blockAsks graft arithmetic at depth two" prog [echoW, objectingW])
      "blockasks graft at depth"
    count := count + 1
  | .error e => throw <| IO.userError s!"vector 3 refused: {e.render}"

  -- …and one vector per remaining guard, so all five guard identities are in
  -- the corpus. The budget refusal comes from parseable source (`chain`'s
  -- doubling makes 2^13 questions of thirteen functions); the other two only
  -- exist hand-built, because the parser refuses their source spellings.
  match Dsl.parseProgramWith [] []
      (chain 13 ++ "workflow { a <- f13 \"x\"\n b <- f13 \"y\"\n ask tool \"t\" \"{a} {b}\" }") with
  | .ok prog =>
    writeEntry dir 3 "vector"
      (programEntry "a program over the question budget, with the count" prog [echoW])
      "question budget with count"
    count := count + 1
  | .error e => throw <| IO.userError s!"vector 4 refused: {e.render}"
  let p11 : Pos := { line := 1, col := 1 }
  let emptyPanelProgram : RawProgram :=
    ⟨[], RawBlock.bind "p" none
      (RawSource.rhs (RawRhs.panel [] p11)) (RawBlock.empty p11) p11⟩
  writeEntry dir 4 "vector"
    (programEntry "an empty panel, hand-built" emptyPanelProgram [echoW])
    "empty panel hand-built"
  count := count + 1
  let servedToolProgram : RawProgram :=
    ⟨[], RawBlock.act
      ⟨some "deep", ⟨Addressee.tool "t", 0⟩, Prompt.normalize [.lit "w"], p11⟩
      (RawBlock.empty p11) p11⟩
  writeEntry dir 5 "vector"
    (programEntry "served by on a tool, hand-built" servedToolProgram [echoW])
    "served by on a tool hand-built"
  count := count + 1

  -- 5. The string layer (D12): the frozen vector table.
  let strings : List (String × String × Option String × String) :=
    [ ("norm ascii mixed case", "norm", none, "  HeLLo World  ")
    , ("norm turkish dotted capital", "norm", none, "İstanbul")
    , ("norm turkish dotless", "norm", none, "ı vs I")
    , ("norm sharp s", "norm", none, "STRASSE straße")
    , ("norm final sigma", "norm", none, "ΟΔΥΣΣΕΥΣ οδυσσεύς")
    , ("norm nbsp", "norm", none, "yes ")
    , ("norm crlf", "norm", none, "yes\r\n")
    , ("norm empty", "norm", none, "")
    , ("norm blank lines", "norm", none, "\n\n  approve  \n\n")
    , ("words splits on runs", "words", none, "  two   words \t here ")
    , ("decodeVerdict approve", "decodeVerdict", none, "APPROVE")
    , ("decodeVerdict approve lowercase", "decodeVerdict", none, "approve")
    , ("decodeVerdict multiword is not approve", "decodeVerdict", none, "approve kind of")
    , ("decodeVerdict objection", "decodeVerdict", none, "OBJECTION: too long")
    , ("decodeVerdict empty", "decodeVerdict", none, "")
    , ("decode flag yes", "decode", some "flag", "yes")
    , ("decode flag Yes crlf", "decode", some "flag", "Yes\r\n")
    , ("decode flag maybe", "decode", some "flag", "maybe")
    , ("decode text passthrough", "decode", some "text", "  anything at all  ")
    , ("decode receipt anything", "decode", some "receipt", "DONE")
    , ("say verdict objection", "say", some "verdict", "OBJECTION: no")
    , ("say flag no", "say", some "flag", "no") ]
  i := 0
  for (name, op, code, text) in strings do
    writeEntry dir i "string" (stringEntry name op code text) name
    count := count + 1
    i := i + 1

  IO.println s!"corpus: {count} entries written to {dir} ({skipped} parse-refused sources skipped: they never reach the boundary)"

end CorpusGen

def main : IO Unit := CorpusGen.main
