import Agentic.Term
import Agentic.Gate
import Agentic.Scope
import Agentic.Env

/-!
# The meaning stratum: two folds over one syntax, and the quotient by one of them

Design §3 and §4. `Agentic.Term` is a *written* workflow and `Agentic.Mat` is a
resource-weighted transition, and until this module they were two strata that
did not touch. Here they meet, twice:

* `muS` — the **quantitative** meaning `⟦·⟧_S`, a fold from a term to a matrix
  over a complete resource semiring. Every clause *is* one row of the design's
  §4 table, so the type-class-morphism equations are true by construction and
  the theorems that state them (`muS_seqT`, `muS_parT`, …) are `rfl`.

* `muExt` — the **extensional** meaning `⟦·⟧_ext`, a fold from a term to a
  partial function, per sample point. This is the one that fixes equality
  (§3), and `WEq` below is its kernel; `Workflow` is the quotient.

The two are genuinely two, and this module ends by proving one half of it
rather than saying it: `one_add_one_of_muS_respects_WEq` shows that a
quantitative meaning which respected extensional equality would force
`1 + 1 = 1` in the carrier — a semiring that cannot count.

What that does *not* buy is a fibration. As the two folds stand there is **no
projection between them in either direction**, because the equalities are
incomparable rather than nested. `muS` does not respect `WEq` (the theorem
just named), so there is no map from the quotient by `WEq` down to matrices;
and `WEq` does not respect equality of `muS` either, since `gateT true t` and
`t` — likewise `scopeT unit t` and `t` — have literally the same matrix
(`muS_gateT_true`, `muS_scopeT_unit`) while `WEq` in general does not identify
them: the extra `gate`/`scope` step shifts every consultation key beneath, and
a key-sensitive runner over a consulting body sees the shift. Neither equality
refines the other, so neither meaning is a quotient or a fibre of the other,
and none can be added until `WEq` is coarsened to key-renaming invariance
(acat-5b7). Only after that coarsening is a `π` between them a question with
an answer.

## The signature of `muS`, and why it carries a scope

The design's §5.3 row is `⟦scope g f⟧ h = ⟦f⟧ (h ⊕ g)`: a scoped meaning is a
*function awaiting its scope*, and entering a scope is precomposition. So the
target of the quantitative fold is not `Mat S i o` but `Scoped G (Mat S i o)`,
the reader of `Agentic.Scope`, and the `scopeT` clause is `withScope`, which is
`actR` — the monoid's right action, imported rather than re-derived. Two
consequences are then theorems instead of interpreter rules: nesting composes
covariantly with the *outer* scope on the left (`muS_scopeT_scopeT`), and
innermost-wins is `Agentic.Scope.innermost_wins` applied to a meaning.

`Op` carries no scope hook — the syntax is deliberately ignorant of what a
leaf means — so the leaf interpretation takes the scope in force as its first
argument: `Interp Op G S := G → {a b} → Op a b → Mat S a b`. That is the
honest v1: a leaf's matrix may depend on the model, temperature or backend the
scope names, which is the entire point of having scopes, and nothing weaker
would let `scopeT` do any work at all.

## What the fold does *not* yet charge for

`shareT` is **quantitatively transparent** here: `muS (shareT l t) = muS t`.
That is honest for v1 and it is not the end of the story. §6a's distinction
has two halves — extensionally the shared and the duplicated term consult
different indices, and that half is discharged by `muExt` below
(`muExt_dupPair_ne_sharedPair`); quantitatively "share costs one, dup costs
two", and charging that requires the fold to know *which sites a term
consults* so that repeated sites are paid for once. A matrix has no room to
record a site, so the quantitative half needs either a site-indexed carrier
(the free semimodule on `Key`) or a separate consultation-multiset fold whose
value is then charged. Neither is built here; the discovered work is recorded
on the tracker, and until it lands the quantitative layer over-charges sharing
by exactly the number of extra reads.
-/

namespace Agentic

namespace Term

/-! ## Stage 1 — the quantitative fold -/

/-- An `Interp Op G S` is a representation of *what the leaves mean*: given the
scope in force, each consultation leaf is read as a resource-weighted
transition.

The scope argument is what makes scoping do work. A leaf's matrix is allowed to
depend on the model, the temperature, the agent or the backend that the
enclosing `scopeT`s named — that dependence *is* the design's Reader row — and
since `Agentic.Term`'s `Op` deliberately knows nothing about scopes, the
dependence has to enter here. -/
def Interp (Op : Type → Type → Type) (G S : Type) : Type 1 :=
  G → {a b : Type} → Op a b → Mat S a b

/-- **The quantitative meaning** `⟦·⟧_S` of design §3: a structural fold from a
written workflow to a resource-weighted transition, awaiting the scope in
force.

Each clause is one row of the §4 table, so the type-class-morphism equations
hold *by construction* and the theorems below that state them are `rfl`:

| clause | matrix | design row |
|---|---|---|
| `prim op` | `interp g op` | the leaf, read under the scope in force |
| `pureT fn` | `Mat.pointMat fn` | Transform: a 0-1 point matrix |
| `seqT` | `Mat.comp` | Category — Chapman–Kolmogorov |
| `parT` | `Mat.kron` | juxtaposition |
| `sumT` | `Mat.matAdd` | Additive — alternatives |
| `choiceT` | `Mat.caseMat` | Choice through a decoded coproduct |
| `gateT b` | `Mat.gate (b = true)` | LeftSemimodule — refusal is `0` |
| `scopeT h` | `withScope h` | Reader — precomposition, `actR` |
| `shareT l` | transparent (v1) | §6a's quantitative half is owed |
| `retryT n` | `Mat.retryTrunc n` | fuel is the star's *truncation* |
| `fanT n` | `Mat.fanMat n` | bounded width, input truncated at `n` |
| `bindT` | `Mat.dependentSeq` | Monad — bind *is* composition |

Two of those rows are commitments kept rather than choices made. `retryT` is
`Mat.retryTrunc`, the truncated star, and never the unbounded `Star.retry`:
the fuel is syntax, the grade calls a fueled loop `static`, and an unbounded
star would make a `.static` term denote an unbounded cost. `fanT n`
truncates its input list at `n`, which is what makes the `bounded n` grade a
true statement about the meaning and not a decoration on it — see
`Mat.fanMat_eq_zero_of_length_gt` and `muS_fanT_zero`.

**The converse does not hold: not every §4 row has a clause here.** The table
above is a function from constructors to rows, not a bijection, and the rows
with no constructor are:

* **Identity.** There is no `idT`, so the Category row's unit is never taken.
  `Mat.pointMat_id` proves `pointMat id = idMat` in `Agentic.Matrix` and
  nothing in this fold connects to it; a syntactic identity would have to be
  written before the unit laws could even be stated.
* **The Additive zero.** `sumT` adds but there is no `zeroT` denoting
  `Mat.zeroMat`, so the additive monoid's unit is missing from the syntax
  (acat-1xo).
* **Panel and convolution.** `parT` is juxtaposition only; the n-ary panel
  with its reducer monoid, §5.1's convolution over the key monoid, has no
  constructor (acat-x9v).
* **Comonad / fork.** No `pinT` or `forkT`, so `Env.pin` and the derivative
  row of the design are unreachable from a written term (acat-vgz).
* **The lax-monoidal inequality.** §4's `⟦f ⊗ g⟧ ≤ ⟦f⟧ ⊗ ⟦g⟧` is an ordering
  statement; this fold has no order on it at all (see `muS_parT`).

Noncomputable, as everything downstream of `Mat.idMat` is: the identity, the
point matrix and the indicator all decide equality classically. -/
noncomputable def muS {Op : Type → Type → Type} {G L S : Type}
    [CompleteCSemiring S] [PMonoid G] (interp : Interp Op G S) :
    ∀ {f : Frag} {i o : Type}, Term Op G L f i o → Scoped G (Mat S i o)
  | _, _, _, .prim op => fun g => interp g op
  | _, _, _, .pureT fn => fun _ => Mat.pointMat fn
  | _, _, _, .seqT t u => fun g => Mat.comp (muS interp t g) (muS interp u g)
  | _, _, _, .parT t u => fun g => Mat.kron (muS interp t g) (muS interp u g)
  | _, _, _, .sumT t u => fun g => Mat.matAdd (muS interp t g) (muS interp u g)
  | _, _, _, .choiceT t u => fun g => Mat.caseMat (muS interp t g) (muS interp u g)
  | _, _, _, .gateT b t => fun g => Mat.gate (b = true) (muS interp t g)
  | _, _, _, .scopeT h t => withScope h (muS interp t)
  | _, _, _, .shareT _ t => muS interp t
  | _, _, _, .retryT n t => fun g => Mat.retryTrunc n (muS interp t g)
  | _, _, _, .fanT n t => fun g => Mat.fanMat n (muS interp t g)
  | _, _, _, .bindT t k =>
      fun g => Mat.dependentSeq (muS interp t g) (fun b => muS interp (k b) g)

section Equations

variable {Op : Type → Type → Type} {G L S : Type}
  [CompleteCSemiring S] [PMonoid G] (interp : Interp Op G S)

/-- **The leaf row**: a consultation denotes whatever the interpretation says
it denotes *under the scope in force*. -/
theorem muS_prim {i o : Type} (op : Op i o) (g : G) :
    muS (L := L) interp (.prim op) g = interp g op := rfl

/-- **The Transform row**: a plain function denotes its 0-1 point matrix. A
`Transform` consults nothing, so it has no scope dependence and costs
nothing. -/
theorem muS_pureT {i o : Type} (fn : i → o) (g : G) :
    muS (Op := Op) (L := L) interp (.pureT fn) g = Mat.pointMat fn := rfl

/-- **The Category row**, with the argument order stated rather than assumed.
The design writes the product as `⟦g ∘ f⟧ = ⟦f⟧ · ⟦g⟧`, diagrammatic order on
the right; `Mat.comp M N` takes `M : Mat ι κ` first and `N : Mat κ ν` second,
so the Lean statement below reads *f-then-g*: the first-run stage is
`Mat.comp`'s first argument. It is the same equation with the operands
flipped into pipeline order, and reading `Mat.comp` as `∘` would invert it. -/
theorem muS_seqT {f g' : Frag} {i j o : Type}
    (t : Term Op G L f i j) (u : Term Op G L g' j o) (g : G) :
    muS interp (.seqT t u) g = Mat.comp (muS interp t g) (muS interp u g) := rfl

/-- **The binary half of the juxtaposition row**: two workflows side by side
denote the Kronecker product of their matrices. Equality, not the design's
inequality, because at this level there is no world to share: the lax
structure map of §4 is about world-threading, which this fold does not carry —
so the lax-monoidal `≤` is not witnessed here, it is absent.

This is not the whole §5.1 row either. `parT` is the binary tensor; the n-ary
panel, with its reducer monoid and convolution fan-in, has no constructor to
denote (acat-x9v). -/
theorem muS_parT {f g' : Frag} {i j k l : Type}
    (t : Term Op G L f i j) (u : Term Op G L g' k l) (g : G) :
    muS interp (.parT t u) g = Mat.kron (muS interp t g) (muS interp u g) := rfl

/-- **The Additive row**: `⟦f ⊕ g⟧ = ⟦f⟧ + ⟦g⟧`. Alternatives are added, and in
particular the quantitative meaning of alternation is symmetric — which the
extensional fold below cannot be, and that difference is recorded there. -/
theorem muS_sumT {f g' : Frag} {i o : Type}
    (t : Term Op G L f i o) (u : Term Op G L g' i o) (g : G) :
    muS interp (.sumT t u) g = Mat.matAdd (muS interp t g) (muS interp u g) := rfl

/-- **The Choice row**: branching on a decoded coproduct denotes the coproduct
case matrix. -/
theorem muS_choiceT {f g' : Frag} {i j o : Type}
    (t : Term Op G L f i o) (u : Term Op G L g' j o) (g : G) :
    muS interp (.choiceT t u) g = Mat.caseMat (muS interp t g) (muS interp u g) := rfl

/-- **The LeftSemimodule row**: a guard denotes the scalar action of its
indicator. The `Bool → Prop` bridge is `b = true`, which is where a written
term's finite datum becomes the semantics' undecided proposition. -/
theorem muS_gateT {f : Frag} {i o : Type} (b : Bool) (t : Term Op G L f i o)
    (g : G) : muS interp (.gateT b t) g = Mat.gate (b = true) (muS interp t g) := rfl

/-- **The Reader row**: `⟦scope h f⟧ g = ⟦f⟧ (g ⊕ h)` — precomposition, with the
ambient scope `g` meeting the annotation `h` on the right, so that `h` is
innermost. -/
theorem muS_scopeT {f : Frag} {i o : Type} (h : G) (t : Term Op G L f i o) (g : G) :
    muS interp (.scopeT h t) g = muS interp t (g ⋄ h) := rfl

/-- **Sharing is quantitatively transparent, for now.** The v1 fold charges a
shared consultation exactly what it charges an unshared one, so `shareT` moves
no weight. What is *not* transparent is the extensional meaning, where the
labelled sites genuinely coincide (`muExt_shareT`, and the pair theorems
below): the two halves of §6a come apart here, and only one is paid. -/
theorem muS_shareT {f : Frag} {i o : Type} (l : L) (t : Term Op G L f i o) (g : G) :
    muS interp (.shareT l t) g = muS interp t g := rfl

/-- **The iteration row**, with the truncation the grade demands: a fueled
retry denotes the *truncated* star `(M_A · d)*` cut at the fuel, never the
unbounded one. -/
theorem muS_retryT {f : Frag} {i o : Type} (n : Nat)
    (t : Term Op G L f i (Sum o i)) (g : G) :
    muS interp (.retryT n t) g = Mat.retryTrunc n (muS interp t g) := rfl

/-- **The bounded-width row**: a fan denotes the truncating fan matrix. -/
theorem muS_fanT {f : Frag} {i o : Type} (n : Nat) (t : Term Op G L f i o) (g : G) :
    muS interp (.fanT n t) g = Mat.fanMat n (muS interp t g) := rfl

/-- **The Monad row**: `⟦w >>= k⟧ = ⟦w⟧ >>= ⟦·⟧ ∘ k`. Value-dependent
sequencing is `Mat.dependentSeq`, which *is* matrix composition
(`Mat.dependentSeq_eq_comp`) — the meaning space is monadic, and what full
bind costs is instruments, not meaning. -/
theorem muS_bindT {f g' : Frag} {i k o : Type}
    (t : Term Op G L f i k) (kf : k → Term Op G L g' PUnit o) (g : G) :
    muS interp (.bindT t kf) g
      = Mat.dependentSeq (muS interp t g) (fun b => muS interp (kf b) g) := rfl

end Equations

section ScopeLaws

variable {Op : Type → Type → Type} {G L S : Type}
  [CompleteCSemiring S] [PMonoid G] (interp : Interp Op G S)

/-- **Scoping composes covariantly**, at meanings: nesting `h₂` inside `h₁` is
entering the single scope `h₁ ⋄ h₂`, outer operand on the left. This is
`Scope.withScope_compose` — the theorem `Agentic.Scope` proved about the
action — read at the quantitative fold, and writing it with the operands
exchanged would be the classic §5.3 error and a false equation. -/
theorem muS_scopeT_scopeT {f : Frag} {i o : Type} (h₁ h₂ : G)
    (t : Term Op G L f i o) :
    muS interp (.scopeT h₁ (.scopeT h₂ t)) = withScope (h₁ ⋄ h₂) (muS interp t) :=
  withScope_compose h₁ h₂ (muS interp t)

/-- The empty scope changes no meaning. -/
theorem muS_scopeT_unit {f : Frag} {i o : Type} (t : Term Op G L f i o) :
    muS interp (.scopeT (PMonoid.unit : G) t) = muS interp t :=
  withScope_one (muS interp t)

end ScopeLaws

section Refusal

variable {Op : Type → Type → Type} {G L S : Type}
  [CompleteCSemiring S] [PMonoid G] (interp : Interp Op G S)

/-- **A shut gate denotes refusal**: `gateT false` is the zero matrix, whatever
it guards. The `Bool → Prop` bridge is what makes this a computation —
`false = true` is refuted by `Bool.noConfusion` — and the annihilation of `0`
through composition then propagates the refusal with no `Halt` and no
exception. -/
theorem muS_gateT_false {f : Frag} {i o : Type} (t : Term Op G L f i o) (g : G) :
    muS interp (.gateT false t) g = Mat.zeroMat :=
  Mat.gate_false (fun h => Bool.noConfusion h) _

/-- An open gate is no gate at all. -/
theorem muS_gateT_true {f : Frag} {i o : Type} (t : Term Op G L f i o) (g : G) :
    muS interp (.gateT true t) g = muS interp t g :=
  Mat.gate_true rfl _

/-- **A fan of no copies denotes the constant `[]`.** This is the observable
consequence `Agentic.Term.fanT` promised to state at the fold: the truncation
is not a convention of an interpreter, it is what `fanT 0` *means*, and no
input list can smuggle work past it. -/
theorem muS_fanT_zero {f : Frag} {i o : Type} (t : Term Op G L f i o) (g : G) :
    muS interp (.fanT 0 t) g = Mat.pointMat (fun _ : List i => ([] : List o)) :=
  Mat.fanMat_zero (muS interp t g)

/-- **The truncation is observable at every fan**: under `fanT n`, no output
list longer than `n` carries any weight. Together with the grade
`Frag.scale n`, this is what makes "at most `n` copies" a fact about the
meaning. -/
theorem muS_fanT_eq_zero_of_length_gt {f : Frag} {i o : Type} (n : Nat)
    (t : Term Op G L f i o) (g : G) (as : List i) (bs : List o)
    (h : n < bs.length) : muS interp (.fanT n t) g as bs = 0 :=
  Mat.fanMat_eq_zero_of_length_gt n (muS interp t g) as bs h

end Refusal

end Term

/-! ## Stage 1b — width as a term fold, checked against the grade

The grade index of `Agentic.Term` is a *claim* about a term's data-dependent
width. This section re-runs the same arithmetic as a fold over the term and
proves the two agree exactly. Both sides are syntax: the fold reads the term,
the index is computed by the constructors, and their agreement is a
homomorphism check between two ways of doing one piece of arithmetic. The
*semantic* width — consultations in flight at a run, peak over branches — is
not defined anywhere in this package, so the bound `peak t ≤ widthT t` that
would make the grade a statement about meaning is owed, and tracked as
acat-vbl.

Width is not a semiring factor — the design's §7 correction, "peak width is not
a semiring at all (its would-be one and zero coincide); it is a separate
monoid fold" — so `widthT` is a fold on the *term*, not a read-out of `muS`,
and it needs no carrier at all. Its target is `Option Nat`, `none` being the
honest answer of the monadic fragment: not "zero", not "unknown", but *there is
no a-priori width*, which is exactly what an opaque continuation forfeits.
-/

namespace Frag

/-- The width a grade claims: `static` claims zero data-dependent width,
`bounded n` claims at most `n`, and `monadic` claims nothing — `none` is the
a-priori silence of §4, not a numeral.

`static` and `bounded 0` are the two ways of writing "no data-dependent width"
(`Agentic.Frag`'s header), and this function identifies them, which is why the
agreement theorem below is an *equation* and not merely an inequality. -/
def width : Frag → Option Nat
  | static => some 0
  | bounded n => some n
  | monadic => none

/-- Widths of parts that are not in flight together: the larger one, silence
absorbing. This is the arithmetic of `join`. -/
def wMax : Option Nat → Option Nat → Option Nat
  | some a, some b => some (max a b)
  | _, _ => none

/-- Widths of parts that *are* in flight together: they add, silence
absorbing. This is the arithmetic of `par`. -/
def wAdd : Option Nat → Option Nat → Option Nat
  | some a, some b => some (a + b)
  | _, _ => none

/-- The width of `n` copies of a body: multiplicities multiply, the body
counting at least as one copy of itself (`max 1 m`, acat-l59). This is the
arithmetic of `scale`. -/
def wScale (n : Nat) : Option Nat → Option Nat
  | some m => some (n * max 1 m)
  | none => none

/-- Sequencing, alternation and branching claim the larger width. -/
theorem width_join (f g : Frag) : width (join f g) = wMax (width f) (width g) := by
  cases f <;> cases g <;> simp [width, join, wMax] <;> omega

/-- A tensor claims the sum of its branches' widths. -/
theorem width_par (f g : Frag) : width (par f g) = wAdd (width f) (width g) := by
  cases f <;> cases g <;> simp [width, par, wAdd]

/-- A fan claims the product of its multiplicity with its body's width, the
body counting at least once. -/
theorem width_scale (n : Nat) (f : Frag) : width (scale n f) = wScale n (width f) := by
  cases f <;> simp [width, scale, wScale]

end Frag

namespace Term

/-- **The width fold**: the width a written workflow claims, computed from the
term and nothing else. It is the grade's arithmetic re-run as a term fold, and
is intended to bound how many consultations can be outstanding at once — the
bound itself is owed (acat-vbl), since no semantic width is defined here.

`none` is the monadic fragment's honest answer — an opaque continuation has no
a-priori width, and the fold says so instead of inventing a number. Everything
else is the arithmetic the grade already fixed: sequencing and alternation take
the larger width, a tensor adds (both branches are in flight), a fan multiplies
by its multiplicity with the body counting at least once, and gates, scopes,
labels and fuel change no shape at all.

Note what is *not* here: no recursion into `bindT`'s continuation. There is
none to do — the continuation is an opaque function, so the fold is finite
precisely because it stops. -/
def widthT {Op : Type → Type → Type} {G L : Type} :
    ∀ {f : Frag} {i o : Type}, Term Op G L f i o → Option Nat
  | _, _, _, .prim _ => some 0
  | _, _, _, .pureT _ => some 0
  | _, _, _, .seqT t u => Frag.wMax (widthT t) (widthT u)
  | _, _, _, .parT t u => Frag.wAdd (widthT t) (widthT u)
  | _, _, _, .sumT t u => Frag.wMax (widthT t) (widthT u)
  | _, _, _, .choiceT t u => Frag.wMax (widthT t) (widthT u)
  | _, _, _, .gateT _ t => widthT t
  | _, _, _, .scopeT _ t => widthT t
  | _, _, _, .shareT _ t => widthT t
  | _, _, _, .retryT _ t => widthT t
  | _, _, _, .fanT n t => Frag.wScale n (widthT t)
  | _, _, _, .bindT _ _ => none

section Width

variable {Op : Type → Type → Type} {G L : Type}

/-- **The fold and the index compute the same arithmetic.** The width `widthT`
folds out of a term is exactly the width its grade index claims — for every
term, at every grade, with no side condition.

Read it for what it is: a syntax-to-syntax homomorphism check. `widthT` re-runs
the grade arithmetic (`Frag.wMax`/`wAdd`/`wScale`) as a fold over the term,
`Frag.width` reads it off the index the constructors computed, and the theorem
says the two routes agree. It confirms that the fold's arithmetic and the
index's arithmetic were not written to diverge; it does *not* say either one
counts consultations. No semantic notion of width — consultations in flight,
peak over branches — is defined in this package, and the bound
`peak t ≤ widthT t` that would turn a `.bounded 3` index into a statement about
what a run does is owed (acat-vbl).

It is an equation rather than the expected inequality because `Frag.width`
collapses the one residual slack in the grade order (`static` versus
`bounded 0`) that `Frag`'s header records; the inequality forms that a fold
consumer wants are the corollaries below. -/
theorem widthT_eq_width : ∀ {f : Frag} {i o : Type} (t : Term Op G L f i o),
    widthT t = Frag.width f := by
  intro f i o t
  induction t with
  | prim _ => rfl
  | pureT _ => rfl
  | seqT t u ih₁ ih₂ =>
    show Frag.wMax (widthT t) (widthT u) = _
    rw [ih₁, ih₂, Frag.width_join]
  | parT t u ih₁ ih₂ =>
    show Frag.wAdd (widthT t) (widthT u) = _
    rw [ih₁, ih₂, Frag.width_par]
  | sumT t u ih₁ ih₂ =>
    show Frag.wMax (widthT t) (widthT u) = _
    rw [ih₁, ih₂, Frag.width_join]
  | choiceT t u ih₁ ih₂ =>
    show Frag.wMax (widthT t) (widthT u) = _
    rw [ih₁, ih₂, Frag.width_join]
  | gateT _ t ih => exact ih
  | scopeT _ t ih => exact ih
  | shareT _ t ih => exact ih
  | retryT _ t ih => exact ih
  | fanT n t ih =>
    show Frag.wScale n (widthT t) = _
    rw [ih, Frag.width_scale]
  | bindT _ _ _ _ => rfl

/-- A term graded `bounded n` has width exactly `n`: the bound in the type is
the bound the fold reports. -/
theorem widthT_bounded {n : Nat} {i o : Type} (t : Term Op G L (.bounded n) i o) :
    widthT t = some n := widthT_eq_width t

/-- A static term has no data-dependent width at all. -/
theorem widthT_static {i o : Type} (t : Term Op G L .static i o) :
    widthT t = some 0 := widthT_eq_width t

/-- A monadic term has no a-priori width: the instruments answer "no a-priori
cost", which is the truth and not an evasion. -/
theorem widthT_monadic {i o : Type} (t : Term Op G L .monadic i o) :
    widthT t = none := widthT_eq_width t

/-- **The fan's width, as the inequality acat-l59 asked for.** True by
definition of the fold: `widthT (fanT n t)` *is* `Frag.wScale n (widthT t)`, so
this is `Nat.le_of_eq` on a definitional identity, not a bound proved against
anything independent. The semantic bound — that a run of `fanT n t` has at most
`n * max 1 m` consultations in flight — is owed (acat-vbl).

The `max 1 m` is what the arithmetic buys: with a plain `n * m` a three-way fan
over a body of width `0` would be reported at width `0`, while the body's own
consultations are instantiated three times over. -/
theorem widthT_fanT_le {f : Frag} {i o : Type} (n m w : Nat)
    (t : Term Op G L f i o) (ht : widthT t = some m)
    (hw : widthT (.fanT n t) = some w) : w ≤ n * max 1 m := by
  have h : widthT (Term.fanT n t) = Frag.wScale n (widthT t) := rfl
  rw [h, ht] at hw
  exact Nat.le_of_eq (Option.some.inj hw.symm)

/-- The same fact as an equation, which is what the fold actually computes. -/
theorem widthT_fanT {f : Frag} {i o : Type} (n : Nat) (t : Term Op G L f i o) :
    widthT (.fanT n t) = Frag.wScale n (widthT t) := rfl

end Width

section WidthSmoke

/-! ### The width fold at the memorialized witnesses

`Agentic.Term`'s smoke section keeps the terms that fixed the grade
arithmetic. Here the *fold* is run on them, which is what turns those examples
from claims about indices into claims about width. -/

/-- **The acat-l59 witness, weighed.** A body that consults, transforms and
then fans zero ways is graded `bounded 0`; fanning it three ways runs its
consultation three times, and the fold reports three — the number the old
`n * m` arithmetic got wrong. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    widthT (G := G) (L := L)
      (.fanT 3 (.seqT (.seqT (.prim q) (.pureT (fun s => [s]))) (.fanT 0 (.prim q))))
      = some 3 := rfl

/-- Two bounded stages side by side add: eight, not five. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    widthT (G := G) (L := L) (.parT (.fanT 3 (.prim q)) (.fanT 5 (.prim q)))
      = some 8 := rfl

/-- A fan over a fan multiplies: fifteen. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String) :
    widthT (G := G) (L := L) (.fanT 3 (.fanT 5 (.prim q))) = some 15 := rfl

/-- A full continuation forfeits the a-priori width, and the fold says so. -/
example (Op : Type → Type → Type) (G L : Type) (q : Op String String)
    (plan : String → Term Op G L .static PUnit Nat) :
    widthT (.bindT (.prim q) plan) = none := rfl

end WidthSmoke

section MeaningSmoke

/-! ### The quantitative fold at the memorialized witnesses

That `muS` *elaborates* on these terms is the load-bearing check: the fold's
clauses have to produce matrices whose index types line up with the term's,
and the fan, retry and choice rows are where that could fail. -/

/-- **The acat-l59 witness has a quantitative meaning**, at every complete
resource semiring and every scope monoid. -/
noncomputable example (Op : Type → Type → Type) (G L S : Type)
    [CompleteCSemiring S] [PMonoid G] (interp : Interp Op G S)
    (q : Op String String) : Scoped G (Mat S (List String) (List (List String))) :=
  muS (L := L) interp
    (.fanT 3 (.seqT (.seqT (.prim q) (.pureT (fun s => [s]))) (.fanT 0 (.prim q))))

/-- The static pipeline of `Agentic.Term`'s first smoke example — consult,
decode onto a coproduct, branch, all under a guard and a fueled retry — has a
quantitative meaning too, and every row it uses is one of the §4 rows. -/
noncomputable example (Op : Type → Type → Type) (G L S : Type)
    [CompleteCSemiring S] [PMonoid G] (interp : Interp Op G S)
    (q : Op String String) : Scoped G (Mat S String Nat) :=
  muS (L := L) interp
    (.retryT 3
      (.gateT true
        (.seqT (.prim q)
          (.seqT (.pureT (fun s => if s.isEmpty then Sum.inl s else Sum.inr s))
            (.choiceT (.pureT (fun s => Sum.inr s)) (.pureT (fun s => Sum.inl s.length)))))))

end MeaningSmoke

end Term

/-! ## Stage 2 — the extensional fold, keyed by site

Design §3's other homomorphism: `⟦·⟧_ext`, a partial function per sample
point. Everything difficult about it is the *consultation index*.
`Agentic.Env.share_ne_dup` proves that the index at which the answer sheet is
consulted is part of the meaning, and `Agentic.Term` accordingly fixed the
syntax's side of the bargain — every `prim` occurrence is a distinct site, and
`shareT l` is the one override. This section pays the fold's side: it computes
the site, as a path through the term, and hands it to the runner as the key at
which the world is consulted.
-/

/-- A `Step` is one segment of a path through a written workflow: which way the
fold went at a branching constructor.

Two of the constructors carry a number, and their carrying it is a decision,
not a convenience. `retry trip` keys each trip round a fueled loop separately
and `fan ix` keys each copy of a fan separately, so a body run three times is
three consultation sites. The conservative reading is the safe one: the
default must never silently equate two draws (`Env.share_ne_dup`), and
"one site per iteration" errs towards duplication while "one site per loop"
would erase the difference between a retry that re-asks and a retry that
replays. Whether a *labelled* body should be asked once across trips —
"ask-once" sharing rather than "same site" sharing — is left open deliberately
and is acat-0vv's decision to make.

There is deliberately **no `share` step**. `shareT` does not extend the path;
it *replaces the base* (`Key.rel`), which is what sharing by label means, so a
step for it would be dead syntax that no key ever contains.

`bindL`/`bindR` are two steps rather than the one a first draft would write.
With a single `bind` step the prefix of `bindT` would key at the node itself
and the continuation at one step below it, and in `bindT (bindT w k₁) k₂` the
two continuations would then collide on the very same key — two distinct
consultations reading one answer, which is exactly the silent correlation the
whole design refuses. -/
inductive Step where
  /-- Into the first stage of a `seqT`. -/
  | seqL : Step
  /-- Into the second stage of a `seqT`. -/
  | seqR : Step
  /-- Into the left branch of a `parT`. -/
  | parL : Step
  /-- Into the right branch of a `parT`. -/
  | parR : Step
  /-- Into the first alternative of a `sumT`. -/
  | sumL : Step
  /-- Into the second alternative of a `sumT`. -/
  | sumR : Step
  /-- Into the left arm of a `choiceT`. -/
  | choiceL : Step
  /-- Into the right arm of a `choiceT`. -/
  | choiceR : Step
  /-- Under a `gateT`. -/
  | gate : Step
  /-- Under a `scopeT`. -/
  | scope : Step
  /-- Into the `trip`-th time round a `retryT`'s body. -/
  | retry (trip : Nat) : Step
  /-- Into the `ix`-th copy of a `fanT`'s body. -/
  | fan (ix : Nat) : Step
  /-- Into the prefix of a `bindT`. -/
  | bindL : Step
  /-- Into the continuation of a `bindT`. -/
  | bindR : Step
  deriving DecidableEq, Repr

/-- A `Site` is a representation of *where in a written workflow a
consultation happens*: the path from the enclosing base to the leaf, outermost
step first. Identity of sites is positional, exactly as `Agentic.Term`
promised — `parT (prim q) (prim q)` yields the two distinct sites `[parL]` and
`[parR]`. -/
abbrev Site : Type := List Step

/-- A `Key L` is a representation of *the consultation index a leaf reads at*:
a site, together with what that site is measured from.

`abs s` is the absolute path from the root of the term. `rel l s` is the path
from the nearest enclosing `shareT l`, and that is the whole mechanism of
sharing: two occurrences of `shareT l t` anywhere in a workflow rebase to the
same base, so equal labels over equal bodies produce *equal keys* and
therefore — the runner being a function — equal answers. The base is the label
and nothing else, so equal labels over *unequal* bodies produce equal keys as
well, which is the collision acat-bmc records. Label equality is
never tested; it does not have to be, because equal labels build equal keys,
and so the fold demands no `DecidableEq L` and the syntax's refusal to demand
anything of `L` survives into the semantics.

Note what the conservative reading keeps: the sub-site under a label still
contains `retry` and `fan` indices, so a labelled body run twice by a loop is
still two sites. Sharing here means *the same site across two written
occurrences*, not *ask once across trips*. -/
inductive Key (L : Type) where
  /-- A site measured from the root of the term. -/
  | abs (site : Site) : Key L
  /-- A site measured from the nearest enclosing `shareT` with this label. -/
  | rel (label : L) (site : Site) : Key L

namespace Key

variable {L : Type}

/-- The key a fold starts at: the empty path from the root. -/
def root : Key L := .abs []

/-- Descend one step, extending the path and leaving the base alone. -/
def push : Key L → Step → Key L
  | .abs s, st => .abs (s ++ [st])
  | .rel l s, st => .rel l (s ++ [st])

/-- **Rebasing**: what `shareT l` does to the key. The absolute position of
the labelled occurrence is discarded and the path restarts at the label, so
every occurrence of `shareT l t` consults the same sites. This is §6a's
`share` operation, and it is the only thing in the fold that is not a
descent. -/
def rebase (l : L) : Key L := .rel l []

end Key

/-- A `Runner Op G L` is a representation of *the world, decoded*: given the
scope in force and the consultation key, it answers a leaf — or refuses.

The runner owns the environment rather than receiving one, and that is the
honest v1 rather than an evasion. `Agentic.Env`'s `Env C O` assigns one
outcome type `O` to every consultation, while an `Op a b` answers in `b` and
the `b`s vary from leaf to leaf; bridging the two requires either a universe
of decodable answers or a dependent answer sheet, and neither belongs in the
first fold. So the runner is exactly agent-functor's `LeafRunner` — the case
study of design §9, whose `runPure` with an oracle the design identifies as
`⟦·⟧_ext` at a deterministic sample point — and an `Env`-explicit version,
with `pin`, caching and the counterfactual-substitution theorems stated
*through* the fold, is follow-up work.

What the runner does *not* get to do is see the term. It sees a key, and the
key is computed by the fold from the syntax, which is what makes sharing and
duplication its business to respect rather than its business to decide
(`askRunner` below is the concrete `Env`-backed instance). -/
def Runner (Op : Type → Type → Type) (G L : Type) : Type 1 :=
  G → Key L → {a b : Type} → Op a b → a → Option b

/-- Running a fueled loop: try the body, answer on `Sum.inl`, go round on
`Sum.inr` while fuel remains, and refuse when it runs out. The trip counter is
threaded so that the caller can key each trip separately; the fuel and the
trip number move in opposite directions and are not the same number.

The arithmetic is chosen to agree with the quantitative fold: fuel `n` admits
at most `n + 1` attempts here, and `Mat.retryTrunc n` is
`(I + L + ⋯ + Lⁿ) · E` — at most `n` traversals of the loop block followed by
one exit, which is the same `n + 1` body runs. The two meanings of a `retryT n`
therefore count the same trips, and the `retry trip` keys they would assign
range over the same numbers. -/
def retryLoop {i o : Type} (step : Nat → i → Option (Sum o i)) :
    Nat → Nat → i → Option o
  | 0, trip, a =>
    match step trip a with
    | some (Sum.inl b) => some b
    | some (Sum.inr _) => none
    | none => none
  | n + 1, trip, a =>
    match step trip a with
    | some (Sum.inl b) => some b
    | some (Sum.inr a') => retryLoop step n (trip + 1) a'
    | none => none

/-- Two loops whose bodies agree at every trip agree: the loop is a
congruence, which is what lets key-insensitivity propagate through `retryT`. -/
theorem retryLoop_congr {i o : Type} {s₁ s₂ : Nat → i → Option (Sum o i)}
    (h : ∀ trip a, s₁ trip a = s₂ trip a) :
    ∀ (n trip : Nat) (a : i), retryLoop s₁ n trip a = retryLoop s₂ n trip a
  | 0, trip, a => by
    show (match s₁ trip a with
          | some (Sum.inl b) => some b | some (Sum.inr _) => none | none => none)
        = (match s₂ trip a with
          | some (Sum.inl b) => some b | some (Sum.inr _) => none | none => none)
    rw [h trip a]
  | n + 1, trip, a => by
    show (match s₁ trip a with
          | some (Sum.inl b) => some b
          | some (Sum.inr a') => retryLoop s₁ n (trip + 1) a'
          | none => none)
        = (match s₂ trip a with
          | some (Sum.inl b) => some b
          | some (Sum.inr a') => retryLoop s₂ n (trip + 1) a'
          | none => none)
    rw [h trip a]
    cases s₂ trip a with
    | none => rfl
    | some x =>
      cases x with
      | inl b => rfl
      | inr a' => exact retryLoop_congr h n (trip + 1) a'

/-- Running a fan: the body on each element in turn, indexed, refusing as soon
as any copy refuses. -/
def fanRun {i o : Type} (step : Nat → i → Option o) : Nat → List i → Option (List o)
  | _, [] => some []
  | ix, a :: as =>
    match step ix a with
    | none => none
    | some b => (fanRun step (ix + 1) as).map (fun bs => b :: bs)

/-- Two fans whose bodies agree at every index agree. -/
theorem fanRun_congr {i o : Type} {s₁ s₂ : Nat → i → Option o}
    (h : ∀ ix a, s₁ ix a = s₂ ix a) :
    ∀ (ix : Nat) (as : List i), fanRun s₁ ix as = fanRun s₂ ix as
  | _, [] => rfl
  | ix, a :: as => by
    show (match s₁ ix a with
          | none => none
          | some b => (fanRun s₁ (ix + 1) as).map (fun bs => b :: bs))
        = (match s₂ ix a with
          | none => none
          | some b => (fanRun s₂ (ix + 1) as).map (fun bs => b :: bs))
    rw [h ix a, fanRun_congr h (ix + 1) as]

namespace Term

/-- **The extensional meaning** `⟦·⟧_ext` of design §3: a structural fold from
a written workflow to a partial function, given a runner, the scope in force,
and the key of the node being read.

The clauses, and the decisions in them:

* `seqT` threads `Option` — refusal anywhere refuses the composite, which is
  `Env.extComp_none_left`/`_right` at the level of terms.
* `parT` runs both and pairs the answers, **left first and
  short-circuiting** — if the left branch refuses, the right is never run.
  That is a bias, in the same way `sumT`'s is, and it is recorded at
  `muExt_parT`.
* `sumT` is **leftmost-defined**, and this is a genuine departure worth
  naming: `⊕` is *symmetric* in `muS` (`Mat.matAdd_comm`) and cannot be here,
  because a deterministic extensional layer must choose one answer and the
  design gives no choice function. The bias is documented, not hidden, and the
  design question — whether the extensional layer should be relational, or
  carry an explicit choice, or whether `sumT` should record its own priority —
  is recorded as discovered work.
* `choiceT` cases on the decoded coproduct: value-dependence bought at no
  cost, §4's static fragment.
* `gateT false` is `none`: refusal is partiality, `Env`'s documented
  convention, and it annihilates by the `Option` threading above.
* `scopeT h` recurses at `g ⋄ h` — the same right action as `muS`, so the two
  meanings scope alike.
* `shareT l` **rebases the key on the label alone**, and that is the one
  clause the whole section exists for. The body is not consulted and neither
  is the surrounding scope: see `muExt_shareT` for what that costs (acat-bmc).
* `retryT n` iterates up to `n` times with the trip number in the key.
* `fanT n` truncates its input at `n` — the same commitment `muS` keeps — and
  keys each copy by its index.
* `bindT` binds through the intermediate value, prefix and continuation
  keyed apart. -/
def muExt {Op : Type → Type → Type} {G L : Type} [PMonoid G]
    (run : Runner Op G L) :
    ∀ {f : Frag} {i o : Type}, Term Op G L f i o → G → Key L → i → Option o
  | _, _, _, .prim op => fun g k a => run g k op a
  | _, _, _, .pureT fn => fun _ _ a => some (fn a)
  | _, _, _, .seqT t u => fun g k a =>
      (muExt run t g (k.push .seqL) a).bind (muExt run u g (k.push .seqR))
  | _, _, _, .parT t u => fun g k p =>
      (muExt run t g (k.push .parL) p.1).bind fun b =>
        (muExt run u g (k.push .parR) p.2).map fun d => (b, d)
  | _, _, _, .sumT t u => fun g k a =>
      (muExt run t g (k.push .sumL) a).orElse fun _ =>
        muExt run u g (k.push .sumR) a
  | _, _, _, .choiceT t u => fun g k x =>
      match x with
      | Sum.inl a => muExt run t g (k.push .choiceL) a
      | Sum.inr b => muExt run u g (k.push .choiceR) b
  | _, _, _, .gateT b t => fun g k a =>
      if b then muExt run t g (k.push .gate) a else none
  | _, _, _, .scopeT h t => fun g k => muExt run t (g ⋄ h) (k.push .scope)
  | _, _, _, .shareT l t => fun g _ => muExt run t g (Key.rebase l)
  | _, _, _, .retryT n t => fun g k a =>
      retryLoop (fun trip a' => muExt run t g (k.push (.retry trip)) a') n 0 a
  | _, _, _, .fanT n t => fun g k as =>
      fanRun (fun ix a => muExt run t g (k.push (.fan ix)) a) 0 (as.take n)
  | _, _, _, .bindT t kf => fun g k a =>
      (muExt run t g (k.push .bindL) a).bind fun b =>
        muExt run (kf b) g (k.push .bindR) PUnit.unit

section ExtEquations

variable {Op : Type → Type → Type} {G L : Type} [PMonoid G] (run : Runner Op G L)

/-- A leaf consults the world at its own site. -/
theorem muExt_prim {i o : Type} (op : Op i o) (g : G) (k : Key L) (a : i) :
    muExt run (.prim op) g k a = run g k op a := rfl

/-- A Transform consults nothing and refuses nothing. -/
theorem muExt_pureT {i o : Type} (fn : i → o) (g : G) (k : Key L) (a : i) :
    muExt (Op := Op) run (.pureT fn) g k a = some (fn a) := rfl

/-- Sequencing threads refusal. -/
theorem muExt_seqT {f g' : Frag} {i j o : Type}
    (t : Term Op G L f i j) (u : Term Op G L g' j o) (g : G) (k : Key L) (a : i) :
    muExt run (.seqT t u) g k a
      = (muExt run t g (k.push .seqL) a).bind (muExt run u g (k.push .seqR)) := rfl

/-- A tensor runs both branches, at two distinct sites — **left first, and
short-circuiting on the left's refusal**, which is a deviation worth naming in
the same breath as `sumT`'s leftmost bias.

`Mat.kron` is symmetric in the weight it assigns the two branches: neither
factor can prevent the other from contributing. The `Option`-bind here cannot
be, because a deterministic partial fold has to sequence two effects and the
design supplies no way to run them independently — so when the left branch
refuses, the right branch's consultation does not happen at all, and the two
folds disagree about which sites a refusing tensor visits. This is one of the
recorded obstructions to a `π` relating the two meanings (acat-qtv). -/
theorem muExt_parT {f g' : Frag} {i j k' l : Type}
    (t : Term Op G L f i j) (u : Term Op G L g' k' l) (g : G) (k : Key L)
    (p : i × k') :
    muExt run (.parT t u) g k p
      = (muExt run t g (k.push .parL) p.1).bind fun b =>
          (muExt run u g (k.push .parR) p.2).map fun d => (b, d) := rfl

/-- Alternation is leftmost-defined: the documented bias. -/
theorem muExt_sumT {f g' : Frag} {i o : Type}
    (t : Term Op G L f i o) (u : Term Op G L g' i o) (g : G) (k : Key L) (a : i) :
    muExt run (.sumT t u) g k a
      = (muExt run t g (k.push .sumL) a).orElse
          (fun _ => muExt run u g (k.push .sumR) a) := rfl

/-- **A shut gate refuses**, and by the `Option` threading nothing downstream
of it runs: refusal is partiality, and it annihilates. -/
theorem muExt_gateT_false {f : Frag} {i o : Type} (t : Term Op G L f i o)
    (g : G) (k : Key L) (a : i) : muExt run (.gateT false t) g k a = none := rfl

/-- An open gate is no gate at all. -/
theorem muExt_gateT_true {f : Frag} {i o : Type} (t : Term Op G L f i o)
    (g : G) (k : Key L) (a : i) :
    muExt run (.gateT true t) g k a = muExt run t g (k.push .gate) a := rfl

/-- Scoping recurses at the extended scope, outer on the left — the same
`actR` order the quantitative fold uses, so the two meanings agree about what
"innermost wins" means. -/
theorem muExt_scopeT {f : Frag} {i o : Type} (h : G) (t : Term Op G L f i o)
    (g : G) (k : Key L) :
    muExt run (.scopeT h t) g k = muExt run t (g ⋄ h) (k.push .scope) := rfl

/-- **Sharing rebases on the label alone**: the key inside `shareT l` does not
depend on where the `shareT` was written, only on the label. This is the clause
that makes two occurrences of `shareT l t` one consultation.

It is also the clause's whole liability, and the docstrings elsewhere should
be read against this equation rather than against their intent. The rebased key
is `Key.rel l []`; it records neither the body nor the scope. So:

* **Label collision is not detected.** `shareT l t` and `shareT l u` with
  *different* bodies rebase to the same base, and wherever their sites happen
  to coincide they read one answer — two consultations the designer wrote as
  distinct, silently correlated. Nothing in the fold can notice, since `L` is
  not even required to have decidable equality.
* **Sharing is scope-blind.** The key carries no scope, so the same label
  under two different `scopeT`s rebases identically; only the runner's own use
  of its `G` argument can keep those consultations apart.

Body agreement is therefore the designer's obligation, not a checked property.
Making it checkable — a well-formedness condition on labels, or a key that
records the body — is acat-bmc. -/
theorem muExt_shareT {f : Frag} {i o : Type} (l : L) (t : Term Op G L f i o)
    (g : G) (k : Key L) :
    muExt run (.shareT l t) g k = muExt run t g (Key.rebase l) := rfl

/-- **A tensor is a congruence for meaning**: replacing either branch by a
term with the same extensional meaning does not move the tensor's. This is the
`parT` case of the lifting obligation that Stage 3 discharges for `seqT`, and
it is what the share-transparency corollary below is proved with. -/
theorem muExt_parT_congr {f g' : Frag} {i j k' l : Type}
    {t t' : Term Op G L f i j} {u u' : Term Op G L g' k' l}
    (h₁ : muExt run t = muExt run t') (h₂ : muExt run u = muExt run u') :
    muExt run (.parT t u) = muExt run (.parT t' u') := by
  funext g k p
  rw [muExt_parT, muExt_parT, h₁, h₂]

/-- Bind threads the intermediate value, with the prefix and the continuation
keyed apart. -/
theorem muExt_bindT {f g' : Frag} {i k' o : Type}
    (t : Term Op G L f i k') (kf : k' → Term Op G L g' PUnit o)
    (g : G) (k : Key L) (a : i) :
    muExt run (.bindT t kf) g k a
      = (muExt run t g (k.push .bindL) a).bind
          (fun b => muExt run (kf b) g (k.push .bindR) PUnit.unit) := rfl

/-- A `0`-fan denotes the constant `[]`, independent of its input and of the
runner: the extensional shadow of `muS_fanT_zero`. (The statement is about the
value, not about consultations — this fold counts nothing, so "consults
nothing" is not something it can say. What it does say is that the body never
appears on the right-hand side.) -/
theorem muExt_fanT_zero {f : Frag} {i o : Type} (t : Term Op G L f i o)
    (g : G) (k : Key L) (as : List i) :
    muExt run (.fanT 0 t) g k as = some ([] : List o) := rfl

end ExtEquations

section KeyIrrelevance

variable {Op : Type → Type → Type} {G L : Type} [PMonoid G] {run : Runner Op G L}

/-- **When the runner ignores keys, the fold ignores sites.** A runner that
answers the same question the same way wherever it is asked is precisely a
runner for which the consultation index is not observable, and under it every
term's meaning is independent of the key it is read at.

This is the fold's analogue of `Env.share_eq_dup_of_agree`: the distinction
between sharing and duplication is invisible exactly at the sample points
where the answer sheet does not depend on the index. It is a theorem about
*every* term, so the transparency results below are corollaries rather than
special pleading. -/
theorem muExt_key_irrelevant
    (hrun : ∀ (g : G) (k k' : Key L) {a b : Type} (op : Op a b) (x : a),
      run g k op x = run g k' op x) :
    ∀ {f : Frag} {i o : Type} (t : Term Op G L f i o) (g : G) (k k' : Key L) (x : i),
      muExt run t g k x = muExt run t g k' x := by
  intro f i o t
  induction t with
  | prim op => intro g k k' x; exact hrun g k k' op x
  | pureT fn => intro _ _ _ _; rfl
  | seqT t u ih₁ ih₂ =>
    intro g k k' x
    rw [muExt_seqT, muExt_seqT, ih₁ g (k.push .seqL) (k'.push .seqL) x]
    cases muExt run t g (k'.push .seqL) x with
    | none => rfl
    | some b => exact ih₂ g (k.push .seqR) (k'.push .seqR) b
  | parT t u ih₁ ih₂ =>
    intro g k k' p
    rw [muExt_parT, muExt_parT, ih₁ g (k.push .parL) (k'.push .parL) p.1,
      ih₂ g (k.push .parR) (k'.push .parR) p.2]
  | sumT t u ih₁ ih₂ =>
    intro g k k' x
    rw [muExt_sumT, muExt_sumT, ih₁ g (k.push .sumL) (k'.push .sumL) x,
      ih₂ g (k.push .sumR) (k'.push .sumR) x]
  | choiceT t u ih₁ ih₂ =>
    intro g k k' x
    cases x with
    | inl a => exact ih₁ g (k.push .choiceL) (k'.push .choiceL) a
    | inr b => exact ih₂ g (k.push .choiceR) (k'.push .choiceR) b
  | gateT b t ih =>
    intro g k k' x
    cases b with
    | false => rfl
    | true => exact ih g (k.push .gate) (k'.push .gate) x
  | scopeT h t ih => intro g k k' x; exact ih (g ⋄ h) (k.push .scope) (k'.push .scope) x
  | shareT l t _ => intro _ _ _ _; rfl
  | retryT n t ih =>
    intro g k k' x
    exact retryLoop_congr
      (fun trip a => ih g (k.push (.retry trip)) (k'.push (.retry trip)) a) n 0 x
  | fanT n t ih =>
    intro g k k' as
    exact fanRun_congr
      (fun ix a => ih g (k.push (.fan ix)) (k'.push (.fan ix)) a) 0 (as.take n)
  | bindT t kf ih₁ ih₂ =>
    intro g k k' x
    rw [muExt_bindT, muExt_bindT, ih₁ g (k.push .bindL) (k'.push .bindL) x]
    cases muExt run t g (k'.push .bindL) x with
    | none => rfl
    | some b => exact ih₂ b g (k.push .bindR) (k'.push .bindR) PUnit.unit

/-- **Sharing is transparent to a key-blind runner.** Labelling a
sub-workflow changes nothing when the world answers the same wherever it is
asked — the reading under which `share` and `dup` are interchangeable, and the
reason the distinction is so easy to lose. -/
theorem muExt_shareT_transparent
    (hrun : ∀ (g : G) (k k' : Key L) {a b : Type} (op : Op a b) (x : a),
      run g k op x = run g k' op x)
    {f : Frag} {i o : Type} (l : L) (t : Term Op G L f i o) :
    muExt run (.shareT l t) = muExt run t := by
  funext g k x
  exact muExt_key_irrelevant hrun t g (Key.rebase l) k x

end KeyIrrelevance

end Term

/-! ### The decision made observable

`Agentic.Env` exhibited two workflows that differ only in *where* the answer
sheet is consulted, and proved them different meanings. `Agentic.Term`
memorialized the same pair as written terms — `dupPair`, two `prim`
occurrences, and `sharedPair`, the same two under one label. The fold now
closes the circle: under a runner backed by an answer sheet that answers by
site, the two terms denote different partial functions.
-/

/-- The smallest interesting leaf signature: one question, asked of a `String`
and answered with a `Nat`. It is the `Op` at which `Agentic.Term`'s `dupPair`
and `sharedPair` are stated. -/
inductive AskOp : Type → Type → Type where
  /-- The one question. -/
  | ask : AskOp String Nat

/-- **A runner backed by an answer sheet**, keyed by consultation site: this is
`Agentic.Env`'s `Env` at the index the fold computes, so `Env (Key L) Nat` is
literally the design's "one sample point, an answer for every question the run
might ask" with *question* read as *site*. The heterogeneity that forced the
runner abstraction is absent here because there is only one leaf type. -/
def askRunner {G L : Type} (ε : Env (Key L) Nat) : Runner AskOp G L :=
  fun _ k => @fun _ _ op _ => match op with | AskOp.ask => some (ε k)

/-- The answer sheet that answers the two sites of a tensor differently —
`Env.epsSplit` transported to keys. A world in which the second draw does not
match the first is all the counterexample needs. -/
def epsSplitKey : Env (Key Nat) Nat
  | .abs [Step.parR] => 1
  | _ => 0

/-- Duplication spends two consultations, and reads two different answers. -/
theorem muExt_dupPair_apply :
    Term.muExt (askRunner epsSplitKey)
        (Term.dupPair (G := LastOpt Unit) (L := Nat) AskOp.ask)
        LastOpt.unset Key.root ("", "") = some (0, 1) := rfl

/-- Sharing spends one consultation, and reads its answer twice: both branches
rebase to the same key, so the answer sheet is consulted at one site. -/
theorem muExt_sharedPair_apply :
    Term.muExt (askRunner epsSplitKey)
        (Term.sharedPair (G := LastOpt Unit) (0 : Nat) AskOp.ask)
        LastOpt.unset Key.root ("", "") = some (0, 0) := rfl

/-- **Sharing is not duplication — as written terms, through the fold.**

This is the design's §6a distinction discharged where it had to be discharged:
`Env.share_ne_dup` exhibited two *meanings* that differ, and the syntax could
only promise that it recorded which one was written. The promise is now kept —
the fold sends `dupPair` and `sharedPair` to different partial functions,
because the sites it computes for them are different keys, and a runner backed
by an answer sheet that distinguishes those sites distinguishes the terms.

Note where the work is done: not in comparing labels (nothing here tests `L`
for equality) but in `Key.rebase`, which makes two occurrences of one label
build one key. -/
theorem muExt_dupPair_ne_sharedPair :
    Term.muExt (askRunner epsSplitKey)
        (Term.dupPair (G := LastOpt Unit) (L := Nat) AskOp.ask)
      ≠ Term.muExt (askRunner epsSplitKey)
        (Term.sharedPair (G := LastOpt Unit) (0 : Nat) AskOp.ask) := by
  intro h
  have h1 := congrFun (congrFun (congrFun h LastOpt.unset) Key.root) ("", "")
  rw [muExt_dupPair_apply, muExt_sharedPair_apply] at h1
  exact absurd h1 (by decide)

/-- **And they are the same under a key-blind runner.** The constant answer
sheet is the sample point at which the two agree, which is
`Env.share_eq_dup_of_agree` for written terms: the distinction is real, and it
is invisible to any single world that does not depend on where it is asked. -/
theorem muExt_dupPair_eq_sharedPair_of_const {G : Type} [PMonoid G] (v : Nat)
    (l : Nat) :
    Term.muExt (askRunner (G := G) (fun _ => v))
        (Term.dupPair (L := Nat) AskOp.ask)
      = Term.muExt (askRunner (G := G) (fun _ => v))
        (Term.sharedPair l AskOp.ask) := by
  have hrun : ∀ (g : G) (k k' : Key Nat) {a b : Type} (op : AskOp a b) (x : a),
      askRunner (G := G) (fun _ => v) g k op x
        = askRunner (G := G) (fun _ => v) g k' op x := by
    intro _ _ _ _ _ op _
    cases op
    rfl
  have hs := Term.muExt_shareT_transparent hrun l (Term.prim (G := G) AskOp.ask)
  exact Term.muExt_parT_congr _ hs.symm hs.symm

/-- **One label over two different bodies reads one answer.** The two terms
below share the label `0` and differ in their bodies, and both consult the
answer sheet at the single key `Key.rel 0 [parL]`: the rebase keys on the label
alone, so the collision is invisible to the fold and to the runner. Nothing
here is a soundness bug in the fold — it is the cost of keying by label
without a well-formedness condition tying a label to a body, which is
acat-bmc. -/
theorem muExt_shareT_label_collision (ε : Env (Key Nat) Nat) :
    Term.muExt (askRunner ε)
        (Term.shareT (G := LastOpt Unit) (0 : Nat)
          (Term.parT (Term.prim AskOp.ask) (Term.pureT (fun s : String => s))))
        LastOpt.unset Key.root ("a", "b")
        = some (ε (.rel 0 [Step.parL]), "b")
      ∧ Term.muExt (askRunner ε)
        (Term.shareT (G := LastOpt Unit) (0 : Nat)
          (Term.parT (Term.prim AskOp.ask) (Term.pureT (fun s : String => s ++ "!"))))
        LastOpt.unset Key.root ("a", "b")
        = some (ε (.rel 0 [Step.parL]), "b!") :=
  ⟨rfl, rfl⟩

/-! ## Stage 3 — workflow equality is the quotient by meaning

Design §3: *semantic equality is equality of `⟦·⟧_ext`* — "the audit rejected
weakening equality to protect a caching story" — and §8's Lean argument is that
this is a definable type rather than a convention: `Quotient (Setoid.ker
denote)`, with `Quot.lift` turning respect-for-meaning into a proof obligation
the compiler checks.

That is what this section builds. `WEq` is extensional equality quantified over
*all* runners and *all* scopes; `Workflow` is the quotient; and `Workflow.seq`
is one operation lifted through it — sequencing descends because it respects
meaning, and the proof that it does is a proof, not a comment.

Read the scale of that honestly. What is built here is the **type-level move**
— equality as a quotient by meaning, with the respect obligation discharged by
the elaborator — on exactly one operation, with **no laws**. `Workflow` is not
a category and this section does not claim it is: see the discussion at
`Workflow.seq_of` for which laws fail and why acat-5b7 is the prerequisite for
any of them.
-/

namespace Term

/-- **Workflow equality**: two written workflows are equal when no runner, at
any scope, from any key, can tell them apart.

The quantification over runners is what makes this the design's equality
rather than a weaker one. A single runner is one sample point plus one
decoding; asking for agreement at all of them is asking for agreement as
*meanings*, which is why `dupPair` and `sharedPair` are not `WEq`
(`muExt_dupPair_ne_sharedPair` exhibits the separating runner) even though a
key-blind runner cannot see the difference
(`muExt_dupPair_eq_sharedPair_of_const`).

The quantification over keys deserves naming as a *strengthening*: because a
term is compared at every key, two terms that differ only in where their
consultations sit are still distinguished. `WEq` is therefore quite fine — it
identifies terms that consult nothing (Transform fusion, an open gate, a
duplicated alternative) and terms whose consultations are keyed alike, and it
does not identify a term with a re-plumbed copy of itself. Whether the coarser
equality that quantifies keys *outside* the comparison is the better notion is
a real design question, and it is recorded as discovered work (acat-5b7)
rather than settled here. It is also the reason the quotient below carries no
laws: fineness at the key is exactly what breaks associativity. -/
def WEq {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f : Frag}
    {i o : Type} (t u : Term Op G L f i o) : Prop :=
  ∀ (run : Runner Op G L) (g : G) (k : Key L), muExt run t g k = muExt run u g k

namespace WEq

variable {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f : Frag} {i o : Type}

/-- Every workflow means what it means. -/
theorem refl (t : Term Op G L f i o) : WEq t t := fun _ _ _ => rfl

/-- Meaning-equality is symmetric. -/
theorem symm {t u : Term Op G L f i o} (h : WEq t u) : WEq u t :=
  fun run g k => (h run g k).symm

/-- Meaning-equality is transitive. -/
theorem trans {t u v : Term Op G L f i o} (h₁ : WEq t u) (h₂ : WEq u v) : WEq t v :=
  fun run g k => (h₁ run g k).trans (h₂ run g k)

end WEq

/-- Workflow equality is an equivalence, so it is one: the `Setoid` whose
quotient is the space of workflows-up-to-meaning. -/
instance wSetoid {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f : Frag}
    {i o : Type} : Setoid (Term Op G L f i o) where
  r := WEq
  iseqv := ⟨WEq.refl, WEq.symm, WEq.trans⟩

/-- **A `Workflow` is a written workflow up to meaning**: the quotient of the
term syntax by extensional equality. This is design §3's "semantic equality is
equality of `⟦·⟧_ext`" as a *type* — two terms that mean the same thing are
not merely provably interchangeable, they are the same element — and §8's
reason for choosing Lean: the obligation to respect meaning is discharged at
the definition of every operation, by the elaborator, or the operation does
not exist.

What this type does **not** yet carry is any algebra. It has exactly one
operation (`Workflow.seq`) and no laws whatsoever: `WEq` compares terms key by
key, and every structural rearrangement moves keys, so associativity fails, a
unit is unavailable, and `gateT true`/`scopeT unit` are not absorbed. The
details are at `Workflow.seq_of`. -/
def Workflow (Op : Type → Type → Type) (G L : Type) [PMonoid G] (f : Frag)
    (i o : Type) : Type 1 :=
  Quotient (wSetoid (Op := Op) (G := G) (L := L) (f := f) (i := i) (o := o))

/-- The workflow a written term denotes. -/
def Workflow.of {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f : Frag}
    {i o : Type} (t : Term Op G L f i o) : Workflow Op G L f i o :=
  Quotient.mk _ t

/-- **Sequencing respects meaning**, so it descends to the quotient: this is
the lifting obligation, discharged. Both arguments may be replaced by terms of
equal meaning, and the composite's meaning does not move — because the `seqT`
clause of the fold consults its subterms only through their own meanings, at
keys it computes from the node and not from the subterms' shapes. -/
theorem WEq.seqT_congr {Op : Type → Type → Type} {G L : Type} [PMonoid G]
    {f g' : Frag} {i j o : Type} {t t' : Term Op G L f i j}
    {u u' : Term Op G L g' j o} (ht : WEq t t') (hu : WEq u u') :
    WEq (.seqT t u) (.seqT t' u') := by
  intro run g k
  funext a
  rw [muExt_seqT, muExt_seqT, ht run g (k.push .seqL), hu run g (k.push .seqR)]

/-- **Sequencing on the quotient**: `Workflow.seq` exists because
`WEq.seqT_congr` exists; had sequencing failed to respect meaning, this
definition would not elaborate, which is exactly the discipline the design
asked a host language to enforce. -/
def Workflow.seq {Op : Type → Type → Type} {G L : Type} [PMonoid G]
    {f g' : Frag} {i j o : Type} :
    Workflow Op G L f i j → Workflow Op G L g' j o →
      Workflow Op G L (f.join g') i o :=
  Quotient.lift₂ (fun t u => Workflow.of (Term.seqT t u))
    (fun _ _ _ _ ht hu => Quotient.sound (WEq.seqT_congr ht hu))

/-- Sequencing on the quotient computes: the lift of a pair of written terms is
the written composite.

**The §8 move in miniature — and only the move.** What has been demonstrated by
`Workflow`, `Workflow.seq` and this equation is the *type-level* claim: that
"equality is equality of meaning" can be a type rather than a convention, with
the respect-for-meaning obligation checked by the elaborator at the definition
of the operation. It is not the claim that a category has been built.

`Workflow` currently has **one operation and no laws**, and the laws are not
merely unproved, they are false as `WEq` stands:

* **Associativity fails.** `seqT (seqT a b) c` keys its stages at
  `[seqL, seqL]`, `[seqL, seqR]`, `[seqR]`, while `seqT a (seqT b c)` keys them
  at `[seqL]`, `[seqR, seqL]`, `[seqR, seqR]`. `WEq` compares at each key, so a
  key-sensitive runner over consulting stages separates the two groupings.
* **There is no unit.** `seqT (pureT id) t` pushes a `seqR` step onto every
  consultation of `t`, so it is not `WEq` to `t` for the same reason.
* **`gateT true` and `scopeT unit` are not absorbed**, likewise by the `gate`
  and `scope` steps they insert — even though both are absorbed by `muS`
  (`muS_gateT_true`, `muS_scopeT_unit`).

Every one of these failures is the same failure: `WEq` is sensitive to the
exact key at which a consultation sits, and structural rearrangement renames
keys. Coarsening `WEq` to be invariant under key renaming is acat-5b7, and it
is the prerequisite for `Workflow` to be a category rather than a quotient set
with a binary operation on it. -/
theorem Workflow.seq_of {Op : Type → Type → Type} {G L : Type} [PMonoid G]
    {f g' : Frag} {i j o : Type} (t : Term Op G L f i j)
    (u : Term Op G L g' j o) :
    Workflow.seq (Workflow.of t) (Workflow.of u) = Workflow.of (Term.seqT t u) :=
  rfl

/-! ### The two meanings are incomparable

`WEq` does **not** imply equality of quantitative meanings. The witness is
alternation: extensionally `w ⊕ w` is `w` — the leftmost-defined alternative is
the only one anyone sees — while quantitatively `⟦w ⊕ w⟧ = ⟦w⟧ + ⟦w⟧`, which is
`⟦w⟧` only in a carrier whose alternation is idempotent. A carrier that
*counts* separates the two terms that the extensional layer identified; that is
`one_add_one_of_muS_respects_WEq` below.

Nor does the containment run the other way. `gateT true t` and `t` have the
same matrix (`muS_gateT_true`), and `scopeT unit t` and `t` likewise
(`muS_scopeT_unit`), yet `WEq` does not identify either pair in general: the
extra `gate`/`scope` step shifts every consultation key inside, and `WEq`
compares at each key rather than up to renaming, so a key-sensitive runner over
a consulting body tells them apart.

So the two equalities are **incomparable**, and this is the honest statement to
replace the fibration story: there is no projection between the two meanings in
either direction, and none can be added until `WEq` is coarsened by
key-renaming invariance (acat-5b7). One direction is impossible outright, not
merely unbuilt — `one_add_one_of_muS_respects_WEq` shows that a `π` from the
`WEq` quotient to matrices would collapse any carrier that counts.
-/

/-- **Transform fusion is a workflow equality**: two plain functions in
sequence are the composite function. This is the shape of equality that
survives the fine-grained keying — neither term consults, so no key enters the
comparison — and it is the sanity check that `WEq` identifies *something*. -/
theorem WEq_seqT_pureT {Op : Type → Type → Type} {G L : Type} [PMonoid G]
    {i j o : Type} (f₁ : i → j) (f₂ : j → o) :
    WEq (Op := Op) (G := G) (L := L)
      (.seqT (.pureT f₁) (.pureT f₂)) (.pureT (fun a => f₂ (f₁ a))) := by
  intro _ _ _
  funext _
  rfl

/-- A duplicated alternative is extensionally invisible: the leftmost branch
answers, so the second is never reached. (Stated for `pureT` so that no
consultation, and hence no key, enters the comparison.) -/
theorem WEq_sumT_pureT_self {Op : Type → Type → Type} {G L : Type} [PMonoid G]
    {i o : Type} (fn : i → o) :
    WEq (Op := Op) (G := G) (L := L) (.sumT (.pureT fn) (.pureT fn)) (.pureT fn) := by
  intro _ _ _
  funext _
  rfl

/-- **The quantitative meaning does not respect extensional equality.**

Suppose it did — suppose every pair of terms with one extensional meaning had
one matrix. Then, since `w ⊕ w` and `w` are extensionally equal, the carrier
would have to satisfy `1 + 1 = 1`: a resource semiring that cannot count, in
which two ways of arriving are one way. `Prop`, `Cost` and `Prob` are such
carriers and are unbothered; the expectation semiring is not, and neither is
any carrier in which the number of alternatives is part of the answer.

This is why the package carries two folds rather than one meaning with a cost
annotation. It rules out one of the two projections design §3's fibration
would need: no `π` sends a `Workflow` (a `WEq` class) to a matrix. The other
projection is missing too, for the unrelated reason recorded above — `WEq` is
finer than matrix equality at `gateT true` and `scopeT unit` — so the
quantitative meaning does not live *over* the quotient either. It lives beside
it, until acat-5b7 coarsens `WEq`. -/
theorem one_add_one_of_muS_respects_WEq {Op : Type → Type → Type} {G L S : Type}
    [CompleteCSemiring S] [PMonoid G] (g : G) (interp : Interp Op G S)
    (h : ∀ t u : Term Op G L .static Unit Unit, WEq t u → muS interp t = muS interp u) :
    (1 : S) + 1 = 1 := by
  have he := h _ _ (WEq_sumT_pureT_self (Op := Op) (G := G) (L := L)
    (fun x : Unit => x))
  have hp : (Mat.pointMat (fun x : Unit => x) : Mat S Unit Unit) () () = 1 :=
    Mat.pointMat_apply_self _ ()
  have h2 : (Mat.pointMat (fun x : Unit => x) : Mat S Unit Unit) () ()
      + (Mat.pointMat (fun x : Unit => x) : Mat S Unit Unit) () ()
      = (Mat.pointMat (fun x : Unit => x) : Mat S Unit Unit) () () :=
    congrFun (congrFun (congrFun he g) ()) ()
  rw [hp] at h2
  exact h2

end Term

end Agentic
