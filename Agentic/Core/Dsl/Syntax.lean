import Agentic.Core.Plan

/-!
# The raw syntax: the unchecked text of a workflow

Stage 3, part one. This module is the *first-order* half of the DSL: a term
language of names, strings and numbers that mentions no `Plan`, no `Env` and no
`Expr`, so that parsing is a total function into ordinary data and every
question of well-typedness is deferred to `Agentic/Core/Dsl/Check.lean`.

Two shapes here are decisions rather than conveniences, and both are forced by
the requirement that the checker be *structurally* recursive.

* **A branching is one constructor per tag type, and its arms are fields.**
  `Plan.case` demands a `FinEnum`, hence *total* arms, so the two branchings the
  answer universe admits — two-valued (`El .flag`) and three-valued (`VTag`) —
  are two constructors whose arms are ordinary recursive fields. The obvious
  alternative, `case (x : String) (arms : List (String × RawBlock))`, is a
  nested inductive and a checker recursing through it must be well-founded;
  `WellFounded.fix` does not reduce in the kernel, and the flagship theorems of
  `Agentic/Core/Dsl.lean` need the checker to reduce. A *mutual* inductive
  `RawBlock`/`RawArms` avoids that and was measured: its `brecOn` turned a
  three-second kernel reduction into a three-minute one, because the
  course-of-values structure of a mutual family is rebuilt at every node. So
  exhaustiveness is enforced in the shape of the syntax, which is the cheapest
  place there is, and *which* branching a `case` is remains a question for the
  checker, where the scrutinee's code is known.
* **`revising` is a tail and not a right-hand side.** `Ctx = List Code`, so the
  `Option (El c)` a bounded revision produces cannot be a context entry; it is
  reached by `Plan.graft`, whose continuation is not a binder. The syntax
  records that by giving `revising` no name to bind and putting its two
  outcomes — `accepted` and `exhausted` — in the term.

`define` does not appear below. It is textual and the parser expands it, so a
`Raw` mentions only names that a checker can be asked to resolve.
-/

namespace Agentic.Core

/-! ## Rendering a verdict as text

The one library function the DSL needs that the stack did not already have.
`Agentic/Core/HardenPatch.lean` has the same function under `Harden.render`;
`Agentic/Core/Dsl.lean` proves the two spellings are one function, by `rfl`, so
nothing here is a second convention. -/

namespace Verdict

/-- `[[render v]]` = a verdict as text an addressee can read: its objections,
separated by `"; "`, and nothing where it declined — a refusal has no objection
list to show.

This is what makes `with (patch, why)` legal in a language whose interpolation
is restricted to text: `why` is bound to `render ∘ ·`, an `Expr Γ String`, so
the restriction holds without an exception rather than being waived for one
construct.

The projection is written out rather than taken from `Verdict.objections`
because that name belongs to `Agentic/Core/Report.lean`, which imports the
transport; a checker must not. `Agentic/Core/Dsl.lean` proves this is
`Harden.render`, by `rfl`, so the three spellings are one function. -/
def render (v : Verdict) : String :=
  String.intercalate "; " (if h : v = 0 then [] else FreeMonoid.toList (WithZero.unzero h))

/-- Approval renders as nothing: there was nothing to say. -/
@[simp] theorem render_approve : render Verdict.approve = "" := rfl

/-- A refusal renders as nothing either — `declined = 0` annihilates, and there
is no objection list under it. That the two collapse is why a revision is told
*that* it was not approved by being asked again, not by reading this string. -/
@[simp] theorem render_declined : render Verdict.declined = "" := rfl

end Verdict

namespace Dsl

/-! ## Positions and diagnoses -/

/-- `[[Pos]]` = a point of the source text, one-based, as a reader counts. -/
structure Pos where
  /-- Line number, counting from one. -/
  line : Nat
  /-- Column number, counting from one. -/
  col : Nat
  deriving Repr, DecidableEq, Inhabited

/-- `[[CheckError]]` = why a source text denotes no workflow: where, what was
wrong, and the fragment it was wrong at.

A structure and not a bare `String` because three consumers must report the same
thing the same way — the `agent-cat run|cost|plan` front end, the checker's own
tests, and any tool surface that hands a diagnosis back for self-correction —
and a message is only identical across three call sites if it is built once. -/
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

/-- The diagnosis, as the `Except String` the top-level front end returns. -/
def CheckError.render (e : CheckError) : String := toString e

/-! ## Prompts -/

/-- `[[Chunk]]` = one piece of a prompt: literal text, or the value of a name.

The interpolation `{x}` is a `Chunk` and not a general expression because the
language has no expressions: a prompt is a concatenation of things said and
things heard, and nothing else can appear in one. -/
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
one that mentions something is `Plan.ask`, which is `pipeline`. The syntax
therefore decides the rung of a node, and this function is where it does it. -/
def Prompt.closed : Prompt → Option String
  | [] => some ""
  | [.lit s] => some s
  | .lit s :: rest => (Prompt.closed rest).map (s ++ ·)
  | .interp _ :: _ => none

/-- `[[Prompt.normalize p]]` = `p` with empty literals dropped.

Applied by the parser after `define` expansion, where a macro that expands to
nothing would otherwise leave a chunk that says nothing.

**Adjacent literals are deliberately *not* fused.** Fusing them is the obvious
tidying and it is wrong here: `Prompt.expr` emits the concatenation of the
chunks *left-associated*, exactly as `a ++ b ++ c` parses in Lean, so a prompt
whose chunks are written the way an author would write the same string in Lean
elaborates to the very same `Expr` — which is what makes
`Dsl.denote_flagshipPlan` a `rfl` against `Agentic/Core/HardenPatch.lean`'s
hand-written prompts rather than a proof about `String.append_assoc`. Fusing
`"\n"` into the `verdictSpec` macro that follows it would reassociate one
append and cost that equation. -/
def Prompt.normalize : Prompt → Prompt
  | [] => []
  | .lit "" :: rest => Prompt.normalize rest
  | ch :: rest => ch :: Prompt.normalize rest

/-! ## The unchecked term language -/

/-- `[[RawTarget]]` = whom a question is put to and which draw it is: the part
of `Q.Shape` an author writes. The third field of a shape — the scope — is the
unit of the scope monoid at every node the syntax can write, and `@model` is the
only override, so it is not a field here. -/
structure RawTarget where
  /-- Who is asked. -/
  addressee : Addressee
  /-- Which independent draw this is; `0` unless deliberately resampling. -/
  draw : Nat
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawAsk]]` = one question, as written: an optional model override, the
kind of answer wanted, the addressee, and the words. -/
structure RawAsk where
  /-- The `@model "s"` prefix, if any. -/
  model : Option String
  /-- Which of the four answer kinds is wanted. -/
  code : Code
  /-- Whom to ask. -/
  target : RawTarget
  /-- What to say. -/
  prompt : Prompt
  /-- Where the construct begins, for diagnoses. -/
  pos : Pos
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawRhs]]` = what a name may be bound to, or what a `check` clause may
be: one question, or a panel of them. -/
inductive RawRhs where
  /-- A single question. -/
  | ask (a : RawAsk)
  /-- A panel: several questions, their answers combined in the monoid of the
  answer kind. Only `.verdict` carries one, which the checker enforces. -/
  | panel (members : List RawAsk) (pos : Pos)
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawBlock]]` = an unchecked block: some bindings, then a tail.

Every block ends in a tail — `done`, `act`, a branching or `revising` — which is
what makes every block a workflow returning unit rather than a workflow
returning an answer somebody has to do something with. -/
inductive RawBlock where
  /-- `let x = rhs` followed by the rest of the block. -/
  | bind (x : String) (rhs : RawRhs) (rest : RawBlock) (pos : Pos)
  /-- `done`: stop, having done nothing further. -/
  | done (pos : Pos)
  /-- `act tgt "…"`: the terminal act, an `.ack` question and nothing after
  it. -/
  | act (target : RawTarget) (prompt : Prompt) (pos : Pos)
  /-- `case x { yes -> {…} no -> {…} }`: the two values of `El .flag`. -/
  | caseFlag (x : String) (yes no : RawBlock) (pos : Pos)
  /-- `case x { approve -> {…} object -> {…} declined -> {…} }`: the three
  values of `VTag`, the finite classifier of a verdict. -/
  | caseVerdict (x : String) (approve object declined : RawBlock) (pos : Pos)
  /-- `revising a upto n check (p) {…} with (p, why) {…} accepted (p) {…}
  exhausted {…}`: bounded revision, whose four clauses are literally
  `Plan.revising`'s four arguments plus the two outcomes.

  `upto n` performs **n+1 checks and at most n revisions** — check first, revise
  in the recursive call — which is the reading `Plan.revising`'s docstring
  records three independent derivations getting backwards. -/
  | revising (subject : String) (upto : Nat)
      (checkBinder : String) (check : RawRhs)
      (artBinder : String) (whyBinder : String) (revise : RawRhs)
      (acceptedBinder : String) (accepted : RawBlock)
      (exhausted : RawBlock) (pos : Pos)
  deriving Repr, DecidableEq, Inhabited

/-- `[[Raw]]` = an unchecked text of a workflow: the body of `workflow { … }`,
with every `define` already expanded. -/
abbrev Raw : Type := RawBlock

/-- Where a right-hand side begins, for diagnoses. -/
def RawRhs.pos : RawRhs → Pos
  | .ask a => a.pos
  | .panel _ p => p

/-! ## The names of the answer kinds

Spelled once, so that the parser's keywords and the checker's diagnoses cannot
drift apart. -/

/-- `[[codeName c]]` = the keyword that writes the code `c`. -/
def codeName : Code → String
  | .text => "text"
  | .verdict => "verdict"
  | .flag => "flag"
  | .ack => "ack"

/-- …and the keyword parsed back, which is the section `codeName` splits. -/
def codeOfName : String → Option Code
  | "text" => some .text
  | "verdict" => some .verdict
  | "flag" => some .flag
  | "ack" => some .ack
  | _ => none

/-- **Morphism equation.** `codeOfName` is a retraction of `codeName`: every
answer kind is written by exactly one keyword and read back as itself, so the
two tables above are one table. -/
@[simp] theorem codeOfName_codeName (c : Code) : codeOfName (codeName c) = some c := by
  cases c <;> rfl

end Dsl

end Agentic.Core
