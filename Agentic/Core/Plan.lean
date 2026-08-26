import Agentic.Core.Dlg
import Agentic.Core.Request
import Agentic.Core.Text
import Mathlib.Data.FinEnum

/-!
# Plans: the first-order syntax with binders

Rederivation kernel §2 (the five term formers), §2.4 (every deleted construct
and its derived form), §3 q2 (sharing is a variable used twice), §3 q3 (`under`
is a fold), §3 q5 (check first, revise in the recursive call), §3 q6 (a panel is
independent asks plus a monoid fold). The meaning of everything defined here is
`Agentic.Core.denote`, in `Agentic/Core/Denote.lean`; **every morphism equation
quoted in a docstring below is proved there**, adjacent to the fold it is about,
because that is the file the fold lives in.

The one design decision, which the whole module is a consequence of: the dilemma
*point-free plumbing or host binding* is false, and the third option is to own
the binder. A `Plan` is first-order — an inspectable term — and its variables
are de Bruijn indices, so there is no α-equivalence, no capture, no ill-scoped
term and no `Quot`. What the host supplies is not the sequencing but the *pure*
part: a request annotation's **words** are built by an `Expr`, while question
shape and execution intent are written in the term. Denotation forgets intent;
an answer may change only words, keeping content-dependent prompts below the
monadic rung and operational cost readable from syntax.

Three things are therefore **not** here, on purpose.

* There is no `Monad Plan` instance. `Plan` is a syntax, not a workflow;
  sequencing is `graft`, which is substitution into the `ret` leaves, and the
  monadic form `bindP` is derived from it *through `dyn`* — which is exactly the
  statement that general value-sequencing is the dynamic rung. `mapP` and
  `zipWith` (hence `panel`) are derived without `dyn`, so the functorial and
  applicative structure costs nothing while the monadic structure costs the
  quarantine. That asymmetry is the kernel's §4 in miniature and it is visible
  in the *types* of the derivations rather than asserted about them.
* There is no `scopeT`, no `shareT`, no `parT`, no `retryT`, no `seqT`. `under`
  is a fold, sharing is `Var` used twice, independence is a property of a term,
  revision is `Nat.rec`, and juxtaposition of `ask` nodes is the sequencing.
* There is no label, no site and no key. The world is keyed by questions.
-/

namespace Agentic.Core

/-! ## Annotated execution observations

These belong to the executable `Plan` representation. `ExecEvent.forget` is the
K6 map back to the bare-question semantic event. -/

/-- How one Plan occurrence obtained its answer. A memo hit has no dispatched
question; a fresh attempt records the operationally selected question, including
any failover relabelling. -/
inductive AnswerSource (c : Code) where
  | reused
  | asked (dispatched : Q c)

/-- One annotated Plan occurrence and its answer. `authored` never changes under
routing or failover. -/
structure ExecEvent where
  c : Code
  authored : Request c
  source : AnswerSource c
  answer : El c

/-- Annotated execution trace, compared exactly at representation lockstep. -/
abbrev ExecTrace : Type := List ExecEvent

/-- Forget execution annotation and attribution, retaining the authored semantic
question and answer. -/
def ExecEvent.forget (e : ExecEvent) : Event :=
  ⟨e.c, e.authored.question, e.answer⟩

@[simp] theorem ExecEvent.forget_mk (c : Code) (r : Request c)
    (source : AnswerSource c) (answer : El c) :
    (ExecEvent.mk c r source answer).forget = ⟨c, r.question, answer⟩ := rfl

/-! ## Contexts, environments, variables -/

/-- `[[Ctx]]` = what is known so far, as a list of answer codes — innermost
binding first, so de Bruijn index `0` is the most recently received answer.

A list of `Code`s and not of types: the context can only hold things an
addressee actually said, which is what keeps `Env Γ` in `Type 0` and the whole
syntax first-order. -/
abbrev Ctx : Type := List Code

/-- `[[Env Γ]]` = a point of the product `∏ c ∈ Γ, El c`: one actual answer for
each code the context records.

**The tail is delayed, and that is a measurement and not a taste.** The one
constructor takes its tail as `Unit → Env Γ`; `Env.cons` is the eager
constructor everything else writes, and `Env.consBy` the delayed one that
`Sub.lift` needs. The meaning is unchanged — `Unit → A` is `A` up to the η law
Lean decides definitionally, which is why `head_cons`, `tail_cons` and
`cons_head_tail` are all still `rfl`.

What changes is what it costs to read index `0`. A `Sub Γ Δ` is a *function*
`Env Δ → Env Γ`, so going under a binder is `Sub.lift σ = fun δ => δ.head ∷ σ
δ.tail`, and with a strict tail that `∷` runs `σ` — rebuilding the entire outer
environment — even for an expression that reads nothing but the answer just
bound. In `Plan.revising` the artefact expression at round `i+1` is exactly such
a read, and it is read twice per round (once on its own, once inside the
verdict), so the cost of an expression doubled with every round: measured on a
bounded revision of `n` amendments, `Explain.costSummary` took 3 ms at `n = 2`,
121 ms at 14, 1.9 s at 18 and 122 s at 24 — while the tree it prices has
`2n + 2` leaves. Delaying the tail makes reading index `0` a projection again.

It is not free, and the price is paid in the kernel: reducing `Env.tail` now
costs one β-step more, and the module that reduces the most of them,
`Agentic/Core/DslFlagship.lean`, elaborates in 249 s where it took 178 s
(`Agentic/Core/HardenPatch.lean`, 75 s, does not move). That is the trade — 40%
on one module's proofs, against `2ⁿ` on every run. -/
inductive Env : Ctx → Type where
  /-- The empty environment: nothing has been answered yet. -/
  | nil : Env []
  /-- One more answer, in front of the rest, with the rest not yet demanded. -/
  | consBy {c : Code} {Γ : Ctx} (x : El c) (γ : Unit → Env Γ) : Env (c :: Γ)

namespace Env

variable {c : Code} {Γ : Ctx}

/-- `[[Env.cons x γ]]` = `x` in front of `γ`: the constructor as the rest of this
package writes it, with the tail already in hand. -/
def cons (x : El c) (γ : Env Γ) : Env (c :: Γ) := .consBy x fun _ => γ

/-- The most recent answer. -/
def head : Env (c :: Γ) → El c
  | .consBy x _ => x

/-- Everything but the most recent answer. -/
def tail : Env (c :: Γ) → Env Γ
  | .consBy _ γ => γ ()

@[simp] theorem head_cons (x : El c) (γ : Env Γ) : (Env.cons x γ).head = x := rfl

@[simp] theorem tail_cons (x : El c) (γ : Env Γ) : (Env.cons x γ).tail = γ := rfl

/-- **Delaying the tail changes no environment.** `consBy` is `cons` on a tail
that has already been produced, so the two agree wherever both apply and the
delay is invisible to every theorem — which is why nothing else in the package
mentions `consBy`, and why `head_cons`, `tail_cons` and `cons_head_tail` are
still the whole interface. -/
@[simp] theorem consBy_eq_cons (x : El c) (γ : Env Γ) :
    Env.consBy x (fun _ => γ) = Env.cons x γ := rfl

/-- η for environments: an extended environment is its head consed onto its
tail. This is what makes the identity substitution's lift the identity. -/
@[simp] theorem cons_head_tail (γ : Env (c :: Γ)) : Env.cons γ.head γ.tail = γ := by
  cases γ; rfl

end Env

/-- `[[Var Γ c]]` = a de Bruijn index: a proof that the context records an answer
of code `c`, which is the same thing as a projection out of `Env Γ`.

Membership *as data*, because the projection has to compute. This is the whole
of the incumbent's label/site/key apparatus: an answer is referred to by where
it was bound, and referring to it twice is sharing (§3 q2). -/
inductive Var : Ctx → Code → Type where
  /-- The most recently bound answer. -/
  | here {c : Code} {Γ : Ctx} : Var (c :: Γ) c
  /-- An answer bound further out. -/
  | there {c c' : Code} {Γ : Ctx} : Var Γ c → Var (c' :: Γ) c

/-- **Morphism equation.** `[[Var.get v]]` is the projection `Env Γ → El c` that
`v` names; `get .here = head` and `get (.there v) = get v ∘ tail`, which are the
two clauses below and are the only content a variable has. -/
def Var.get : {Γ : Ctx} → {c : Code} → Var Γ c → Env Γ → El c
  | _, _, .here, γ => γ.head
  | _, _, .there v, γ => v.get γ.tail

@[simp] theorem Var.get_here {c : Code} {Γ : Ctx} (x : El c) (γ : Env Γ) :
    Var.get .here (Env.cons x γ) = x := rfl

@[simp] theorem Var.get_there {c c' : Code} {Γ : Ctx} (v : Var Γ c) (x : El c') (γ : Env Γ) :
    Var.get (.there v) (Env.cons x γ) = v.get γ := rfl

/-- `[[Expr Γ A]]` = a pure function of what is known: `Env Γ → A`.

Prompt construction is ordinary data, so nothing about building a question is an
effect, and `ask`'s question can mention every answer in scope. -/
abbrev Expr (Γ : Ctx) (A : Type) : Type := Env Γ → A

/-- The expression that reads a variable. `[[Expr.var v]] = [[Var.get v]]`. -/
abbrev Expr.var {Γ : Ctx} {c : Code} (v : Var Γ c) : Expr Γ (El c) := v.get

/-- The expression that ignores what is known. `[[Expr.const a]] = const a`. -/
abbrev Expr.const {Γ : Ctx} {A : Type} (a : A) : Expr Γ A := fun _ => a

/-! ## Substitutions: the category of contexts -/

/-- `[[Sub Γ Δ]]` = a way of reading a `Γ`-environment out of a `Δ`-environment;
that is, `Expr Δ (Env Γ)`, a context morphism.

Semantic rather than syntactic, and that is not a shortcut: `Expr` is already a
function of environments, so a renaming of variables has nothing to act on
except environments. Weakening, exchange, contraction and genuine substitution
are all inhabitants of this one type, and the substitution lemma
(`denote_sub`) is one line as a result.

**And it is what makes the arrow reading of the `pipeline` rung exact here.**
Atkey's "What is a categorical model of arrows?" declines the folklore
equivalence between arrows and Freyd categories — his own abstract says it "is
more subtle than that" — and derives *indexed* Freyd categories instead, with a
further condition for an indexed one to be an ordinary one; the differentiating
point is how much structure a computation's inputs carry. Because `Sub Γ Δ` is
an arbitrary *function* `Env Δ → Env Γ`, this package lands in the degenerate,
maximally-structured case: every pure map between environment types is
available, weakening, exchange, contraction and substitution are one operation,
and the Freyd reading of `pipeline` is exact rather than approximate. It would
stop being exact the moment anyone replaced `Sub` with a syntactic category of
renamings, which is one more reason not to. -/
abbrev Sub (Γ Δ : Ctx) : Type := Expr Δ (Env Γ)

namespace Sub

variable {Γ Δ Θ : Ctx} {c : Code}

/-- The identity context morphism. `[[Sub.id]] = id`. -/
abbrev id : Sub Γ Γ := fun γ => γ

/-- Composition of context morphisms: `[[comp σ τ]] = [[σ]] ∘ [[τ]]`, going
`Γ → Δ → Θ` on contexts and `Env Θ → Env Δ → Env Γ` on environments. -/
abbrev comp (σ : Sub Γ Δ) (τ : Sub Δ Θ) : Sub Γ Θ := fun θ => σ (τ θ)

/-- Weakening: forget the most recently bound answer. `[[wk]] = Env.tail`. -/
abbrev wk : Sub Γ (c :: Γ) := Env.tail

/-- Going under a binder: keep the new answer, act with `σ` on the rest.
`[[lift σ]] = fun δ => δ.head ∷ σ δ.tail`.

Written with `Env.consBy`, so `σ` runs only if something reads past the new
answer. `Env.consBy_eq_cons` says that is the same environment; the docstring on
`Env` says what it costs when it is not. -/
abbrev lift (σ : Sub Γ Δ) : Sub (c :: Γ) (c :: Δ) := fun δ => .consBy δ.head fun _ => σ δ.tail

/-- Left unit of composition. -/
@[simp] theorem id_comp (σ : Sub Γ Δ) : comp Sub.id σ = σ := rfl

/-- Right unit of composition. -/
@[simp] theorem comp_id (σ : Sub Γ Δ) : comp σ Sub.id = σ := rfl

/-- Associativity: contexts and their morphisms are a category. -/
theorem comp_assoc (σ : Sub Γ Δ) (τ : Sub Δ Θ) (υ : Sub Θ Ξ) :
    comp (comp σ τ) υ = comp σ (comp τ υ) := rfl

/-- Lifting the identity is the identity — the η law of `Env` in the form the
functoriality of `Plan.sub` needs. -/
@[simp] theorem lift_id : (lift Sub.id : Sub (c :: Γ) (c :: Γ)) = Sub.id := by
  funext δ; exact Env.cons_head_tail δ

/-- Lifting is functorial. -/
@[simp] theorem lift_comp (σ : Sub Γ Δ) (τ : Sub Δ Θ) :
    (lift (comp σ τ) : Sub (c :: Γ) (c :: Θ)) = comp (lift σ) (lift τ) := rfl

/-- Weakening is natural: reading past a fresh binding is the same whether the
context morphism is applied before or after.

**What these three are, in the vocabulary of strength.** On environments,
`Env (c :: Γ) ≅ El c × Env Γ` (`Env.cons_head_tail`), and under that
isomorphism the three declarations above are the strength of the context
extension functor and its projection:

```
Sub.lift σ  =  id_{El c} × σ  =  second' σ        (Strong's `second'`, at `(→)`)
Sub.wk      =  π₂
wk_lift     =  the naturality square of π₂
```

Three `rfl`s, and naming them is not free of content: the seed question that
produced this note asked whether `Plan` wanted profunctor-optic machinery, and
the answer is that the *only* piece of it the package uses is this strength,
which is `id × −` at `(→)` and needs no `Strong` class, no Tambara module and no
profunctor composition to state. Running the coherence checklist that the name
`second'` generates is what turned up the one square this package was missing —
`Morphism.sub_mapP`, the bifunctor law, which follows in one line and was stated
nowhere. Vocabulary that generates a completeness checklist earns its keep even
when every entry it finds is a `rfl`; a vocabulary that generates a second
development does not, which is why nothing else from that direction was
taken. -/
@[simp] theorem wk_lift (σ : Sub Γ Δ) :
    comp (wk (c := c)) (lift σ) = comp σ (wk (c := c)) := rfl

end Sub

/-! ## The closed tag universe a branching may name

`case` branches on a *finite* tag, and the elaborator emits exactly three of
them (`Agentic/Core/Dsl/Check.lean`'s `case` sites: a flag, a verdict's
classifier, a bounded revision's settled-or-not, and — since D4 — a three-way
bounded revision's ending). So the tag is written as a closed
three-constructor object rather than as a quantified `[FinEnum T] [DecidableEq T]`,
which is what the Haskell port already does (`data Tag t where TBool; TVTag`,
`haskell/src/Agentic/Plan.hs:468`).

**A tag is added, not opened.** `Ending` (D4) was the first constructor since
the universe was closed at two, and adding it cost exactly what the closure
promised: one `El` clause, one `values` clause, three instances, one
`finEnum_toList` case, and nothing at all in `Level`, `Cost` or `Explain`, which
fold over `Tag.values` generically. `Explain` did gain clauses, and they are the
closure working rather than an exception to it: `Dsl.RawBlock.revisionBounds`
traverses the *raw syntax*, so it pays for a new bounded-revision **form** — the
`revisingOn` source and the `caseEnding` block — and not for the tag that form's
exit branches on.

Three things follow, and each is the reason the closure is worth its churn.

* **`Plan` lands in `Type 0`.** A constructor that quantifies over `Type` forces
  the inductive up a universe; `Tag` and `Code` are ordinary data, so neither
  `case` nor `dyn` does. (That is *necessary* and not sufficient — see the note
  on `PlanF` below, where the third cause is recorded.)
* **No `FinEnum` in the syntax at all.** The hygiene note that used to live on
  the `case` constructor is discharged rather than argued: `Agentic/Core/Certify.lean`'s
  zero-axiom claim is about `Plan`'s whole transitive graph, and after the
  closure that graph contains no enumeration, no `Fintype` and no `Finset`. The
  enumerations move to the *analyses*, where a `Finset.univ` was always
  admissible.
* **The two signatures become literally the same.** `Tag`, `Tag.El` and
  `Tag.values` are `Plan.hs`'s `Tag`, its type index and `tagValues`, and
  `tagValues` was written by hand to reproduce this package's `FinEnum` order.
  `Tag.finEnum_toList` below is the machine-checked statement that it does. -/

/-- `[[VTag]]` = the finite classifier of a verdict: the three answers that a
`case` can branch on.

The classifier and not the verdict itself, because `Verdict` is
`WithZero (FreeMonoid Objection)` and is infinite: what a workflow branches on
is *whether* there were objections, while the objections themselves ride in the
environment into the arm that was taken. That split — a finite tag decides the
shape, the unbounded payload flows on — is the whole of why the domain sits
below the monadic rung. -/
inductive VTag where
  /-- Nothing was objected to. -/
  | approve
  /-- Objections were raised. -/
  | object
  /-- The addressee would not answer. -/
  | declined
  deriving DecidableEq, Repr, Inhabited

/-- The three tags, enumerated. Written out rather than derived because there is
no `deriving FinEnum`; `Fintype VTag` comes back from Mathlib's
`FinEnum`-to-`Fintype` instance, so every `Finset.univ` in
`Agentic/Core/Level.lean` and `Agentic/Core/Cost.lean` is unchanged. -/
instance instFinEnumVTag : FinEnum VTag :=
  FinEnum.ofList [.approve, .object, .declined] (by intro t; cases t <;> simp)

/-- The two-element tag type, enumerated. Mathlib has `Fintype Bool` but no
`FinEnum Bool`.

**`scoped`, because `Bool` is not this package's type.** `test/Pollution.lean`
exists to keep this package from making claims about `Bool`, `Prop` and `ℕ` on
everyone who transitively imports it; a `scoped` instance is a claim made only
where the package's vocabulary has been opened. -/
scoped instance instFinEnumBool : FinEnum Bool :=
  FinEnum.ofList [false, true] (by decide)

/-- `[[Ending]]` = how a three-way bounded revision left off (D4).

The exit tag of `Plan.revisingOn`: a review's verdict tag decides the fate
rather than a single approval predicate, so a refusal ends the loop instead of
buying it another trip. Ordinary data, so adding a fourth ending later is a
local, total, kernel-checked edit — and see `revisingOn`'s docstring for why the
*classifier* does not extend for free. -/
inductive Ending where
  /-- A review approved. -/
  | settled
  /-- The bound ran out with an objection outstanding. -/
  | unsettled
  /-- A review declined: no answer, and no more trips. -/
  | abandoned
  deriving DecidableEq, Repr, Inhabited

/-- `[[Ending.ofVTag t]]` = the fate a verdict tag names at the last round:
approval settles, an objection leaves the loop unsettled, a refusal abandons
it. Total today, and deliberately so (D4 §3.6). -/
def Ending.ofVTag : VTag → Ending
  | .approve => .settled
  | .object => .unsettled
  | .declined => .abandoned

/-- The three endings, enumerated, in the order `Tag.values` writes them. -/
instance instFinEnumEnding : FinEnum Ending :=
  FinEnum.ofList [.settled, .unsettled, .abandoned] (by intro t; cases t <;> simp)

/-- `[[Tag]]` = the tags a branching may name. Three, and the elaborator emits
exactly these three. -/
inductive Tag where
  /-- A yes/no branching — `Plan.caseB`, and the surface's `if`. -/
  | bool
  /-- A verdict's three-way classifier — `Plan.caseV`, and the surface's
  `approved`/`objected`/`no answer`. -/
  | vtag
  /-- A three-way bounded revision's exit — `Plan.revisingOn`, and the surface's
  `settled`/`unsettled`/`abandoned`. -/
  | ending
  deriving DecidableEq, Repr, Inhabited

/-- `[[Tag.El t]]` = the type the tag names. A `def` and not an `abbrev`, so
that nothing here installs a `FinEnum` on `Bool` by unification. -/
def Tag.El : Tag → Type
  | .bool => Bool
  | .vtag => VTag
  | .ending => Ending

/-- Each tag's type is enumerated — in the *analyses*, which is where an
enumeration was always allowed to live. -/
instance instFinEnumTagEl : (t : Tag) → FinEnum t.El
  | .bool => instFinEnumBool
  | .vtag => instFinEnumVTag
  | .ending => instFinEnumEnding

/-- …and has decidable equality. -/
instance instDecidableEqTagEl : (t : Tag) → DecidableEq t.El
  | .bool => inferInstanceAs (DecidableEq Bool)
  | .vtag => inferInstanceAs (DecidableEq VTag)
  | .ending => inferInstanceAs (DecidableEq Ending)

/-- …and is inhabited, which a probe rendering needs. -/
instance instInhabitedTagEl : (t : Tag) → Inhabited t.El
  | .bool => inferInstanceAs (Inhabited Bool)
  | .vtag => inferInstanceAs (Inhabited VTag)
  | .ending => inferInstanceAs (Inhabited Ending)

/-- `[[Tag.values t]]` = the tag's inhabitants in enumeration order — the list
every analysis that crosses a branching folds over, and `Plan.hs`'s `tagValues`
transliterated. -/
def Tag.values : (t : Tag) → List t.El
  | .bool => [false, true]
  | .vtag => [.approve, .object, .declined]
  | .ending => [.settled, .unsettled, .abandoned]

/-- **The hand-written order is the enumeration's order**, at every tag. This is
what keeps `Explain.planLines` byte-identical across the closure, and what the
Haskell's `tagValues` is checked against. -/
@[simp] theorem Tag.finEnum_toList : ∀ t : Tag, FinEnum.toList t.El = t.values
  | .bool => by decide
  | .vtag => by decide
  | .ending => by decide

/-! ## The five term formers -/

/-- `[[Plan Γ A]] = Env Γ → Dlg A`: a first-order, intrinsically-typed term
denoting a workflow under an environment.

Five formers, each forced (kernel §2.3), and the meaning function `denote` in
`Agentic/Core/Denote.lean` is the fold that says what each one means:

```
denote (ret e)        γ = .done (e γ)
denote (askC c q k)   γ = .ask c q                     (fun x => denote k (γ ▷ x))
denote (ask c s e k)  γ = .ask c (s.withPrompt (e γ))  (fun x => denote k (γ ▷ x))
denote (case e arms)  γ = denote (arms (e γ)) γ
denote (dyn  e f)     γ = denote (f (e γ))    γ
```

**`Type 0`, and it took three closures to get there.** The two the design
papers name are `case`'s tag and `dyn`'s answer type: a constructor that
quantifies over `Type` forces the inductive up a universe, and both did. The
third is not in any of them and is the reason this declaration is written with
the *answer type as a parameter*: `A` was an **index**, bound afresh in every
constructor, and a constructor argument whose type is `Type` forces `Type 1` by
itself — closing `case` and `dyn` alone leaves `Plan` exactly where it was. `A`
is constant across all five formers, so it can be a parameter, and `Plan Γ A`
below is the package's spelling of `PlanF A Γ`, unchanged at every use site. -/
inductive PlanF (A : Type) : Ctx → Type where
  /-- The unit: answer with a pure function of what is known. -/
  | ret {Γ : Ctx} (e : Expr Γ A) : PlanF A Γ
  /-- **Ask a closed request and bind the answer.** Its request mentions nothing
  in scope, which is what gives a `Const S`-valued analysis a domain — the batch
  rung is recorded in the term or it is not well defined (kernel §2.3,
  `attack-adequacy` F1). -/
  | askC {Γ : Ctx} (c : Code) (q : Request c) (k : PlanF A (c :: Γ)) : PlanF A Γ
  /-- **Ask a question whose *words* are built from the answers so far, and bind
  the answer.** The node the domain forces: the guide's text goes into the
  reviewer's prompt, the draft into the review, the objections into the
  revision. Ask-and-bind in one former, so the syntax is already A-normal and no
  analysis has to reconstruct where an answer went.

  **The shape is term-level data and only the prompt is an expression**, which
  is the whole of the kernel's C2. `Request c ≅ Request.Shape c × String`; intent,
  the scope and the draw are written by the author in the term `s`, and the
  answer flows into the words and nowhere else — not because a predicate on the
  term says so, but because there is no place in the node for it to flow. The
  shape sequence of a `pipeline` plan is therefore a *projection of the syntax*
  (`shapes_eq_of_le_pipeline`, which carries no hypothesis). -/
  | ask {Γ : Ctx} (c : Code) (s : Request.Shape c) (e : Expr Γ String)
      (k : PlanF A (c :: Γ)) : PlanF A Γ
  /-- **Finite-tag branching, both arms in the term.** `Selective.branch`, with
  the payload riding in the context into whichever arm is taken. The tag is a
  `Tag` — an inhabitant of the closed universe above, not a
  quantified `Type` — so the branch structure is a genuine finite tree, the cost
  of the not-taken arm is enumerable rather than lost, and the *syntax* mentions
  no enumeration at all.

  **What the closure discharges.** Mathlib's `Fintype` holds a `Finset`, a
  `Finset` holds a `Multiset`, and a `Multiset` is a quotient — so a syntax
  whose `case` node mentions `Fintype` depends on `propext` and `Quot.sound`
  *as a type*, before any theorem about it is stated, and
  `Agentic/Core/Certify.lean`'s empty axiom set for `certify_sound` is a claim
  about this constructor's whole transitive graph. The package used to answer
  that with `FinEnum`, which is a bijection with `Fin n` built out of `Fin`,
  `Equiv` and `List` and is quotient-free. `Tag` answers it more simply: there
  is nothing to be hygienic about, because there is nothing there. The
  enumeration `Tag.values` lives in the analyses, where a `Finset.univ` was
  always admissible. -/
  | case {Γ : Ctx} (t : Tag) (e : Expr Γ t.El) (arms : t.El → PlanF A Γ) : PlanF A Γ
  /-- **Quarantined: a plan computed from an unbounded answer.** The one
  higher-order node, kept because directive (1) asks for it and no finite tag
  can reach it. Its presence is what makes a plan dynamic, and the absence of an
  analysis homomorphism here is a theorem to be proved rather than a hole to be
  papered over.

  Its answer type is a `Code` and not a quantified `Type`, for the universe
  reason above. Nothing is lost: `El .text` is `String`, which is infinite, and
  `Cost.no_finite_bill_set_at_dyn` — the witness that no finite bill set
  describes a dynamic plan — is stated at exactly that former. -/
  | dyn {Γ : Ctx} (b : Code) (e : Expr Γ (El b)) (f : El b → PlanF A Γ) : PlanF A Γ

/-- `[[Plan Γ A]]` = `PlanF A Γ`: the package's spelling, context first. The
answer type is `PlanF`'s parameter because a `Type`-valued *index* would put the
syntax back in `Type 1` (see `PlanF`'s docstring); it is constant across the
five formers, so nothing is given up by fixing it. -/
abbrev Plan (Γ : Ctx) (A : Type) : Type := PlanF A Γ

namespace Plan

/-! The five formers under the name the package writes them by. Aliases and not
wrappers: `Plan.ret` *is* `PlanF.ret`, so a `simp` set keyed on one fires on the
other and every `rfl` that used to close still does. -/
export PlanF (ret askC ask case dyn)

end Plan

/-! ## The initial algebra: one recursion, and every analysis is an instance of it

`Plan`'s five formers are a signature; every analysis in this package is a
homomorphism out of the syntax for that signature. `PlanAlg` is that signature's
algebra, `PlanAlg.fold` the homomorphism it induces, and `PlanAlg.fold_unique`
initiality — the fold is the *only* homomorphism, so the structural inductions
the package used to write one per analysis are all the same induction.

It lives here, immediately below the inductive, because it is the recursion
scheme *of* the inductive: `sub`, `under` and `graft` below are already
instances of it, and so are `denote` (`Agentic/Core/Denote.lean`), `level`
(`Agentic/Core/Level.lean`), `codes`, `shapes`, `asks` (`Agentic/Core/Cost.lean`)
and `size`, `askNodes`, `explain` (`Agentic/Core/Explain.lean`).
`Agentic/Core/Alg.lean` is where the *equations* between them are stated.

**Universe polymorphism is what makes one record serve every carrier**, and it
is now polymorphism with nothing to do: every carrier in the table is `Type 0`,
because closing `case`'s tag and `dyn`'s answer type — and making the answer
type `PlanF`'s *parameter* rather than an index — put `Plan` and `Cont` there
too. `PlanAlg` stays stated at `Type v` all the same: `Plan.rec` is
universe-polymorphic in its motive, the statement costs nothing, and an analysis
into a large carrier remains writable.

**One analysis does not fit**: `Cost.costM`, whose signature absorbs the level
bound (`(p : Plan Γ A) → level p ≤ Level.branch → …`) and an algebra carrier may
not mention `p`. That is the deliberate decision recorded at `Cost.lean`'s C3
section — "the analysis applies at this rung is the *type* of the fold rather
than a side condition" — so the honest count is eleven of twelve. -/

universe v

/-- `[[PlanAlg P]]` = an algebra for the `Plan` signature, indexed the way `Plan`
is: one field per former, with the recursive positions replaced by the carrier.

The five fields *are* the structure a target must carry for an interpretation to
exist — in this package's own vocabulary, and not in a hierarchy of profunctor
classes. `ret` is the pure part, `askC` a nullary generator's binding, `ask` a
unary generator's, `case` the finite copair and `dyn` the one higher-order
former. -/
structure PlanAlg (P : Ctx → Type → Type v) where
  /-- What a pure leaf becomes. -/
  ret  : {Γ : Ctx} → {A : Type} → Expr Γ A → P Γ A
  /-- What a closed question and its binding become. -/
  askC : {Γ : Ctx} → {A : Type} → (c : Code) → Request c → P (c :: Γ) A → P Γ A
  /-- What an open question — shape in the term, words computed — and its
  binding become. -/
  ask  : {Γ : Ctx} → {A : Type} → (c : Code) → Request.Shape c → Expr Γ String → P (c :: Γ) A → P Γ A
  /-- What a finite branch becomes: the copair over the tag's type. -/
  case : {Γ : Ctx} → {A : Type} → (t : Tag) → Expr Γ t.El → (t.El → P Γ A) → P Γ A
  /-- What the quarantined dynamic former becomes. -/
  dyn  : {Γ : Ctx} → {A : Type} → (b : Code) → Expr Γ (El b) → (El b → P Γ A) → P Γ A

namespace PlanAlg

variable {P : Ctx → Type → Type v} (alg : PlanAlg P)

/-- `[[alg.fold p]]` = the homomorphism out of the syntax. **One** structural
recursion, in place of one per analysis.

`{A : Type}` is bound before the recursion because it is `PlanF`'s parameter:
the recursion is on the `Ctx` index at a fixed answer type, which is what every
one of the twelve analyses does anyway. -/
def fold {A : Type} : {Γ : Ctx} → Plan Γ A → P Γ A
  | _, .ret e => alg.ret e
  | _, .askC c q k => alg.askC c q (fold k)
  | _, .ask c s e k => alg.ask c s e (fold k)
  | _, .case t e arms => alg.case t e (fun x => fold (arms x))
  | _, .dyn b e f => alg.dyn b e (fun x => fold (f x))

@[simp] theorem fold_ret {Γ : Ctx} {A : Type} (e : Expr Γ A) :
    alg.fold (Plan.ret e) = alg.ret e := rfl

@[simp] theorem fold_askC {Γ : Ctx} {A : Type} (c : Code) (q : Request c) (k : Plan (c :: Γ) A) :
    alg.fold (Plan.askC c q k) = alg.askC c q (alg.fold k) := rfl

@[simp] theorem fold_ask {Γ : Ctx} {A : Type} (c : Code) (s : Request.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) :
    alg.fold (Plan.ask c s e k) = alg.ask c s e (alg.fold k) := rfl

@[simp] theorem fold_case {Γ : Ctx} {A : Type} (t : Tag) (e : Expr Γ t.El)
    (arms : t.El → Plan Γ A) :
    alg.fold (Plan.case t e arms) = alg.case t e (fun x => alg.fold (arms x)) := rfl

@[simp] theorem fold_dyn {Γ : Ctx} {A : Type} (b : Code) (e : Expr Γ (El b))
    (f : El b → Plan Γ A) :
    alg.fold (Plan.dyn b e f) = alg.dyn b e (fun x => alg.fold (f x)) := rfl

/-- **Initiality: the fold is the only homomorphism.** Anything that satisfies
the five equations *is* the fold.

This is the theorem the package used to prove one instance at a time. Given it,
a new analysis costs an algebra record and its five equations — which are `rfl`
if the analysis was written as a fold — and every invariance result about it is
a fusion argument rather than a fresh induction. -/
theorem fold_unique (h : {Γ : Ctx} → {A : Type} → Plan Γ A → P Γ A)
    (hret : ∀ {Γ A} (e : Expr Γ A), h (.ret e) = alg.ret e)
    (haskC : ∀ {Γ A} c q (k : Plan (c :: Γ) A), h (.askC c q k) = alg.askC c q (h k))
    (hask : ∀ {Γ A} c s e (k : Plan (c :: Γ) A), h (.ask c s e k) = alg.ask c s e (h k))
    (hcase : ∀ {Γ A} (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A),
       h (.case t e arms) = alg.case t e (fun x => h (arms x)))
    (hdyn : ∀ {Γ A} (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A),
       h (.dyn b e f) = alg.dyn b e (fun x => h (f x))) :
    ∀ {Γ : Ctx} {A : Type} (p : Plan Γ A), h p = alg.fold p := by
  intro Γ A p
  induction p with
  | ret e => exact hret e
  | askC c q k ih => rw [haskC, ih]; rfl
  | ask c s e k ih => rw [hask, ih]; rfl
  | case t e arms ih => rw [hcase]; exact congrArg _ (funext fun x => ih x)
  | dyn b e f ih => rw [hdyn]; exact congrArg _ (funext fun x => ih x)

end PlanAlg

namespace Plan

variable {Γ Δ Θ : Ctx} {A B C : Type}

/-! ## Renaming and substitution: `Plan` is a presheaf on contexts -/

/-- Renaming, as an algebra.

Its carrier is the *function space* `∀ Δ, Sub Γ Δ → Plan Δ A` — the ordinary
fold-with-accumulator move, and the reason `Sub.lift` appears in the `askC` and
`ask` clauses: the algebra's action on its accumulator is "reach past one more
binder". -/
def subAlg : PlanAlg (fun Γ A => ∀ Δ : Ctx, Sub Γ Δ → Plan Δ A) where
  ret e := fun _ σ => .ret (fun δ => e (σ δ))
  askC c q k := fun _ σ => .askC c q (k _ (Sub.lift σ))
  ask c s e k := fun _ σ => .ask c s (fun δ => e (σ δ)) (k _ (Sub.lift σ))
  case t e arms := fun _ σ => .case t (fun δ => e (σ δ)) (fun x => arms x _ σ)
  dyn b e f := fun _ σ => .dyn b (fun δ => e (σ δ)) (fun x => f x _ σ)

/-- `[[sub p σ]]` = `p` read in a bigger (or otherwise related) context.

**Morphism equation** (`denote_sub`, proved in `Denote.lean`):
`denote (sub p σ) δ = denote p (σ δ)`. Weakening and substitution are the same
operation here, because a context morphism is a function on environments.

`subAlg.fold` and not a recursion of its own: there is one structural recursion
on `Plan` in this package, and the five equations below say what this instance
of it does. -/
def sub {A : Type} : {Γ Δ : Ctx} → Plan Γ A → Sub Γ Δ → Plan Δ A :=
  fun p σ => subAlg.fold p _ σ

/-! ### The five defining equations of `sub`, each a `rfl` -/

theorem sub_ret {Γ Δ : Ctx} (e : Expr Γ A) (σ : Sub Γ Δ) :
    sub (Plan.ret e) σ = .ret (fun δ => e (σ δ)) := rfl

theorem sub_askC {Γ Δ : Ctx} (c : Code) (q : Request c) (k : Plan (c :: Γ) A) (σ : Sub Γ Δ) :
    sub (Plan.askC c q k) σ = .askC c q (sub k (Sub.lift σ)) := rfl

theorem sub_ask {Γ Δ : Ctx} (c : Code) (s : Request.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) (σ : Sub Γ Δ) :
    sub (Plan.ask c s e k) σ = .ask c s (fun δ => e (σ δ)) (sub k (Sub.lift σ)) := rfl

theorem sub_case {Γ Δ : Ctx} (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A) (σ : Sub Γ Δ) :
    sub (Plan.case t e arms) σ = .case t (fun δ => e (σ δ)) (fun x => sub (arms x) σ) := rfl

theorem sub_dyn {Γ Δ : Ctx} (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A) (σ : Sub Γ Δ) :
    sub (Plan.dyn b e f) σ = .dyn b (fun δ => e (σ δ)) (fun x => sub (f x) σ) := rfl

/-- Renaming along the identity is the identity: the first functor law of the
presheaf `Γ ↦ Plan Γ A`. -/
@[simp] theorem sub_id (p : Plan Γ A) : sub p Sub.id = p := by
  induction p with
  | ret e => rfl
  | askC c q k ih => simp only [sub_askC, Sub.lift_id, ih]
  | ask c s e k ih => simp only [sub_ask, Sub.lift_id, ih]
  | case t e arms ih => simp only [sub_case]; exact congrArg _ (funext fun x => ih x)
  | dyn b e f ih => simp only [sub_dyn]; exact congrArg _ (funext fun x => ih x)

/-- Renaming composes: the second functor law. -/
theorem sub_comp (p : Plan Γ A) (σ : Sub Γ Δ) (τ : Sub Δ Θ) :
    sub (sub p σ) τ = sub p (Sub.comp σ τ) := by
  induction p generalizing Δ Θ with
  | ret e => rfl
  | askC c q k ih => simp only [sub_askC, Sub.lift_comp]; exact congrArg _ (ih _ _)
  | ask c s e k ih => simp only [sub_ask, Sub.lift_comp]; exact congrArg _ (ih _ _)
  | case t e arms ih => simp only [sub_case]; exact congrArg _ (funext fun x => ih x _ _)
  | dyn b e f ih => simp only [sub_dyn]; exact congrArg _ (funext fun x => ih x _ _)

/-! ## Scope: `under σ` is a fold and a monoid action -/

/-- Relabelling, as an algebra: what `under σ` (just below) does at each former.

**Morphism equation** (`denote_under`, proved in `Denote.lean`):
`denote (under σ p) γ = Dlg.under σ (denote p γ)` — the plan-level scope
operator is the dialogue-level one, transported along the meaning. A *fold*,
defined where the recursion's target lives, and not a constructor: the
package's own no-weakening-constructor rule is what condemns `scopeT`.

`PlanAlg` at the carrier `P Γ A = Plan Γ A`, which is what "a fold back into the
syntax" means: only the two question formers do anything, and each does the one
thing `σ` says. -/
def underAlg (σ : Sig) : PlanAlg (fun Γ A => Plan Γ A) where
  ret e := .ret e
  askC c q k := .askC c (σ.onRequest c q) k
  ask c s e k := .ask c (σ.onRequestShape c s) e k
  case t e arms := .case t e arms
  dyn b e f := .dyn b e f

/-- `[[under σ p]]` = `p` with every question relabelled by `σ`. -/
def under {A : Type} (σ : Sig) : {Γ : Ctx} → Plan Γ A → Plan Γ A :=
  fun p => (underAlg σ).fold p

/-! ### The five defining equations of `under`, each a `rfl` -/

theorem under_ret (σ : Sig) (e : Expr Γ A) : under σ (Plan.ret e) = .ret e := rfl

theorem under_askC (σ : Sig) (c : Code) (q : Request c) (k : Plan (c :: Γ) A) :
    under σ (Plan.askC c q k) = .askC c (σ.onRequest c q) (under σ k) := rfl

theorem under_ask (σ : Sig) (c : Code) (s : Request.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) :
    under σ (Plan.ask c s e k) = .ask c (σ.onRequestShape c s) e (under σ k) := rfl

theorem under_case (σ : Sig) (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A) :
    under σ (Plan.case t e arms) = .case t e (fun x => under σ (arms x)) := rfl

theorem under_dyn (σ : Sig) (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A) :
    under σ (Plan.dyn b e f) = .dyn b e (fun x => under σ (f x)) := rfl

/-- **Action law 1**: `under 1 = id`. -/
@[simp] theorem under_idSig (p : Plan Γ A) : under idSig p = p := by
  induction p with
  | ret e => rfl
  | askC c q k ih => simp only [under_askC, idSig_onRequest, ih]
  | ask c s e k ih => simp only [under_ask, idSig_onRequestShape, ih]
  | case t e arms ih => simp only [under_case]; exact congrArg _ (funext fun x => ih x)
  | dyn b e f ih => simp only [under_dyn]; exact congrArg _ (funext fun x => ih x)

/-- **Action law 2**: `under σ ∘ under τ = under (σ ∘ τ)`. With `under_idSig`
this says relabellings act on plans; it is `Agentic.actR_compose` at this
carrier, and it is the whole of the scope algebra at the syntax. -/
theorem under_under (σ τ : Sig) (p : Plan Γ A) :
    under σ (under τ p) = under (compSig σ τ) p := by
  induction p with
  | ret e => rfl
  | askC c q k ih => simp only [under_askC, compSig_onRequest, ih]
  | ask c s e k ih => simp only [under_ask, compSig_onRequestShape, ih]
  | case t e arms ih => simp only [under_case]; exact congrArg _ (funext fun x => ih x)
  | dyn b e f ih => simp only [under_dyn]; exact congrArg _ (funext fun x => ih x)

/-- **Innermost wins, at the operator the author actually writes.** Nesting one
model scope inside another — what the surface writes
`model mOuter <| model mInner <| body` — is the inner scope alone: the outer one
contributes nothing to any question of `body`.

This is the load-bearing form of `Question.compSig_atModel_atModel`. Because
`under` composes by `compSig`, the *outer* relabelling is the one applied
*last*, so an `atModel` that appended its setting on the right of the scope
would make the outermost model win; that this equation closes is what rules the
mistake out. -/
theorem under_atModel_atModel (mOuter mInner : String) (p : Plan Γ A) :
    under (atModel mOuter) (under (atModel mInner) p) = under (atModel mInner) p := by
  rw [under_under, compSig_atModel_atModel]

/-- Relabelling commutes with renaming: scope is a fact about questions and
renaming is a fact about variables, and the two do not interact. -/
theorem under_sub (σ : Sig) (p : Plan Γ A) (τ : Sub Γ Δ) :
    under σ (sub p τ) = sub (under σ p) τ := by
  induction p generalizing Δ with
  | ret e => rfl
  | askC c q k ih => simp only [sub_askC, under_askC]; exact congrArg _ (ih _)
  | ask c s e k ih => simp only [sub_ask, under_ask]; exact congrArg _ (ih _)
  | case t e arms ih => simp only [sub_case, under_case]; exact congrArg _ (funext fun x => ih x _)
  | dyn b e f ih => simp only [sub_dyn, under_dyn]; exact congrArg _ (funext fun x => ih x _)

/-! ## Sequencing is grafting -/

/-- `[[Cont Γ A B]]` = a continuation that can be grafted onto every leaf of a
`Γ`-plan: for each context `Δ` the leaf might sit in, a way of reading `Γ` back
out of it and an `A`-valued expression there, it gives a `Δ`-plan.

Context-polymorphic because the leaves of a plan do *not* all sit in `Γ`: each
`ask` on the way to a leaf has bound one more answer. The `Sub Γ Δ` argument is
how a continuation written against `Γ` reaches the leaf, and the `Expr Δ A` is
the value the leaf produced — as an expression, not as a value, which is
precisely why grafting need not go through `dyn`. -/
abbrev Cont (Γ : Ctx) (A B : Type) : Type := ∀ Δ : Ctx, Sub Γ Δ → Expr Δ A → Plan Δ B

/-- Sequencing, as an algebra: what `graft` (just below) does at each former.

**This is sequencing, and it is substitution, not a constructor** (kernel §2.4:
"`>>=` is substitution"). Its morphism equation is `denote_graft` in
`Denote.lean`: if the continuation means the semantic continuation `K` at every
leaf, then `denote (graft p k) γ = denote p γ >>= fun a => K a γ`. Grafting is
strictly more general than `bind`, because the leaf's continuation may also read
the answers bound between the root and the leaf — which is what `bind` cannot
see and what makes a plan a *term* rather than a tree of closures.

Its carrier is the function space `P Γ A = Cont Γ A B → Plan Γ B`, the same
fold-with-accumulator move `subAlg` makes. The `askC` clause is
`fun rec k => .askC c q (rec (fun Δ σ e => k Δ (Sub.comp Sub.wk σ) e))` — so
"rebuild the continuation with one more weakening" is literally the algebra
acting on its accumulator, which is a better account of the bookkeeping than any
comment about it. -/
def graftAlg (B : Type) : PlanAlg (fun Γ A => Cont Γ A B → Plan Γ B) where
  ret e := fun k => k _ Sub.id e
  askC c q rec := fun k => .askC c q (rec (fun Δ σ e => k Δ (Sub.comp Sub.wk σ) e))
  ask c s d rec := fun k => .ask c s d (rec (fun Δ σ e => k Δ (Sub.comp Sub.wk σ) e))
  case t d arms := fun k => .case t d (fun x => arms x k)
  dyn b d f := fun k => .dyn b d (fun x => f x k)

/-- `[[graft p k]]` = `p` with every `ret` leaf replaced by `k` at that leaf.
`graftAlg B`'s fold; the five equations below are its clauses. -/
def graft {B : Type} : {Γ : Ctx} → {A : Type} → Plan Γ A → Cont Γ A B → Plan Γ B :=
  fun p k => (graftAlg B).fold p k

/-! ### The five defining equations of `graft`, each a `rfl` -/

theorem graft_ret {B : Type} (e : Expr Γ A) (k : Cont Γ A B) :
    graft (Plan.ret e) k = k _ Sub.id e := rfl

theorem graft_askC {B : Type} (c : Code) (q : Request c) (p : Plan (c :: Γ) A) (k : Cont Γ A B) :
    graft (Plan.askC c q p) k
      = .askC c q (graft p (fun Δ σ e => k Δ (Sub.comp Sub.wk σ) e)) := rfl

theorem graft_ask {B : Type} (c : Code) (s : Request.Shape c) (d : Expr Γ String)
    (p : Plan (c :: Γ) A) (k : Cont Γ A B) :
    graft (Plan.ask c s d p) k
      = .ask c s d (graft p (fun Δ σ e => k Δ (Sub.comp Sub.wk σ) e)) := rfl

theorem graft_case {B : Type} (t : Tag) (d : Expr Γ t.El) (arms : t.El → Plan Γ A)
    (k : Cont Γ A B) :
    graft (Plan.case t d arms) k = .case t d (fun x => graft (arms x) k) := rfl

theorem graft_dyn {B : Type} (b : Code) (d : Expr Γ (El b)) (f : El b → Plan Γ A)
    (k : Cont Γ A B) :
    graft (Plan.dyn b d f) k = .dyn b d (fun x => graft (f x) k) := rfl

/-- `[[mapP f p]] = f <$> [[p]]`: the functorial action, derived from `graft`
and — the point — **without `dyn`**, so mapping a plan does not move its rung.
Morphism equation `denote_mapP` in `Denote.lean`. -/
def mapP (f : A → B) (p : Plan Γ A) : Plan Γ B :=
  graft p (fun _ _ e => .ret (fun δ => f (e δ)))

/-- `[[zipWith f p q]] = f <$> [[p]] <*> [[q]]`: the applicative action, again
derived without `dyn`. `q` is grafted under `p`'s binders by `sub`, which is the
sense in which two questions that do not mention each other's variables are
independent (§3 q6). Morphism equation `denote_zipWith` in `Denote.lean`. -/
-- Solved from the equation: the outer graft supplies `a` and reaches the leaf
-- with `σ`, `sub q σ` moves `q` under `p`'s binders, and the inner graft
-- supplies `b`; nothing else can typecheck.
def zipWith (f : A → B → C) (p : Plan Γ A) (q : Plan Γ B) : Plan Γ C :=
  graft p (fun _ σ e => graft (sub q σ) (fun _ τ e' => .ret (fun θ => f (e (τ θ)) (e' θ))))

/-- `[[pairP p q]] = (·, ·) <$> [[p]] <*> [[q]]`. -/
def pairP (p : Plan Γ A) (q : Plan Γ B) : Plan Γ (A × B) := zipWith Prod.mk p q

/-- `[[seq p q]] = [[p]] >> [[q]]`: run `p`, discard its answer, run `q`. No
`dyn`, because the answer is discarded. -/
def seq (p : Plan Γ A) (q : Plan Γ B) : Plan Γ B :=
  graft p (fun _ σ _ => sub q σ)

/-- `[[bindP p k]] = [[p]] >>= fun a => [[k a]]`: the monadic sequencing, and
the **only** derived form that needs `dyn`.

That it needs `dyn` is the content, not an implementation accident: `k` is a
genuine function of an unrestricted answer, so the plan that follows is computed
from an answer, which is the definition of the dynamic rung. Everything the
domain actually does with an answer — putting it into the next prompt
(`ask`), branching on a finite classifier of it (`case`), folding a panel of
them (`zipWith`) — is available without it. -/
def bindP {c : Code} (p : Plan Γ (El c)) (k : El c → Plan Γ B) : Plan Γ B :=
  graft p (fun _ σ e => .dyn c e (fun a => sub (k a) σ))

/-! ## Authoring forms -/

/-- `[[askC1 c q]] = Dlg.ask1 c q`: put a closed question and answer with the
reply. -/
def askC1 (c : Code) (q : Request c) : Plan Γ (El c) := .askC c q (.ret (Expr.var .here))

/-- `[[ask1 c s e]]` = put the question of shape `s` whose words `e` builds from
what is known, and answer with the reply. -/
def ask1 (c : Code) (s : Request.Shape c) (e : Expr Γ String) : Plan Γ (El c) :=
  .ask c s e (.ret (Expr.var .here))

/-- `[[caseB e t f]] = if e then t else f`, with **both** arms in the term.
`Bool` is the two-element `Fintype`, so this is `case` and nothing new; the
incumbent's `gateT` is this with `f = ret ()`. -/
def caseB (e : Expr Γ Bool) (t f : Plan Γ A) : Plan Γ A :=
  .case .bool e (fun b => cond b t f)

end Plan

/-! ## The finite classifier of a verdict

`VTag` itself is declared above, beside `Tag`, because `Plan.case` names it. -/

/-- **Morphism equation.** `[[Verdict.tag]]` is the classifying map onto the
three-element tag set: refusal to `declined`, the unit to `approve`, and every
nonempty product of objections to `object`. Solved, not checked: the definition
is the case split the equation asks for, in the only order that is decidable. -/
def Verdict.tag (v : Verdict) : VTag :=
  if v = Verdict.declined then .declined else if v = Verdict.approve then .approve else .object

/-- Approval is not refusal: the unit of the verdict monoid is not its zero. -/
theorem Verdict.approve_ne_declined : Verdict.approve ≠ Verdict.declined :=
  fun h => Verdict.not_approved_declined h.symm

@[simp] theorem Verdict.tag_declined : Verdict.tag Verdict.declined = .declined := by
  simp [Verdict.tag]

@[simp] theorem Verdict.tag_approve : Verdict.tag Verdict.approve = .approve := by
  simp [Verdict.tag, Verdict.approve_ne_declined]

/-- …and every nonempty product of objections to `object` — the third leg of
the classifier, so that all three tags are reached by name. -/
@[simp] theorem Verdict.tag_object (ob : Objection) (obs : List Objection) :
    Verdict.tag (Verdict.object (ob :: obs)) = .object := by
  have h1 : Verdict.object (ob :: obs) ≠ Verdict.declined :=
    Verdict.object_ne_declined _
  have h2 : Verdict.object (ob :: obs) ≠ Verdict.approve := fun h =>
    List.cons_ne_nil ob obs ((Verdict.approved_object_iff (ob :: obs)).mp h)
  simp [Verdict.tag, h1, h2]

/-- The tag says `approve` exactly when the verdict approves — the classifier is
faithful about the only distinction a panel's reducer makes. -/
theorem Verdict.tag_eq_approve_iff (v : Verdict) :
    Verdict.tag v = .approve ↔ Verdict.Approved v := by
  by_cases h₁ : v = Verdict.declined
  · subst h₁; simp [Verdict.tag, Verdict.not_approved_declined]
  · by_cases h₂ : v = Verdict.approve
    · subst h₂; simp
    · simp [Verdict.tag, Verdict.Approved, h₁, h₂]

/-- `[[approvedB v]] = decide (Approved v)`: the decidable tag a `caseB`
branches on. Decidable because `Verdict` has decidable equality, which is also
what makes the per-run certificate a `Bool` rather than a proposition. -/
def Verdict.approvedB (v : Verdict) : Bool := decide (v = Verdict.approve)

@[simp] theorem Verdict.approvedB_eq_true_iff (v : Verdict) :
    Verdict.approvedB v = true ↔ Verdict.Approved v := by
  simp [Verdict.approvedB, Verdict.Approved]

namespace Plan

variable {Γ Δ : Ctx} {A B C : Type}

/-- Branching on a verdict's tag: `case` at the finite classifier, with the
verdict itself still available to every arm as an expression. -/
def caseV (e : Expr Γ Verdict) (arms : VTag → Plan Γ A) : Plan Γ A :=
  .case .vtag (fun γ => Verdict.tag (e γ)) arms

/-! ## Panels -/

/-- The verdict monoid, at the code that carries it: `El .verdict` is `Verdict`,
so a panel of verdicts reduces with the monoid `Verdict` already has. Declared
because instance search does not unfold `El`, and declared **only** at
`.verdict`: nothing here installs arithmetic on `El .flag = Bool`. -/
instance instMonoidElVerdict : Monoid (El .verdict) := inferInstanceAs (Monoid Verdict)

/-- `[[panel ps]]` = ask each member of the panel and combine the replies with
the monoid.

Derived, in one line, from `zipWith` and the monoid — there is no `panelT`, no
`parT` and no reducer parameter beyond the `Monoid` instance, because "everyone
approved" is `Verdict.Approved`'s morphism into conjunction (§3 q6) and quorum
is a morphism out of `(ℕ, +)`. Its two morphism equations, proved in
`Denote.lean`, are the ones that matter:

```
run   ω (denote (panel ps) γ) = (ps.map (fun p => run   ω (denote p γ))).prod
trace ω (denote (panel ps) γ) = (ps.map (fun p => trace ω (denote p γ))).flatten
```

— the value is a `foldMap` into the monoid, and the transcript is the
concatenation, in order. "Parallel" is a fact about a runtime; what is semantic
is exactly how much of a panel survives reordering, and the answer is: the
approval decision (`approved_panel_perm`), the transcript up to permutation
(`trace_panel_perm`) and the bill in a commutative carrier
(`billFresh_panel_perm`) — but *not* the aggregate verdict, whose monoid is
noncommutative because an objection list is a record. -/
def panel [Monoid (El c)] (ps : List (Plan Γ (El c))) : Plan Γ (El c) :=
  ps.foldr (zipWith (· * ·)) (.ret (fun _ => 1))

@[simp] theorem panel_nil [Monoid (El c)] :
    panel ([] : List (Plan Γ (El c))) = .ret (fun _ => 1) := rfl

@[simp] theorem panel_cons [Monoid (El c)] (p : Plan Γ (El c)) (ps : List (Plan Γ (El c))) :
    panel (p :: ps) = zipWith (· * ·) p (panel ps) := rfl

/-- `[[panelText parts]]` = `panel`'s twin at `.text`: the same fan-out, the same
one question per member, the same trace, and a different fold. `panel` folds
into the verdict monoid; `panelText` folds into the free monoid over **fenced
blocks**, in member order, so the result is a document whose reader can tell
which member said what.

The monoid is `(String, ++, "")` *after* each member's answer has been wrapped
by `Dsl.block`. Associative, non-commutative, and — the property that matters,
and the one `panel` also has — `doc (ms ++ ns) = doc ms ++ doc ns`, so a fan
split in two and folded separately folds to the same document.

**No `Monoid (El .text)` instance is installed**, and for a sharper reason than
`panel`'s docstring gives at `.flag`: an instance at `.text` would make
`Plan.panel` typecheck at `.text` and fold member answers *unfenced*, giving the
language two ways to fold a text fan, one of which throws away the names.
`panelText` is written out so that there is exactly one.

Derived from `zipWith`, so it is `graft`-based, reaches no `dyn`, and is
invisible to `Level`, `Cost` and `Explain` — it is ordinary nodes by the time
any fold sees it. With *n* members: `askNodes` is *n*, `size` is *n + 1*, the
rung is `batch` if every member's prompt is closed, and the path count does not
move. The **trace** holds *n* events carrying each member's raw reply verbatim,
and the fenced document appears nowhere in it: the trace is what was asked and
what was answered; the document is what the program then computed. -/
def panelText (parts : List (String × Plan Γ (El .text))) : Plan Γ (El .text) :=
  parts.foldr
    (fun p acc => zipWith (fun a rest => String.append (Dsl.block p.1 a) rest) p.2 acc)
    (.ret (fun _ => ""))

@[simp] theorem panelText_nil :
    panelText ([] : List (String × Plan Γ (El .text))) = .ret (fun _ => "") := rfl

@[simp] theorem panelText_cons (p : String × Plan Γ (El .text))
    (ps : List (String × Plan Γ (El .text))) :
    panelText (p :: ps)
      = zipWith (fun a rest => String.append (Dsl.block p.1 a) rest) p.2 (panelText ps) := rfl

/-! ## Bounded revision -/

/-- `[[revising check revise n a]]` = check the artefact `a`; if it is approved,
stop with it; otherwise revise it and go again, at most `n` times; if the last
check still objects, hand back the candidate it ran out holding, marked
unsettled.

**The ending carries the candidate** (D3). The result is `El c × Bool` — *the
candidate always, and whether it settled* — and not `Option (El c)`: on
exhaustion the loop is holding the artefact the `n`-th amendment produced and
the `n+1`-th review objected to, and the `Option` threw it away. It is not the
candidate that *would have been* produced by amending in response to the final
objection, which was never asked for and must not be invented. A product of an
answer and a tag costs nothing structurally, because `A` is `PlanF`'s parameter
rather than an index, and `Bool` is already a `Tag`; so not one term node moves
against the `Option` spelling, and `size`, `askNodes` and `costM` cannot see the
change.

**Check first, revise in the recursive call** (kernel §3 q5, `attack-adequacy`
A1). `revising … n` **writes** `n + 1` checks and `n` revisions into the term,
and never pays for a revision it does not check — which is what "revise up to
twice" means in English and what three independent derivations in the dossier
got backwards. What a *run* performs is a range and not a number: the loop
reviews first and stops the moment a review approves, so a run performs between
**one** and `n + 1` checks and at most `n` revisions. Approval on the first
round performs exactly one — read it off the `n + 1` clause below, whose
`caseB` takes the `.ret` arm without reaching the recursive call.
`Acceptance.trace_upToTwice_stubborn` in `Denote.lean` is the machine-checked
statement of the transcript at the other end of that range, where no review ever
approves.

Derived: `Nat.rec` in the metalanguage building an unrolled plan, so the meaning
of a bounded loop is its unrolling — no fuel index, no truncated star, no `ℕ∞`.
The objections are threaded: `revise` receives the artefact *and* the verdict,
so a revision knows what it is answering.

**The `n` is a bound on the elaboration, and this definition does not enforce
one.** `Nat.rec` here is unguarded: `revising check revise n` builds a term
whose size grows with `n`, so an `n` a hostile source names is an *elaboration*
cost and not merely a large result, and nothing in this module refuses it. The
obligation is discharged one layer up and only there: `Dsl.maxRevisions`
(`Agentic/Core/Dsl/Check.lean`) caps it at 64, `Dsl.checkLoopParts` refuses a
larger numeral **before** elaborating anything, and `Dsl.checkProgram` runs
`Dsl.overRevised` over the raw syntax first so the refusal lands at the
offending line. A caller that applies `revising` directly — a hand-built `Plan`,
a future surface — inherits that obligation and gets no guard from here (obr
`acat-1t1`). -/
def revising {Γ : Ctx} {c : Code}
    (check : Cont Γ (El c) Verdict)
    (revise : Cont Γ (El c × Verdict) (El c)) :
    Nat → Cont Γ (El c) (El c × Bool)
  | 0 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        .ret (fun θ => (a (τ θ), Verdict.approvedB (v θ)))
  | n + 1 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        caseB (fun θ => Verdict.approvedB (v θ))
          (.ret (fun θ => (a (τ θ), true)))
          (graft (revise _ (Sub.comp σ τ) (fun θ => (a (τ θ), v θ))) fun _ ρ a' =>
            revising check revise n _ (Sub.comp (Sub.comp σ τ) ρ) a')

/-- `[[revisingOn check revise n a]]` = the same bounded revision, whose round
reads the review's **verdict tag** three ways rather than one predicate two
ways: approval settles, an objection buys another trip (or, at the last round,
leaves the loop unsettled), and a refusal **abandons** it at once.

`revising` tests `Verdict.approvedB`, so `object` and `declined` are the same
thing to it — a refusal buys a trip it should end. `revisingOn` branches on
`Verdict.tag`, the finite classifier `caseV` already uses, and maps its three
values onto three fates.

Note the base clause needs **no** `case`: the ending is a pure function of the
verdict, so round `n` is one `ret`, exactly as `revising`'s is. What the extra
exit edge costs is leaves: `L 0 = 1` and `L (k+1) = L k + 2` — the approve-`ret`
and the declined-`ret` — so an unrolled `revisingOn … n` has **`2n+1`** leaves
against `revising`'s `n+1`, and the consuming exit is replicated once per leaf.
`maxQuestions` is checked against that count, so a `revisingOn` with a wide tail
reaches the budget refusal at roughly half the bound a `revising` does. -/
def revisingOn {Γ : Ctx} {c : Code}
    (check : Cont Γ (El c) Verdict)
    (revise : Cont Γ (El c × Verdict) (El c)) :
    Nat → Cont Γ (El c) (El c × Ending)
  | 0 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        .ret (fun θ => (a (τ θ), Ending.ofVTag (Verdict.tag (v θ))))
  | n + 1 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        caseV v (fun t =>
          match t with
          | .approve => .ret (fun θ => (a (τ θ), Ending.settled))
          | .declined => .ret (fun θ => (a (τ θ), Ending.abandoned))
          | .object =>
              graft (revise _ (Sub.comp σ τ) (fun θ => (a (τ θ), v θ))) fun _ ρ a' =>
                revisingOn check revise n _ (Sub.comp (Sub.comp σ τ) ρ) a')

end Plan

end Agentic.Core
