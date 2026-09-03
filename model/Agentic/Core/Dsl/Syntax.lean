import Agentic.Core.Plan

/-!
# The raw syntax: the unchecked term of a workflow

Stage 3, part one, and **the conformance boundary itself**. This module is the
*first-order* half of the language: a term language of names, strings and
numbers that mentions no `Plan`, no `Env` and no `Expr`, so that building one is
a total function into ordinary data and every question of well-typedness is
deferred to `Agentic/Core/Dsl/Check.lean`.

A `RawProgram` is exactly what crosses between the two implementations
(`doc/research/connection.md`, D10): it is what `bisim/corpus/`
freezes, what the bisim `conformance-oracle` accepts, and what the Haskell authoring
surface builds. Nothing upstream of it is shared, and since the Lean excision
nothing upstream of it exists on this side at all.

The shapes are the redesign's (obr acat-k28; its grammar page went with the
`.wf` language and is in git history): bindings are a name and a source with
the kind usually inferred; branching is on a flag, on a verdict, or on a
bounded revision's settled-or-not result, or a three-way bounded revision's
ending; the loop is a bounded revision of a
subject by an
amendment; a statement-position ask is the act. Three shapes here are decisions
rather than conveniences.

* **A branching is one constructor per tag type, and its arms are fields.**
  `Plan.case` demands a `Tag`, hence *total* arms, so each branching the
  surface writes — two-valued (`El .flag`), three-valued (`VTag`), the
  two-valued settled-or-not of a loop result and the three-valued `Ending` of a
  `revising on` — is a constructor whose arms are
  ordinary recursive fields. A nested `List (String × RawBlock)` would force
  well-founded recursion on the checker, and `WellFounded.fix` does not reduce
  in the kernel, which the flagship theorems need it to.
* **A bound loop is a source, and its `case` is the next statement.** `Ctx =
  List Code`, so the candidate-and-ending pair a bounded revision produces
  cannot be a context entry; it is reached by `Plan.graft`, whose continuation
  is not a binder. The surface writes `x <- revising …` and then `case x
  { settled p {…} unsettled q {…} }`, and the checker requires the `case` to be
  the very next statement, so the pair never needs a context slot: the two
  statements elaborate to one graft whose continuation is the `case` the arms
  write, and **each arm binds the candidate** — the settled one the artefact a
  review approved, the unsettled one the artefact the final review objected to.
* **The kind annotation is optional syntax, not optional information.** A
  binder may write `x : text <-`; when it does not, the checker infers the
  kind from the name's first ground use, and refuses a name with no use to
  infer from. The annotation is carried in the syntax so that the refusal can
  say exactly where one would go.

`define` does not appear below. It is textual and an authoring surface expands
it before building a `Raw` — a hole names a define or a binding, and the two
namespaces are disjoint by construction — so a `Raw` mentions only names a
checker can be asked to resolve. The corpus pins that expansion having happened:
`battery-026`, `-027`, `-122` and `-123` are frozen `Raw`s in which every define
is already literal text.
-/

namespace Agentic.Core

/-! ## Rendering a verdict as text

The DSL needs one, for a `{v}` hole at a verdict binding, and it does **not**
define one: `Verdict.render` and `Verdict.objections` are stated once in
`Agentic/Core/Question.lean`, beside the verdict algebra they read, and this
module re-uses them. There used to be a copy here and a second copy in
`Agentic/Core/HardenPatch.lean` with an `rfl` theorem gluing the two; obr
`acat-j61` names that pattern and the single definition is the repair. -/

namespace Dsl

/-! ## Positions and diagnoses -/

/-- `[[Pos]]` = a point of an authoring surface's source text, one-based, as a
reader counts. Carried through the boundary so that a diagnosis can name a
place; the checker never interprets it. -/
structure Pos where
  /-- Line number, counting from one. -/
  line : Nat
  /-- Column number, counting from one. -/
  col : Nat
  deriving Repr, DecidableEq, Inhabited

/-- `[[CheckError]]` = why a program denotes no workflow: where, what was wrong,
and the fragment it was wrong at.

A structure and not a bare `String` because more than one consumer must report
the same thing the same way — the conformance oracle, which serializes it, and
any tool surface that hands a diagnosis back for self-correction — and a message
is only identical across call sites if it is built once.

The corpus compares the *classification* and not these strings
(`Conformance.classify`, `refusedJson`): `pos`, `excerpt` and `message` are
oracle-only fields, so a rewording is a one-line edit to the classifier and not a
break of the Haskell side. -/
structure CheckError where
  /-- Where the offending construct begins. -/
  pos : Pos
  /-- What is wrong, in one sentence. -/
  message : String
  /-- The offending fragment, quoted, or `""` where there is nothing to quote. -/
  excerpt : String
  deriving Repr, Inhabited

instance : ToString CheckError where
  toString e :=
    let at_ := if e.excerpt.isEmpty then "" else s!" at `{e.excerpt}`"
    s!"{e.pos.line}:{e.pos.col}: {e.message}{at_}"

/-! ## Prompts -/

/-- `[[Chunk]]` = one piece of a prompt: literal text, or the value of a name.

The interpolation `{x}` is a `Chunk` and not a general expression because the
language has no expressions: a prompt is a concatenation of things said and
things heard, and nothing else can appear in one. A hole that names a define
never reaches this type: an authoring surface expands it, so a `Raw`'s prompts
hold only literals and answer-holes. -/
inductive Chunk where
  /-- Text written in the source. -/
  | lit (s : String)
  /-- The answer bound to a name, spliced in. -/
  | interp (name : String)
  deriving Repr, DecidableEq, Inhabited

/-- `[[Prompt]]` = everything said in one question, as written: a list of
chunks, read left to right. -/
abbrev Prompt : Type := List Chunk

/-- `[[Prompt.closed p]]` = the words of `p` when it mentions no name, and
`none` when it does.

The distinction is not cosmetic. A prompt that mentions nothing in scope is a
*closed* question, which is `Plan.askC` and starts a plan at the `batch` rung;
one that mentions something is `Plan.ask`, which is `pipeline`. After `define`
expansion every hole that named a define is a literal, so a question is closed
exactly when every hole it wrote named one. -/
def Prompt.closed : Prompt → Option String
  | [] => some ""
  | [.lit s] => some s
  | .lit s :: rest => (Prompt.closed rest).map (s ++ ·)
  | .interp _ :: _ => none

/-! ### Chunking is the author's, not the checker's

**Adjacent literals are deliberately *not* fused, and no pass here rewrites a
`Prompt`.** Fusing adjacent literals is the obvious tidying and it is wrong:
`Prompt.expr` (`Agentic/Core/Dsl/Check.lean`) emits the concatenation of the
chunks *left-associated*, exactly as `a ++ b ++ c` parses in Lean, so a prompt
whose chunks are written the way an author would write the same string in Lean
elaborates to the very same `Expr` — which is what keeps the flagship's
transcript agreements with `Agentic/Core/HardenPatch.lean` computations rather
than proofs about `String.append_assoc`. A `define` spliced into a prompt
therefore contributes *its own chunk*, and two adjacent `lit`s in a corpus
prompt are legitimate and must round-trip verbatim.

This module used to carry a `Prompt.normalize` — empty literals dropped — as a
*statement* of what an authoring surface should do after `define` expansion.
Nothing in Lean ever applied it, and the authoring surface is now Haskell's
`[wf|…|]` quoter, where the rule is applied and stated (`Agentic.WF.normalize`);
a specification with no implementation on its own side is a claim, so it went
with obr `acat-o5o`. What is normative here is the non-fusion above, which
`Prompt.expr` enforces by construction.
-/

/-! ## The unchecked term language -/

/-- `[[RawTarget]]` = whom a question is put to and which draw it is: the part
of `Q.Shape` an author writes. The third field of a shape — the scope — is the
unit of the scope monoid at every node the syntax can write, and
`served by "…"` is the only override, so it is not a field here. -/
structure RawTarget where
  /-- Who is asked. -/
  addressee : Addressee
  /-- Which independent draw this is; `0` unless deliberately resampling. -/
  draw : Nat
  deriving Repr, DecidableEq, Inhabited

/-- `[[Served]]` = the models that may answer a pinned question: the one the
author named, and the ones the runner may fall back to, in the order they are
tried (D6).

A structure and not a `List String`, so that "pinned but empty" is
unrepresentable and no new guard is owed; and a *payload* of the existing
`Option`, so that `"model": null` still reads as unpinned. **The alternates are
dropped at elaboration** — `Check.askShape` takes `primary` alone — and that is
the formal statement that fail-over is not part of a program's meaning: two asks
differing only in their alternates elaborate to the same plan, ask the same
question and bill the same. -/
structure Served where
  /-- The model that serves this question. -/
  primary : String
  /-- The models that may answer in its place, in the order they are tried. -/
  alternates : List String
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawAsk]]` = one question as written: addressee, optional serving model,
words and position. Answer kind and execution intent are occurrence properties,
not Raw fields. Binder/panel position fixes kind; source form fixes the annotated
Plan intent. The checker preserves the version-2 Raw wire. -/
structure RawAsk where
  /-- The model override, if any — with its alternates; legal only on a model
  addressee, which `Check.askGuard` enforces on every `Raw` however it was
  built. -/
  model : Option Served
  /-- Whom to ask. -/
  target : RawTarget
  /-- What to say. -/
  prompt : Prompt
  /-- Where the construct begins, for diagnoses. -/
  pos : Pos
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawArg]]` = one argument at a call site, after an authoring surface has
resolved defines and labelled fences: the name of something in scope, or literal
words (a quoted string, a fenced block, an expanded define, or a labelled
fence's content — the checker cannot tell, which is the point). -/
inductive RawArg where
  /-- A name in scope, passed at the parameter's kind. -/
  | name (x : String) (pos : Pos)
  /-- Words, elaborated in the caller's bindings; fills a `text` parameter. -/
  | lit (p : Prompt) (pos : Pos)
  deriving Repr, DecidableEq, Inhabited

/-- Where an argument is written. -/
def RawArg.pos : RawArg → Pos
  | .name _ p => p
  | .lit _ p => p

/-- `[[TextMember]]` = one member of a text panel: the name its block is fenced
under, and the question that fills it.

A named structure and not a `String × RawAsk`, because the pair's derived codec
puts a two-element array on the wire and **the corpus is read by humans**: a
member is `{"name": …, "ask": …}`. The label comes first here because it is how
the source reads. -/
structure TextMember where
  /-- The name this member's block is fenced under. -/
  name : String
  /-- The question put to this member. -/
  ask : RawAsk
  deriving Repr, DecidableEq, Inhabited

/-- `[[Decider]]` = the closed vocabulary of pure classifications (D7).

Four, named in the kernel, held identically in Lean and Haskell, and **closed**:
a fifth is a language change and is reviewed as one. Each reads the text bound
to a name and answers `flag`, asking nothing — so a classification that used to
round-trip through an answerer becomes a fact about the text, and a decider's
test can never be chosen by a model. -/
inductive Decider where
  /-- The last non-empty line is one of the needles. -/
  | lastNonEmptyLineIs
  /-- Some line is exactly one of the needles. -/
  | containsLine
  /-- Some line begins with one of the needles. -/
  | anyLineStartsWith
  /-- Some path named by a diff header matches one of the globs. -/
  | anyPathMatches
  deriving Repr, DecidableEq, Inhabited

/-- `[[deciderName d]]` = the keyword that writes the decider `d`. -/
def deciderName : Decider → String
  | .lastNonEmptyLineIs => "lastNonEmptyLineIs"
  | .containsLine => "containsLine"
  | .anyLineStartsWith => "anyLineStartsWith"
  | .anyPathMatches => "anyPathMatches"

/-- …and the keyword parsed back, which is the section `deciderName` splits. -/
def deciderOfName : String → Option Decider
  | "lastNonEmptyLineIs" => some .lastNonEmptyLineIs
  | "containsLine" => some .containsLine
  | "anyLineStartsWith" => some .anyLineStartsWith
  | "anyPathMatches" => some .anyPathMatches
  | _ => none

/-- **Morphism equation.** `deciderOfName` is a retraction of `deciderName`, so
an authoring surface's keyword, the checker's diagnosis and the corpus's field
are one table — the same discipline `codeOfName` holds for the four built-in
answer kinds. -/
@[simp] theorem deciderOfName_deciderName (d : Decider) :
    deciderOfName (deciderName d) = some d := by
  cases d <;> rfl

/-- `[[Decider.run d ws s]]` = the classification `d` makes of the text `s`
against the needles `ws`. The four total algorithms, in full, each composed from
`Agentic/Core/Text.lean`'s already-pinned primitives so that the divergence
surface between the two implementations is exactly what is new and what is new
is small.

* `lastNonEmptyLineIs` — `getLast?` on `dlines` is literally "the last non-empty
  line", because `answerLines` has already dropped the blanks. Empty input and
  whitespace-only input both give `false`, which matches incite's `tripEnding`
  reporting a protocol violation on empty.
* `containsLine` — exact line equality, the only exact-match member of the
  family. It has **no incite ancestor** and is admitted on its own merits: it is
  what a program wants when the program itself dictated the sentinel ("end with
  a line that is exactly `READY`"), where a prefix test would admit `READY-ISH`
  and a decider that admits more than the program asked for is the failure mode
  this vocabulary exists to remove.
* `anyLineStartsWith` — reconstructs both `isRed` and `decideFactsResolved` from
  incite's `Incite/Feature.hs`; prefix, not equality, any line, not the last.
* `anyPathMatches` — reconstructs `diffNamesHaskell` from incite's
  `Incite/Review.hs` in one binding: `headerPaths` reproduces its
  lines-filtered-by-header-prefix-then-words structure, and `matchGlob "*<ext>"`
  reproduces its suffix test because `*` crosses `/` and the match is anchored
  at the end. It is the *only* decider that covers it, because the test is
  two-level — a prefix on the line, then a suffix on each token of that line. -/
def Decider.run : Decider → List String → String → Bool
  | .lastNonEmptyLineIs, ws, s =>
    match (Exec.dlines s).getLast? with
    | none => false
    | some l => ws.any (fun w => l == Exec.dneedle w)
  | .containsLine, ws, s =>
    (Exec.dlines s).any (fun l => ws.any (fun w => l == Exec.dneedle w))
  | .anyLineStartsWith, ws, s =>
    (Exec.dlines s).any (fun l => ws.any (fun w => (Exec.dneedle w).isPrefixOf l))
  | .anyPathMatches, gs, s =>
    (Exec.headerPaths s).any (fun p => gs.any (fun g => Exec.matchGlob g p))

/-- `[[RawRhs]]` = a clause-position source: one question, a panel of them, a
text panel, a decision about text already in hand, or a call of a function. The
loop is not here — a bounded revision's result is not a value a clause can
hold. -/
inductive RawRhs where
  /-- A single question. -/
  | ask (a : RawAsk)
  /-- `panel, all must approve [ … ]`: several questions, their answers combined
  in the verdict monoid — the one rule the menu currently has, named on the
  page. -/
  | panel (members : List RawAsk) (pos : Pos)
  /-- `panel as text [ name: ask, … ]`: several questions, each member's answer
  fenced under its own name and the blocks concatenated in member order. The
  label is explicit and is *not* the addressee id: two members of one spread
  routinely share an addressee, and a document whose names change when an
  operator repoints a lens is naming the wrong thing. -/
  | panelText (members : List TextMember) (pos : Pos)
  /-- `decide d x [w₁, …]`: a pure classification of the text bound to `x`,
  answering `flag`. It asks nothing, and its needles are **literal program
  text** — never a `Prompt` — because a needle a model could author is a test a
  model chooses, which is not a decider. -/
  | decide (decider : Decider) (subject : String) (needles : List String) (pos : Pos)
  /-- `f a₁ … aₙ`: a function applied, by juxtaposition, to exactly its arity
  in single-token arguments. The function is a named open plan; the call is
  substitution, so nothing here is a new node. -/
  | call (fn : String) (args : List RawArg) (pos : Pos)
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawSource]]` = what a binding may bind: a clause-position source, or a
bounded revision.

`revising s as c, at most n amendments { v <- review  amend c { source } }`:
the loop revises `s`, calling the moving candidate `c`; each round binds one
verdict (`v`, an ordinary binding with an author-chosen name) by the review
source; the loop settles when it approves, and otherwise the `amend` source's
answer — with `c` and `v` in scope — becomes the next candidate. -/
inductive RawSource where
  /-- One question or one panel. -/
  | rhs (r : RawRhs)
  /-- A bounded revision. `reviewAnn` is the optional `: verdict` annotation on
  the review binding, kept so the checker can refuse a wrong one at its own
  position. -/
  | revising (subject carrier : String) (bound : Nat)
      (reviewName : String) (reviewAnn : Option Code) (review : RawRhs)
      (amend : RawRhs) (pos : Pos)
  /-- `revising on s as c, at most n amendments { v <- review  amend c { source } }`:
  the same loop, whose fork reads the review's verdict three ways — approval
  settles, an objection amends, a refusal abandons.

  The payload is identical to `revising`'s and only the constructor differs,
  deliberately: **the difference is in how the loop reads its verdict, which is
  a property of the loop and not of its clauses**, so the checker's long
  prologue is shared verbatim between the two clauses rather than transcribed.
  Its consuming form is `caseEnding`, never `caseResult`. -/
  | revisingOn (subject carrier : String) (bound : Nat)
      (reviewName : String) (reviewAnn : Option Code) (review : RawRhs)
      (amend : RawRhs) (pos : Pos)
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawBlock]]` = an unchecked block: statements, of which the branchings
are terminal — each arm *is* the rest of the workflow — and a statement-position
ask is the act, which may be followed. `stop` writes a receipt-valued ending;
`answer x` returns one live binding from a result-valued program; and `{ }` is
not writable. -/
inductive RawBlock where
  /-- `stop`, or a receipt-valued block whose statements ran out after an act.
  The position is where the nothing is written. -/
  | empty (pos : Pos)
  /-- `answer x`: return the live binding named `x`. The program's expected
  result code is carried outside the frozen `RawProgram` record and imposed by
  `checkProgramResult`; every branch is checked at that same code. -/
  | answer (x : String) (pos : Pos)
  /-- `x <- source` or `x : kind <- source`, followed by the rest. When the
  source is a `revising`, the rest must begin with `case x { settled …
  unsettled … }`, which the checker enforces. -/
  | bind (x : String) (ann : Option Code) (src : RawSource) (rest : RawBlock) (pos : Pos)
  /-- A statement-position ask: an occurrence-sensitive `Intent.effect` at
  `.ack`. It binds nothing, and the block continues after it. -/
  | act (a : RawAsk) (rest : RawBlock) (pos : Pos)
  /-- `if x {…} else {…}`: the two values of `El .flag`, both arms written. -/
  | ifFlag (x : String) (yes no : RawBlock) (pos : Pos)
  /-- `case x { approved {…} objected {…} no answer {…} }`: the three values of
  `VTag`, the finite classifier of a verdict. -/
  | caseVerdict (x : String) (approved objected noAnswer : RawBlock) (pos : Pos)
  /-- `case x { settled p {…} unsettled q {…} }`: the two outcomes of a bounded
  revision, the settled artefact bound as `p` and the last candidate — the one
  the final review objected to — bound as `q`. Legal only immediately after
  `x <- revising …`, which the checker enforces.

  **The two names may coincide**, because they bind in disjoint arms, and an
  authoring surface that builds both arms at the same depth will always make
  them coincide. -/
  | caseResult (x : String) (settledName unsettledName : String)
      (settled unsettled : RawBlock) (pos : Pos)
  /-- `case x { settled p {…} unsettled q {…} abandoned t {…} }`: the three
  outcomes of a three-way bounded revision, each binding the candidate in hand.
  Legal only immediately after `x <- revising on …`, which the checker
  enforces. -/
  | caseEnding (x : String) (settledName unsettledName abandonedName : String)
      (settled unsettled abandoned : RawBlock) (pos : Pos)
  /-- `known here: a, b, c` (or `known here: nothing`): a checker-verified
  assertion of exactly the names in scope, innermost first. Documentation that
  cannot rot. -/
  | knownHere (names : List String) (rest : RawBlock) (pos : Pos)
  /-- A statement-position call of a `-> receipt` function: a reusable act
  sequence, run for its doing, and the block continues after it. -/
  | callStmt (fn : String) (args : List RawArg) (rest : RawBlock) (pos : Pos)
  deriving Repr, DecidableEq, Inhabited

/-- `[[Raw]]` = an unchecked text of a workflow: the body of `workflow { … }`,
with every `define` already expanded. -/
abbrev Raw : Type := RawBlock

/-- `[[RawBodyStmt]]` = one statement of a function body. A body's binding takes
a `RawRhs`, not a `RawSource`, so a loop in a body is unwritable by type; the
branchings are likewise absent, so **a function is a reusable sequence of
questions, not a reusable decision** — decisions stay where they are read. -/
inductive RawBodyStmt where
  /-- `x <- rhs`, with the optional kind annotation. -/
  | bind (x : String) (ann : Option Code) (rhs : RawRhs) (pos : Pos)
  /-- A statement-position ask: an act inside the body. -/
  | act (a : RawAsk) (pos : Pos)
  /-- A statement-position call of a `-> receipt` function. -/
  | callS (fn : String) (args : List RawArg) (pos : Pos)
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawFn]]` = one function, as written: `function name (p : kind, …) ->
kind { body }`. The body is statements and — for a value-returning function —
`answer x`, naming a parameter or a body binding; a `-> receipt` function's
body just ends, because `El .ack = Unit` and the end of a block already is the
receipt. -/
structure RawFn where
  /-- The function's name (dotted when it came in through an import). -/
  name : String
  /-- The parameters, in source order, each with its kind. -/
  params : List (String × Code)
  /-- The declared result kind. -/
  result : Code
  /-- The body's statements, in order. -/
  body : List RawBodyStmt
  /-- `answer x` for a value function; `none` for `-> receipt`. -/
  answer : Option String
  /-- Where the `answer` (or the body's end) is written, for diagnoses. -/
  answerPos : Pos
  /-- Where the function begins. -/
  pos : Pos
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawProgram]]` = a whole program after the import walk: every reachable
library's functions (dotted), and one block — the libraries' primings, in
post-order, spliced ahead of the main workflow. -/
structure RawProgram where
  /-- Every function in scope, in stratified order: a call may name only an
  earlier entry, which is what refuses recursion. -/
  fns : List RawFn
  /-- The primings and the workflow, as one block. -/
  main : Raw
  deriving Repr, DecidableEq, Inhabited

/-- Where a right-hand side begins, for diagnoses. -/
def RawRhs.pos : RawRhs → Pos
  | .ask a => a.pos
  | .panel _ p => p
  | .panelText _ p => p
  | .decide _ _ _ p => p
  | .call _ _ p => p

/-- Where a source begins, for diagnoses. -/
def RawSource.pos : RawSource → Pos
  | .rhs r => r.pos
  | .revising _ _ _ _ _ _ _ p => p
  | .revisingOn _ _ _ _ _ _ _ p => p

/-! ## The names of the answer kinds

Spelled once for diagnostics and for the four built-in string-layer codes.
A schema-indexed code is structural data and cannot be reconstructed from this
one-word diagnostic name. -/

/-- `[[codeName c]]` = the keyword that writes the code `c`. -/
def codeName : Code → String
  | .text => "text"
  | .verdict => "verdict"
  | .flag => "flag"
  | .ack => "receipt"
  | .structured _ => "structured"

/-- Parse a built-in code name. A structured code also needs its schema. -/
def codeOfName : String → Option Code
  | "text" => some .text
  | "verdict" => some .verdict
  | "flag" => some .flag
  | "receipt" => some .ack
  | _ => none

@[simp] theorem codeOfName_text : codeOfName "text" = some .text := rfl
@[simp] theorem codeOfName_verdict : codeOfName "verdict" = some .verdict := rfl
@[simp] theorem codeOfName_flag : codeOfName "flag" = some .flag := rfl
@[simp] theorem codeOfName_receipt : codeOfName "receipt" = some .ack := rfl

end Dsl

end Agentic.Core
