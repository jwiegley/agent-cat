import Agentic.Core.Explain
import Agentic.Core.Report
import Agentic.Core.Schema.Conformance

/-!
# The conformance library

Stage: the connection (`doc/research/connection.md`, D4).

The Lean side of the bisimulation: a line-delimited JSON process that checks
and observes programs so that the Haskell implementation has something exact to
agree with. **A test dependency and only ever a test dependency** — the
production runner never speaks to this process; the frozen corpus under
`test/corpus/` is its output, committed, so Tier 0 runs with no Lean in the
loop.

Three request kinds (`doc/conformance-schema.md` is the format of record):

* `{"id": …, "program": <RawProgram>, "worlds": [<WorldSpec>]}` → the
  observation record: the refusal (classified by the guard enum defined HERE —
  `CheckError` carries no code, and adding one would edit literals that
  theorems pin), or the checked term's static folds and one trace-and-bills
  block per world.
* `{"id": …, "string": {"op": "norm"|"words"|"decodeVerdict"|"decode"|"say",
  …}}` → the string layer (`Exec.norm` is ASCII-only where Haskell's `toLower`
  is Unicode; this request kind exists because nothing else on the boundary
  ever reaches `Decode`).
* `{"id": …, "ping": true}` → liveness, so a hung request is distinguishable
  from a dead process.

The import list is connection.md §3.2's exactly — `Explain` (which carries
`Dsl`, `Cost`, `Denote`) and `Report` (which carries `sayAnswer`, the shipped
answer rendering) — and **not** `DslFlagship`, so the oracle builds in seconds.

Every request may carry `"budgetMs"`; on expiry the reply is
`{"timeout": {"ms": n}}` — an observation, not an error (D13): the two
implementations genuinely differ in asymptotics (`Env.consBy`), and an
asymmetry must be recordable as an asymmetry. The expired task is abandoned,
not cancelled; an oracle run is short-lived by design.
-/

namespace Agentic.Core.Conformance

open Agentic.Core
open Agentic.Core.Dsl
open Lean (Json ToJson FromJson toJson fromJson?)

/-! ## Codecs for the wire: `Raw` in, observations out

Standalone `deriving instance`, so no file under `Agentic/Core` is touched. -/

deriving instance FromJson, ToJson for Pos
deriving instance FromJson, ToJson for Chunk
deriving instance FromJson, ToJson for Addressee
deriving instance FromJson, ToJson for RawTarget
deriving instance FromJson, ToJson for Served
deriving instance FromJson, ToJson for Decider
deriving instance FromJson, ToJson for RawAsk
deriving instance FromJson, ToJson for TextMember
deriving instance FromJson, ToJson for RawArg
deriving instance FromJson, ToJson for RawRhs
deriving instance FromJson, ToJson for RawSource
deriving instance FromJson, ToJson for RawBlock
deriving instance FromJson, ToJson for RawBodyStmt
deriving instance FromJson, ToJson for RawFn
deriving instance FromJson, ToJson for RawProgram

/-! ## The world, specified as data

A world is a function of the question (`Ω = (c : Code) → Q c → El c`), so it is
specified as a small closed DSL and interpreted — never serialized as a
function. Ten combinators cover the whole existing pin suite (connection.md
§3.3). -/

/-- A verdict, as a literal. -/
inductive VLit where
  | approve
  | declined
  | object (objections : List String)
  deriving FromJson, ToJson

def VLit.toVerdict : VLit → Verdict
  | .approve => Verdict.approve
  | .declined => Verdict.declined
  | .object os => Verdict.object os

/-- How the world answers `text` questions. -/
inductive TextSpec where
  /-- The answer is the prompt itself — `DslSmoke`'s default world. -/
  | echo
  /-- The prompt wrapped in the given brackets, e.g. `<`…`>` — the echo that
  makes splices visible. -/
  | wrap (pre post : String)
  | const (s : String)
  /-- `"draw:" ++ toString q.draw` — distinguishes resamplings. -/
  | byDraw
  /-- First entry whose key is a prefix of the prompt wins; else the default. -/
  | byPrefix (table : List (String × String)) (default : String)
  deriving FromJson, ToJson

/-- How the world answers `verdict` questions. -/
inductive VerdictSpec where
  | const (v : VLit)
  | byPrefix (table : List (String × VLit)) (default : VLit)
  deriving FromJson, ToJson

/-- How the world answers `flag` questions. -/
inductive FlagSpec where
  | const (b : Bool)
  /-- `q.prompt == s` — `DslSmoke`'s "is it ready now?" world. -/
  | promptEq (s : String)
  | byPrefix (table : List (String × Bool)) (default : Bool)
  deriving FromJson, ToJson

structure WorldSpec where
  text : TextSpec := .echo
  verdict : VerdictSpec := .const .approve
  flag : FlagSpec := .const true
  schema : List Schema.Conformance.Answer := []

private def worldFieldD {α : Type} [FromJson α] (json : Json) (name : String)
    (fallback : α) : Except String α :=
  match json.getObjVal? name with
  | .error _ => return fallback
  | .ok value => if value.isNull then return fallback else fromJson? value

instance : FromJson WorldSpec where
  fromJson? json := do
    let text ← worldFieldD json "text" TextSpec.echo
    let verdict ← worldFieldD json "verdict" (VerdictSpec.const .approve)
    let flag ← worldFieldD json "flag" (FlagSpec.const true)
    let schema ← worldFieldD json "schema" []
    if Schema.Conformance.Answer.uniqueSchemas schema then return { text, verdict, flag, schema }
    else throw "WorldSpec.schema contains two answers for one schema"

instance : ToJson WorldSpec where
  toJson world :=
    let fields : List (String × Json) :=
      [("text", toJson world.text), ("verdict", toJson world.verdict), ("flag", toJson world.flag)]
    Json.mkObj <| if world.schema.isEmpty then fields else
      fields ++ [("schema", toJson world.schema)]

def TextSpec.answer {c : Code} (spec : TextSpec) (q : Q c) : String :=
  match spec with
  | .echo => q.prompt
  | .wrap pre post => pre ++ q.prompt ++ post
  | .const s => s
  | .byDraw => "draw:" ++ toString q.draw
  | .byPrefix table d =>
      match table.find? (fun e => e.1.isPrefixOf q.prompt) with
      | some e => e.2
      | none => d

def WorldSpec.toWorld (w : WorldSpec) : Ω
  | .text, q => w.text.answer q
  | .verdict, q =>
    match w.verdict with
    | .const v => v.toVerdict
    | .byPrefix table d =>
      match table.find? (fun e => e.1.isPrefixOf q.prompt) with
      | some e => e.2.toVerdict
      | none => d.toVerdict
  | .flag, q =>
    match w.flag with
    | .const b => b
    | .promptEq s => q.prompt == s
    | .byPrefix table d =>
      match table.find? (fun e => e.1.isPrefixOf q.prompt) with
      | some e => e.2
      | none => d
  | .ack, _ => ()
  | .structured schema, _ => (Schema.Conformance.Answer.lookup w.schema schema).getD default

/-! ## Serializing observations

`Event` is first-order data (`Event.toSigma`), and the record serializes it as
data — never `Trace.render`, which is a pretty-printer (connection.md §1.3). -/

/-- A verdict as data: its tag, and the objections where the tag carries any. -/
def verdictJson (v : Verdict) : Json :=
  match Verdict.tag v with
  | .approve => Json.mkObj [("tag", "approve")]
  | .declined => Json.mkObj [("tag", "declined")]
  | .object =>
    Json.mkObj
      [ ("tag", "object")
      , ("objections", toJson
          (v.recZeroCoe ([] : List Objection) FreeMonoid.toList : List Objection)) ]

/-- An answer, at its code. -/
def answerJson : (c : Code) → El c → Json
  | .text, s => Json.str s
  | .verdict, v => verdictJson v
  | .flag, b => Json.bool b
  | .ack, _ => Json.null
  | .structured schema, value => Schema.Conformance.encodeShape schema.1 value

def scopeJson (s : QScope) : Json :=
  Json.mkObj
    [ ("model", match s.1 with | some m => Json.str m | none => Json.null)
    , ("mode", match s.2 with | some m => Json.str m | none => Json.null) ]

/-- A code on the observation wire. Built-ins retain their strings; structured
codes carry the schema that is part of their identity. The `json` tag belongs
only to this JSON wire representation. -/
def codeJson : Code → Json
  | .text => "text"
  | .verdict => "verdict"
  | .flag => "flag"
  | .ack => "receipt"
  | .structured schema => Json.mkObj [("json", Json.mkObj [("schema", toJson schema)])]

def codeSchemas : Code → List Schema
  | .structured schema => [schema]
  | .text => []
  | .verdict => []
  | .flag => []
  | .ack => []

def schemaCodesAlg : PlanAlg (fun _ _ => List Schema) where
  ret _ := []
  askC code _ rest := codeSchemas code ++ rest
  ask code _ _ rest := codeSchemas code ++ rest
  case := fun tag _ arms => tag.values.flatMap arms
  dyn _ _ _ := []

def planSchemas {Γ : Ctx} {A : Type} (plan : Plan Γ A) : List Schema :=
  schemaCodesAlg.fold plan

def WorldSpec.covers (world : WorldSpec) (schemas : List Schema) : Bool :=
  schemas.all fun schema => (Schema.Conformance.Answer.lookup world.schema schema).isSome

def eventJson (e : Event) : Json :=
  Json.mkObj
    [ ("code", codeJson e.c)
    , ("addressee", toJson e.q.addressee)
    , ("scope", scopeJson e.q.scope)
    , ("prompt", Json.str e.q.prompt)
    , ("draw", toJson e.q.draw)
    , ("answer", answerJson e.c e.a) ]

/-! ## The refusal classifier (D7)

`CheckError` is `⟨pos, message, excerpt⟩` with no classification field, and
adding one would edit literals pinned inside theorems. So the guard code is a
total function from the message text to a small closed enum, defined here and
only here: the oracle's artifact. When the checker's wording moves, this
classifier is what follows it — a one-line edit in a test-only executable,
caught by the frozen corpus on the same commit. -/

inductive Guard where
  | panelEmpty
  | revisionBound
  | questionBudget
  | servedBy
  | dupFunction
  | deciderEmpty
  | other
  deriving ToJson

def classify (msg : String) : Guard :=
  if (msg.splitOn "a panel needs at least one member").length > 1 then .panelEmpty
  -- A text panel's empty fan is the same mistake in the same family, so it is
  -- the same guard: `PanelEmpty` means "a fan with no members" whichever monoid
  -- it folds into.
  else if (msg.splitOn "a text panel needs at least one member").length > 1 then .panelEmpty
  else if (msg.splitOn "at most 64 amendments").length > 1 then .revisionBound
  else if (msg.splitOn "elaborates to").length > 1 then .questionBudget
  else if (msg.splitOn "`served by` names the model").length > 1 then .servedBy
  else if (msg.splitOn "two functions answer to one name").length > 1 then .dupFunction
  -- Both degeneracies of a decider — no needle at all, and a needle that says
  -- nothing — are one guard, because they are one mistake: a test that is
  -- constantly false, or constantly true, with nothing in the source to show it.
  else if (msg.splitOn "a decider needs").length > 1 then .deciderEmpty
  else .other

/-- The computed `n` of a `maxQuestions` refusal — read back out of the
message, which is the checker's own statement of it. -/
def budgetN (msg : String) : Option Nat :=
  match msg.splitOn "elaborates to " with
  | _ :: rest :: _ =>
    let digits := rest.toList.takeWhile Char.isDigit
    if digits.isEmpty then none
    else some (digits.foldl (fun n d => n * 10 + (d.toNat - 48)) 0)
  | _ => none

/-! ## The observation record (connection.md §3.1) -/

def refusedJson (e : CheckError) : Json :=
  Json.mkObj
    [ ("refused", Json.mkObj
        [ ("guard", toJson (classify e.message))          -- compared
        , ("n", match budgetN e.message with              -- compared (budget only)
            | some n => toJson n
            | none => Json.null)
        , ("pos", toJson e.pos)                           -- oracle-only
        , ("excerpt", Json.str e.excerpt)                 -- oracle-only
        , ("message", Json.str e.message) ]) ]            -- oracle-only

def worldObservation (p : Plan [] Unit) (w : WorldSpec) : Json :=
  let t := Plan.trace w.toWorld p Env.nil
  Json.mkObj
    [ ("world", toJson w)
    , ("trace", Json.arr (t.map eventJson).toArray)
    , ("billFresh", toJson (Multiplicative.toAdd (billFresh tick t)))
    , ("billMemo", toJson (Multiplicative.toAdd (billMemo tick t))) ]

def observe (prog : RawProgram) (worlds : List WorldSpec) : Json :=
  match h : checkProgram prog with
  | .error e => refusedJson e
  | .ok p =>
    if worlds.all (fun world => WorldSpec.covers world (planSchemas p)) then
      let hl : level p ≤ Level.branch := checkProgram_level_le prog p h
      let (lo, hi, paths) := Explain.costSummary p hl
      let fns := match checkFnsList [] prog.fns with
        | .ok fns => fns
        | .error _ => []   -- unreachable: checkProgram checked the table first
      Json.mkObj
        [ ("level", Json.str (levelName (level p)))
        , ("size", toJson (Plan.size p))
        , ("askNodes", toJson (Plan.askNodes p))
        , ("codes", match codes p with
            | some cs => Json.arr (cs.map codeJson).toArray
            | none => Json.null)
        , ("costSummary", Json.mkObj
            [ ("minFold", match lo with | some n => toJson n | none => Json.null)
            , ("maxFold", match hi with | some n => toJson n | none => Json.null)
            , ("paths", toJson paths) ])
        , ("blockAsks", toJson (blockAsks fns prog.main))
        , ("fnAsks", Json.arr (fns.map (fun fe =>
            Json.arr #[Json.str fe.name, toJson fe.asks])).toArray)
        , ("worlds", Json.arr (worlds.map (worldObservation p)).toArray) ]
    else
      Json.mkObj [("error", "world is missing an answer for a queried structured schema")]

/-! ## The string layer (D12)

The surface this design ranks first for divergence risk — `Exec.norm` is
ASCII-only where Haskell's `toLower` is Unicode — and the only Tier-0 coverage
it can get, because on a program-in/world-out boundary nothing ever calls
`Decode`. -/

/-- The three original ops, unchanged in shape and in meaning. -/
def stringOp (op : String) (code : Option String) (text : String) : Json :=
  let wrap (j : Json) : Json := Json.mkObj [("result", j)]
  match op with
  | "norm" => wrap (Json.str (Exec.norm text))
  | "words" => wrap (toJson (Exec.words text))
  | "decodeVerdict" => wrap (verdictJson (Exec.decodeVerdict text))
  | "decode" =>
    match code.bind codeOfName with
    | some c =>
      match Decode c text with
      | some a => Json.mkObj [("result", Json.mkObj [("answer", answerJson c a)])]
      | none => Json.mkObj [("result", Json.mkObj [("answer", Json.null)])]
    | none => Json.mkObj [("error", Json.str "decode takes a code: text, verdict, flag or receipt")]
  | "say" =>
    match code.bind codeOfName with
    | some c =>
      match Decode c text with
      | some a => Json.mkObj [("result", Json.str (sayAnswer c a))]
      | none => Json.mkObj [("result", Json.null)]
    | none => Json.mkObj [("error", Json.str "say takes a code")]
  | _ => Json.mkObj [("error", Json.str s!"unknown string op `{op}`")]

def getStrField (j : Json) (k : String) : Option String :=
  (j.getObjVal? k).toOption.bind (·.getStr?.toOption)

/-- The string layer, dispatched off the whole `{"string": …}` object because
the new ops (D2's fence, D7's deciders) carry fields the three original ones did
not. **The extension is additive**: `{"op", "code"?, "text"}` still means exactly
what it meant, and an old oracle meeting a new request answers
`{"error": "unknown string op …"}`, which is a loud failure and not a silent one.

The four low-level ops (`bare`, `fields`, `headerPaths`, `matchGlob`) exist so
that a divergence is *localizable*: a `decide` mismatch with all four green is a
composition bug, and with one of them red is that function's bug. Same reason
`norm` and `words` are pinned apart from `decode`. -/
def stringOpOf (sj : Json) : Json :=
  let op := (getStrField sj "op").getD ""
  let code := getStrField sj "code"
  let text := (getStrField sj "text").getD ""
  let wrap (j : Json) : Json := Json.mkObj [("result", j)]
  match op with
  | "bare" => wrap (Json.str (Exec.bare text))
  | "fields" => wrap (toJson (Exec.fields text))
  | "headerPaths" => wrap (toJson (Exec.headerPaths text))
  | "matchGlob" =>
    match getStrField sj "pattern" with
    | some pat => wrap (Json.bool (Exec.matchGlob pat text))
    | none => Json.mkObj [("error", Json.str "matchGlob takes a `pattern`")]
  | "fence" =>
    match getStrField sj "name" with
    | some n => wrap (Json.str (Dsl.block n text))
    | none => Json.mkObj [("error", Json.str "fence takes a `name`")]
  | "decide" =>
    match (getStrField sj "decider").bind deciderOfName with
    | none =>
      Json.mkObj [("error", Json.str "decide takes a decider: lastNonEmptyLineIs, \
                                     containsLine, anyLineStartsWith or anyPathMatches")]
    | some d =>
      match (sj.getObjVal? "needles").toOption.bind
          (fun nj => (fromJson? (α := List String) nj).toOption) with
      | none => Json.mkObj [("error", Json.str "decide takes `needles`, a list of strings")]
      | some ws => wrap (Json.bool (Decider.run d ws text))
  | _ => stringOp op code text

/-! ## The loop -/

def getStr? (j : Json) (k : String) : Option String :=
  (j.getObjVal? k).toOption.bind (·.getStr?.toOption)

end Agentic.Core.Conformance
