import Agentic.Core.Dsl.Syntax
import Agentic.Core.Level

/-!
# The checker: raw syntax to a plan that is well-typed by construction

Stage 3, part three, and the module the language is *for*.

```lean
check : (Γ : Ctx) → Bindings Γ → Raw → Except CheckError (Plan Γ Unit)
```

**The type is the soundness statement.** There is no ill-typed output to
validate after the fact and no second pass that could disagree with the first:
on success the checker hands back an inhabitant of `Plan Γ Unit`, which is the
intrinsically-typed syntax of `Agentic/Core/Plan.lean`, so "the program
type-checks" and "the program exists" are one proposition.

Four points where the elaboration is a decision rather than a transcription.

* **A name is a de Bruijn index, computed by the plumbing rather than by hand.**
  `Bindings Γ` maps a source name to a `Code` and an `Expr Γ (El code)`. A
  binding extends it with `Expr.var .here` in `c :: Γ` and weakens everything
  already there along `Sub.wk`, so the resolved variable *is* the de Bruijn
  index and the shifting is `Sub`'s. The one entry carrying a different `Expr`
  is a loop's review binding, presented at `Code.verdict` and rendered only
  where a `{v}` hole asks for it as text.

* **The kind of a binding is inferred from its first ground use.** The language
  restricts consumption to holes and branchings, so the walk is short and
  deterministic: a `{x}` hole says `text` (a verdict binding is grounded
  positionally, never by a hole),
  `if x` says `flag`, a verdict `case` says `verdict`, a panel or a review
  position says `verdict`, and a `revising` subject shares its carrier's kind.
  A later use that disagrees is refused by the ordinary kind-mismatch
  diagnoses, so "the first use fixes the kind" is a reading order, not a
  loophole; a bound name with *no* ground use is refused with the annotation
  named, because a question's kind is an observable of the question and must
  come from somewhere.

* **A bound loop's result is *pending*, not in scope.** `Ctx = List Code` has
  no code for a candidate-and-ending pair, so `x <- revising …` does not extend
  the context: the checker carries the loop's plan as a pending obligation that
  the very next statement — `case x { settled p {…} unsettled q {…} }` — must
  consume, and the pair elaborates to one `Plan.graft` whose continuation is
  the `case` the arms write. The pend carries its exit **tag**, which is what
  pairs a `revising` with `caseResult` and a `revising on` with `caseEnding`;
  the mismatches and every other statement while a result is pending are refused
  by name.

* **A closed prompt is a closed question.** A prompt that mentions no name has
  its words in the term, so the node emitted is `Plan.askC` and the plan starts
  at the `batch` rung; one that mentions a name is `Plan.ask`. Every hole that
  named a define is expanded into literal text before `Raw` is built, so a
  question is closed exactly when every hole it wrote named a define.

No clause emits `Plan.dyn`. That is not an accident of this implementation but
the point of the language, and `Agentic/Core/Dsl.lean` proves it.
-/

namespace Agentic.Core.Dsl

open Agentic.Core

/-! ## The naming environment -/

/-- `[[Binding Γ]]` = what one source name means: the kind of answer it stands
for, and how to read that answer out of a `Γ`-environment. -/
structure Binding (Γ : Ctx) where
  /-- The name, as written. -/
  name : String
  /-- The kind of answer it stands for. -/
  code : Code
  /-- How to read it: a pure function of what is known. -/
  val : Expr Γ (El code)

/-- `[[Bindings Γ]]` = the names in scope, innermost first. -/
abbrev Bindings (Γ : Ctx) : Type := List (Binding Γ)

/-- `[[b.at? c]]` = `b`'s value where `b` answers a `c`, and `none` where it
answers something else. The one place a code is compared, so the one place a
construct can be told that it was handed the wrong kind of answer. -/
def Binding.at? {Γ : Ctx} (b : Binding Γ) (c : Code) : Option (Expr Γ (El c)) :=
  if h : b.code = c then some (h ▸ b.val) else none

/-- `[[Bindings.rename σ S]]` = the names of `S`, read in a bigger context. -/
def Bindings.rename {Γ Δ : Ctx} (σ : Sub Γ Δ) (S : Bindings Γ) : Bindings Δ :=
  List.map (fun b => (⟨b.name, b.code, fun δ => b.val (σ δ)⟩ : Binding Δ)) S

/-- Innermost-first lookup. -/
def Bindings.find? {Γ : Ctx} (S : Bindings Γ) (x : String) : Option (Binding Γ) :=
  List.find? (fun b => b.name == x) S

/-- Extend the names with one bound by an `ask`: de Bruijn index `0` for the new
one, everything else shifted out by one. -/
def Bindings.push {Γ : Ctx} (x : String) (c : Code) (S : Bindings Γ) : Bindings (c :: Γ) :=
  ⟨x, c, Expr.var .here⟩ :: S.rename Sub.wk

/-! ## Diagnoses -/

private def unbound (pos : Pos) (x : String) : CheckError :=
  ⟨pos, "unbound name; nothing in scope answers to it", x⟩

private def lookupBinding {Γ : Ctx} (S : Bindings Γ) (pos : Pos) (x : String) :
    Except CheckError (Binding Γ) :=
  match Bindings.find? S x with
  | some b => .ok b
  | none => .error (unbound pos x)

/-- **No shadowing.** A live name may not be introduced again; a name whose
scope has ended may be. The refusal names the collision, so an author who meant
a new value knows which of the two spellings must move. -/
private def freshName {Γ : Ctx} (S : Bindings Γ) (pos : Pos) (x : String) :
    Except CheckError Unit :=
  match Bindings.find? S x with
  | some _ => .error ⟨pos, "this name is already in scope, and a live name is \
                           not introduced twice; rename one of the two", x⟩
  | none => .ok ()

/-! ## Prompts -/

/-- One chunk, as an expression. A hole splices an answer *as text*, and each
kind has at most one way to be text: a text answer is itself, and a verdict is
its objections joined by `"; "` (`Verdict.render` — approval and no-answer
splice as nothing, having nothing to say). A flag and a receipt have no
canonical text, so they are refused: a language that silently picked `"yes"`
would be a language whose prompts are not determined by their source. -/
private def chunkExpr {Γ : Ctx} (S : Bindings Γ) (pos : Pos) :
    Chunk → Except CheckError (Expr Γ String)
  | .lit s => .ok (fun _ => s)
  | .interp nm =>
    match lookupBinding S pos nm with
    | .error err => .error err
    | .ok b =>
      match b.at? .text with
      | some e => .ok e
      | none =>
        match b.at? .verdict with
        | some e => .ok (fun δ => Verdict.render (e δ))
        | none =>
          .error ⟨pos, s!"only a text or a verdict answer interpolates into a \
                         prompt — a verdict splices as its objections — but \
                         `{nm}` answers `{codeName b.code}`, which has no text \
                         of its own", nm⟩

/-- The chunks after the first, appended to what is already built.
**Left-associated, and that is the decision** — see `Prompt.normalize`'s
docstring for what it buys. -/
private def Prompt.exprFrom {Γ : Ctx} (S : Bindings Γ) (pos : Pos) (acc : Expr Γ String) :
    Prompt → Except CheckError (Expr Γ String)
  | [] => .ok acc
  | ch :: rest =>
    match chunkExpr S pos ch with
    | .error err => .error err
    | .ok e => Prompt.exprFrom S pos (fun δ => acc δ ++ e δ) rest

/-- `[[Prompt.expr S p]]` = the words `p` writes, as a pure function of what is
known. -/
def Prompt.expr {Γ : Ctx} (S : Bindings Γ) (pos : Pos) :
    Prompt → Except CheckError (Expr Γ String)
  | [] => .ok (fun _ => "")
  | ch :: rest =>
    match chunkExpr S pos ch with
    | .error err => .error err
    | .ok e => Prompt.exprFrom S pos e rest

/-! ## Questions -/

/-- The shape a target writes: the addressee and the draw as given, the scope at
the unit of the scope monoid, and the `served by` override — if there is one —
applied to it. -/
def askShape (m : Option String) (c : Code) (t : RawTarget) : Q.Shape c :=
  -- Its argument is the *primary* alone: `RawAsk.model` is an `Option Served`
  -- and the call sites pass `a.model.map (·.primary)`. **The alternates are
  -- dropped here**, which is the formal statement that fail-over (D6) is not
  -- part of the meaning — nothing downstream of this function can see them.
  let s : Q.Shape c := { addressee := t.addressee, scope := 1, draw := t.draw }
  match m with
  | none => s
  | some mid => atModel mid c s

/-- **Morphism equation.** At a single question the scope fold *is* the shape's
relabelling: this is what licenses `served by` being elaborated by rewriting a
shape rather than by wrapping a term. -/
theorem under_ask1 (σ : Sig) {Γ : Ctx} (c : Code) (s : Q.Shape c) (e : Expr Γ String) :
    Plan.under σ (Plan.ask1 c s e) = Plan.ask1 c (σ c s) e := rfl

/-- …and the same at a closed question, where the relabelling acts on the whole
`Q` because the words are in the term too. -/
theorem under_askC1 (σ : Sig) {Γ : Ctx} (c : Code) (q : Q c) :
    Plan.under σ (Plan.askC1 (Γ := Γ) c q) = Plan.askC1 c (σ.onQ c q) := rfl

/-! ## Kind inference

The language has exactly two consumption sites — a hole in a prompt, and a
branching — so the kind of a binding is decided by scanning forward for the
first ground use. The scan is structural, first-match, and deliberately
ignorant of shadowing: a program that shadows is refused by `freshName` before
any inferred kind is acted on.

One share is followed: a `revising` subject has its carrier's kind, so the
subject's scan continues into the loop's clauses under the carrier's name. The
share from a loop's result to its `settled` binder is *not* followed — a
program whose kind is discoverable only through it writes one annotation, and
the refusal says where. -/

private def firstOf (a b : Option Code) : Option Code :=
  match a with
  | some c => some c
  | none => b

/-- The kind a prompt's holes assert about `x`. A hole splices text *or* a
verdict, so as a ground site it is read as `text` — a name whose only use is
being spliced is a text question. A verdict binding never depends on this:
panels, review bindings and `case` arms ground it positionally, and the
annotation is always there for the remaining case. -/
private def usePrompt (x : String) (p : Prompt) : Option Code :=
  p.findSome? fun ch =>
    match ch with
    | .lit _ => none
    | .interp nm => if nm == x then some Code.text else none

/-- The kind a call's arguments assert: a name passed at a parameter is
grounded at the parameter's kind — positional, like a panel member. -/
private def useArgs (sig : List (String × List (String × Code) × Code))
    (x : String) (fn : String) (args : List RawArg) : Option Code :=
  match sig.find? (fun q => q.1 == fn) with
  | none => none
  | some (_, ps, _) =>
    (args.zip ps).findSome? fun aq =>
      match aq.1 with
      | .name y _ => if y == x then some aq.2.2 else none
      | .lit p _ => usePrompt x p

private def useKindR (sig : List (String × List (String × Code) × Code))
    (x : String) : RawRhs → Option Code
  | .ask a => usePrompt x a.prompt
  | .panel ms _ => ms.findSome? (fun a => usePrompt x a.prompt)
  | .panelText ms _ => ms.findSome? (fun m => usePrompt x m.ask.prompt)
  -- A decider **grounds its subject's kind**: `y <- ask …` with no annotation
  -- followed by `f <- decide lastNonEmptyLineIs y […]` infers `y : text`, which
  -- is the ergonomic that makes the vocabulary pleasant to use.
  | .decide _ x' _ _ => if x' == x then some Code.text else none
  | .call f args _ => useArgs sig x f args

private def useKindS (sig : List (String × List (String × Code) × Code))
    (x : String) : RawSource → Option Code
  | .rhs r => useKindR sig x r
  | .revising subj carrier _ _ _ review amend _ =>
    firstOf (useKindR sig x review)
      (firstOf (useKindR sig x amend)
        (if subj == x then
          firstOf (useKindR sig carrier review) (useKindR sig carrier amend)
        else none))
  | .revisingOn subj carrier _ _ _ review amend _ =>
    firstOf (useKindR sig x review)
      (firstOf (useKindR sig x amend)
        (if subj == x then
          firstOf (useKindR sig carrier review) (useKindR sig carrier amend)
        else none))

/-- The first ground use of `x` in a block, in reading order. -/
private def useKindB (sig : List (String × List (String × Code) × Code))
    (x : String) : RawBlock → Option Code
  | .empty _ => none
  | .knownHere _ rest _ => useKindB sig x rest
  | .act a rest _ => firstOf (usePrompt x a.prompt) (useKindB sig x rest)
  | .callStmt f args rest _ =>
    firstOf (useArgs sig x f args) (useKindB sig x rest)
  | .bind _ _ src rest _ => firstOf (useKindS sig x src) (useKindB sig x rest)
  | .ifFlag x' y n _ =>
    if x' == x then some Code.flag
    else firstOf (useKindB sig x y) (useKindB sig x n)
  | .caseVerdict x' a o d _ =>
    if x' == x then some Code.verdict
    else firstOf (useKindB sig x a) (firstOf (useKindB sig x o) (useKindB sig x d))
  | .caseResult _ _ _ settled unsettled _ =>
    firstOf (useKindB sig x settled) (useKindB sig x unsettled)
  | .caseEnding _ _ _ _ settled unsettled abandoned _ =>
    firstOf (useKindB sig x settled)
      (firstOf (useKindB sig x unsettled) (useKindB sig x abandoned))

/-- The kind of a binding: its annotation, or its first ground use, or the
refusal that names the annotation. -/
private def bindKind (sig : List (String × List (String × Code) × Code))
    (pos : Pos) (x : String) (ann : Option Code) (rest : RawBlock) :
    Except CheckError Code :=
  match ann with
  | some c => .ok c
  | none =>
    match useKindB sig x rest with
    | some c => .ok c
    | none =>
      .error ⟨pos, s!"nothing fixes what kind of answer `{x}` names: use it \
                     (a hole, an `if`, a `case`), or annotate it — \
                     `{x} : text <- …`", x⟩

/-! ## The function table

A function is a named open plan over exactly its parameters: `Sub Γ Δ` is
definitionally an argument list of typed expressions, so a call is `Plan.sub`
and everything else is inherited (the β-law is `denote_sub`, a call's rung is
the function's by `level_sub`). The table is stratified — a call may name only
an earlier entry — which is what refuses recursion. -/

/-- The context of a parameter list, innermost-last: `p₁` is the outermost
binding, exactly as `Bindings.push` builds it. -/
def paramCtx (l : List Code) : Ctx := l.foldl (fun Γ c => c :: Γ) []

/-- One checked function: its parameters, its result, its plan — and the number
of questions its plan holds, pre-computed for the size guard. -/
structure FnEntry : Type where
  /-- The full (possibly dotted) name. -/
  name : String
  /-- The parameters, in source order. -/
  params : List (String × Code)
  /-- The declared result kind. -/
  result : Code
  /-- The body, checked once, over exactly the parameters. -/
  plan : Plan (paramCtx (params.map Prod.snd)) (El result)
  /-- How many questions the plan holds — the size the guard prices. -/
  asks : Nat

/-- The table, in stratified order. -/
abbrev Fns : Type := List FnEntry

/-- Look a call head up. -/
def Fns.find? (fns : Fns) (x : String) : Option FnEntry :=
  List.find? (fun f => f.name == x) fns

/-- The parameter kinds by name, for inference's positional grounding. -/
def fnSigsOf (fns : Fns) : List (String × List (String × Code) × Code) :=
  fns.map (fun f => (f.name, f.params, f.result))

/-! ## Elaborating questions at an imposed kind -/

/-- `served by` names the model that serves a **model** addressee. An authoring
surface may refuse the other spellings earlier; this is the refusal *every*
`Raw` meets, so the invariant belongs to the checker and not to any grammar. -/
def askGuard (a : RawAsk) : Except CheckError Unit :=
  match a.model, a.target.addressee with
  | some _, .model _ => .ok ()
  | some _, _ =>
    .error ⟨a.pos, "`served by` names the model that serves a model addressee; \
                   a tool or a person is not served by one", "served"⟩
  | none, _ => .ok ()

/-- One question at the kind its position or its binder fixed: `Plan.askC1`
where the words are in the term, `Plan.ask1` where they are computed. -/
def askPlan {Γ : Ctx} (c : Code) (S : Bindings Γ) (a : RawAsk) :
    Except CheckError (Plan Γ (El c)) :=
  match askGuard a with
  | .error err => .error err
  | .ok _ =>
  let s := askShape (a.model.map (·.primary)) c a.target
  match Prompt.closed a.prompt with
  | some words => .ok (Plan.askC1 c (s.withPrompt words))
  | none =>
    match Prompt.expr S a.pos a.prompt with
    | .error err => .error err
    | .ok e => .ok (Plan.ask1 c s e)

/-- The members of a panel, each at `.verdict` — the kind the rule's monoid
lives at. -/
def checkMembers {Γ : Ctx} (S : Bindings Γ) :
    List RawAsk → Except CheckError (List (Plan Γ (El .verdict)))
  | [] => .ok []
  | a :: as =>
    match askPlan Code.verdict S a with
    | .error err => .error err
    | .ok p =>
      match checkMembers S as with
      | .error err => .error err
      | .ok ps => .ok (p :: ps)

/-- The members of a text panel, each at `.text` — the kind the fence's monoid
lives at — with the label carried through, checked for validity, and checked
against the labels already seen.

**Duplicate labels are refused**, in the family of the empty-panel refusal: two
`<a>` blocks in one document make the names not a key, which defeats the whole
point of naming them. Both refusals are `CheckError`s and not `Guard`s — guards
are the program-budget family, and these are well-formedness. -/
def checkMembersText {Γ : Ctx} (S : Bindings Γ) (seen : List String) :
    List TextMember → Except CheckError (List (String × Plan Γ (El .text)))
  | [] => .ok []
  | m :: as =>
    if !validLabel m.name then
      .error ⟨m.ask.pos, s!"a text panel names each member's block, and a name begins \
                           with an ASCII letter and continues with letters, digits, \
                           `-`, `_` or `.`", m.name⟩
    else if seen.contains m.name then
      .error ⟨m.ask.pos, "two members of a text panel answer to one name, and the \
                         names of a fenced document are its key; rename one", m.name⟩
    else
      match askPlan Code.text S m.ask with
      | .error err => .error err
      | .ok p =>
        match checkMembersText S (m.name :: seen) as with
        | .error err => .error err
        | .ok ps => .ok ((m.name, p) :: ps)

/-- One argument, elaborated at the parameter's kind: a name reads its binding
(at exactly that kind — no silent rendering), and words fill a `text`
parameter. -/
def argExpr {Γ : Ctx} (S : Bindings Γ) (fname pname : String) (c : Code) :
    RawArg → Except CheckError (Expr Γ (El c))
  | .name x pos =>
    match lookupBinding S pos x with
    | .error err => .error err
    | .ok b =>
      match b.at? c with
      | some e => .ok e
      | none =>
        if b.code = Code.verdict && c = Code.text then
          .error ⟨pos, s!"`{fname}`'s parameter `{pname}` takes `text`, and \
                        `{x}` answers `verdict`; a hole is where a verdict \
                        becomes text — write the argument as words: \"\{{x}}\"", x⟩
        else
          .error ⟨pos, s!"`{fname}`'s parameter `{pname}` takes \
                        `{codeName c}`, but `{x}` answers `{codeName b.code}`", x⟩
  | .lit p pos =>
    match c with
    | .text => Prompt.expr S pos p
    | c =>
      .error ⟨pos, s!"words fill a `text` parameter, and `{fname}`'s parameter \
                    `{pname}` takes `{codeName c}`; pass a name that answers \
                    it", fname⟩

/-- The arguments, elaborated left to right into the context morphism a call
substitutes along: `Sub Γf Δ` is definitionally this argument list, so the
fold below *is* the calling convention. -/
def checkArgs {Δ : Ctx} (S : Bindings Δ) (fname : String) :
    (ps : List (String × Code)) → List RawArg → (acc : Ctx) → Sub acc Δ →
    Except CheckError (Sub ((ps.map Prod.snd).foldl (fun Γ c => c :: Γ) acc) Δ)
  | [], [], _, σ => .ok σ
  | (pn, c) :: ps, a :: as, acc, σ =>
    match argExpr S fname pn c a with
    | .error err => .error err
    | .ok e => checkArgs S fname ps as (c :: acc) (fun δ => Env.cons (e δ) (σ δ))
  | (_, _) :: _, [], _, _ =>
    .error ⟨⟨0, 0⟩, s!"`{fname}` is applied to too few arguments", fname⟩
  | [], _ :: _, _, _ =>
    .error ⟨⟨0, 0⟩, s!"`{fname}` is applied to too many arguments", fname⟩

/-- The arity refusals, held for every table and scope — and held *apart*: a
parameter with no argument is refused as too few, with exactly this
diagnosis… -/
theorem checkArgs_too_few {Δ : Ctx} (S : Bindings Δ) (fname pn : String)
    (c : Code) (ps : List (String × Code)) (acc : Ctx) (σ : Sub acc Δ) :
    checkArgs S fname ((pn, c) :: ps) [] acc σ
      = .error ⟨⟨0, 0⟩, s!"`{fname}` is applied to too few arguments", fname⟩ :=
  rfl

/-- …and an argument with no parameter as too many. -/
theorem checkArgs_too_many {Δ : Ctx} (S : Bindings Δ) (fname : String)
    (a : RawArg) (args : List RawArg) (acc : Ctx) (σ : Sub acc Δ) :
    checkArgs S fname [] (a :: args) acc σ
      = .error ⟨⟨0, 0⟩, s!"`{fname}` is applied to too many arguments", fname⟩ :=
  rfl

/-- A call, as the plan it substitutes to: the function's plan, read through
the argument list. -/
def callPlan {Δ : Ctx} (S : Bindings Δ) (fns : Fns) (f : String)
    (args : List RawArg) (pos : Pos) : Except CheckError (Σ c : Code, Plan Δ (El c)) :=
  match fns.find? f with
  | none =>
    .error ⟨pos, "no function answers to this name (functions are declared \
                 above their first use)", f⟩
  | some fe =>
    match checkArgs S f fe.params args [] (fun _ => Env.nil) with
    | .error err => .error err
    | .ok σ => .ok ⟨fe.result, Plan.sub fe.plan σ⟩

/-- A clause-position source at an imposed kind. A panel answers `verdict` and
nothing else — `all must approve` is the verdict monoid, and no other kind
carries one. A call answers its declared result. -/
def rhsPlan {Γ : Ctx} (fns : Fns) (c : Code) (S : Bindings Γ) (r : RawRhs) (what : String) :
    Except CheckError (Plan Γ (El c)) :=
  match r with
  | .ask a => askPlan c S a
  | .panel ms pos =>
    match ms with
    | [] => .error ⟨pos, "a panel needs at least one member", "panel"⟩
    | _ =>
      match c with
      | .verdict =>
        match checkMembers S ms with
        | .error err => .error err
        | .ok ps => .ok (Plan.panel ps)
      | c =>
        .error ⟨pos, s!"{what}: a panel combines its members in the verdict \
                       monoid, so it answers `verdict`, not `{codeName c}`", "panel"⟩
  | .panelText ms pos =>
    match ms with
    | [] => .error ⟨pos, "a text panel needs at least one member", "panelText"⟩
    | _ =>
      match c with
      | .text =>
        match checkMembersText S [] ms with
        | .error err => .error err
        | .ok ps => .ok (Plan.panelText ps)
      | c =>
        .error ⟨pos, s!"{what}: a text panel fences its members' answers into a \
                       document, so it answers `text`, not `{codeName c}`",
                "panelText"⟩
  | .decide d x ws pos =>
    -- Both degeneracies refused before anything is elaborated: an empty needle
    -- list is a test that is constantly false and an empty needle a test that
    -- is constantly true, with nothing in the source to show it.
    if ws.isEmpty then
      .error ⟨pos, "a decider needs at least one needle to test for", deciderName d⟩
    else if ws.any (fun w => w.isEmpty) then
      .error ⟨pos, "a decider needs its needles to say something, and the empty \
                   needle tests nothing", deciderName d⟩
    else
    match c with
    | .flag =>
      match lookupBinding S pos x with
      | .error err => .error err
      | .ok b =>
        match b.at? Code.text with
        | some e => .ok (.ret (fun γ => Decider.run d ws (e γ)))
        | none =>
          .error ⟨pos, s!"a decider reads `text`, and `{x}` answers \
                         `{codeName b.code}`", x⟩
    | c =>
      .error ⟨pos, s!"{what}: a decider answers `flag`, not `{codeName c}`",
              "decide"⟩
  | .call f args pos =>
    match callPlan S fns f args pos with
    | .error err => .error err
    | .ok ⟨rc, p⟩ =>
      if h : rc = c then .ok (h ▸ p)
      else
        .error ⟨pos, s!"{what}: `{f}` answers `{codeName rc}`, \
                       not `{codeName c}`", f⟩

/-- A binding's former at an imposed kind: `x <- ask …` is **one** node —
`Plan.ask` is ask-and-bind — and a panel's value reaches the rest through
`Plan.graft`. -/
def bindForm {A : Type} {Γ : Ctx} (fns : Fns) (c : Code) (S : Bindings Γ) (r : RawRhs) :
    Except CheckError (Plan (c :: Γ) A → Plan Γ A) :=
  match r with
  | .ask a =>
    match askGuard a with
    | .error err => .error err
    | .ok _ =>
    let s := askShape (a.model.map (·.primary)) c a.target
    match Prompt.closed a.prompt with
    | some words => .ok (fun k => Plan.askC c (s.withPrompt words) k)
    | none =>
      match Prompt.expr S a.pos a.prompt with
      | .error err => .error err
      | .ok e => .ok (fun k => Plan.ask c s e k)
  | .panel ms pos =>
    match rhsPlan fns c S (.panel ms pos) "this binding" with
    | .error err => .error err
    | .ok v => .ok (fun k =>
        Plan.graft v (fun _ σ e => Plan.sub k (fun δ => Env.cons (e δ) (σ δ))))
  | .panelText ms pos =>
    match rhsPlan fns c S (.panelText ms pos) "this binding" with
    | .error err => .error err
    | .ok v => .ok (fun k =>
        Plan.graft v (fun _ σ e => Plan.sub k (fun δ => Env.cons (e δ) (σ δ))))
  -- **A decider costs nothing in every fold — including `size`.** Its value is a
  -- `.ret`, and `Plan.graft_ret` says `graft (ret e) k = k _ Sub.id e`, so this
  -- form elaborates to `Plan.sub k (Env.cons (e δ) ∘ …)`: the continuation with
  -- the value substituted in, and **no node at all**. `Plan.sub` preserves
  -- `size`, `askNodes` and `level`, so the net effect of replacing an asked flag
  -- with a decider is one fewer question on every path, the same number of
  -- paths, and the same rung.
  | .decide d x ws pos =>
    match rhsPlan fns c S (.decide d x ws pos) "this binding" with
    | .error err => .error err
    | .ok v => .ok (fun k =>
        Plan.graft v (fun _ σ e => Plan.sub k (fun δ => Env.cons (e δ) (σ δ))))
  | .call f args pos =>
    match rhsPlan fns c S (.call f args pos) "this binding" with
    | .error err => .error err
    | .ok v => .ok (fun k =>
        Plan.graft v (fun _ σ e => Plan.sub k (fun δ => Env.cons (e δ) (σ δ))))

/-! ### The three continuations of a bounded revision

Each is a `Plan.Cont`, i.e. a family indexed by the context the leaf sits in,
and each is built from **one** plan checked in **one** context by the same move:
extend the context morphism by the value the continuation is handed. -/

/-- The review binding's source: the candidate under review is de Bruijn `0`. -/
def checkCont {Γ : Ctx} {c : Code} (chk : Plan (c :: Γ) (El .verdict)) :
    Plan.Cont Γ (El c) Verdict :=
  fun _ σ a => Plan.sub chk (fun δ => Env.cons (a δ) (σ δ))

/-- The `amend` clause: the review's verdict is de Bruijn `0` — bound under the
author's chosen name, *at* `Code.verdict`, rendered only where a `{v}`
hole asks — and the candidate is de Bruijn `1`. -/
def reviseCont {Γ : Ctx} {c : Code} (rev : Plan (.verdict :: c :: Γ) (El c)) :
    Plan.Cont Γ (El c × Verdict) (El c) :=
  fun _ σ av => Plan.sub rev (fun δ => Env.cons (av δ).2 (Env.cons (av δ).1 (σ δ)))

/-- The outcomes of a bounded revision, generalised over the exit tag: `case` on
the ending the loop reports, with **the candidate reaching every arm** as de
Bruijn `0`.

Written once and instantiated twice — at `.bool` for `revising`'s two endings
(D3) and at `.ending` for `revisingOn`'s three (D4) — because the two want the
same continuation at two different tags.

`finishCont acc exh` used to be here and is `exitCont .bool (fun b => cond b acc
exh)`; since `Plan.caseB e t f = .case .bool e (fun b => cond b t f)`, **the
emitted node, its tag and its arm order are literally unchanged**, and
`Tag.values .bool = [false, true]` keeps `arm 0` the unsettled arm and `arm 1`
the settled one, which is what keeps `Explain.planLines`' arm numbering fixed.
The one real difference: **both** arms are now `Plan (c :: Γ) Unit` and both are
substituted with the candidate, where the unsettled arm used to be
`Plan.sub exh σ` at `Γ` and the settled arm read a `default` no run ever saw. -/
def exitCont {Γ : Ctx} {c : Code} (t : Tag)
    (arms : t.El → Plan (c :: Γ) Unit) : Plan.Cont Γ (El c × t.El) Unit :=
  fun _ σ final =>
    Plan.case t (fun δ => (final δ).2)
      (fun x => Plan.sub (arms x) (fun δ => Env.cons (final δ).1 (σ δ)))

/-! ## How far a bounded revision may be unrolled -/

/-- `[[maxRevisions]]` = the largest `n` an `at most n amendments` may name.
A resource limit and not a judgment, so it is refused with the same
`CheckError` as every other refusal. **Here and not in an authoring surface**,
because it is the *elaboration* that unrolls: `Dsl.check` runs the same
`Nat.rec` on every `Raw`, however that `Raw` was built. -/
def maxRevisions : Nat := 64

/-! ## The pending result of a bound loop -/

/-- `[[Pend Γ]]` = a bound loop whose settled-or-not result the next statement
must consume: the name it was bound to, the candidate's kind, and the loop's
plan. Not a `Binding` — `Ctx` has no code for an `Option` — which is exactly
why it is carried here instead. -/
structure Pend (Γ : Ctx) : Type where
  /-- The name the loop was bound to. -/
  name : String
  /-- The candidate's kind. -/
  code : Code
  /-- Which exit tag the loop reports: `.bool` for a `revising` (settled or not)
  and `.ending` for a `revising on` (settled, unsettled or abandoned). It is
  what pairs a pend with the one block form that may consume it. -/
  tag : Tag
  /-- The loop, as a plan of its candidate and its ending. -/
  plan : Plan Γ (El code × tag.El)

/-- The refusal every statement other than the consuming `case` gets while a
result is pending. -/
private def pendingErr (pos : Pos) (x : String) : CheckError :=
  ⟨pos, s!"the revising result `{x}` is not yet consumed: `case {x} \{ settled … \
          unsettled … }` is the next statement, and nothing else touches it", x⟩

/-! ## The prologue a bounded revision's two forms share -/

/-- `[[LoopParts Γ]]` = everything a bounded revision's prologue produces.

`revising` and `revising on` differ only in **how the loop reads its verdict**,
which is a property of the loop and not of its clauses — so the bound pre-check,
the annotation refusals, the three `freshName`s, the subject lookup, the two
clause contexts and the two `rhsPlan`s are shared verbatim through this record
rather than transcribed into a second clause that could drift. -/
structure LoopParts (Γ : Ctx) : Type where
  /-- The candidate's kind: the subject's, which the carrier shares. -/
  code : Code
  /-- How to read the subject out of a `Γ`-environment. -/
  subject : Expr Γ (El code)
  /-- The review clause, checked with the candidate as de Bruijn `0` under the
  carrier's name. -/
  review : Plan (code :: Γ) (El Code.verdict)
  /-- The amend clause, checked with the verdict as de Bruijn `0` under the
  review binding's name and the candidate as `1`. -/
  amend : Plan (Code.verdict :: code :: Γ) (El code)

/-- The prologue, run once for either loop form. -/
def checkLoopParts (fns : Fns) {Γ : Ctx} (S : Bindings Γ)
    (x : String) (ann : Option Code) (subj carrier : String) (n : Nat)
    (rname : String) (rann : Option Code) (review amend : RawRhs)
    (rpos pos : Pos) : Except CheckError (LoopParts Γ) :=
  -- Before anything is elaborated, because `n` is the depth of the elaboration
  -- itself and not merely the size of its result.
  if maxRevisions < n then
    .error ⟨rpos, s!"a bounded revision is unrolled into the term it writes, \
                    so its bound may name at most {maxRevisions} amendments",
            s!"at most {n} amendments"⟩
  else
  match ann with
  | some _ =>
    .error ⟨pos, "a revising result is settled-or-not, which is not one of the \
                 four kinds; it takes no annotation and is consumed by its \
                 `case`", x⟩
  | none =>
  match (match rann with
         | none => .ok ()
         | some Code.verdict => .ok ()
         | some c =>
           .error ⟨rpos, s!"a review answers `verdict`, not `{codeName c}`: \
                          the loop settles when it approves", rname⟩ :
         Except CheckError Unit) with
  | .error err => .error err
  | .ok _ =>
  match freshName S pos x with
  | .error err => .error err
  | .ok _ =>
  match freshName S rpos carrier with
  | .error err => .error err
  | .ok _ =>
  match freshName S rpos rname with
  | .error err => .error err
  | .ok _ =>
  match lookupBinding S rpos subj with
  | .error err => .error err
  | .ok b =>
  -- The names each clause is handed. The review sees the candidate as de
  -- Bruijn `0` under the carrier's name; the amend sees the verdict as `0`
  -- under the review binding's name — at `Code.verdict`, rendered only where
  -- a hole asks for it as text — and the candidate as `1`.
  let Swith : Bindings (Code.verdict :: b.code :: Γ) :=
    ⟨carrier, b.code, fun δ => Env.head (Env.tail δ)⟩ ::
    ⟨rname, Code.verdict, fun δ => Env.head δ⟩ ::
    Bindings.rename Sub.wk (Bindings.rename Sub.wk S)
  match rhsPlan fns Code.verdict (Bindings.push carrier b.code S) review
      "the review of a bounded revision" with
  | .error err => .error err
  | .ok reviewP =>
  match rhsPlan fns b.code Swith amend "the `amend` of a bounded revision" with
  | .error err => .error err
  | .ok amendP => .ok ⟨b.code, b.val, reviewP, amendP⟩

/-! ## The checker -/

set_option maxHeartbeats 1000000 in
/-- `[[checkBlock fns Γ S pend b]]` = the plan `b` writes under the names `S`
and the function table `fns`, with `pend` the loop result the previous
statement left to be consumed, or the reason `b` writes none. -/
def checkBlock (fns : Fns) : (Γ : Ctx) → Bindings Γ → Option (Pend Γ) → RawBlock →
    Except CheckError (Plan Γ Unit)
  | _, _, none, .empty _ => .ok (.ret fun _ => ())
  | _, _, some pd, .empty pos => .error (pendingErr pos pd.name)
  | Γ, S, none, .knownHere names rest pos =>
    let live := S.map (·.name)
    if names == live then checkBlock fns Γ S none rest
    else
      .error ⟨pos, s!"`known here` asserts the names in scope, innermost first, \
                     and they are: {String.intercalate ", " live}",
              String.intercalate ", " names⟩
  | _, _, some pd, .knownHere _ _ pos => .error (pendingErr pos pd.name)
  | Γ, S, none, .act a rest _pos =>
    match bindForm fns Code.ack S (.ask a) with
    | .error err => .error err
    | .ok form =>
      match checkBlock fns Γ S none rest with
      | .error err => .error err
      | .ok k => .ok (form (Plan.sub k Sub.wk))
  | _, _, some pd, .act _ _ pos => .error (pendingErr pos pd.name)
  | _, _, some pd, .bind _ _ _ _ pos => .error (pendingErr pos pd.name)
  | _, _, some pd, .callStmt _ _ _ pos => .error (pendingErr pos pd.name)
  | Γ, S, none, .callStmt f args rest pos =>
    -- A statement call runs for its doing: only a `-> receipt` function has
    -- nothing to hand back, so only one may stand here.
    match callPlan S fns f args pos with
    | .error err => .error err
    | .ok ⟨rc, p⟩ =>
      match rc, p with
      | .ack, p =>
        match checkBlock fns Γ S none rest with
        | .error err => .error err
        | .ok k =>
          .ok (Plan.graft p (fun _ σ _ => Plan.sub k σ))
      | rc, _ =>
        .error ⟨pos, s!"`{f}` answers `{codeName rc}`, and its answer has \
                       nowhere to go: bind it, `x <- {f} …`", f⟩
  | Γ, S, none, .bind x ann (.rhs rhs) rest pos =>
    match freshName S pos x with
    | .error err => .error err
    | .ok _ =>
    -- A panel's or a call's kind is positional; inference runs only for a
    -- plain ask. A wrong annotation is refused by the positional diagnosis.
    match (match rhs with
           | .panel _ _ => .ok (ann.getD Code.verdict)
           -- Positional, never inferred: a text panel answers `text` and a
           -- decider answers `flag`, and a wrong annotation is refused by the
           -- positional diagnosis in `rhsPlan`.
           | .panelText _ _ => .ok (ann.getD Code.text)
           | .decide _ _ _ _ => .ok (ann.getD Code.flag)
           | .call f _ _ =>
             (match fns.find? f with
              | some fe =>
                if fe.result = Code.ack then
                  .error ⟨pos, s!"`{f}` answers `receipt`, which binds nothing \
                                that can be consumed; call it as a statement", f⟩
                else .ok (ann.getD fe.result)
              | none =>
                .error ⟨pos, "no function answers to this name (functions are \
                             declared above their first use)", f⟩)
           | .ask _ => bindKind (fnSigsOf fns) pos x ann rest : Except CheckError Code) with
    | .error err => .error err
    | .ok c =>
    match bindForm fns c S rhs with
    | .error err => .error err
    | .ok form =>
      match checkBlock fns (c :: Γ) (Bindings.push x c S) none rest with
      | .error err => .error err
      | .ok k => .ok (form k)
  | Γ, S, none, .bind x ann (.revising subj carrier n rname rann review amend rpos) rest pos =>
    match checkLoopParts fns S x ann subj carrier n rname rann review amend rpos pos with
    | .error err => .error err
    | .ok lp =>
      checkBlock fns Γ S
        (some ⟨x, lp.code, .bool,
          Plan.revising (checkCont lp.review) (reviseCont lp.amend) n Γ Sub.id lp.subject⟩)
        rest
  | Γ, S, none, .bind x ann (.revisingOn subj carrier n rname rann review amend rpos) rest pos =>
    match checkLoopParts fns S x ann subj carrier n rname rann review amend rpos pos with
    | .error err => .error err
    | .ok lp =>
      checkBlock fns Γ S
        (some ⟨x, lp.code, .ending,
          Plan.revisingOn (checkCont lp.review) (reviseCont lp.amend) n Γ Sub.id lp.subject⟩)
        rest
  | Γ, S, none, .ifFlag x y n pos =>
    match lookupBinding S pos x with
    | .error err => .error err
    | .ok bnd =>
    match bnd.at? .flag with
    | none =>
      .error ⟨pos, s!"an `if` branches on a flag, \
                     but `{x}` answers `{codeName bnd.code}`", x⟩
    | some e =>
    match checkBlock fns Γ S none y with
    | .error err => .error err
    | .ok y' =>
    match checkBlock fns Γ S none n with
    | .error err => .error err
    | .ok n' => .ok (Plan.caseB e y' n')
  | _, _, some pd, .ifFlag _ _ _ pos => .error (pendingErr pos pd.name)
  | Γ, S, none, .caseVerdict x a o d pos =>
    match lookupBinding S pos x with
    | .error err => .error err
    | .ok bnd =>
    match bnd.at? .verdict with
    | none =>
      .error ⟨pos, s!"the arms `approved`, `objected` and `no answer` branch on \
                     a `verdict`, but `{x}` answers `{codeName bnd.code}`", x⟩
    | some e =>
    match checkBlock fns Γ S none a with
    | .error err => .error err
    | .ok a' =>
    match checkBlock fns Γ S none o with
    | .error err => .error err
    | .ok o' =>
    match checkBlock fns Γ S none d with
    | .error err => .error err
    | .ok d' =>
      .ok (Plan.caseV e (fun t => match t with
        | .approve => a' | .object => o' | .declined => d'))
  | _, _, some pd, .caseVerdict _ _ _ _ pos => .error (pendingErr pos pd.name)
  | Γ, S, some pd, .caseResult x sname uname settled unsettled pos =>
    if x != pd.name then
      .error ⟨pos, s!"the pending revising result is `{pd.name}`, and it is \
                     consumed first", x⟩
    else
    match pd with
    | ⟨_, pc, .bool, pplan⟩ =>
      -- **The unsettled binder is checked for freshness against the enclosing
      -- scope**, on the same rule and with the same message as the settled one.
      -- That is what keeps kind inference sound: `useKindB` is structural,
      -- first-match and deliberately ignorant of shadowing precisely because
      -- `freshName` refuses shadowing before any inferred kind is acted on, and
      -- a binder without its check would open that hole in the unsettled arm.
      match freshName S pos sname with
      | .error err => .error err
      | .ok _ =>
      match freshName S pos uname with
      | .error err => .error err
      | .ok _ =>
      match checkBlock fns (pc :: Γ) (Bindings.push sname pc S) none settled with
      | .error err => .error err
      | .ok settledP =>
      match checkBlock fns (pc :: Γ) (Bindings.push uname pc S) none unsettled with
      | .error err => .error err
      | .ok unsettledP =>
        .ok (Plan.graft pplan (exitCont .bool (fun b => cond b settledP unsettledP)))
    | _ =>
      .error ⟨pos, s!"`{x}` is bound by `revising on …`, and that result has \
                     three endings: its `case` writes `settled`, `unsettled` \
                     and `abandoned`", x⟩
  | _, _, none, .caseResult x _ _ _ _ pos =>
    .error ⟨pos, s!"`case {x} \{ settled … }` consumes a revising result, and \
                   `{x}` is not one: it is bound by `{x} <- revising …` as the \
                   statement before its `case`", x⟩
  | Γ, S, some pd, .caseEnding x sname uname aname settled unsettled abandoned pos =>
    if x != pd.name then
      .error ⟨pos, s!"the pending revising result is `{pd.name}`, and it is \
                     consumed first", x⟩
    else
    match pd with
    | ⟨_, pc, .ending, pplan⟩ =>
      match freshName S pos sname with
      | .error err => .error err
      | .ok _ =>
      match freshName S pos uname with
      | .error err => .error err
      | .ok _ =>
      match freshName S pos aname with
      | .error err => .error err
      | .ok _ =>
      match checkBlock fns (pc :: Γ) (Bindings.push sname pc S) none settled with
      | .error err => .error err
      | .ok settledP =>
      match checkBlock fns (pc :: Γ) (Bindings.push uname pc S) none unsettled with
      | .error err => .error err
      | .ok unsettledP =>
      match checkBlock fns (pc :: Γ) (Bindings.push aname pc S) none abandoned with
      | .error err => .error err
      | .ok abandonedP =>
        .ok (Plan.graft pplan (exitCont .ending (fun e =>
          match e with
          | .settled => settledP
          | .unsettled => unsettledP
          | .abandoned => abandonedP)))
    | _ =>
      .error ⟨pos, s!"`{x}` is bound by `revising …`, and that result has two \
                     endings: its `case` writes `settled` and `unsettled`, and \
                     nothing is abandoned", x⟩
  | _, _, none, .caseEnding x _ _ _ _ _ _ pos =>
    .error ⟨pos, s!"`case {x} \{ settled … abandoned … }` consumes a `revising \
                   on` result, and `{x}` is not one: it is bound by \
                   `{x} <- revising on …` as the statement before its `case`", x⟩

/-- `[[check Γ S r]]` = the workflow `r` writes, or the reason it writes none.

**This type is the type-soundness theorem.** A checker returning
`Except CheckError (Plan Γ Unit)` cannot return an ill-typed plan, because an
ill-typed plan is not an inhabitant of `Plan Γ Unit`. -/
def check (Γ : Ctx) (S : Bindings Γ) (r : Raw) : Except CheckError (Plan Γ Unit) :=
  checkBlock [] Γ S none r

/-- **An empty panel is refused, with exactly this diagnosis** — for every
scope, annotation, continuation and pair of positions, at the entry point that
exists for every `Raw` (an authoring surface is expected to demand a member;
this is what happens when one does not). Stated here because `freshName` is
private. -/
theorem check_panel_nil {Γ : Ctx} (S : Bindings Γ) (x : String) (ann : Option Code)
    (rest : RawBlock) (ppos bpos : Pos) (hx : Bindings.find? S x = none) :
    check Γ S (.bind x ann (.rhs (.panel [] ppos)) rest bpos)
      = .error ⟨ppos, "a panel needs at least one member", "panel"⟩ := by
  unfold check checkBlock freshName
  rw [hx]
  rfl

/-- **An empty text panel is refused too**, on the same rule and in the same
family — `PanelEmpty` means "a fan with no members" whichever monoid it folds
into. Its own diagnosis, because the two answer different kinds and the
positional refusal that follows names one of them. -/
theorem check_panelText_nil {Γ : Ctx} (S : Bindings Γ) (x : String) (ann : Option Code)
    (rest : RawBlock) (ppos bpos : Pos) (hx : Bindings.find? S x = none) :
    check Γ S (.bind x ann (.rhs (.panelText [] ppos)) rest bpos)
      = .error ⟨ppos, "a text panel needs at least one member", "panelText"⟩ := by
  unfold check checkBlock freshName
  rw [hx]
  rfl

/-! ## Function bodies

A body is checked once, over exactly its parameters, and the entry's plan is
what every call substitutes into. The initial bindings are the parameters, so
"a body cannot see the caller" is the type, not a rule. -/

/-- The parameters, as the bindings a body starts from — the same left fold
`paramCtx` takes, so the two agree definitionally. -/
def paramBindings : (ps : List (String × Code)) → (acc : Ctx) → Bindings acc →
    Bindings ((ps.map Prod.snd).foldl (fun Γ c => c :: Γ) acc)
  | [], _, S => S
  | (pn, c) :: ps, acc, S => paramBindings ps (c :: acc) (Bindings.push pn c S)

/-- The first ground use of `x` in a body, in reading order. -/
private def useKindBody (sig : List (String × List (String × Code) × Code))
    (x : String) : List RawBodyStmt → Option Code
  | [] => none
  | .bind _ _ r _ :: rest => firstOf (useKindR sig x r) (useKindBody sig x rest)
  | .act a _ :: rest => firstOf (usePrompt x a.prompt) (useKindBody sig x rest)
  | .callS f args _ :: rest => firstOf (useArgs sig x f args) (useKindBody sig x rest)

/-- A body binding's kind: its annotation, its first ground use, the `answer`
that names it (grounded at the function's result), or the refusal. -/
private def bodyBindKind (sig : List (String × List (String × Code) × Code))
    (pos : Pos) (x : String) (ann : Option Code) (rest : List RawBodyStmt)
    (answer : Option String) (result : Code) : Except CheckError Code :=
  match ann with
  | some c => .ok c
  | none =>
    match firstOf (useKindBody sig x rest)
        (match answer with
         | some y => if y == x then some result else none
         | none => none) with
    | some c => .ok c
    | none =>
      .error ⟨pos, s!"nothing fixes what kind of answer `{x}` names: use it \
                     (a hole, an argument, the `answer`), or annotate it — \
                     `{x} : text <- …`", x⟩

/-- The body's statements, continuation-passed so the terminal sees the final
bindings. -/
def checkBody {k : Code} (fns : Fns) (answer : Option String) (result : Code) :
    (Γ : Ctx) → Bindings Γ → List RawBodyStmt →
    (fin : (Δ : Ctx) → Bindings Δ → Except CheckError (Plan Δ (El k))) →
    Except CheckError (Plan Γ (El k))
  | Γ, S, [], fin => fin Γ S
  | Γ, S, .bind x ann rhs pos :: rest, fin =>
    match freshName S pos x with
    | .error err => .error err
    | .ok _ =>
    match (match rhs with
           | .panel _ _ => .ok (ann.getD Code.verdict)
           -- Positional, never inferred: a text panel answers `text` and a
           -- decider answers `flag`, and a wrong annotation is refused by the
           -- positional diagnosis in `rhsPlan`.
           | .panelText _ _ => .ok (ann.getD Code.text)
           | .decide _ _ _ _ => .ok (ann.getD Code.flag)
           | .call f _ _ =>
             (match fns.find? f with
              | some fe =>
                if fe.result = Code.ack then
                  .error ⟨pos, s!"`{f}` answers `receipt`, which binds nothing \
                                that can be consumed; call it as a statement", f⟩
                else .ok (ann.getD fe.result)
              | none =>
                .error ⟨pos, "no function answers to this name (functions are \
                             declared above their first use)", f⟩)
           | .ask _ =>
             bodyBindKind (fnSigsOf fns) pos x ann rest answer result :
           Except CheckError Code) with
    | .error err => .error err
    | .ok c =>
    match bindForm fns c S rhs with
    | .error err => .error err
    | .ok form =>
      match checkBody fns answer result (c :: Γ) (Bindings.push x c S) rest fin with
      | .error err => .error err
      | .ok k' => .ok (form k')
  | Γ, S, .act a _ :: rest, fin =>
    match bindForm fns Code.ack S (.ask a) with
    | .error err => .error err
    | .ok form =>
      match checkBody fns answer result Γ S rest fin with
      | .error err => .error err
      | .ok k' => .ok (form (Plan.sub k' Sub.wk))
  | Γ, S, .callS f args pos :: rest, fin =>
    match callPlan S fns f args pos with
    | .error err => .error err
    | .ok ⟨rc, p⟩ =>
      match rc, p with
      | .ack, p =>
        match checkBody fns answer result Γ S rest fin with
        | .error err => .error err
        | .ok k' => .ok (Plan.graft p (fun _ σ _ => Plan.sub k' σ))
      | rc, _ =>
        .error ⟨pos, s!"`{f}` answers `{codeName rc}`, and its answer has \
                       nowhere to go: bind it, `x <- {f} …`", f⟩

/-- One function, checked into its entry. -/
def checkFn (fns : Fns) (f : RawFn) : Except CheckError FnEntry :=
  let Γ0 := paramCtx (f.params.map Prod.snd)
  let S0 : Bindings Γ0 := paramBindings f.params [] []
  match f.answer with
  | some x =>
    match checkBody (k := f.result) fns f.answer f.result Γ0 S0 f.body
        (fun _ SΔ =>
          match lookupBinding SΔ f.answerPos x with
          | .error err => .error err
          | .ok b =>
            match b.at? f.result with
            | some e => .ok (Plan.ret e)
            | none =>
              .error ⟨f.answerPos, s!"`answer {x}`: `{x}` answers \
                                     `{codeName b.code}`, but `{f.name}` \
                                     answers `{codeName f.result}`", x⟩) with
    | .error err => .error err
    | .ok p => .ok ⟨f.name, f.params, f.result, p, 0⟩
  | none =>
    match f.result with
    | .ack =>
      match checkBody (k := Code.ack) fns f.answer f.result Γ0 S0 f.body
          (fun _ _ => .ok (Plan.ret (fun _ => ()))) with
      | .error err => .error err
      | .ok p => .ok ⟨f.name, f.params, Code.ack, p, 0⟩
    | c =>
      .error ⟨f.answerPos, s!"a value function ends with `answer <name>`; \
                            `{f.name}` answers `{codeName c}`", f.name⟩

/-! ## The size of the elaboration

The term a program elaborates to is priced before it is built: a loop's tail
is replicated once per exit, and a call inlines its function's questions per
site, so the recurrence below is the elaborated term's question count, computed
over the raw syntax with the (already stratified) table. -/

/-- The largest number of questions an elaborated program may hold. A resource
limit, like `maxRevisions`, refused with an ordinary diagnosis. -/
def maxQuestions : Nat := 4096

/-- Questions in a clause-position source. -/
def rhsAsks (fns : Fns) : RawRhs → Nat
  | .ask _ => 1
  | .panel ms _ => ms.length
  | .panelText ms _ => ms.length
  -- A decider asks nothing: its value is a `.ret`, and `Plan.graft_ret` leaves
  -- no node at all.
  | .decide _ _ _ _ => 0
  | .call f _ _ =>
    match fns.find? f with
    | some fe => fe.asks
    | none => 0

/-- Questions in a body. -/
def bodyAsks (fns : Fns) : List RawBodyStmt → Nat
  | [] => 0
  | .bind _ _ r _ :: rest => rhsAsks fns r + bodyAsks fns rest
  | .act _ _ :: rest => 1 + bodyAsks fns rest
  | .callS f _ _ :: rest => rhsAsks fns (.call f [] ⟨0, 0⟩) + bodyAsks fns rest

/-- Questions in the elaborated term of a block — with the loop's tail counted
once per exit, which is what the graft builds. -/
def blockAsks (fns : Fns) : RawBlock → Nat
  | .empty _ => 0
  | .knownHere _ r _ => blockAsks fns r
  | .act _ r _ => 1 + blockAsks fns r
  | .callStmt f _ r _ => rhsAsks fns (.call f [] ⟨0, 0⟩) + blockAsks fns r
  | .bind _ _ (.rhs rhs) r _ => rhsAsks fns rhs + blockAsks fns r
  | .bind _ _ (.revising _ _ n _ _ rev am _) (.caseResult _ _ _ st un _) _ =>
    (n + 1) * rhsAsks fns rev + n * rhsAsks fns am
      + (n + 1) * (blockAsks fns st + blockAsks fns un)
  | .bind _ _ (.revising _ _ n _ _ rev am _) r _ =>
    (n + 1) * rhsAsks fns rev + n * rhsAsks fns am + blockAsks fns r
  -- The three-way loop's unroll has `2n+1` `ret` leaves — the approve-`ret` and
  -- the declined-`ret` per round above the base, plus the base's — and the exit
  -- is replicated once per leaf. The loop's own contribution is `revising`'s.
  | .bind _ _ (.revisingOn _ _ n _ _ rev am _) (.caseEnding _ _ _ _ st un ab _) _ =>
    (n + 1) * rhsAsks fns rev + n * rhsAsks fns am
      + (2 * n + 1) * (blockAsks fns st + blockAsks fns un + blockAsks fns ab)
  | .bind _ _ (.revisingOn _ _ n _ _ rev am _) r _ =>
    (n + 1) * rhsAsks fns rev + n * rhsAsks fns am + blockAsks fns r
  | .ifFlag _ y n _ => blockAsks fns y + blockAsks fns n
  | .caseVerdict _ a o d _ => blockAsks fns a + blockAsks fns o + blockAsks fns d
  | .caseResult _ _ _ st un _ => blockAsks fns st + blockAsks fns un
  | .caseEnding _ _ _ _ st un ab _ =>
    blockAsks fns st + blockAsks fns un + blockAsks fns ab

/-- The table, checked in order — each entry **priced before it is built**:
`bodyAsks` reads the raw body against the table so far, so an entry whose
inlining would exceed the bound is refused without elaborating a node of
it. -/
def checkFnsList (acc : Fns) : List RawFn → Except CheckError Fns
  | [] => .ok acc
  | f :: rest =>
    -- An authoring surface may refuse a duplicate name at the declaration; this
    -- is the refusal every table meets, because `Fns.find?` answers with the
    -- first match and a silent first-wins resolution is a wrong body running.
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

/-! ## The program front end -/

/-- The first revising bound over `maxRevisions`, in reading order — scanned
off the raw syntax so a hostile bound is refused *at its own line*, before the
question count at `⟨0,0⟩` would claim it as a mere size. The message is
byte-identical to `checkBlock`'s own refusal, which still stands behind it for
the hand-built entry points. -/
def overRevised : Raw → Option (Pos × Nat)
  | .empty _ => none
  | .knownHere _ r _ => overRevised r
  | .act _ r _ => overRevised r
  | .callStmt _ _ r _ => overRevised r
  | .bind _ _ (.rhs _) r _ => overRevised r
  | .bind _ _ (.revising _ _ n _ _ _ _ rpos) r _ =>
    if maxRevisions < n then some (rpos, n) else overRevised r
  | .bind _ _ (.revisingOn _ _ n _ _ _ _ rpos) r _ =>
    if maxRevisions < n then some (rpos, n) else overRevised r
  | .ifFlag _ y n _ => (overRevised y).orElse fun _ => overRevised n
  | .caseVerdict _ a o d _ =>
    ((overRevised a).orElse fun _ => overRevised o).orElse fun _ => overRevised d
  | .caseResult _ _ _ s u _ => (overRevised s).orElse fun _ => overRevised u
  | .caseEnding _ _ _ _ s u a _ =>
    ((overRevised s).orElse fun _ => overRevised u).orElse fun _ => overRevised a

/-- `[[checkProgram prog]]` = the plan the whole program writes: the functions
checked once, the elaboration sized — hostile loop bounds first, at their own
lines, then the question count — and the spliced block checked against the
table. -/
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

end Agentic.Core.Dsl
