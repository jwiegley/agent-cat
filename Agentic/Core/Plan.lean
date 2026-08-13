import Agentic.Core.Dlg
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
part: a question's **words** are built by an `Expr`, an ordinary function of the
answers in scope, while the question's **shape** — who is asked, under what
scope, at which draw — is written in the term. That split is what keeps a
content-dependent prompt below the monadic rung *and* keeps the cost of the
conversation readable off the term (`Agentic/Core/Cost.lean`, C2).

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

/-! ## Contexts, environments, variables -/

/-- `[[Ctx]]` = what is known so far, as a list of answer codes — innermost
binding first, so de Bruijn index `0` is the most recently received answer.

A list of `Code`s and not of types: the context can only hold things an
addressee actually said, which is what keeps `Env Γ` in `Type 0` and the whole
syntax first-order. -/
abbrev Ctx : Type := List Code

/-- `[[Env Γ]]` = a point of the product `∏ c ∈ Γ, El c`: one actual answer for
each code the context records. -/
inductive Env : Ctx → Type where
  /-- The empty environment: nothing has been answered yet. -/
  | nil : Env []
  /-- One more answer, in front of the rest. -/
  | cons {c : Code} {Γ : Ctx} (x : El c) (γ : Env Γ) : Env (c :: Γ)

namespace Env

variable {c : Code} {Γ : Ctx}

/-- The most recent answer. -/
def head : Env (c :: Γ) → El c
  | .cons x _ => x

/-- Everything but the most recent answer. -/
def tail : Env (c :: Γ) → Env Γ
  | .cons _ γ => γ

@[simp] theorem head_cons (x : El c) (γ : Env Γ) : (Env.cons x γ).head = x := rfl

@[simp] theorem tail_cons (x : El c) (γ : Env Γ) : (Env.cons x γ).tail = γ := rfl

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
(`denote_sub`) is one line as a result. -/
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
`[[lift σ]] = fun δ => δ.head ∷ σ δ.tail`. -/
abbrev lift (σ : Sub Γ Δ) : Sub (c :: Γ) (c :: Δ) := fun δ => .cons δ.head (σ δ.tail)

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
context morphism is applied before or after. -/
@[simp] theorem wk_lift (σ : Sub Γ Δ) :
    comp (wk (c := c)) (lift σ) = comp σ (wk (c := c)) := rfl

end Sub

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

`Type 1` because `case` and `dyn` quantify over a `Type`; `A` itself is a
`Type`, so `denote` lands in `Dlg A : Type` and nothing about the meaning moves
up a universe. -/
inductive Plan : Ctx → Type → Type 1 where
  /-- The unit: answer with a pure function of what is known. -/
  | ret {Γ : Ctx} {A : Type} (e : Expr Γ A) : Plan Γ A
  /-- **Ask a closed question and bind the answer.** The generator, and the only
  effect. Its question mentions nothing in scope, which is what gives a
  `Const S`-valued analysis a domain — the batch rung is recorded in the term or
  it is not well defined (kernel §2.3, `attack-adequacy` F1). -/
  | askC {Γ : Ctx} {A : Type} (c : Code) (q : Q c) (k : Plan (c :: Γ) A) : Plan Γ A
  /-- **Ask a question whose *words* are built from the answers so far, and bind
  the answer.** The node the domain forces: the guide's text goes into the
  reviewer's prompt, the draft into the review, the objections into the
  revision. Ask-and-bind in one former, so the syntax is already A-normal and no
  analysis has to reconstruct where an answer went.

  **The shape is term-level data and only the prompt is an expression**, which
  is the whole of the kernel's C2. `Q c ≅ Q.Shape c × String`; the addressee,
  the scope and the draw are written by the author in the term `s`, and the
  answer flows into the words and nowhere else — not because a predicate on the
  term says so, but because there is no place in the node for it to flow. The
  shape sequence of a `pipeline` plan is therefore a *projection of the syntax*
  (`shapes_eq_of_le_pipeline`, which carries no hypothesis). -/
  | ask {Γ : Ctx} {A : Type} (c : Code) (s : Q.Shape c) (e : Expr Γ String)
      (k : Plan (c :: Γ) A) : Plan Γ A
  /-- **Finite-tag branching, both arms in the term.** `Selective.branch`, with
  the payload riding in the context into whichever arm is taken. `T` is a
  `FinEnum`, so the branch structure is a genuine finite tree and the cost of
  the not-taken arm is enumerable rather than lost.

  **`FinEnum` and not `Fintype`, for one reason and it is recorded here.**
  Mathlib's `Fintype` holds a `Finset`, a `Finset` holds a `Multiset`, and a
  `Multiset` is a quotient — so a syntax whose `case` node mentions `Fintype`
  depends on `propext` and `Quot.sound` *as a type*, before any theorem about it
  is stated. `Agentic/Core/Certify.lean` claims an empty axiom set for
  `certify_sound`, and that claim is about the whole transitive graph, of which
  this constructor is a part. `FinEnum` says the same thing — a bijection with
  `Fin n` — out of `Fin`, `Equiv` and `List`, none of which is a quotient, and
  Mathlib derives `Fintype` from it (priority 100), so every `Finset.univ` in
  `Agentic/Core/Level.lean` and `Agentic/Core/Cost.lean` is unchanged. The
  enumeration adds an order that the semantics does not read; nothing below
  branches on it. -/
  | case {Γ : Ctx} {A : Type} {T : Type} [FinEnum T] [DecidableEq T]
      (e : Expr Γ T) (arms : T → Plan Γ A) : Plan Γ A
  /-- **Quarantined: a plan computed from an unbounded answer.** The one
  higher-order node, kept because directive (1) asks for it and no finite tag
  can reach it. Its presence is what makes a plan dynamic, and the absence of an
  analysis homomorphism here is a theorem to be proved rather than a hole to be
  papered over. -/
  | dyn {Γ : Ctx} {A : Type} {B : Type} (e : Expr Γ B) (f : B → Plan Γ A) : Plan Γ A

/-- The two-element tag type, enumerated, so that `Plan.caseB` is `Plan.case` at
`Bool` and nothing new. Mathlib has `Fintype Bool` but no `FinEnum Bool`.

**`scoped`, because `Bool` is not this package's type.** `test/Pollution.lean`
exists to keep this package from making claims about `Bool`, `Prop` and `ℕ` on
everyone who transitively imports it; a `scoped` instance is a claim made only
where the package's vocabulary has been opened, which is the smallest scope in
which `caseB` can be written at all. -/
scoped instance instFinEnumBool : FinEnum Bool :=
  FinEnum.ofList [false, true] (by decide)

namespace Plan

variable {Γ Δ Θ : Ctx} {A B C : Type}

/-! ## Renaming and substitution: `Plan` is a presheaf on contexts -/

/-- `[[sub p σ]]` = `p` read in a bigger (or otherwise related) context.

**Morphism equation** (`denote_sub`, proved in `Denote.lean`):
`denote (sub p σ) δ = denote p (σ δ)`. Weakening and substitution are the same
operation here, because a context morphism is a function on environments. -/
def sub {A : Type} : {Γ Δ : Ctx} → Plan Γ A → Sub Γ Δ → Plan Δ A
  | _, _, .ret e, σ => .ret (fun δ => e (σ δ))
  | _, _, .askC c q k, σ => .askC c q (sub k (Sub.lift σ))
  | _, _, .ask c s e k, σ => .ask c s (fun δ => e (σ δ)) (sub k (Sub.lift σ))
  | _, _, @Plan.case _ _ T fT dT e arms, σ =>
      @Plan.case _ _ T fT dT (fun δ => e (σ δ)) (fun t => sub (arms t) σ)
  | _, _, .dyn e f, σ => .dyn (fun δ => e (σ δ)) (fun b => sub (f b) σ)

/-- Renaming along the identity is the identity: the first functor law of the
presheaf `Γ ↦ Plan Γ A`. -/
@[simp] theorem sub_id (p : Plan Γ A) : sub p Sub.id = p := by
  induction p with
  | ret e => rfl
  | askC c q k ih => simp only [sub, Sub.lift_id, ih]
  | ask c s e k ih => simp only [sub, Sub.lift_id, ih]
  | case e arms ih => simp only [sub]; exact congrArg _ (funext fun t => ih t)
  | dyn e f ih => simp only [sub]; exact congrArg _ (funext fun b => ih b)

/-- Renaming composes: the second functor law. -/
theorem sub_comp (p : Plan Γ A) (σ : Sub Γ Δ) (τ : Sub Δ Θ) :
    sub (sub p σ) τ = sub p (Sub.comp σ τ) := by
  induction p generalizing Δ Θ with
  | ret e => rfl
  | askC c q k ih => simp only [sub, Sub.lift_comp]; exact congrArg _ (ih _ _)
  | ask c s e k ih => simp only [sub, Sub.lift_comp]; exact congrArg _ (ih _ _)
  | case e arms ih => simp only [sub]; exact congrArg _ (funext fun t => ih t _ _)
  | dyn e f ih => simp only [sub]; exact congrArg _ (funext fun b => ih b _ _)

/-! ## Scope: `under σ` is a fold and a monoid action -/

/-- `[[under σ p]]` = `p` with every question relabelled by `σ`.

**Morphism equation** (`denote_under`, proved in `Denote.lean`):
`denote (under σ p) γ = Dlg.under σ (denote p γ)` — the plan-level scope
operator is the dialogue-level one, transported along the meaning. A *fold*,
defined where the recursion's target lives, and not a constructor: the
package's own no-weakening-constructor rule is what condemns `scopeT`. -/
def under {A : Type} (σ : Sig) : {Γ : Ctx} → Plan Γ A → Plan Γ A
  | _, .ret e => .ret e
  | _, .askC c q k => .askC c (σ.onQ c q) (under σ k)
  | _, .ask c s e k => .ask c (σ c s) e (under σ k)
  | _, @Plan.case _ _ T fT dT e arms => @Plan.case _ _ T fT dT e (fun t => under σ (arms t))
  | _, .dyn e f => .dyn e (fun b => under σ (f b))

/-- **Action law 1**: `under 1 = id`. -/
@[simp] theorem under_idSig (p : Plan Γ A) : under idSig p = p := by
  induction p with
  | ret e => rfl
  | askC c q k ih => simp only [under, idSig_onQ, ih]
  | ask c s e k ih => simp only [under, idSig, ih]
  | case e arms ih => simp only [under]; exact congrArg _ (funext fun t => ih t)
  | dyn e f ih => simp only [under]; exact congrArg _ (funext fun b => ih b)

/-- **Action law 2**: `under σ ∘ under τ = under (σ ∘ τ)`. With `under_idSig`
this says relabellings act on plans; it is `Agentic.actR_compose` at this
carrier, and it is the whole of the scope algebra at the syntax. -/
theorem under_under (σ τ : Sig) (p : Plan Γ A) :
    under σ (under τ p) = under (compSig σ τ) p := by
  induction p with
  | ret e => rfl
  | askC c q k ih => simp only [under, compSig_onQ, ih]
  | ask c s e k ih => simp only [under, compSig, ih]
  | case e arms ih => simp only [under]; exact congrArg _ (funext fun t => ih t)
  | dyn e f ih => simp only [under]; exact congrArg _ (funext fun b => ih b)

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
  | askC c q k ih => simp only [sub, under]; exact congrArg _ (ih _)
  | ask c s e k ih => simp only [sub, under]; exact congrArg _ (ih _)
  | case e arms ih => simp only [sub, under]; exact congrArg _ (funext fun t => ih t _)
  | dyn e f ih => simp only [sub, under]; exact congrArg _ (funext fun b => ih b _)

/-! ## Sequencing is grafting -/

/-- `[[Cont Γ A B]]` = a continuation that can be grafted onto every leaf of a
`Γ`-plan: for each context `Δ` the leaf might sit in, a way of reading `Γ` back
out of it and an `A`-valued expression there, it gives a `Δ`-plan.

Context-polymorphic because the leaves of a plan do *not* all sit in `Γ`: each
`ask` on the way to a leaf has bound one more answer. The `Sub Γ Δ` argument is
how a continuation written against `Γ` reaches the leaf, and the `Expr Δ A` is
the value the leaf produced — as an expression, not as a value, which is
precisely why grafting need not go through `dyn`. -/
abbrev Cont (Γ : Ctx) (A B : Type) : Type 1 := ∀ Δ : Ctx, Sub Γ Δ → Expr Δ A → Plan Δ B

/-- `[[graft p k]]` = `p` with every `ret` leaf replaced by `k` at that leaf.

**This is sequencing, and it is substitution, not a constructor** (kernel §2.4:
"`>>=` is substitution"). Its morphism equation is `denote_graft` in
`Denote.lean`: if the continuation means the semantic continuation `K` at every
leaf, then `denote (graft p k) γ = denote p γ >>= fun a => K a γ`. Grafting is
strictly more general than `bind`, because the leaf's continuation may also read
the answers bound between the root and the leaf — which is what `bind` cannot
see and what makes a plan a *term* rather than a tree of closures. -/
def graft {B : Type} : {Γ : Ctx} → {A : Type} → Plan Γ A → Cont Γ A B → Plan Γ B
  | _, _, .ret e, k => k _ Sub.id e
  | _, _, .askC c q p, k => .askC c q (graft p (fun Δ σ e => k Δ (Sub.comp Sub.wk σ) e))
  | _, _, .ask c s d p, k => .ask c s d (graft p (fun Δ σ e => k Δ (Sub.comp Sub.wk σ) e))
  | _, _, @Plan.case _ _ T fT dT d arms, k =>
      @Plan.case _ _ T fT dT d (fun t => graft (arms t) k)
  | _, _, .dyn d f, k => .dyn d (fun b => graft (f b) k)

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
def bindP (p : Plan Γ A) (k : A → Plan Γ B) : Plan Γ B :=
  graft p (fun _ σ e => .dyn e (fun a => sub (k a) σ))

/-! ## Authoring forms -/

/-- `[[askC1 c q]] = Dlg.ask1 c q`: put a closed question and answer with the
reply. -/
def askC1 (c : Code) (q : Q c) : Plan Γ (El c) := .askC c q (.ret (Expr.var .here))

/-- `[[ask1 c s e]]` = put the question of shape `s` whose words `e` builds from
what is known, and answer with the reply. -/
def ask1 (c : Code) (s : Q.Shape c) (e : Expr Γ String) : Plan Γ (El c) :=
  .ask c s e (.ret (Expr.var .here))

/-- `[[caseB e t f]] = if e then t else f`, with **both** arms in the term.
`Bool` is the two-element `Fintype`, so this is `case` and nothing new; the
incumbent's `gateT` is this with `f = ret ()`. -/
def caseB (e : Expr Γ Bool) (t f : Plan Γ A) : Plan Γ A :=
  .case e (fun b => cond b t f)

end Plan

/-! ## The finite classifier of a verdict -/

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

/-- The three tags, enumerated. Written out rather than derived because `case`
asks for a `FinEnum` and there is no `deriving FinEnum`; `Fintype VTag` comes
back from Mathlib's `FinEnum`-to-`Fintype` instance, so nothing downstream
notices. -/
instance instFinEnumVTag : FinEnum VTag :=
  FinEnum.ofList [.approve, .object, .declined] (by intro t; cases t <;> simp)

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
  .case (fun γ => Verdict.tag (e γ)) arms

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

/-! ## Bounded revision -/

/-- `[[revising check revise n a]]` = check the artefact `a`; if it is approved,
stop with it; otherwise revise it and go again, at most `n` times; if the last
check still objects, give up with `none`.

**Check first, revise in the recursive call** (kernel §3 q5, `attack-adequacy`
A1). `revising … n` performs `n + 1` checks and at most `n` revisions, and never
pays for a revision it does not check — which is what "revise up to twice"
means in English and what three independent derivations in the dossier got
backwards. `Acceptance.trace_upToTwice_stubborn` in `Denote.lean` is the
machine-checked statement of the resulting transcript.

Derived: `Nat.rec` in the metalanguage building an unrolled plan, so the meaning
of a bounded loop is its unrolling — no fuel index, no truncated star, no `ℕ∞`.
The objections are threaded: `revise` receives the artefact *and* the verdict,
so a revision knows what it is answering. -/
def revising {Γ : Ctx} {c : Code}
    (check : Cont Γ (El c) Verdict)
    (revise : Cont Γ (El c × Verdict) (El c)) :
    Nat → Cont Γ (El c) (Option (El c))
  | 0 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        .ret (fun θ => if Verdict.approvedB (v θ) then some (a (τ θ)) else none)
  | n + 1 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        caseB (fun θ => Verdict.approvedB (v θ))
          (.ret (fun θ => some (a (τ θ))))
          (graft (revise _ (Sub.comp σ τ) (fun θ => (a (τ θ), v θ))) fun _ ρ a' =>
            revising check revise n _ (Sub.comp (Sub.comp σ τ) ρ) a')

end Plan

end Agentic.Core
