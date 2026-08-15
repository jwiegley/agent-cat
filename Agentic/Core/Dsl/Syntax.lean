import Agentic.Core.Plan

/-!
# The raw syntax: the unchecked text of a workflow

Stage 3, part one. This module is the *first-order* half of the DSL: a term
language of names, strings and numbers that mentions no `Plan`, no `Env` and no
`Expr`, so that parsing is a total function into ordinary data and every
question of well-typedness is deferred to `Agentic/Core/Dsl/Check.lean`.

This is the **redesigned** surface (doc/research/dsl-redesign/GRAMMAR.md, obr
acat-k28): bindings are `name <- source` with the kind usually inferred;
branching is `if`/`else` on a flag and `case` on a verdict or on a bounded
revision's settled-or-not result; the loop is `revising s as c, at most n
amendments { v <- review-source  amend c { source } }`; a statement-position
`ask` is the act. Three shapes here are decisions rather than conveniences.

* **A branching is one constructor per tag type, and its arms are fields.**
  `Plan.case` demands a `FinEnum`, hence *total* arms, so each branching the
  surface writes — two-valued (`El .flag`), three-valued (`VTag`), and the
  two-valued settled-or-not of a loop result — is a constructor whose arms are
  ordinary recursive fields. A nested `List (String × RawBlock)` would force
  well-founded recursion on the checker, and `WellFounded.fix` does not reduce
  in the kernel, which the flagship theorems need it to.
* **A bound loop is a source, and its `case` is the next statement.** `Ctx =
  List Code`, so the `Option (El c)` a bounded revision produces cannot be a
  context entry; it is reached by `Plan.graft`, whose continuation is not a
  binder. The surface writes `x <- revising …` and then `case x { settled p
  {…} unsettled {…} }`, and the checker requires the `case` to be the very
  next statement, so the option value never needs a context slot: the pair
  elaborates to one graft whose continuation is the `caseB` the arms write.
* **The kind annotation is optional syntax, not optional information.** A
  binder may write `x : text <-`; when it does not, the checker infers the
  kind from the name's first ground use, and refuses a name with no use to
  infer from. The annotation is carried in the syntax so that the refusal can
  say exactly where one would go.

`define` does not appear below. It is textual and the parser expands it — a
`{$name}` hole is a define, a `{name}` hole is an answer — so a `Raw` mentions
only names a checker can be asked to resolve.
-/

namespace Agentic.Core

/-! ## Rendering a verdict as text

The one library function the DSL needs that the stack did not already have.
`Agentic/Core/HardenPatch.lean` has the same function under `Harden.render`;
`Agentic/Core/DslFlagship.lean` proves the two spellings are one function, by
`rfl`, so nothing here is a second convention. -/

namespace Verdict

/-- `[[render v]]` = a verdict as text an addressee can read: its objections,
separated by `"; "`, and nothing where it declined — a refusal has no objection
list to show.

This is what a `{v}` hole means at a verdict: a verdict has exactly one way to
be text — this one — so the hole elaborates to `render ∘ ·`, an
`Expr Γ String`, totally and canonically, with nothing for the author to
choose and therefore nothing for the surface to say. -/
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
things heard, and nothing else can appear in one. A `{$d}` define-hole never
reaches this type: the parser expands it, so a `Raw`'s prompts hold only
literals and answer-holes. -/
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
expansion every `{$d}` hole is a literal, so a question is closed exactly when
every hole it wrote was a define — which is readable at the question. -/
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
elaborates to the very same `Expr` — which is what keeps the flagship's
transcript agreements with `Agentic/Core/HardenPatch.lean` computations rather
than proofs about `String.append_assoc`. -/
def Prompt.normalize : Prompt → Prompt
  | [] => []
  | .lit "" :: rest => Prompt.normalize rest
  | ch :: rest => ch :: Prompt.normalize rest

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

/-- `[[RawAsk]]` = one question, as written: the addressee, an optional serving
model, and the words. The **kind is not a field**: it comes from the binder's
annotation or inference, from the position (a panel member and a review binding
answer `verdict`; a statement ask answers `receipt`), and the checker imposes
it. -/
structure RawAsk where
  /-- The `served by "s"` override, if any; legal only on a model addressee,
  which the parser enforces. -/
  model : Option String
  /-- Whom to ask. -/
  target : RawTarget
  /-- What to say. -/
  prompt : Prompt
  /-- Where the construct begins, for diagnoses. -/
  pos : Pos
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawRhs]]` = a clause-position source: one question, or a panel of them.
The loop is not here — a bounded revision's result is not a value a clause can
hold. -/
inductive RawRhs where
  /-- A single question. -/
  | ask (a : RawAsk)
  /-- `panel, all must approve [ … ]`: several questions, their answers combined
  in the verdict monoid — the one rule the menu currently has, named on the
  page. -/
  | panel (members : List RawAsk) (pos : Pos)
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
  deriving Repr, DecidableEq, Inhabited

/-- `[[RawBlock]]` = an unchecked block: statements, of which the branchings
are terminal — each arm *is* the rest of the workflow — and a statement-position
ask is the act, which may be followed. `stop` writes the block that does
nothing, and `{ }` is not writable. -/
inductive RawBlock where
  /-- `stop`, or a block whose statements ran out after an act. The position is
  where the nothing is written. -/
  | empty (pos : Pos)
  /-- `x <- source` or `x : kind <- source`, followed by the rest. When the
  source is a `revising`, the rest must begin with `case x { settled …
  unsettled … }`, which the checker enforces. -/
  | bind (x : String) (ann : Option Code) (src : RawSource) (rest : RawBlock) (pos : Pos)
  /-- A statement-position `ask`: the act. It binds nothing and asks for
  nothing back (`.ack`), and the block continues after it. -/
  | act (a : RawAsk) (rest : RawBlock) (pos : Pos)
  /-- `if x {…} else {…}`: the two values of `El .flag`, both arms written. -/
  | ifFlag (x : String) (yes no : RawBlock) (pos : Pos)
  /-- `case x { approved {…} objected {…} no answer {…} }`: the three values of
  `VTag`, the finite classifier of a verdict. -/
  | caseVerdict (x : String) (approved objected noAnswer : RawBlock) (pos : Pos)
  /-- `case x { settled p {…} unsettled {…} }`: the two outcomes of a bounded
  revision, with the settled artefact bound as `p`. Legal only immediately
  after `x <- revising …`, which the checker enforces. -/
  | caseResult (x : String) (settledName : String) (settled unsettled : RawBlock) (pos : Pos)
  /-- `known here: a, b, c` (or `known here: nothing`): a checker-verified
  assertion of exactly the names in scope, innermost first. Documentation that
  cannot rot. -/
  | knownHere (names : List String) (rest : RawBlock) (pos : Pos)
  deriving Repr, DecidableEq, Inhabited

/-- `[[Raw]]` = an unchecked text of a workflow: the body of `workflow { … }`,
with every `define` already expanded. -/
abbrev Raw : Type := RawBlock

/-- Where a right-hand side begins, for diagnoses. -/
def RawRhs.pos : RawRhs → Pos
  | .ask a => a.pos
  | .panel _ p => p

/-- Where a source begins, for diagnoses. -/
def RawSource.pos : RawSource → Pos
  | .rhs r => r.pos
  | .revising _ _ _ _ _ _ _ p => p

/-! ## The names of the answer kinds

Spelled once, so that the parser's keywords and the checker's diagnoses cannot
drift apart. -/

/-- `[[codeName c]]` = the keyword that writes the code `c`. -/
def codeName : Code → String
  | .text => "text"
  | .verdict => "verdict"
  | .flag => "flag"
  | .ack => "receipt"

/-- …and the keyword parsed back, which is the section `codeName` splits. -/
def codeOfName : String → Option Code
  | "text" => some .text
  | "verdict" => some .verdict
  | "flag" => some .flag
  | "receipt" => some .ack
  | _ => none

/-- **Morphism equation.** `codeOfName` is a retraction of `codeName`: every
answer kind is written by exactly one keyword and read back as itself, so the
two tables above are one table. (`.ack` is *written* `receipt`, because what an
act hands back is a receipt and carries no information.) -/
@[simp] theorem codeOfName_codeName (c : Code) : codeOfName (codeName c) = some c := by
  cases c <;> rfl

end Dsl

end Agentic.Core
