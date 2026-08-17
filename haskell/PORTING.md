# PORTING.md — the week-one porting spec

*What four implementers must agree on without reading each other's work.*

The Lean side at the repository root is normative. The frozen corpus at
`test/corpus/*.json` (121 entries) is the arbiter:
where this document and the corpus disagree, **the corpus wins** and this
document is wrong. Where this document and the Lean source disagree, the Lean
source wins. Never edit anything outside `haskell/`.

Week-one scope is exactly four things:

1. the `Raw` AST types and their JSON codec (`Agentic.Raw`),
2. the five term-level guards and the two ask counts (`Agentic.Guards`),
3. the string layer (`Agentic.Text`),
4. the corpus runner (`tier0/Main.hs`).

**Not** in scope: the typing judgment, the parser, `Plan` denotation, worlds,
traces, bills, `level`/`size`/`askNodes`/`codes`/`costSummary`. Those are later
weeks and the corpus fields carrying them are simply not compared yet.

---

## 1 Layout and API

Agreed repository layout for `haskell/`. Do not create other
top-level paths.

```
flake.nix          devShell: (haskellPackages.ghcWithPackages (p: [p.aeson]))
                   plus cabal-install.  The flake devShell is the only
                   environment; install no global tools.
agentic.cabal      library: hs-source-dirs: src
                     exposed-modules: Agentic.Raw, Agentic.Text, Agentic.Guards
                   executable tier0: hs-source-dirs: tier0, main-is: Main.hs
                   build-depends: base, aeson, text, bytestring, containers,
                                  directory, filepath, vector, scientific
src/Agentic/Raw.hs     the Raw AST + FromJSON/ToJSON
src/Agentic/Text.hs    stringOp, Verdict
src/Agentic/Guards.hs  guardCheck, askCounts
tier0/Main.hs          the corpus runner
PORTING.md             this file
README.md              written by the runner agent
```

Exact exports:

```haskell
module Agentic.Raw
  ( Pos(..), Code(..), Chunk(..), Prompt, Addressee(..)
  , RawTarget(..), RawAsk(..), RawArg(..), RawRhs(..), RawSource(..)
  , Raw(..), RawBodyStmt(..), RawFn(..), RawProgram(..)
  ) -- every type with FromJSON and ToJSON

module Agentic.Guards
  ( Guard(..)          -- PanelEmpty | RevisionBound | QuestionBudget
                       -- | ServedBy | DupFunction
  , guardCheck         -- :: RawProgram -> Maybe (Guard, Maybe Integer)
  , askCounts          -- :: RawProgram -> (Integer, [(Text, Integer)])
  )

module Agentic.Text
  ( Verdict(..)
  , stringOp           -- :: Text -> Maybe Text -> Text -> Aeson.Value
  )
```

Conventions: Lean `Nat` is Haskell `Integer` (never `Int`; the corpus does not
exercise overflow but the counts multiply). Lean `String` is `Data.Text.Text`.
Haskell field and constructor names may be idiomatic — the JSON is what must
match, and comparison is on `Data.Aeson.Value`, so **object key order is free**.

`tier0` usage: `tier0 [corpusDir]`, defaulting to
`test/corpus`.

---

## 2 The Raw types

Source of record: `Agentic/Core/Dsl/Syntax.lean`,
with `Code` and `Addressee` from
`Agentic/Core/Question.lean`.

### 2.1 `Code` and `Addressee` (Question.lean)

```lean
inductive Addressee where
  | model (id : String)
  | tool (id : String)
  | person (id : String)
  deriving DecidableEq, Repr, Inhabited

inductive Code where
  | text
  | verdict
  | flag
  | ack
  deriving DecidableEq, Repr, Inhabited
```

`Code` has **four** constructors and the fourth is spelled `ack`. It is
*written* `receipt` in surface syntax and in diagnostics, via

```lean
def codeName : Code → String
  | .text => "text" | .verdict => "verdict" | .flag => "flag" | .ack => "receipt"
def codeOfName : String → Option Code
  | "text" => some .text | "verdict" => some .verdict
  | "flag" => some .flag | "receipt" => some .ack | _ => none
```

**This is the single most dangerous asymmetry on the wire; see §3.4.**

### 2.2 Positions and prompts

```lean
structure Pos where
  line : Nat
  col : Nat

inductive Chunk where
  | lit (s : String)
  | interp (name : String)

abbrev Prompt : Type := List Chunk
```

`Prompt.normalize` drops empty literals and deliberately does **not** fuse
adjacent literals; `Prompt.closed` returns the words when no `interp` appears.
Neither is ported — the parser applies `normalize`, and the Haskell side only
round-trips a `Prompt` as data. Do not normalize on decode or encode: a corpus
prompt may legitimately contain two adjacent `lit` chunks
(`battery-124-adjacent-holes-and-escapes-against-holes`) and re-encoding must
reproduce it verbatim.

### 2.3 The term language

```lean
structure RawTarget where
  addressee : Addressee
  draw : Nat

structure RawAsk where
  model : Option String     -- the `served by "s"` override
  target : RawTarget
  prompt : Prompt
  pos : Pos

inductive RawArg where
  | name (x : String) (pos : Pos)
  | lit (p : Prompt) (pos : Pos)

inductive RawRhs where
  | ask (a : RawAsk)
  | panel (members : List RawAsk) (pos : Pos)
  | call (fn : String) (args : List RawArg) (pos : Pos)

inductive RawSource where
  | rhs (r : RawRhs)
  | revising (subject carrier : String) (bound : Nat)
      (reviewName : String) (reviewAnn : Option Code) (review : RawRhs)
      (amend : RawRhs) (pos : Pos)

inductive RawBlock where
  | empty (pos : Pos)
  | bind (x : String) (ann : Option Code) (src : RawSource) (rest : RawBlock) (pos : Pos)
  | act (a : RawAsk) (rest : RawBlock) (pos : Pos)
  | ifFlag (x : String) (yes no : RawBlock) (pos : Pos)
  | caseVerdict (x : String) (approved objected noAnswer : RawBlock) (pos : Pos)
  | caseResult (x : String) (settledName : String) (settled unsettled : RawBlock) (pos : Pos)
  | knownHere (names : List String) (rest : RawBlock) (pos : Pos)
  | callStmt (fn : String) (args : List RawArg) (rest : RawBlock) (pos : Pos)

abbrev Raw : Type := RawBlock

inductive RawBodyStmt where
  | bind (x : String) (ann : Option Code) (rhs : RawRhs) (pos : Pos)
  | act (a : RawAsk) (pos : Pos)
  | callS (fn : String) (args : List RawArg) (pos : Pos)

structure RawFn where
  name : String
  params : List (String × Code)
  result : Code
  body : List RawBodyStmt
  answer : Option String
  answerPos : Pos
  pos : Pos

structure RawProgram where
  fns : List RawFn
  main : Raw
```

Note the two multi-name binder groups: `revising (subject carrier : String)`
declares **two** arguments named `subject` and `carrier`, and
`caseVerdict (approved objected noAnswer : RawBlock)` declares **three**. Every
argument of every constructor above carries a user-visible name — this is what
selects the named-field JSON form in §3.

`Raw` is a type synonym for `RawBlock`; the export list names `Raw(..)` because
in Haskell the two are one `data RawBlock` (call it whatever you like and
`type Raw = RawBlock`).

Two derived accessors exist in Lean (`RawRhs.pos`, `RawSource.pos`,
`RawArg.pos`) and are not on the wire; port them only if convenient.

---

## 3 The JSON encoding

### 3.1 The rules, verbatim from Lean

`conformance/Conformance.lean` derives every codec
standalone:

```lean
deriving instance FromJson, ToJson for Code
deriving instance FromJson, ToJson for Pos
deriving instance FromJson, ToJson for Chunk
deriving instance FromJson, ToJson for Addressee
deriving instance FromJson, ToJson for RawTarget
deriving instance FromJson, ToJson for RawAsk
deriving instance FromJson, ToJson for RawArg
deriving instance FromJson, ToJson for RawRhs
deriving instance FromJson, ToJson for RawSource
deriving instance FromJson, ToJson for RawBlock
deriving instance FromJson, ToJson for RawBodyStmt
deriving instance FromJson, ToJson for RawFn
deriving instance FromJson, ToJson for RawProgram
```

so the encoding is exactly Lean's `deriving ToJson` strategy, documented in
`Lean/Data/Json/FromToJson/Basic.lean`:

> - Basic types corresponding to JSON values are encoded as these values.
>   `Bool` is encoded as `true`/`false`. `String`s are encoded as JSON strings.
>   Numeric types are encoded as JSON numbers […]
> - `Unit` is encoded as `{}` (empty JSON object).
> - `Array`s and `List`s are encoded as JSON arrays.
> - `Option.none` is encoded as `null`, whereas `some a` has the same encoding
>   as `a`.
> - General `structure`s are encoded as JSON objects in the obvious way.
>   `Option` fields whose names end with `?` have special support […]
> - General `inductive` types are encoded on a per-constructor basis.
>   - An argument-free constructor is encoded as its name (a JSON string).
>   - A constructor with named arguments only is encoded as the JSON object
>     `{ "ctorName": { "arg1": argVal1, ..., "argN": argValN } }`.
>   - A constructor with one unnamed argument is encoded as the JSON object
>     `{ "ctorName": argVal }`.
>   - A constructor with more than one unnamed argument is encoded as the JSON
>     object `{ "ctorName": [argVal1, ..., argValN] }`.

and `Prod` is an array (`Prod.toJson (a, b) = Json.arr #[toJson a, toJson b]`).

**The multi-argument question, settled.** The task list flags this as the
likeliest codec mistake. The answer, from `Lean/Elab/Deriving/FromToJson.lean`:

```lean
match args, userNames with
| #[], _              => ``(toJson $(quote ctorStr))
| #[(x, t)], none     => ``(mkObj [($(quote ctorStr), $(← mkToJson x t))])
| xs, none            => ``(mkObj [($(quote ctorStr), Json.arr #[$[$xs:term],*])])
| xs, some userNames  => ``(mkObj [($(quote ctorStr), mkObj [$[$xs:term],*])])
```

with `userNames` set to `some` only when `userNames.size == binders.size`, i.e.
when **every** argument has a user-visible name. Every constructor of every
`Raw` inductive names all its arguments, so **every non-nullary constructor takes
the named-field object form** — including the one-argument ones. There are no
positional arrays anywhere in a `RawProgram`. Confirmed against the corpus:
`Chunk.lit` (one named argument) encodes as `{"lit": {"s": "w"}}`, not
`{"lit": "w"}`.

Decoding (`Json.getTag?` + `Json.parseCtorFields`): the tag is the string itself
for a nullary constructor, or the sole key of a one-key object otherwise; the
payload is read field by field by name. `getObjValD` is used for structure
fields, so a **missing** key decodes as `null`, which an `Option` field accepts
as `none`. Be liberal on input (missing key = `null` = `Nothing` for `Option`
fields) and strict on output (**always emit the explicit `null`** — the corpus
has `"model": null`, `"ann": null`, `"reviewAnn": null`, `"answer": null`).

### 3.2 The tag/field table

| Lean | JSON |
| --- | --- |
| `Pos ⟨l,c⟩` | `{"line": l, "col": c}` |
| `Code.text/.verdict/.flag/.ack` | `"text"` / `"verdict"` / `"flag"` / `"ack"` |
| `Chunk.lit s` | `{"lit": {"s": s}}` |
| `Chunk.interp n` | `{"interp": {"name": n}}` |
| `Prompt` | array of `Chunk` |
| `Addressee.model i` | `{"model": {"id": i}}` (likewise `tool`, `person`) |
| `RawTarget` | `{"addressee": …, "draw": n}` |
| `RawAsk` | `{"model": …\|null, "target": …, "prompt": […], "pos": …}` |
| `RawArg.name x p` | `{"name": {"x": x, "pos": p}}` |
| `RawArg.lit pr p` | `{"lit": {"p": [chunks], "pos": p}}` |
| `RawRhs.ask a` | `{"ask": {"a": …}}` |
| `RawRhs.panel ms p` | `{"panel": {"members": [asks], "pos": p}}` |
| `RawRhs.call f as p` | `{"call": {"fn": f, "args": [args], "pos": p}}` |
| `RawSource.rhs r` | `{"rhs": {"r": …}}` |
| `RawSource.revising …` | `{"revising": {"subject","carrier","bound","reviewName","reviewAnn","review","amend","pos"}}` |
| `RawBlock.empty p` | `{"empty": {"pos": p}}` |
| `RawBlock.bind …` | `{"bind": {"x","ann","src","rest","pos"}}` |
| `RawBlock.act …` | `{"act": {"a","rest","pos"}}` |
| `RawBlock.ifFlag …` | `{"ifFlag": {"x","yes","no","pos"}}` |
| `RawBlock.caseVerdict …` | `{"caseVerdict": {"x","approved","objected","noAnswer","pos"}}` |
| `RawBlock.caseResult …` | `{"caseResult": {"x","settledName","settled","unsettled","pos"}}` |
| `RawBlock.knownHere …` | `{"knownHere": {"names": [strings], "rest", "pos"}}` |
| `RawBlock.callStmt …` | `{"callStmt": {"fn","args","rest","pos"}}` |
| `RawBodyStmt.bind …` | `{"bind": {"x","ann","rhs","pos"}}` |
| `RawBodyStmt.act …` | `{"act": {"a","pos"}}` |
| `RawBodyStmt.callS …` | `{"callS": {"fn","args","pos"}}` |
| `RawFn` | `{"name","params","result","body","answer","answerPos","pos"}` |
| `RawProgram` | `{"fns": [RawFn], "main": RawBlock}` |
| `(String × Code)` | `["p", "text"]` |

### 3.3 Tag collisions

Four tags are reused across types and are told apart **only by position in the
tree**, never by shape-sniffing:

* `"bind"` — `RawBlock.bind` (fields `x ann src rest pos`) vs `RawBodyStmt.bind`
  (fields `x ann rhs pos`). Note `src : RawSource` vs `rhs : RawRhs`: a body
  binding cannot hold a `revising`, by type.
* `"act"` — `RawBlock.act` (`a rest pos`) vs `RawBodyStmt.act` (`a pos`).
* `"lit"` — `Chunk.lit` (`s`) vs `RawArg.lit` (`p pos`).
* `"name"` — `RawArg.name` (`x pos`), while `Chunk.interp` uses the *field* name
  `"name"` for its string. Different levels; no ambiguity if you decode by
  expected type.

Do not write a generic "decode any node" function. Decode by expected type, as
Lean does.

### 3.4 The two spellings of `Code` (the trap)

Inside a `RawProgram` — the fields `ann`, `reviewAnn`, `result`, and the second
component of a `params` pair — `Code` uses the **derived constructor names**:
`"text"`, `"verdict"`, `"flag"`, **`"ack"`**.

Everywhere else on the wire — the `code` field of a `string` request, the `code`
field of a trace `Event`, the entries of the checked reply's `codes` array —
`Code` uses **`codeName`/`codeOfName`**: `"text"`, `"verdict"`, `"flag"`,
**`"receipt"`**.

Verified exhaustively over the corpus: the key/value pairs occurring in requests
are `("ann","ack"|"flag"|"text"|"verdict")`, `("result","ack"|…)`,
`("reviewAnn","text"|"verdict")` and `("code","receipt"|"flag"|"text"|"verdict")`;
in replies only `("code","receipt"|…)`. `"ack"` never appears in a reply and
`"receipt"` never appears inside a `RawProgram`.

Consequence for Haskell: give `Code` *two* JSON encodings. The `FromJSON`/
`ToJSON` instance is the `ack` one (that is the one the `Raw` codec uses);
export separate `codeName :: Code -> Text` / `codeOfName :: Text -> Maybe Code`
functions for `Agentic.Text` and for any later trace work.

Related decoy: binder names in the corpus are sometimes literally the strings
`"text"` and `"verdict"` (`battery-132-kind-names-spelled-as-binder-names`).
A `"x": "text"` in a `bind` is a *name*, not a `Code`. Decode by field, not by
value.

### 3.5 Normative examples

#### `vector-004-empty-panel-hand-built` — a bind, a panel, `Option` as null

```json
{"main": {"bind": {"x": "p",
                   "src": {"rhs": {"r": {"panel": {"pos": {"line": 1, "col": 1},
                                                   "members": []}}}},
                   "rest": {"empty": {"pos": {"line": 1, "col": 1}}},
                   "pos": {"line": 1, "col": 1},
                   "ann": null}},
 "fns": []}
```

Read: `RawBlock.bind "p" none (.rhs (.panel [] ⟨1,1⟩)) (.empty ⟨1,1⟩) ⟨1,1⟩`.
Note the double wrapping `{"rhs": {"r": …}}` — `RawSource.rhs` names its single
argument `r`, so it still gets an object.

#### `vector-005-served-by-on-a-tool-hand-built` — an act, an addressee, `Chunk.lit`

```json
{"main": {"act": {"rest": {"empty": {"pos": {"line": 1, "col": 1}}},
                  "pos": {"line": 1, "col": 1},
                  "a": {"target": {"draw": 0,
                                   "addressee": {"tool": {"id": "t"}}},
                        "prompt": [{"lit": {"s": "w"}}],
                        "pos": {"line": 1, "col": 1},
                        "model": "deep"}}},
 "fns": []}
```

`"model": "deep"` is `some "deep"` — an `Option String` encodes as the payload,
not as `{"some": …}`. This is the served-by guard vector: a `model` override on
a `tool` addressee.

#### `vector-000-duplicate-function-names-hand-built` — `RawFn`, `params` tuples, `"ack"`-family `Code`

```json
{"main": {"empty": {"pos": {"line": 1, "col": 1}}},
 "fns": [{"result": "text",
          "pos": {"line": 1, "col": 1},
          "params": [["p", "text"]],
          "name": "f",
          "body": [],
          "answerPos": {"line": 1, "col": 1},
          "answer": "p"},
         {"result": "text", "pos": {"line": 1, "col": 1},
          "params": [["p", "text"]], "name": "f", "body": [],
          "answerPos": {"line": 1, "col": 1}, "answer": "p"}]}
```

`params` is `List (String × Code)` → an array of two-element arrays. A `-> receipt`
function is spelled `"result": "ack"` with `"answer": null`, e.g. from
`battery-144`:

```json
{"result": "ack", "pos": {"line": 9, "col": 1},
 "params": [["patch", "text"]], "name": "applied",
 "body": [{"act": {"pos": {"line": 10, "col": 3},
                   "a": {"target": {"draw": 0, "addressee": {"tool": {"id": "apply"}}},
                         "prompt": [{"lit": {"s": "apply: "}}, {"interp": {"name": "patch"}}],
                         "pos": {"line": 10, "col": 3}, "model": null}}}],
 "answerPos": {"line": 11, "col": 1}, "answer": null}
```

Note `RawBodyStmt.act` has only `a` and `pos` — no `rest`.

#### Branchings and calls (from `battery-066`, `battery-070`, `battery-143/144`, `battery-107`)

```json
{"ifFlag": {"x": "g",
            "yes": {"empty": {"pos": {"line": 3, "col": 19}}},
            "no":  {"empty": {"pos": {"line": 3, "col": 33}}},
            "pos": {"line": 3, "col": 12}}}

{"caseVerdict": {"x": "p",
                 "approved": {"empty": {…}},
                 "objected": {"empty": {…}},
                 "noAnswer": {"empty": {…}},
                 "pos": {"line": 2, "col": 12}}}

{"callStmt": {"fn": "applied",
              "args": [{"name": {"x": "d", "pos": {"line": 13, "col": 10}}}],
              "rest": {"empty": {…}},
              "pos": {"line": 13, "col": 2}}}

{"callS": {"fn": "mk",
           "args": [{"name": {"x": "p", "pos": {"line": 13, "col": 6}}}],
           "pos": {"line": 13, "col": 3}}}

{"call": {"fn": "mk",
          "args": [{"lit": {"p": [{"lit": {"s": "a goal"}}],
                            "pos": {"line": 12, "col": 20}}}],
          "pos": {"line": 12, "col": 17}}}

{"knownHere": {"names": ["d"], "rest": {…}, "pos": {"line": 6, "col": 12}}}
```

Note the two nested `lit`s in `RawArg.lit`: the outer is the `RawArg`
constructor, the inner is the `Chunk`.

#### `vector-002-blockasks-graft-at-depth` — `revising` and `caseResult`

Abridged (full file is the normative copy):

```json
{"revising": {"subject": "d",
              "carrier": "c",
              "bound": 2,
              "reviewName": "v",
              "reviewAnn": null,
              "review": {"ask": {"a": {…"prompt": [{"lit": {"s": "review "}},
                                                   {"interp": {"name": "c"}}]…}}},
              "amend": {"ask": {"a": {…}}},
              "pos": {"line": 2, "col": 8}}}

{"caseResult": {"x": "r",
                "settledName": "x",
                "settled": {…},
                "unsettled": {"empty": {…}},
                "pos": {"line": 6, "col": 3}}}
```

---

## 4 The guards and the counts

Source of record: `Agentic/Core/Dsl/Check.lean` and
the classifier in `Conformance.lean`.

### 4.1 The classifier and the compared fields

The guard is not a field of `CheckError`; the oracle assigns it by matching the
message text:

```lean
def classify (msg : String) : Guard :=
  if (msg.splitOn "a panel needs at least one member").length > 1 then .panelEmpty
  else if (msg.splitOn "at most 64 amendments").length > 1 then .revisionBound
  else if (msg.splitOn "elaborates to").length > 1 then .questionBudget
  else if (msg.splitOn "`served by` names the model").length > 1 then .servedBy
  else if (msg.splitOn "two functions answer to one name").length > 1 then .dupFunction
  else .other

def budgetN (msg : String) : Option Nat :=
  match msg.splitOn "elaborates to " with
  | _ :: rest :: _ =>
    let digits := rest.toList.takeWhile Char.isDigit
    if digits.isEmpty then none
    else some (digits.foldl (fun n d => n * 10 + (d.toNat - 48)) 0)
  | _ => none
```

and `refusedJson` marks the compared/oracle-only split:

```lean
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
```

**`pos`, `excerpt` and `message` are never compared.** They are functions of
written characters and of the checker's wording, which the Haskell side does not
have. Only `guard` and `n` are comparands, and `n` is non-null exactly for the
two `questionBudget` messages (both contain the literal `"elaborates to "`
followed immediately by digits).

`Guard` derives `ToJson` from nullary constructors, so on the wire it is a bare
string: `"panelEmpty" | "revisionBound" | "questionBudget" | "servedBy" |
"dupFunction" | "other"`.

### 4.2 The constants

```lean
def maxRevisions : Nat := 64      -- Check.lean:519
def maxQuestions : Nat := 4096    -- Check.lean:874
```

Both comparisons are **strict `<` on the limit**, i.e. the bound is inclusive:
`if maxRevisions < n then …` refuses `n = 65` and accepts `n = 64`;
`if maxQuestions < n then …` refuses `n = 4097` and accepts `n = 4096`.

### 4.3 The counting recurrences (exact)

```lean
def rhsAsks (fns : Fns) : RawRhs → Nat
  | .ask _ => 1
  | .panel ms _ => ms.length
  | .call f _ _ =>
    match fns.find? f with
    | some fe => fe.asks
    | none => 0

def bodyAsks (fns : Fns) : List RawBodyStmt → Nat
  | [] => 0
  | .bind _ _ r _ :: rest => rhsAsks fns r + bodyAsks fns rest
  | .act _ _ :: rest => 1 + bodyAsks fns rest
  | .callS f _ _ :: rest => rhsAsks fns (.call f [] ⟨0, 0⟩) + bodyAsks fns rest

def blockAsks (fns : Fns) : RawBlock → Nat
  | .empty _ => 0
  | .knownHere _ r _ => blockAsks fns r
  | .act _ r _ => 1 + blockAsks fns r
  | .callStmt f _ r _ => rhsAsks fns (.call f [] ⟨0, 0⟩) + blockAsks fns r
  | .bind _ _ (.rhs rhs) r _ => rhsAsks fns rhs + blockAsks fns r
  | .bind _ _ (.revising _ _ n _ _ rev am _) (.caseResult _ _ st un _) _ =>
    (n + 1) * rhsAsks fns rev + n * rhsAsks fns am
      + (n + 1) * (blockAsks fns st + blockAsks fns un)
  | .bind _ _ (.revising _ _ n _ _ rev am _) r _ =>
    (n + 1) * rhsAsks fns rev + n * rhsAsks fns am + blockAsks fns r
  | .ifFlag _ y n _ => blockAsks fns y + blockAsks fns n
  | .caseVerdict _ a o d _ => blockAsks fns a + blockAsks fns o + blockAsks fns d
  | .caseResult _ _ st un _ => blockAsks fns st + blockAsks fns un
```

Facts an implementer must not get wrong:

* **Clause order matters.** The `revising`-followed-by-`caseResult` clause
  precedes the general `revising` clause. Match on the pair `(src, rest)`.
* **`args` are ignored by the count.** `rhsAsks` on a `call` looks up only the
  callee's `asks`; `callStmt`/`callS` are priced as `rhsAsks (.call f [] ⟨0,0⟩)`
  — the arguments are literally discarded.
* **An unknown callee costs 0.** `fns.find? f = none → 0`. No error here; the
  error comes later from the typing judgment.
* **`revising` multiplies.** `n` amendments means `n+1` reviews and `n` amends —
  the review runs once before any amendment — and the loop's *tail*, when the
  next statement is the consuming `caseResult`, is replicated `n+1` times,
  because the graft's continuation appears once per exit.
* **A `revising` with no consuming `caseResult` does not replicate the tail.**
  That program is ill-typed and refuses as `other`, but the count is still
  defined and `guardCheck` may still need it to decide the budget.

The Fns table is built by `checkFnsList` and each entry's `asks` is
**`bodyAsks` against the table *before* it**:

```lean
def checkFnsList (acc : Fns) : List RawFn → Except CheckError Fns
  | [] => .ok acc
  | f :: rest =>
    if acc.any (fun fe => fe.name == f.name) then
      .error ⟨f.pos, "two functions answer to one name; rename one", f.name⟩
    else
    let n := bodyAsks acc f.body
    if maxQuestions < n then
      .error ⟨f.pos, s!"`{f.name}` elaborates to {n} questions, and the \
                       bound is {maxQuestions}", f.name⟩
    else
      match checkFn acc f with
      | .error err => .error err
      | .ok fe => checkFnsList (acc ++ [{ fe with asks := n }]) rest
```

So in Haskell:

```haskell
fnTable :: [RawFn] -> [(Text, Integer)]
fnTable = go []
  where go acc []     = acc
        go acc (f:fs) = go (acc ++ [(fnName f, bodyAsks acc (fnBody f))]) fs
```

and `askCounts prog = (blockAsks table (progMain prog), table)` with
`table = fnTable (progFns prog)`. The reply's `fnAsks` is exactly this list, in
table order, as `[["name", n], …]`.

**Worked example — `vector-002-blockasks-graft-at-depth`, reply `blockAsks: 39`.**
The shape is `bind d ← ask; bind r ← revising(bound 2); caseResult r settled=S
unsettled=empty`, with `S = bind r2 ← revising(bound 3); caseResult r2
settled=(act; empty) unsettled=empty`.

```
blockAsks S    = (3+1)*1 + 3*1 + (3+1)*(1 + 0)          = 4 + 3 + 4  = 11
blockAsks rest = (2+1)*1 + 2*1 + (2+1)*(11 + 0)         = 3 + 2 + 33 = 38
blockAsks main = rhsAsks(ask) + 38                      = 1 + 38     = 39
```

**Worked example — `vector-003-question-budget-with-count`, `n = 8193`.**
`f1` has one ask; each `f(i+1)` calls `f(i)` twice, so `asks(f(i)) = 2^(i-1)` and
`asks(f13) = 4096` — which is `≤ 4096`, so no *per-function* budget fires. Main
is `a ← f13 …; b ← f13 …; act`, i.e. `4096 + 4096 + 1 = 8193 > 4096`, and the
program-level budget refuses with `"this program elaborates to 8193 questions,
and the bound is 4096"`, `pos = {"line": 0, "col": 0}`, `excerpt = ""`, `n = 8193`.

These recurrences were checked mechanically against all 59 checked corpus
entries: `blockAsks` and `fnAsks` reproduce exactly, 59/59.

### 4.4 The order in which the guards fire — corrected

`checkProgram` is the only entry point the wire uses:

```lean
def checkProgram (prog : RawProgram) : Except CheckError (Plan [] Unit) :=
  match checkFnsList [] prog.fns with
  | .error err => .error err
  | .ok fns =>
    match overRevised prog.main with
    | some (rpos, n) =>
      .error ⟨rpos, s!"a bounded revision is unrolled into the term it writes, \
                      so its bound may name at most {maxRevisions} amendments",
              s!"at most {n} amendments"⟩
    | none =>
      let n := blockAsks fns prog.main
      if maxQuestions < n then
        .error ⟨⟨0, 0⟩, s!"this program elaborates to {n} questions, and the \
                          bound is {maxQuestions}", ""⟩
      else
        checkBlock fns [] [] none prog.main
```

**The claimed order in the task brief is wrong in three places.** The brief said
"dup-function first, then per-function budget, then per-block guards in
traversal order (panel empty, revision bound, served-by), then the
program-level budget". Corrections:

1. **The whole function table is processed before anything in `main`** — and
   `checkFnsList` calls `checkFn` on each entry, so a `panelEmpty` or a
   `servedBy` inside a function *body* fires during the table pass, ahead of
   every guard reachable from `main`. Also, the loop is per function: for
   `fns = [f0, f1]`, `f0`'s dup check, `f0`'s budget check and `f0`'s body are
   all done before `f1`'s dup check. A program whose `f0` body has an empty
   panel and whose `f1` duplicates `f0`'s name refuses `panelEmpty`, not
   `dupFunction`.
2. **`revisionBound` is not a traversal guard.** It is a separate pre-pass,
   `overRevised`, over the raw `main` block in reading order, run **after** the
   table and **before** the program budget and before `checkBlock` ever runs.
   So it beats `panelEmpty` and `servedBy` in `main`, whatever their relative
   source positions. (`checkBlock` carries a second, byte-identical
   `maxRevisions` refusal at `Check.lean:614` for hand-built entry points; it is
   unreachable through `checkProgram` because `overRevised` pre-empts it.)
3. **The program-level budget fires before the block traversal**, not after it.
   So an over-budget program refuses `questionBudget` even if its `main` also
   contains an empty panel.

The corrected order, which is what `guardCheck` must implement:

```
for each f in prog.fns, in order:
    1. name already in table          -> DupFunction
    2. bodyAsks(table, f.body) > 4096 -> QuestionBudget (that n)
    3. scan f.body in statement order -> PanelEmpty / ServedBy   (see §4.5)
    4. push (f.name, bodyAsks(table, f.body))
then:
    5. overRevised(main), reading order    -> RevisionBound
    6. blockAsks(table, main) > 4096       -> QuestionBudget (that n)
    7. scan main in traversal order        -> PanelEmpty / ServedBy   (see §4.5)
otherwise Nothing.
```

`overRevised` in full:

```lean
def overRevised : Raw → Option (Pos × Nat)
  | .empty _ => none
  | .knownHere _ r _ => overRevised r
  | .act _ r _ => overRevised r
  | .callStmt _ _ r _ => overRevised r
  | .bind _ _ (.rhs _) r _ => overRevised r
  | .bind _ _ (.revising _ _ n _ _ _ _ rpos) r _ =>
    if maxRevisions < n then some (rpos, n) else overRevised r
  | .ifFlag _ y n _ => (overRevised y).orElse fun _ => overRevised n
  | .caseVerdict _ a o d _ =>
    ((overRevised a).orElse fun _ => overRevised o).orElse fun _ => overRevised d
  | .caseResult _ _ s u _ => (overRevised s).orElse fun _ => overRevised u
```

It does not descend into function bodies — it cannot need to, because
`RawBodyStmt.bind` takes a `RawRhs` and a `revising` is unwritable there.

### 4.5 The two traversal guards

`servedBy`, from `askGuard` (Check.lean:320):

```lean
def askGuard (a : RawAsk) : Except CheckError Unit :=
  match a.model, a.target.addressee with
  | some _, .model _ => .ok ()
  | some _, _ =>
    .error ⟨a.pos, "`served by` names the model that serves a model addressee; \
                   a tool or a person is not served by one", "served"⟩
  | none, _ => .ok ()
```

i.e. fire iff `askModel a` is `Just _` **and** the addressee is not `Model`.

`panelEmpty`, from `rhsPlan` (Check.lean:435):

```lean
  | .panel ms pos =>
    match ms with
    | [] => .error ⟨pos, "a panel needs at least one member", "panel"⟩
    | _ => …
```

The emptiness test precedes the kind test, so an empty panel bound at `text`
still refuses `panelEmpty`; a *non-empty* panel bound at `text` refuses `other`
(`battery-062-a-panel-bound-at-text`).

Traversal order inside a `RawRhs`: `panel` checks emptiness first, then its
members left to right (each an `askGuard`); `ask` is one `askGuard`; `call`
raises neither guard.

Traversal order inside a body (`checkBody`, statement by statement, each
statement's own guards before the rest of the body): `bind` → its `rhs`;
`act` → its `RawAsk`; `callS` → nothing.

Traversal order inside a block (`checkBlock`, each statement's own guards before
its children, children in declared order):

| node | order |
| --- | --- |
| `empty` | — |
| `knownHere names rest` | `rest` |
| `act a rest` | `a`, then `rest` |
| `callStmt f args rest` | `rest` |
| `bind x ann (rhs r) rest` | `r`, then `rest` |
| `bind x ann (revising … rev am …) rest` | `rev`, then `am`, then `rest` |
| `ifFlag x yes no` | `yes`, then `no` |
| `caseVerdict x a o d` | `a`, then `o`, then `d` |
| `caseResult x s settled unsettled` | `settled`, then `unsettled` |

### 4.6 The week-one contract

The typing judgment is **not** ported. Guards fire *during* Lean's typed
traversal, so a program that is ill-typed earlier in traversal order refuses as
`other` before a guard is reached; without the judgment the Haskell side cannot
decide which comes first. Therefore `guardCheck` is required to agree with the
oracle only here:

* **On every corpus entry whose reply guard is one of the five** — and there is
  exactly one such entry per guard: `vector-000` (`dupFunction`),
  `vector-003` (`questionBudget`, `n = 8193`), `vector-004` (`panelEmpty`),
  `vector-005` (`servedBy`), `battery-110` (`revisionBound`) — `guardCheck` must
  return `Just (thatGuard, thatN)`, where `thatN` is `Just 8193` for `vector-003`
  and `Nothing` for the other four.
* **On every corpus entry whose reply is `checked`** (59 of them) `guardCheck`
  must return `Nothing`. A false positive here is a bug.
* **On every corpus entry refused `other`** (35 of them) `guardCheck`'s answer is
  unconstrained and Tier 0 does not look at it.

The algorithm of §4.4 was checked mechanically against the whole corpus: it
matches all five guard vectors, returns `Nothing` on all 59 checked entries,
and — a bonus, not a contract — also returns `Nothing` on all 35 `other`
entries. Treat that last fact as a useful smoke test, not a requirement: it can
change without a corpus regeneration only if a future vector is added, and the
contract above is what Tier 0 enforces.

---

## 5 The string layer

Source of record: `Agentic/Core/Exec.lean` (`norm`, `answerLines`, `words`,
`sole`, `decodeFlag`, `decodeVerdict`, `Decode`) and `Agentic/Core/Report.lean`
(`sayFlag`, `sayVerdict`, `sayAnswer`).

### 5.1 The dispatcher

```lean
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
```

`stringOp op code text` returns the **whole reply object**, not the payload.
`code` is read through `codeOfName`, so it is spelled `"receipt"`, never
`"ack"` (§3.4). The request object omits `code` entirely when the op does not
take one — decode it as `Maybe Text` tolerating a missing key.

The `error` branches have no corpus vectors; implement them anyway, byte for
byte (note the backticks around `{op}`).

### 5.2 `norm` — ASCII only, twice over

```lean
def norm (s : String) : String := s.trimAscii.toString.toLower
```

Both halves are ASCII-only, from Lean core:

* `String.trimAscii = s.toSlice.trimAsciiStart.trimAsciiEnd`, and
  `trimAsciiStart = dropWhile s Char.isWhitespace` where
  ```lean
  @[inline] def isWhitespace (c : Char) : Bool :=
    c = ' ' || c = '\t' || c = '\r' || c = '\n'
  ```
  **Exactly four characters.** Not `\v` (U+000B), not `\f` (U+000C), not NBSP
  (U+00A0), not any Unicode space separator.
* `String.toLower = s.map Char.toLower` with
  ```lean
  def toLower (c : Char) : Char :=
    if h : c.val ≥ 'A'.val ∧ c.val ≤ 'Z'.val then ⟨c.val + ('a'.val - 'A'.val), _⟩
    else c
  ```
  **Only `A`–`Z`.** Code-point count is preserved.

Divergence traps, each pinned by a vector:

| trap | vector | input → output |
| --- | --- | --- |
| Turkish dotted capital survives | `string-001` | `"İstanbul"` → `"İstanbul"` |
| Turkish dotless i survives, ASCII `I` lowers | `string-002` | `"ı vs I"` → `"ı vs i"` |
| sharp s untouched, `SS` lowers | `string-003` | `"STRASSE straße"` → `"strasse straße"` |
| Greek untouched entirely | `string-004` | `"ΟΔΥΣΣΕΥΣ οδυσσεύς"` → unchanged |
| **NBSP is not ASCII whitespace** | `string-005` | `"yes\u00a0"` → `"yes\u00a0"` (unchanged — the NBSP is neither stripped nor a token break) |
| CRLF is stripped (both `\r` and `\n`) | `string-006` | `"yes\r\n"` → `"yes"` |
| empty | `string-007` | `""` → `""` |
| leading/trailing blank lines strip | `string-008` | `"\n\n  approve  \n\n"` → `"approve"` |
| ASCII case | `string-000` | `"  HeLLo World  "` → `"hello world"` |

In Haskell: **do not** use `Data.Text.strip` (Unicode `isSpace`, strips NBSP and
`\v`/`\f`) and **do not** use `Data.Text.toLower` (full Unicode, can change
length: `İ` → `i` + U+0307). Write

```haskell
isWsAscii c = c == ' ' || c == '\t' || c == '\r' || c == '\n'
lowerAscii c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c
norm = T.map lowerAscii . T.dropWhile isWsAscii . T.dropWhileEnd isWsAscii
```

(the two drops commute here; Lean does start then end).

### 5.3 `answerLines` and `words`

```lean
def answerLines (s : String) : List String :=
  ((s.splitOn "\n").map (fun l => l.trimAscii.toString)).filter (fun l => !l.isEmpty)
```

Split on `"\n"` **only** (never on `"\r\n"` as a unit), ASCII-trim each piece
— which is what removes the `\r` of a CRLF line — then drop the empty pieces.
`answerLines ""` is `[]`, because `"".splitOn "\n" = [""]` and `""` is filtered
out. `answerLines "   "` is `[]` likewise.

```lean
def words (s : String) : List String :=
  let flush : List Char → List String → List String := fun cur acc =>
    if cur.isEmpty then acc else String.ofList cur :: acc
  let go := (norm s).toList.foldr
    (fun ch (p : List Char × List String) =>
      if ch.isAlphanum then (ch :: p.1, p.2) else (([] : List Char), flush p.1 p.2))
    (([], []) : List Char × List String)
  flush go.1 go.2
```

Operationally: `norm` the string, then split it into maximal runs of
`Char.isAlphanum`, dropping empty runs, preserving order. `Char.isAlphanum` is
**ASCII only** — `isUpper || isLower || isDigit`, all three bounded by ASCII
ranges. So `words "İstanbul"` is `["stanbul"]`: the `İ` survives `norm` and then
splits the token. Haskell's `isAlphaNum` is Unicode and would give
`["i\x307stanbul"]` or `["İstanbul"]` depending on the lowercasing — wrong twice.

Vector: `string-009`, `"  two   words \t here "` → `["two","words","here"]`.
`words ""` is `[]`.

The reply for `words` is a JSON array of strings: `{"result": ["two", …]}`.

### 5.4 `Verdict` and `decodeVerdict`

```lean
def sole (l : List String) : List String → Bool
  | [w] => l.contains w
  | _ => false

def approveWords : List String := ["approve", "approved", "lgtm"]
def approvesB (s : String) : Bool := sole approveWords (words s)

def decodeVerdict (s : String) : Verdict :=
  let ls := answerLines s
  if ls = [] then Verdict.declined
  else if approvesB s then Verdict.approve
  else Verdict.object ls
```

Note `approvesB` runs on the **raw** `s` (through `words`), not on `ls`.

Haskell type and its JSON:

```haskell
data Verdict = Approve | Declined | Object [Text]
```

```json
{"tag": "approve"}
{"tag": "declined"}
{"tag": "object", "objections": ["…", …]}
```

from `verdictJson`:

```lean
def verdictJson (v : Verdict) : Json :=
  match Verdict.tag v with
  | .approve => Json.mkObj [("tag", "approve")]
  | .declined => Json.mkObj [("tag", "declined")]
  | .object =>
    Json.mkObj
      [ ("tag", "object")
      , ("objections", toJson
          (v.recZeroCoe ([] : List Objection) FreeMonoid.toList : List Objection)) ]
```

**Invariant.** In Lean, `Verdict.object []` *is* the monoid unit, i.e. approval,
and would tag as `.approve`. `decodeVerdict` never constructs it (that branch is
guarded by `ls ≠ []`), but a Haskell `Object []` would serialize as
`{"tag":"object","objections":[]}` and diverge. Provide a smart constructor
`mkObject [] = Approve; mkObject os = Object os` and never use the raw one.

Vectors: `string-010` `"APPROVE"` → approve; `string-011` `"approve"` → approve;
`string-012` `"approve kind of"` → `object ["approve kind of"]` (two tokens, so
not a lone approve word); `string-013` `"OBJECTION: too long"` →
`object ["OBJECTION: too long"]`; `string-014` `""` → declined.

### 5.5 `decodeFlag` and `Decode`

```lean
def yesWords : List String := ["yes", "y", "true", "approve", "approved", "ok"]
def noWords : List String := ["no", "n", "false", "reject", "rejected", "deny"]
def saidNo (s : String) : Bool := (words s).any (fun w => noWords.contains w)
def saidYes (s : String) : Bool := sole yesWords (words s)

def decodeFlag (s : String) : Option Bool :=
  if saidNo s then some false
  else if saidYes s then some true
  else none
```

The asymmetry is the safety property: a *no* word **anywhere** denies, a *yes*
must be the **whole** reply, and `saidNo` is tested first.

```lean
def Decode : (c : Code) → String → Option (El c)
  | .text, s => some s
  | .flag, s => decodeFlag s
  | .verdict, s => some (decodeVerdict s)
  | .ack, _ => some ()
```

and the answer serializer:

```lean
def answerJson : (c : Code) → El c → Json
  | .text, s => Json.str s
  | .verdict, v => verdictJson v
  | .flag, b => Json.bool b
  | .ack, _ => Json.null
```

So the `decode` reply is `{"result": {"answer": …}}` where `…` is a string, a
verdict object, a bool, or `null`. **`null` is ambiguous**: it is both
`Decode .ack` succeeding (`answerJson .ack () = Json.null`) and `Decode .flag`
failing. Both branches produce the identical JSON; do not try to distinguish
them.

Vectors: `string-015` `flag "yes"` → `{"result":{"answer":true}}`;
`string-016` `flag "Yes\r\n"` → `true` (norm strips CRLF, lowercases);
`string-017` `flag "maybe"` → `{"result":{"answer":null}}`;
`string-018` `text "  anything at all  "` → `{"result":{"answer":"  anything at all  "}}`
— **`text` is verbatim, never normalized**; `string-019` `receipt "DONE"` →
`{"result":{"answer":null}}`.

### 5.6 `say`

```lean
def sayFlag (b : Bool) : String := if b then "yes" else "no"

def sayVerdict (v : Verdict) : String :=
  if Verdict.approvedB v then "approve"
  else if v = Verdict.declined then "declined"
  else String.intercalate "; " (Verdict.objections v)

def sayAnswer : (c : Code) → El c → String
  | .text, s => s
  | .verdict, v => sayVerdict v
  | .flag, b => sayFlag b
  | .ack, _ => "done"
```

`say` composes `Decode` then `sayAnswer`; a decode failure gives
`{"result": null}` (a bare null, **not** `{"answer": null}` — the two ops differ
in shape).

Vectors: `string-020` `say verdict "OBJECTION: no"` → `{"result":"OBJECTION: no"}`
(decodes to `object ["OBJECTION: no"]`, rendered by `intercalate "; "`);
`string-021` `say flag "no"` → `{"result":"no"}`.

In Haskell:

```haskell
sayVerdict Approve      = "approve"
sayVerdict Declined     = "declined"
sayVerdict (Object os)  = T.intercalate "; " os
```

---

## 6 Tier-0 comparison rules

Each corpus file is `{"name", "request", "reply", "oracleVersion": 1}`. The
runner classifies by the request:

* `request.string` present → a **string entry** (22 in the corpus);
* `request.program` present → a **program entry** (99);
* `request.ping` → none in the corpus; ignore or pass.

All comparisons are on `Data.Aeson.Value`, so object key order and number
formatting are free. Never compare raw bytes.

### 6.1 String entries — compare the whole reply

```
actual = stringOp (req.string.op) (req.string.code) (req.string.text)
assert  actual == entry.reply
```

The entire reply `Value`, nothing excluded. 22/22 must pass.

### 6.2 Program entries — codec round-trip, always

For every program entry, whatever the reply:

```
p       <- fromJSON (req.program)      -- must succeed
assert  toJSON p == req.program        -- as Values
```

99/99 must pass. A decode failure is a test failure, not a skip.

### 6.3 Program entries — refused with one of the five guards

`reply.refused.guard ∈ {panelEmpty, revisionBound, questionBudget, servedBy,
dupFunction}` (5 entries):

```
assert  guardCheck p == Just (guardOf reply.refused.guard, reply.refused.n)
```

`reply.refused.n` is `null` for four of them and `8193` for `vector-003`.
**Do not compare** `reply.refused.pos`, `.excerpt`, `.message` — they are
oracle-only.

### 6.4 Program entries — refused `other`

`reply.refused.guard == "other"` (35 entries): the codec round-trip of §6.2 and
**nothing else**. Do not compare `guardCheck`, `askCounts`, or any refusal
field. These programs are refused by the typing judgment, which is not ported.

### 6.5 Program entries — checked

No `refused` key (59 entries):

```
assert  guardCheck p == Nothing
assert  askCounts p  == (reply.blockAsks, [(n, k) | [n, k] <- reply.fnAsks])
```

`reply.fnAsks` is a JSON array of two-element arrays `["name", n]`, in table
order; compare as an ordered list, not a map.

**Not compared in week one:** `reply.level`, `reply.size`, `reply.askNodes`,
`reply.codes`, `reply.costSummary`, `reply.worlds` (and everything inside a
world: `trace`, `billFresh`, `billMemo`). Those need `Plan` denotation and are
later weeks. The runner should ignore them silently rather than fail on them.

### 6.6 Expected tally

```
121 entries
  22 string          -> §6.1
  99 program         -> §6.2, plus
       5 guard       -> §6.3   (one per guard, listed in §4.6)
      35 other       -> nothing further
      59 checked     -> §6.5
```

The runner should print this tally and exit non-zero on any mismatch, naming the
entry file, the field, the expected value and the actual one.
