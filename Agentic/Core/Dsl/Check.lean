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
type-checks" and "the program exists" are one proposition. Everything the
judgment of the design says — that a name is in scope, that it answers the kind
the construct wants, that a panel's members share a monoid, that a branching is
total — is discharged *before* a term is built, because there is no term to
build otherwise. `Agentic/Core/Dsl.lean` says what that does and does not buy.

Three points where the elaboration is a decision rather than a transcription.

* **A name is a de Bruijn index, computed by the plumbing rather than by hand.**
  `Bindings Γ` maps a source name to a `Code` and an `Expr Γ (El code)`. A
  `let` bound by an `ask` extends it with `Expr.var .here` in `c :: Γ` and
  weakens everything already there along `Sub.wk`, so the resolved variable
  *is* the de Bruijn index and the shifting is `Sub`'s. The three binders that
  are **not** context entries — `accepted (p)`, whose value is an
  `Option (El c)` and so cannot be one (`Ctx = List Code`), and `with (p, why)`,
  whose `why` is a rendered verdict — are entries of the same table carrying a
  different `Expr`. One table, no escape hatch.

* **`@model` rewrites a shape; it does not wrap a term.** `Plan.under σ` is a
  fold over a whole plan, so wrapping the continuation of a `let` in it would
  put the scope on every later question. At a single question the fold is the
  shape's relabelling and nothing else — `under_ask1` below, which is `rfl` —
  so that is what is emitted, and the equation says the two agree.

* **A closed prompt is a closed question.** A prompt that mentions no name has
  its words in the term, so the node emitted is `Plan.askC` and the plan starts
  at the `batch` rung; one that mentions a name is `Plan.ask`. The syntax
  therefore decides the rung, which is what makes `level` a fact about the
  source text.

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

/-- `[[Bindings.rename σ S]]` = the names of `S`, read in a bigger context.
This is the weakening every binder performs, and it is `Sub`'s: a context
morphism is a function on environments, so renaming a table of names is
precomposition. -/
def Bindings.rename {Γ Δ : Ctx} (σ : Sub Γ Δ) (S : Bindings Γ) : Bindings Δ :=
  List.map (fun b => (⟨b.name, b.code, fun δ => b.val (σ δ)⟩ : Binding Δ)) S

/-- Innermost-first lookup, so a `let` shadows an outer name of the same
spelling. -/
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

/-! ## Prompts -/

/-- One chunk, as an expression. Interpolation is defined **only** over
text-typed names: `El .text = String` and nothing else embeds in a string
without a choice of renderer, and a language that silently picked one would be a
language whose prompts are not determined by their source. The one construct
that appears to break the rule — `with (patch, why)` — does not: `why` is bound
to `Verdict.render ∘ ·`, so the renderer is written where the binder is. -/
private def chunkExpr {Γ : Ctx} (S : Bindings Γ) (pos : Pos) :
    Chunk → Except CheckError (Expr Γ String)
  | .lit s => .ok (fun _ => s)
  | .interp x =>
    match lookupBinding S pos x with
    | .error err => .error err
    | .ok b =>
    match b.at? .text with
    | some e => .ok e
    | none =>
      .error ⟨pos, s!"only a text answer interpolates into a prompt, \
                     but `{x}` answers `{codeName b.code}`", x⟩

/-- The chunks after the first, appended to what is already built.

**Left-associated, and that is the decision.** `a ++ b ++ c` parses in Lean as
`(a ++ b) ++ c`, so a prompt written in the DSL with the same chunk boundaries
an author would write in Lean elaborates to a syntactically identical `Expr`.
Right-associating instead is equally correct and equally readable, and it costs
`String.append_assoc` under a `funext` under `Dlg.ask`'s continuation at every
theorem that compares an elaborated prompt with a hand-written one. -/
private def Prompt.exprFrom {Γ : Ctx} (S : Bindings Γ) (pos : Pos) (acc : Expr Γ String) :
    Prompt → Except CheckError (Expr Γ String)
  | [] => .ok acc
  | ch :: rest =>
    match chunkExpr S pos ch with
    | .error err => .error err
    | .ok e => Prompt.exprFrom S pos (fun δ => acc δ ++ e δ) rest

/-- `[[Prompt.expr S p]]` = the words `p` writes, as a pure function of what is
known: literals are constants, interpolations are the variables they name, and
the whole is their concatenation in source order, left-associated. A prompt of
one chunk is that chunk, with no unit appended to it. -/
def Prompt.expr {Γ : Ctx} (S : Bindings Γ) (pos : Pos) :
    Prompt → Except CheckError (Expr Γ String)
  | [] => .ok (fun _ => "")
  | ch :: rest =>
    match chunkExpr S pos ch with
    | .error err => .error err
    | .ok e => Prompt.exprFrom S pos e rest

/-! ## Questions -/

/-- The shape a target writes: the addressee and the draw as given, the scope at
the unit of the scope monoid, and the `@model` override — if there is one —
applied to it. `atModel` appends on the *left*, where the non-commutative
`LastOpt` lets an inner setting have the last word. -/
def askShape (m : Option String) (c : Code) (t : RawTarget) : Q.Shape c :=
  let s : Q.Shape c := { addressee := t.addressee, scope := 1, draw := t.draw }
  match m with
  | none => s
  | some mid => atModel mid c s

/-- **Morphism equation.** At a single question the scope fold *is* the shape's
relabelling: `Plan.under σ (Plan.ask1 c s e) = Plan.ask1 c (σ c s) e`. This is
the equation that licenses `@model` being elaborated by rewriting a shape rather
than by wrapping a term — wrapping would have put the scope on the whole rest of
the block, which is a different workflow. -/
theorem under_ask1 (σ : Sig) {Γ : Ctx} (c : Code) (s : Q.Shape c) (e : Expr Γ String) :
    Plan.under σ (Plan.ask1 c s e) = Plan.ask1 c (σ c s) e := rfl

/-- …and the same at a closed question — the case `checkBinder` and `checkAsk`
actually take for the flagship's `guide` and `draft` nodes, where the relabelling
acts on the whole `Q` because the words are in the term too. -/
theorem under_askC1 (σ : Sig) {Γ : Ctx} (c : Code) (q : Q c) :
    Plan.under σ (Plan.askC1 (Γ := Γ) c q) = Plan.askC1 c (σ.onQ c q) := rfl

/-! ## Elaborating the constructs -/

/-- `[[Checked Γ]]` = a plan together with the kind of answer it produces. The
dependent pair the judgment `Γ; Σ ⊢ a ⇝ Plan Γ (El c)` writes: the code is
recovered from the syntax and the plan's type mentions it, so a construct that
wants a particular kind asks for it in a `match` and nowhere else. -/
structure Checked (Γ : Ctx) : Type 1 where
  /-- The kind of answer. -/
  code : Code
  /-- The plan that produces it. -/
  plan : Plan Γ (El code)

/-- `[[Binder Γ]]` = a `let`'s right-hand side, elaborated: the kind of answer
it binds, and the term former awaiting the rest of the block.

A former rather than a plan, because `let x = ask …` is **one** node —
`Plan.ask` is ask-and-bind — and reconstructing it from a plan and a graft would
put a `sub` between the question and its continuation for no reason. -/
structure Binder (Γ : Ctx) : Type 1 where
  /-- The kind of answer bound. -/
  code : Code
  /-- The rest of the block, plugged in. -/
  form : Plan (code :: Γ) Unit → Plan Γ Unit

/-- One question, as a plan of its own: `Plan.askC1` where the words are in the
term, `Plan.ask1` where they are computed. Used for panel members and for the
`with` clause, whose results are values rather than binders. -/
def checkAsk {Γ : Ctx} (S : Bindings Γ) (a : RawAsk) : Except CheckError (Checked Γ) :=
  let s := askShape a.model a.code a.target
  match Prompt.closed a.prompt with
  | some words => .ok ⟨a.code, Plan.askC1 a.code (s.withPrompt words)⟩
  | none =>
    match Prompt.expr S a.pos a.prompt with
    | .error err => .error err
    | .ok e => .ok ⟨a.code, Plan.ask1 a.code s e⟩

/-- The same, required to answer a particular kind. -/
def checkAskAt {Γ : Ctx} (c : Code) (S : Bindings Γ) (a : RawAsk) (what : String) :
    Except CheckError (Plan Γ (El c)) :=
  match checkAsk S a with
  | .error err => .error err
  | .ok r =>
    if h : r.code = c then .ok (h ▸ r.plan)
    else .error ⟨a.pos, s!"{what}: expected an answer of kind `{codeName c}`, \
                          but this question asks for `{codeName r.code}`", codeName r.code⟩

/-- The members of a panel, each required to be at the kind the first one
chose. -/
def checkMembers {Γ : Ctx} (c : Code) (S : Bindings Γ) :
    List RawAsk → Except CheckError (List (Plan Γ (El c)))
  | [] => .ok []
  | a :: as =>
    match checkAskAt c S a "the members of a panel must agree in answer kind, and this one \
                            disagrees with the first" with
    | .error err => .error err
    | .ok p =>
      match checkMembers c S as with
      | .error err => .error err
      | .ok ps => .ok (p :: ps)

/-- A right-hand side, as a plan: one question, or a panel.

A panel reduces its members in the monoid of the answer kind, and the answer
universe declares one only at `.verdict` — deliberately, since nothing installs
arithmetic on `El .flag = Bool`. So a panel of anything else is rejected here,
naming the kind it was given. -/
def checkRhs {Γ : Ctx} (S : Bindings Γ) : RawRhs → Except CheckError (Checked Γ)
  | .ask a => checkAsk S a
  | .panel ms pos =>
    match ms with
    | [] => .error ⟨pos, "a panel needs at least one member", "panel"⟩
    | m :: rest =>
      if m.code = Code.verdict then
        match checkMembers Code.verdict S (m :: rest) with
        | .error err => .error err
        | .ok ps => .ok ⟨Code.verdict, Plan.panel ps⟩
      else
        .error ⟨pos, s!"a panel combines its members' answers in the monoid of their kind, \
                       and only `verdict` carries one; these answer \
                       `{codeName m.code}`", "panel"⟩

/-- A right-hand side required to answer a particular kind. -/
def checkRhsAt {Γ : Ctx} (c : Code) (S : Bindings Γ) (r : RawRhs) (what : String) :
    Except CheckError (Plan Γ (El c)) :=
  match checkRhs S r with
  | .error err => .error err
  | .ok v =>
    if h : v.code = c then .ok (h ▸ v.plan)
    else .error ⟨r.pos, s!"{what}: expected an answer of kind `{codeName c}`, \
                          but this one produces `{codeName v.code}`", codeName v.code⟩

/-- A `let`'s right-hand side, as the former that binds it.

An `ask` becomes the node itself, so `let x = ask …` is one `Plan.ask`. A panel
is not a binding former, so its value reaches the rest of the block through
`Plan.graft` and the substitution that extends the environment by it — which is
what `graft`'s continuation is for. -/
def checkBinder {Γ : Ctx} (S : Bindings Γ) : RawRhs → Except CheckError (Binder Γ)
  | .ask a =>
    let s := askShape a.model a.code a.target
    match Prompt.closed a.prompt with
    | some words => .ok ⟨a.code, fun k => Plan.askC a.code (s.withPrompt words) k⟩
    | none =>
      match Prompt.expr S a.pos a.prompt with
      | .error err => .error err
      | .ok e => .ok ⟨a.code, fun k => Plan.ask a.code s e k⟩
  | .panel ms pos =>
    match checkRhs S (.panel ms pos) with
    | .error err => .error err
    | .ok v => .ok ⟨v.code, fun k =>
        Plan.graft v.plan (fun _ σ e => Plan.sub k (fun δ => Env.cons (e δ) (σ δ)))⟩

/-! ### The three continuations of a bounded revision

Each is a `Plan.Cont`, i.e. a family indexed by the context the leaf sits in,
and each is built from **one** plan checked in **one** context by the same move:
extend the context morphism by the value the continuation is handed. That move
is `Sub`'s, so a continuation elaborated this way is coherent by construction —
which is exactly the hypothesis `Plan.Denotes` states and `denotes_revising`
consumes. -/

/-- The `check` clause: the artefact under review is de Bruijn `0`. -/
def checkCont {Γ : Ctx} {c : Code} (chk : Plan (c :: Γ) (El .verdict)) :
    Plan.Cont Γ (El c) Verdict :=
  fun _ σ a => Plan.sub chk (fun δ => Env.cons (a δ) (σ δ))

/-- The `with` clause: the verdict is de Bruijn `0` and the artefact de Bruijn
`1`, so a revision knows *what* it is answering — the correction
`attack-adequacy` §2.3 makes to the incumbent, here as a binder rather than as
advice. -/
def reviseCont {Γ : Ctx} {c : Code} (rev : Plan (.verdict :: c :: Γ) (El c)) :
    Plan.Cont Γ (El c × Verdict) (El c) :=
  fun _ σ av => Plan.sub rev (fun δ => Env.cons (av δ).2 (Env.cons (av δ).1 (σ δ)))

/-- The two outcomes: `caseB` on whether the loop produced an artefact, with the
artefact reaching the `accepted` block as de Bruijn `0`. The `none` arm reads
`default`, which no run ever sees — the two theorems about consent in
`Agentic/Core/HardenPatch.lean` are the statement that the unreachable branch is
unreachable. -/
def finishCont {Γ : Ctx} {c : Code} (acc : Plan (c :: Γ) Unit) (exh : Plan Γ Unit) :
    Plan.Cont Γ (Option (El c)) Unit :=
  fun _ σ final =>
    Plan.caseB (fun δ => (final δ).isSome)
      (Plan.sub acc (fun δ => Env.cons ((final δ).getD default) (σ δ)))
      (Plan.sub exh σ)

/-! ## How far a bounded revision may be unrolled

`revising a upto n` elaborates to `Plan.revising … n`, which is `Nat.rec`
building the unrolling, so the source's numeral is the size of the term the
checker returns and the depth of the recursion that returns it. Nothing else in
the language has that property: every other construct costs what it is written
out to.

An unbounded numeral is therefore an unbounded elaboration, and `check`'s type
does not say otherwise — it is total as a function of `Raw`, and a total
function may still be one no machine can run. Measured, at
`revising d upto n check … with … accepted { done } exhausted { done }`:
`upto 1000000000` aborts the process with `Stack overflow detected` in 0.3 s,
`upto 1000` prices in 71 s, `upto 400` in 3.5 s, `upto 100` in 56 ms and
`upto 64` in 20 ms. The bound below is where that curve is still free. -/

/-- `[[maxRevisions]]` = the largest `n` a `revising … upto n` may name.

A resource limit and not a judgment, so it is refused with the same
`CheckError` — position, message, excerpt — as every other refusal, rather than
by a different mechanism that a caller would have to learn.

**Here and not in the parser**, because it is the *elaboration* that unrolls:
`Dsl.check` applied to a hand-built `Raw` runs the same `Nat.rec` as one applied
to parsed text, and a bound in `Dsl.Parse` would leave that caller unguarded.
`checkBlock_bounded` is the statement that this clause is the only way in. -/
def maxRevisions : Nat := 64

/-- `[[b.bounded]]` = every `revising … upto n` in `b` names an `n` that
`maxRevisions` allows. Decidable, and first-order in the syntax: `RawRhs` has no
block inside it, so the recursion is `RawBlock`'s own. -/
def RawBlock.bounded : RawBlock → Bool
  | .done _ => true
  | .act _ _ _ => true
  | .bind _ _ rest _ => rest.bounded
  | .caseFlag _ y n _ => y.bounded && n.bounded
  | .caseVerdict _ a o d _ => a.bounded && o.bounded && d.bounded
  | .revising _ n _ _ _ _ _ _ acc exh _ =>
      decide (n ≤ maxRevisions) && acc.bounded && exh.bounded

/-! ## The checker -/

/-- `[[checkBlock Γ S b]]` = the plan `b` writes under the names `S`, or the
reason it writes none.

The result type is `Plan Γ Unit` and not `Plan Γ A`: every block ends in `done`
or `act`, so a block *is* a closed workflow's worth of syntax, and "a workflow
with a value nobody can receive" is not representable rather than rejected. -/
def checkBlock : (Γ : Ctx) → Bindings Γ → RawBlock → Except CheckError (Plan Γ Unit)
  | _, _, .done _ => .ok (.ret fun _ => ())
  | _, S, .act t pr pos =>
    let s : Q.Shape .ack := { addressee := t.addressee, scope := 1, draw := t.draw }
    match Prompt.closed pr with
    | some words => .ok (Plan.askC .ack (s.withPrompt words) (.ret fun _ => ()))
    | none =>
      match Prompt.expr S pos pr with
      | .error err => .error err
      | .ok e => .ok (Plan.ask .ack s e (.ret fun _ => ()))
  | Γ, S, .bind x rhs rest _ =>
    match checkBinder S rhs with
    | .error err => .error err
    | .ok b =>
      match checkBlock (b.code :: Γ) (Bindings.push x b.code S) rest with
      | .error err => .error err
      | .ok k => .ok (b.form k)
  | Γ, S, .caseFlag x y n pos =>
    match lookupBinding S pos x with
    | .error err => .error err
    | .ok bnd =>
    match checkBlock Γ S y with
    | .error err => .error err
    | .ok y' =>
    match checkBlock Γ S n with
    | .error err => .error err
    | .ok n' =>
    match bnd.at? .flag with
    | some e => .ok (Plan.caseB e y' n')
    | none =>
      .error ⟨pos, s!"the arms `yes` and `no` branch on a `flag`, \
                     but `{x}` answers `{codeName bnd.code}`", x⟩
  | Γ, S, .caseVerdict x a o d pos =>
    match lookupBinding S pos x with
    | .error err => .error err
    | .ok bnd =>
    match checkBlock Γ S a with
    | .error err => .error err
    | .ok a' =>
    match checkBlock Γ S o with
    | .error err => .error err
    | .ok o' =>
    match checkBlock Γ S d with
    | .error err => .error err
    | .ok d' =>
    match bnd.at? .verdict with
    | some e =>
      .ok (Plan.caseV e (fun t => match t with
        | .approve => a' | .object => o' | .declined => d'))
    | none =>
      .error ⟨pos, s!"the arms `approve`, `object` and `declined` branch on a `verdict`, \
                     but `{x}` answers `{codeName bnd.code}`", x⟩
  | Γ, S, .revising subj n cv chk av wv rev pv acc exh pos =>
    -- Before anything is elaborated, because `n` is the depth of the
    -- elaboration itself and not merely the size of its result.
    if maxRevisions < n then
      .error ⟨pos, s!"a bounded revision is unrolled into the term it writes, \
                     so its bound may name at most {maxRevisions} revisions",
              s!"upto {n}"⟩
    else
    match lookupBinding S pos subj with
    | .error err => .error err
    | .ok b =>
    -- The names each clause adds. `check` and `accepted` see the artefact as
    -- de Bruijn `0`; `with` sees the verdict as `0` and the artefact as `1`,
    -- and binds `why` to that verdict *rendered*, which is what keeps
    -- interpolation a text-only operation with no exception.
    let Swith : Bindings (Code.verdict :: b.code :: Γ) :=
      ⟨av, b.code, fun δ => Env.head (Env.tail δ)⟩ ::
      ⟨wv, Code.text, fun δ => Verdict.render (Env.head δ)⟩ ::
      Bindings.rename Sub.wk (Bindings.rename Sub.wk S)
    match checkRhsAt Code.verdict (Bindings.push cv b.code S) chk
        "the `check` clause of a bounded revision" with
    | .error err => .error err
    | .ok chkP =>
    match checkRhsAt b.code Swith rev "the `with` clause of a bounded revision" with
    | .error err => .error err
    | .ok revP =>
    match checkBlock (b.code :: Γ) (Bindings.push pv b.code S) acc with
    | .error err => .error err
    | .ok accP =>
    match checkBlock Γ S exh with
    | .error err => .error err
    | .ok exhP =>
    .ok (Plan.graft
      (Plan.revising (checkCont chkP) (reviseCont revP) n Γ Sub.id b.val)
      (finishCont accP exhP))

/-- **The elaboration is bounded by the source, and `maxRevisions` is the
bound.** Every `revising` the checker accepts — at any depth, in any arm —
names an `n` the bound allows, so the term `checkBlock` returns is at most a
constant times the length of the text that wrote it, and the recursion that
built it went no deeper.

This is the theorem the refusal in the `revising` clause exists to make true.
Without it "we added a guard" is a claim about one clause; with it, it is a
claim about the language. -/
theorem checkBlock_bounded : ∀ (r : RawBlock) (Γ : Ctx) (S : Bindings Γ) (p : Plan Γ Unit),
    checkBlock Γ S r = .ok p → r.bounded = true := by
  intro r
  induction r with
  | done pos => intro _ _ _ _; rfl
  | act t pr pos => intro _ _ _ _; rfl
  | bind x rhs rest pos ih =>
    intro Γ S p h
    simp only [checkBlock] at h
    split at h
    · exact absurd h (by simp)
    · split at h
      · exact absurd h (by simp)
      · rename_i k hk; exact ih _ _ k hk
  | caseFlag x y n pos ihy ihn =>
    intro Γ S p h
    simp only [checkBlock] at h
    split at h
    · exact absurd h (by simp)
    · split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · rename_i y' hy _ n' hn
          simp only [RawBlock.bounded, ihy _ _ y' hy, ihn _ _ n' hn, Bool.and_self]
  | caseVerdict x a o d pos iha iho ihd =>
    intro Γ S p h
    simp only [checkBlock] at h
    split at h
    · exact absurd h (by simp)
    · split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · split at h
          · exact absurd h (by simp)
          · rename_i a' ha _ o' ho _ d' hd
            simp only [RawBlock.bounded, iha _ _ a' ha, iho _ _ o' ho, ihd _ _ d' hd,
              Bool.and_self]
  | revising subj n cv chk av wv rev pv acc exh pos iha ihe =>
    intro Γ S p h
    simp only [checkBlock] at h
    split at h
    · exact absurd h (by simp)
    · rename_i hle
      split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · split at h
          · exact absurd h (by simp)
          · split at h
            · exact absurd h (by simp)
            · rename_i accP hacc
              split at h
              · exact absurd h (by simp)
              · rename_i exhP hexh
                simp only [RawBlock.bounded, iha _ _ accP hacc, ihe _ _ exhP hexh,
                  Bool.and_true, decide_eq_true_eq]
                omega

/-- `[[check Γ S r]]` = the workflow `r` writes, or the reason it writes none.

**This type is the type-soundness theorem.** A checker returning
`Except String (Plan Γ Unit)` cannot return an ill-typed plan, because an
ill-typed plan is not an inhabitant of `Plan Γ Unit`; there is nothing further
to prove and nothing that could go out of date. -/
def check (Γ : Ctx) (S : Bindings Γ) (r : Raw) : Except CheckError (Plan Γ Unit) :=
  checkBlock Γ S r

/-- …and hence of every source the front end accepts: an attacker who chooses
the numeral chooses a number no larger than `maxRevisions`. -/
theorem check_bounded (Γ : Ctx) (S : Bindings Γ) (r : Raw) (p : Plan Γ Unit)
    (h : check Γ S r = .ok p) : r.bounded = true :=
  checkBlock_bounded r Γ S p h

/-- `[[parseAndCheckE s]]` = the closed workflow `s` denotes, or the reason it
denotes none, with a position and an excerpt. -/
def parseAndCheckE (s : String) : Except CheckError (Plan [] Unit) :=
  match parse s with
  | .error e => .error e
  | .ok r => check [] [] r

/-- `[[parseAndCheck s]]` = the closed workflow `s` denotes, or the reason it
denotes none.

The owner's `W Unit` is `Plan [] Unit`, and that is the type: closedness is not
a theorem about the result, it is the result's type. -/
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
