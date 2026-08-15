import Agentic.Core.Dsl.Parse
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
  no code for "settled-or-not", so `x <- revising …` does not extend the
  context: the checker carries the loop's plan as a pending obligation that
  the very next statement — `case x { settled p {…} unsettled {…} }` — must
  consume, and the pair elaborates to one `Plan.graft` whose continuation is
  the `caseB` the arms write. Any other statement while a result is pending is
  refused by name.

* **A closed prompt is a closed question.** A prompt that mentions no name has
  its words in the term, so the node emitted is `Plan.askC` and the plan starts
  at the `batch` rung; one that mentions a name is `Plan.ask`. Every hole that
  named a define was expanded by the parser into literal text, so a question is
  closed exactly when every hole it wrote named a define.

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

private def useKindR (x : String) : RawRhs → Option Code
  | .ask a => usePrompt x a.prompt
  | .panel ms _ => ms.findSome? (fun a => usePrompt x a.prompt)

private def useKindS (x : String) : RawSource → Option Code
  | .rhs r => useKindR x r
  | .revising subj carrier _ _ _ review amend _ =>
    firstOf (useKindR x review)
      (firstOf (useKindR x amend)
        (if subj == x then
          firstOf (useKindR carrier review) (useKindR carrier amend)
        else none))

/-- The first ground use of `x` in a block, in reading order. -/
private def useKindB (x : String) : RawBlock → Option Code
  | .empty _ => none
  | .knownHere _ rest _ => useKindB x rest
  | .act a rest _ => firstOf (usePrompt x a.prompt) (useKindB x rest)
  | .bind _ _ src rest _ => firstOf (useKindS x src) (useKindB x rest)
  | .ifFlag x' y n _ =>
    if x' == x then some Code.flag
    else firstOf (useKindB x y) (useKindB x n)
  | .caseVerdict x' a o d _ =>
    if x' == x then some Code.verdict
    else firstOf (useKindB x a) (firstOf (useKindB x o) (useKindB x d))
  | .caseResult _ _ settled unsettled _ =>
    firstOf (useKindB x settled) (useKindB x unsettled)

/-- The kind of a binding: its annotation, or its first ground use, or the
refusal that names the annotation. -/
private def bindKind (pos : Pos) (x : String) (ann : Option Code) (rest : RawBlock) :
    Except CheckError Code :=
  match ann with
  | some c => .ok c
  | none =>
    match useKindB x rest with
    | some c => .ok c
    | none =>
      .error ⟨pos, s!"nothing fixes what kind of answer `{x}` names: use it \
                     (a hole, an `if`, a `case`), or annotate it — \
                     `{x} : text <- …`", x⟩

/-! ## Elaborating questions at an imposed kind -/

/-- One question at the kind its position or its binder fixed: `Plan.askC1`
where the words are in the term, `Plan.ask1` where they are computed. -/
def askPlan {Γ : Ctx} (c : Code) (S : Bindings Γ) (a : RawAsk) :
    Except CheckError (Plan Γ (El c)) :=
  let s := askShape a.model c a.target
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

/-- A clause-position source at an imposed kind. A panel answers `verdict` and
nothing else — `all must approve` is the verdict monoid, and no other kind
carries one. -/
def rhsPlan {Γ : Ctx} (c : Code) (S : Bindings Γ) (r : RawRhs) (what : String) :
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

/-- A binding's former at an imposed kind: `x <- ask …` is **one** node —
`Plan.ask` is ask-and-bind — and a panel's value reaches the rest through
`Plan.graft`. -/
def bindForm {Γ : Ctx} (c : Code) (S : Bindings Γ) (r : RawRhs) :
    Except CheckError (Plan (c :: Γ) Unit → Plan Γ Unit) :=
  match r with
  | .ask a =>
    let s := askShape a.model c a.target
    match Prompt.closed a.prompt with
    | some words => .ok (fun k => Plan.askC c (s.withPrompt words) k)
    | none =>
      match Prompt.expr S a.pos a.prompt with
      | .error err => .error err
      | .ok e => .ok (fun k => Plan.ask c s e k)
  | .panel ms pos =>
    match rhsPlan c S (.panel ms pos) "this binding" with
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

/-- The two outcomes: `caseB` on whether the loop produced an artefact, with the
artefact reaching the `settled` arm as de Bruijn `0`. The `none` arm reads
`default`, which no run ever sees. -/
def finishCont {Γ : Ctx} {c : Code} (acc : Plan (c :: Γ) Unit) (exh : Plan Γ Unit) :
    Plan.Cont Γ (Option (El c)) Unit :=
  fun _ σ final =>
    Plan.caseB (fun δ => (final δ).isSome)
      (Plan.sub acc (fun δ => Env.cons ((final δ).getD default) (σ δ)))
      (Plan.sub exh σ)

/-! ## How far a bounded revision may be unrolled -/

/-- `[[maxRevisions]]` = the largest `n` an `at most n amendments` may name.
A resource limit and not a judgment, so it is refused with the same
`CheckError` as every other refusal. **Here and not in the parser**, because it
is the *elaboration* that unrolls: `Dsl.check` applied to a hand-built `Raw`
runs the same `Nat.rec` as one applied to parsed text. -/
def maxRevisions : Nat := 64

/-! ## The pending result of a bound loop -/

/-- `[[Pend Γ]]` = a bound loop whose settled-or-not result the next statement
must consume: the name it was bound to, the candidate's kind, and the loop's
plan. Not a `Binding` — `Ctx` has no code for an `Option` — which is exactly
why it is carried here instead. -/
structure Pend (Γ : Ctx) : Type 1 where
  /-- The name the loop was bound to. -/
  name : String
  /-- The candidate's kind. -/
  code : Code
  /-- The loop, as a plan of its settled-or-not result. -/
  plan : Plan Γ (Option (El code))

/-- The refusal every statement other than the consuming `case` gets while a
result is pending. -/
private def pendingErr (pos : Pos) (x : String) : CheckError :=
  ⟨pos, s!"the revising result `{x}` is not yet consumed: `case {x} \{ settled … \
          unsettled … }` is the next statement, and nothing else touches it", x⟩

/-! ## The checker -/

set_option maxHeartbeats 1000000 in
/-- `[[checkBlock Γ S pend b]]` = the plan `b` writes under the names `S`, with
`pend` the loop result the previous statement left to be consumed, or the
reason `b` writes none. -/
def checkBlock : (Γ : Ctx) → Bindings Γ → Option (Pend Γ) → RawBlock →
    Except CheckError (Plan Γ Unit)
  | _, _, none, .empty _ => .ok (.ret fun _ => ())
  | _, _, some pd, .empty pos => .error (pendingErr pos pd.name)
  | Γ, S, none, .knownHere names rest pos =>
    let live := S.map (·.name)
    if names == live then checkBlock Γ S none rest
    else
      .error ⟨pos, s!"`known here` asserts the names in scope, innermost first, \
                     and they are: {String.intercalate ", " live}",
              String.intercalate ", " names⟩
  | _, _, some pd, .knownHere _ _ pos => .error (pendingErr pos pd.name)
  | Γ, S, none, .act a rest _pos =>
    match bindForm Code.ack S (.ask a) with
    | .error err => .error err
    | .ok form =>
      match checkBlock Γ S none rest with
      | .error err => .error err
      | .ok k => .ok (form (Plan.sub k Sub.wk))
  | _, _, some pd, .act _ _ pos => .error (pendingErr pos pd.name)
  | _, _, some pd, .bind _ _ _ _ pos => .error (pendingErr pos pd.name)
  | Γ, S, none, .bind x ann (.rhs rhs) rest pos =>
    match freshName S pos x with
    | .error err => .error err
    | .ok _ =>
    -- A panel's kind is positional — it answers `verdict` or nothing — so
    -- inference runs only for a plain ask. A wrong annotation on a panel is
    -- refused by `bindForm`'s own panel diagnosis.
    match (match rhs with
           | .panel _ _ => .ok (ann.getD Code.verdict)
           | .ask _ => bindKind pos x ann rest : Except CheckError Code) with
    | .error err => .error err
    | .ok c =>
    match bindForm c S rhs with
    | .error err => .error err
    | .ok form =>
      match checkBlock (c :: Γ) (Bindings.push x c S) none rest with
      | .error err => .error err
      | .ok k => .ok (form k)
  | Γ, S, none, .bind x ann (.revising subj carrier n rname rann review amend rpos) rest pos =>
    -- Before anything is elaborated, because `n` is the depth of the
    -- elaboration itself and not merely the size of its result.
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
    match rhsPlan Code.verdict (Bindings.push carrier b.code S) review
        "the review of a bounded revision" with
    | .error err => .error err
    | .ok reviewP =>
    match rhsPlan b.code Swith amend "the `amend` of a bounded revision" with
    | .error err => .error err
    | .ok amendP =>
      checkBlock Γ S
        (some ⟨x, b.code,
          Plan.revising (checkCont reviewP) (reviseCont amendP) n Γ Sub.id b.val⟩)
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
    match checkBlock Γ S none y with
    | .error err => .error err
    | .ok y' =>
    match checkBlock Γ S none n with
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
    match checkBlock Γ S none a with
    | .error err => .error err
    | .ok a' =>
    match checkBlock Γ S none o with
    | .error err => .error err
    | .ok o' =>
    match checkBlock Γ S none d with
    | .error err => .error err
    | .ok d' =>
      .ok (Plan.caseV e (fun t => match t with
        | .approve => a' | .object => o' | .declined => d'))
  | _, _, some pd, .caseVerdict _ _ _ _ pos => .error (pendingErr pos pd.name)
  | Γ, S, some pd, .caseResult x sname settled unsettled pos =>
    if x != pd.name then
      .error ⟨pos, s!"the pending revising result is `{pd.name}`, and it is \
                     consumed first", x⟩
    else
    match freshName S pos sname with
    | .error err => .error err
    | .ok _ =>
    match checkBlock (pd.code :: Γ) (Bindings.push sname pd.code S) none settled with
    | .error err => .error err
    | .ok settledP =>
    match checkBlock Γ S none unsettled with
    | .error err => .error err
    | .ok unsettledP =>
      .ok (Plan.graft pd.plan (finishCont settledP unsettledP))
  | _, _, none, .caseResult x _ _ _ pos =>
    .error ⟨pos, s!"`case {x} \{ settled … }` consumes a revising result, and \
                   `{x}` is not one: it is bound by `{x} <- revising …` as the \
                   statement before its `case`", x⟩

/-- `[[check Γ S r]]` = the workflow `r` writes, or the reason it writes none.

**This type is the type-soundness theorem.** A checker returning
`Except CheckError (Plan Γ Unit)` cannot return an ill-typed plan, because an
ill-typed plan is not an inhabitant of `Plan Γ Unit`. -/
def check (Γ : Ctx) (S : Bindings Γ) (r : Raw) : Except CheckError (Plan Γ Unit) :=
  checkBlock Γ S none r

/-- `[[parseAndCheckE s]]` = the closed workflow `s` denotes, or the reason it
denotes none, with a position and an excerpt. -/
def parseAndCheckE (s : String) : Except CheckError (Plan [] Unit) :=
  match parse s with
  | .error e => .error e
  | .ok r => check [] [] r

/-- `[[parseAndCheck s]]` = the closed workflow `s` denotes, or the reason it
denotes none. -/
def parseAndCheck (s : String) : Except String (Plan [] Unit) :=
  match parseAndCheckE s with
  | .ok p => .ok p
  | .error e => .error e.render

/-- The two spellings agree: the `String` front end is the structured one with
its diagnosis rendered, and nothing is decided twice. -/
theorem parseAndCheck_ok_iff (s : String) (p : Plan [] Unit) :
    parseAndCheck s = .ok p ↔ parseAndCheckE s = .ok p := by
  unfold parseAndCheck
  cases h : parseAndCheckE s with
  | ok q => simp
  | error e => simp

end Agentic.Core.Dsl
