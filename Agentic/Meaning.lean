import Agentic.Term
import Agentic.Gate
import Agentic.Scope
import Agentic.Env
import Mathlib.CategoryTheory.Category.Basic
import Mathlib.Data.ENat.Lattice

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
incomparable rather than nested. `muS` does not respect the extensional
equality (the theorem just named), so there is no map from the quotient down to
matrices; and equality of matrices does not imply the extensional one either,
since `dupPair` and `sharedPair` have literally the same matrix
(`muS_dupPair_eq_sharedPair`, `rfl`, because `muS` is transparent to `shareT`)
and are different workflows (`WEqR_dupPair_ne_sharedPair`). Neither equality
refines the other, so neither meaning is a quotient or a fibre of the other.

That second half used to be argued from `gateT true` and `scopeT unit`, and it
was an artefact: extensional equality was quantified *at* each key, so deleting
a no-op node counted as a semantic change. Stage 3 now quotients by `WEqR`,
which compares two terms up to a relabelling of absolute sites, and the
artefact is gone — an open gate, an empty scope, either unit of sequencing and
either bracketing of a pipeline are all equalities of workflows, the static
fragment is a `CategoryTheory.Category`, and sharing is still not duplication.
What blocks the remaining `π` is now a genuine gap on the *quantitative* side:
a matrix has no room to record a site (acat-qtv).

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

`Term.peak`, the semantic width of Stage 2b, over-charges it by the same
amount and for the same reason (`peak_sharedPair` against
`muExt_sharedPair_one_key`): it counts occurrences in flight, and merging two
occurrences into one site means comparing labels, which nothing in this
package is allowed to do.

## Semantic width, and a finding about the grade

Stage 2b adds the count the grade index was supposed to be about: `Term.peak`,
the consultation sites a run can have in flight, in Mathlib's `ℕ∞`. It is
anchored to `muExt` rather than to the grade's arithmetic — a term of peak zero
means the same thing in every world (`muExt_indep_of_peak_eq_zero`), which is a
property `widthT` does not have at zero (`widthE_zero_not_indep`).

The bound that was expected, `peak t ≤ widthT t`, is **false**, and both
directions fail: `dupPair` peaks at two with a grade width of zero, and
`fanT 7 (pureT id)` peaks at zero with a grade width of seven. Grade width
counts copies of a written shell, not consultations. What is true is
`peak t ≤ writtenSites t * copiesT t` — the consultations written times the
copies the grade admits — and it is tight at both witnesses.
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
homomorphism check between two ways of doing one piece of arithmetic. Nothing
here counts a consultation.

The *semantic* width — consultations in flight at a run — is Stage 2b's
`Term.peak`, and the comparison between the two is not the one this section
used to promise. `peak t ≤ widthT t` is **false**
(`Term.peak_not_le_widthE`: `dupPair` has two consultations in flight and a
grade width of zero), because grade width counts *copies of a written shell*
and `peak` counts consultations. What the grade does bound is one factor of the
count, `peak t ≤ writtenSites t * copiesT t`
(`Term.peak_le_writtenSites_mul_copiesT`), and that is what makes a `.bounded n`
index a statement about a run.

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
term and nothing else. It is the grade's arithmetic re-run as a term fold. It
was *intended* to bound how many consultations can be outstanding at once, and
it does not: `Term.peak` counts those, and it is neither above nor below this
fold (`Term.peak_not_le_widthE`, `Term.peak_lt_widthE_fanT_pureT`). What this
number is, exactly, is the number of copies of the written shell that values
can bring into flight — the second factor of the true bound,
`Term.peak_le_writtenSites_mul_copiesT`.

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
counts consultations. The count is `Term.peak` (Stage 2b), the statement that
turns a `.bounded 3` index into a fact about a run is
`Term.peak_le_of_bounded`, and it needed a second factor — the consultations
the term has *written* — because this fold and the count are incomparable
(`Term.peak_not_le_widthE`).

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
anything independent. The semantic bound is Stage 2b's, and it is not this
statement with `peak` written in: a run of `fanT n t` has at most
`writtenSites t * n * max 1 m` consultations in flight
(`Term.peak_le_writtenSites_mul_copiesT` at a fan), the extra factor being the
consultations the body has written, which no width claim mentions.

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

/-- `Site.strip p s` is `some t` when `s` is `p ++ t`, and `none` when `s` does
not begin with `p`: the one decision a site-relabelling has to make, namely
*is this site below the node I am rewriting at*.

It is written here rather than taken from the list library because the library
spelling that answers the same question (`List.isPrefixOf` plus `List.drop`)
answers it in two steps and forces the caller to re-derive the remainder from a
`Bool`; `strip` returns the remainder with the decision, which is exactly the
shape `Key.relocate` consumes. Decidability comes from `Step`'s derived
`DecidableEq` and asks nothing of `L`, so the fold's promise that labels are
never compared survives into the relabelling machinery. -/
def Site.strip : Site → Site → Option Site
  | [], s => some s
  | _ :: _, [] => none
  | a :: as, b :: bs => if a = b then Site.strip as bs else none

/-- Stripping a genuine prefix returns the remainder. -/
theorem Site.strip_append (p s : Site) : Site.strip p (p ++ s) = some s := by
  induction p with
  | nil => rfl
  | cons a as ih => simp [Site.strip, ih]

/-- Two sites that diverge at the same position are not below one another:
this is what keeps a relabelling of the left branch from touching the right. -/
theorem Site.strip_diverge (p : Site) {a b : Step} (hab : a ≠ b) (s t : Site) :
    Site.strip (p ++ a :: s) (p ++ b :: t) = none := by
  induction p with
  | nil => simp [Site.strip, hab]
  | cons c cs ih => simp [Site.strip, ih]

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

/-- Descend a whole path at once: `k.extend s` is `k` with the site `s`
appended, leaving the base alone. `push` is the one-step case, and the two
lemmas below are all a fold-transport proof ever needs about paths.

This is what makes "the keys a term reads at, from base `k`" a *set with a
description*: every key `muExt` consults below `k` is either `k.extend s` for
the path `s` it walked, or — past a `shareT` — `Key.rebase l |>.extend s`. -/
def extend : Key L → Site → Key L
  | .abs s₀, s => .abs (s₀ ++ s)
  | .rel l s₀, s => .rel l (s₀ ++ s)

/-- An absolute key's descent is an append: the form every relabelling proof
normalises to. -/
theorem push_abs (s : Site) (st : Step) :
    (Key.abs s : Key L).push st = .abs (s ++ [st]) := rfl

/-- Descending nowhere is staying put. -/
theorem extend_nil (k : Key L) : k.extend [] = k := by
  cases k <;> simp [extend]

/-- One step then a path is the path with the step in front. -/
theorem push_extend (k : Key L) (st : Step) (s : Site) :
    (k.push st).extend s = k.extend (st :: s) := by
  cases k <;> simp [extend, push]

/-- A rebased key's descendants are exactly the label's own sites. -/
theorem rebase_extend (l : L) (s : Site) : (Key.rebase l).extend s = .rel l s := by
  simp [rebase, extend]

/-- **A site relabelling**: `relocate base φ` rewrites the path *below* the
absolute site `base` by `φ`, and leaves everything else — every site not below
`base`, and *every* label-based key — exactly where it was.

This is the whole vocabulary the coarsening needs. Erasing a `gate` step is
`relocate s List.tail`; inserting one is `relocate s (Step.gate :: ·)`;
reassociating a `seq` is `relocate s` of a three-clause match on the next two
steps. Each is a finite, decidable rewrite of a path, which is why the laws
below are proved rather than postulated.

That `rel` keys are untouched is not an oversight: a labelled site is *named*,
not positioned, so a renaming of positions has no business moving it — and
that restraint is exactly what keeps `dupPair` and `sharedPair` apart under the
coarser equality (`WEqR_dupPair_ne_sharedPair`). -/
def relocate (base : Site) (φ : Site → Site) : Key L → Key L
  | .abs s => match Site.strip base s with
      | some rest => .abs (base ++ φ rest)
      | none => .abs s
  | .rel l s => .rel l s

/-- A relocation acts on the sites below its base by `φ`. -/
theorem relocate_abs (base : Site) (φ : Site → Site) (s : Site) :
    (relocate (L := L) base φ) (.abs (base ++ s)) = .abs (base ++ φ s) := by
  simp [relocate, Site.strip_append]

/-- **Two relabellings, spliced at a branch**: `splice s st₁ st₂ σ₁ σ₂` runs
`σ₁` on the sites below `s ++ [st₁]`, `σ₂` on those below `s ++ [st₂]`, and
fixes the rest. It is what turns "each child of a node has a relabelling" into
"the node has one", which is the congruence proof for every binary
constructor. -/
def splice (s : Site) (st₁ st₂ : Step) (σ₁ σ₂ : Key L → Key L) : Key L → Key L
  | .abs t => match Site.strip (s ++ [st₁]) t with
      | some _ => σ₁ (.abs t)
      | none => match Site.strip (s ++ [st₂]) t with
        | some _ => σ₂ (.abs t)
        | none => .abs t
  | .rel l t => .rel l t

/-- Below the first branch, the splice is the first relabelling. -/
theorem splice_left (s : Site) (st₁ st₂ : Step) (σ₁ σ₂ : Key L → Key L) (t : Site) :
    splice s st₁ st₂ σ₁ σ₂ (.abs (s ++ st₁ :: t)) = σ₁ (.abs (s ++ st₁ :: t)) := by
  have h₁ : Site.strip (s ++ [st₁]) (s ++ st₁ :: t) = some t := by
    have hh : s ++ st₁ :: t = (s ++ [st₁]) ++ t := by simp
    rw [hh, Site.strip_append]
  simp only [splice]
  rw [h₁]

/-- Below the second branch — which is a *different* branch, by `hst` — the
splice is the second relabelling. -/
theorem splice_right (s : Site) {st₁ st₂ : Step} (hst : st₁ ≠ st₂)
    (σ₁ σ₂ : Key L → Key L) (t : Site) :
    splice s st₁ st₂ σ₁ σ₂ (.abs (s ++ st₂ :: t)) = σ₂ (.abs (s ++ st₂ :: t)) := by
  have hne : Site.strip (s ++ [st₁]) (s ++ st₂ :: t) = none :=
    Site.strip_diverge s hst [] t
  have h₂ : Site.strip (s ++ [st₂]) (s ++ st₂ :: t) = some t := by
    have hh : s ++ st₂ :: t = (s ++ [st₂]) ++ t := by simp
    rw [hh, Site.strip_append]
  simp only [splice]
  rw [hne, h₂]

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

/-- **A relabelling** is a map on keys that may move absolute sites anywhere it
likes but fixes every label-based key.

The asymmetry is the design's, not a convenience: an absolute site is a
*position*, and positions are what structural rearrangement renames, while a
`rel` key is a *name* the designer wrote, and no rearrangement renames it.
Coarsening the equality by exactly this class of maps is therefore the largest
coarsening that still cannot forge sharing — see `WEqR_dupPair_ne_sharedPair`,
where a term that reads one labelled site twice stays distinct from a term that
reads two positional sites, whatever relabelling is applied. -/
def Relabels {L : Type} (σ : Key L → Key L) : Prop :=
  ∀ (l : L) (s : Site), σ (.rel l s) = .rel l s

/-- Identity relabels nothing, which is why every `WEq` pair is a `WEqR` pair. -/
theorem Relabels.id {L : Type} : Relabels (fun k : Key L => k) := fun _ _ => rfl

/-- Relabellings compose, which is why `WLe` is transitive. -/
theorem Relabels.comp {L : Type} {σ τ : Key L → Key L} (hσ : Relabels σ)
    (hτ : Relabels τ) : Relabels (fun k => σ (τ k)) := by
  intro l s
  show σ (τ (.rel l s)) = .rel l s
  rw [hτ l s, hσ l s]

/-- A relocation is a relabelling: it never touches a labelled key. -/
theorem Relabels.relocate {L : Type} (base : Site) (φ : Site → Site) :
    Relabels (Key.relocate (L := L) base φ) := fun _ _ => rfl

/-- A splice of two relabellings is a relabelling. -/
theorem Relabels.splice {L : Type} (s : Site) (st₁ st₂ : Step)
    (σ₁ σ₂ : Key L → Key L) : Relabels (Key.splice (L := L) s st₁ st₂ σ₁ σ₂) :=
  fun _ _ => rfl

/-- **Transporting a runner along a relabelling**: `run.rename σ` is the world
consulted through a renaming of sites. This is the one operation the coarsened
equality is defined against — two terms are equal when each can be read as the
other *by relabelling the world's index*, which is precisely "the two differ
only in where their consultations sit". -/
def Runner.rename {Op : Type → Type → Type} {G L : Type} (run : Runner Op G L)
    (σ : Key L → Key L) : Runner Op G L :=
  fun g k => run g (σ k)

/-- Renaming by the identity is no renaming. -/
theorem Runner.rename_id {Op : Type → Type → Type} {G L : Type}
    (run : Runner Op G L) : run.rename (fun k => k) = run := rfl

/-- Renaming twice is renaming once, by the composite. -/
theorem Runner.rename_rename {Op : Type → Type → Type} {G L : Type}
    (run : Runner Op G L) (σ τ : Key L → Key L) :
    (run.rename σ).rename τ = run.rename (fun k => σ (τ k)) := rfl

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

section Transport

/-! ### The runner-transport lemma

Everything in Stage 3 rests on one lemma: *a term read from one base is the
same term read from another, provided the world is transported along the
relabelling that connects the two bases*. It is proved once, by the same
twelve-constructor induction as `muExt_key_irrelevant`, and every law of the
quotient is an instance of it with a different finite rewrite of paths. -/

variable {Op : Type → Type → Type} {G L : Type} [PMonoid G]

/-- Two worlds *agree below a pair of bases* when asking the first at `k₁`
extended by a path gives what asking the second at `k₀` extended by the same
path gives. This is the induction hypothesis of the transport lemma, named so
that the descent (`AgreeBelow.push`) can be stated. -/
def AgreeBelow (run₁ run₂ : Runner Op G L) (k₁ k₀ : Key L) : Prop :=
  ∀ (g : G) (s : Site) {a b : Type} (op : Op a b) (x : a),
    run₁ g (k₁.extend s) op x = run₂ g (k₀.extend s) op x

omit [PMonoid G] in
/-- Agreement below a pair of bases descends into any child. -/
theorem AgreeBelow.push {run₁ run₂ : Runner Op G L} {k₁ k₀ : Key L}
    (h : AgreeBelow run₁ run₂ k₁ k₀) (st : Step) :
    AgreeBelow run₁ run₂ (k₁.push st) (k₀.push st) := by
  intro g s a b op x
  rw [Key.push_extend, Key.push_extend]
  exact h g (st :: s) op x

/-- **The runner-transport lemma.** If two worlds agree below a pair of bases —
and agree on every labelled key, which is where `shareT` sends the fold no
matter what base it was read from — then every term means the same read from
either base.

The two hypotheses are exactly the two ways `muExt` can produce a key: descent
from the base in force, and the rebase of `shareT`. Nothing else is available
to the fold, which is why this induction is complete rather than merely
plausible, and why the coarsening below is forced to fix labelled keys: they
are the keys no change of base can move. -/
theorem muExt_transport {run₁ run₂ : Runner Op G L}
    (hrel : ∀ (g : G) (l : L) (s : Site) {a b : Type} (op : Op a b) (x : a),
      run₁ g (.rel l s) op x = run₂ g (.rel l s) op x) :
    ∀ {f : Frag} {i o : Type} (t : Term Op G L f i o) (k₁ k₀ : Key L),
      AgreeBelow run₁ run₂ k₁ k₀ → ∀ g : G,
        muExt run₁ t g k₁ = muExt run₂ t g k₀ := by
  intro f i o t
  induction t with
  | prim op =>
    intro k₁ k₀ h g
    funext a
    have hb := h g [] op a
    rwa [Key.extend_nil, Key.extend_nil] at hb
  | pureT fn => intro _ _ _ _; rfl
  | seqT t u ih₁ ih₂ =>
    intro k₁ k₀ h g
    funext a
    rw [muExt_seqT, muExt_seqT, ih₁ (k₁.push .seqL) (k₀.push .seqL) (h.push _) g]
    cases muExt run₂ t g (k₀.push .seqL) a with
    | none => rfl
    | some b => exact congrFun (ih₂ (k₁.push .seqR) (k₀.push .seqR) (h.push _) g) b
  | parT t u ih₁ ih₂ =>
    intro k₁ k₀ h g
    funext p
    rw [muExt_parT, muExt_parT, ih₁ (k₁.push .parL) (k₀.push .parL) (h.push _) g,
      ih₂ (k₁.push .parR) (k₀.push .parR) (h.push _) g]
  | sumT t u ih₁ ih₂ =>
    intro k₁ k₀ h g
    funext a
    rw [muExt_sumT, muExt_sumT, ih₁ (k₁.push .sumL) (k₀.push .sumL) (h.push _) g,
      ih₂ (k₁.push .sumR) (k₀.push .sumR) (h.push _) g]
  | choiceT t u ih₁ ih₂ =>
    intro k₁ k₀ h g
    funext x
    cases x with
    | inl a =>
      exact congrFun (ih₁ (k₁.push .choiceL) (k₀.push .choiceL) (h.push _) g) a
    | inr b =>
      exact congrFun (ih₂ (k₁.push .choiceR) (k₀.push .choiceR) (h.push _) g) b
  | gateT b t ih =>
    intro k₁ k₀ h g
    cases b with
    | false => rfl
    | true => exact ih (k₁.push .gate) (k₀.push .gate) (h.push _) g
  | scopeT hs t ih =>
    intro k₁ k₀ h g
    exact ih (k₁.push .scope) (k₀.push .scope) (h.push _) (g ⋄ hs)
  | shareT l t ih =>
    intro _ _ _ g
    refine ih (Key.rebase l) (Key.rebase l) ?_ g
    intro g' s a b op x
    exact hrel g' l s op x
  | retryT n t ih =>
    intro k₁ k₀ h g
    funext a
    exact retryLoop_congr
      (fun trip a' => congrFun
        (ih (k₁.push (.retry trip)) (k₀.push (.retry trip)) (h.push _) g) a') n 0 a
  | fanT n t ih =>
    intro k₁ k₀ h g
    funext as
    exact fanRun_congr
      (fun ix a => congrFun
        (ih (k₁.push (.fan ix)) (k₀.push (.fan ix)) (h.push _) g) a) 0 (as.take n)
  | bindT t kf ih₁ ih₂ =>
    intro k₁ k₀ h g
    funext a
    rw [muExt_bindT, muExt_bindT, ih₁ (k₁.push .bindL) (k₀.push .bindL) (h.push _) g]
    cases muExt run₂ t g (k₀.push .bindL) a with
    | none => rfl
    | some b =>
      exact congrFun (ih₂ b (k₁.push .bindR) (k₀.push .bindR) (h.push _) g) PUnit.unit

/-- **Reading a term at a moved base is reading the renamed world at the
original base.** This is the transport lemma with the two runners taken to be
one world seen through a relabelling, and it is the form every law uses: to
prove that two shapes mean the same thing, exhibit the finite path rewrite that
carries one shape's sites onto the other's. -/
theorem muExt_rename {run : Runner Op G L} {σ : Key L → Key L} (hσ : Relabels σ)
    {f : Frag} {i o : Type} (t : Term Op G L f i o) (s₁ s₀ : Site)
    (h : ∀ s : Site, σ (.abs (s₁ ++ s)) = .abs (s₀ ++ s)) (g : G) :
    muExt (run.rename σ) t g (.abs s₁) = muExt run t g (.abs s₀) := by
  refine muExt_transport (run₁ := run.rename σ) (run₂ := run) ?_ t _ _ ?_ g
  · intro g' l s a b op x
    show run g' (σ (.rel l s)) op x = _
    rw [hσ l s]
  · intro g' s a b op x
    show run g' (σ (.abs (s₁ ++ s))) op x = run g' (.abs (s₀ ++ s)) op x
    rw [h s]

/-- **Relabellings that agree below the base are interchangeable.** Two
renamings may do anything they like elsewhere; what a term reads from base `s₁`
depends only on their values below `s₁` — and on labelled keys, which both fix.
This is what lets the congruence proofs splice two children's relabellings into
one for the node. -/
theorem muExt_rename_congr {run : Runner Op G L} {σ τ : Key L → Key L}
    (hσ : Relabels σ) (hτ : Relabels τ)
    {f : Frag} {i o : Type} (t : Term Op G L f i o) (s₁ : Site)
    (h : ∀ s : Site, σ (.abs (s₁ ++ s)) = τ (.abs (s₁ ++ s))) (g : G) :
    muExt (run.rename σ) t g (.abs s₁) = muExt (run.rename τ) t g (.abs s₁) := by
  refine muExt_transport (run₁ := run.rename σ) (run₂ := run.rename τ) ?_ t _ _ ?_ g
  · intro g' l s a b op x
    show run g' (σ (.rel l s)) op x = run g' (τ (.rel l s)) op x
    rw [hσ l s, hτ l s]
  · intro g' s a b op x
    show run g' (σ (.abs (s₁ ++ s))) op x = run g' (τ (.abs (s₁ ++ s))) op x
    rw [h s]

end Transport

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

/-- The answer sheet that answers *under a gate* differently from *at the
root*: the world that can see a no-op node. It is what makes the fine equality
`WEq` strictly finer than the coarsened `WEqR` (`WEqR_strictly_coarser`) — the
gate step is invisible to the coarsening and visible to this sheet. -/
def epsGateKey : Env (Key Nat) Nat
  | .abs [Step.gate] => 1
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

/-! ## Stage 2b — semantic width: consultations in flight, and what the grade
actually bounds

Stage 1b's `widthT` folds the *grade's* arithmetic out of the term, and
`widthT_eq_width` checks that fold against the index the constructors computed.
Both sides are syntax, and the check carries no information about meaning: it
is happy to weigh `fanT 7 (pureT id)` at seven while that term consults nothing
at all. This section builds the quantity the grade was supposed to be a bound
on, and then reports what is true of the pair — which is not what was expected.

**`peak`, and why it is not the grade arithmetic again.** `peak` counts
*consultation sites*: a `prim` is one, a `pureT` is none, and every other
clause combines its children by how they sit in time. Sequencing, alternation
and branching take the larger of their children (only one of them is in flight
at a time); a tensor adds (both are); a fan of `n` multiplies by `n` (the copies
are in flight together, and `0` copies are `0` consultations — no `max 1` here,
because that correction belongs to the grade's *shell* arithmetic, not to a
count of consultations); a shut gate is `0`, because nothing under it runs;
labels, scopes and fuel change nothing; and `bindT` is `⊤`, an opaque
continuation forfeiting any a-priori count. So the two folds part company
immediately: `peak (prim q) = 1` where `widthT (prim q) = some 0`, and
`peak (fanT 7 (pureT id)) = 0` where `widthT` says seven.

The target is Mathlib's `ℕ∞` — `WithTop ℕ`, whose `⊤` is the monadic
fragment's silence and whose order, `max`, `+` and `*` are the ones from the
shelf. (That order's `max` is the complete lattice's, so the fold is
`noncomputable`; it is a specification of a count, not a metering
instrument.)

**What makes it semantic.** `muExt_indep_of_peak_eq_zero`: a term whose peak is
`0` has a meaning that does not depend on the runner *at all* — every world
gives it the same partial function. That is a statement about `⟦·⟧_ext`, proved
by the same twelve-constructor induction as the rest of this module, and it is
the property `widthT` conspicuously lacks: `widthT (prim q) = some 0` while
`prim q` reads whatever the world says (`widthE_zero_not_indep`). A fold
answering `0` on a term that consults is not measuring consultations, and a
fold answering `7` on a term that consults nothing is not measuring them
either.

**The inequality acat-vbl asked for is false.** `peak t ≤ widthT t` fails, and
the counterexample is the package's own memorialized pair: `peak (dupPair q)`
is two consultations and `widthT (dupPair q)` is `some 0`
(`peak_not_le_widthE`). The reason is not a bug in either fold — it is what
grade width *means*. `Frag.width` measures data-dependent width, the number of
copies of a written shell that values can bring into flight, and `static` is
the grade of "no copies beyond the one you wrote", not of "no consultations".
Two `prim`s side by side are two consultations and one shell. So the grade
never bounded the count, and no amount of arithmetic agreement between `widthT`
and `Frag.width` was going to make it.

**The inequality that is true.** What the grade bounds is one *factor* of the
count:

`peak t ≤ writtenSites t * copiesT t`

— the peak number of consultations in flight is at most the number of
consultations *written* in the term times the number of copies the grade
admits (`Frag.copies`, which is the grade's own `max 1 m` from `Frag.wScale`:
the shell counts as one copy of itself). Neither factor can be dropped, and the
bound is *tight* at both of the witnesses that refute the naive one:
`fanT 7 (pureT id)` has seven copies of nothing (`0 = 0 * 7`) and `dupPair` has
two writings of one copy (`2 = 2 * 1`). It is not an equality — sequencing puts
two written sites in flight one at a time (`peak_lt_bound_seqT`).

Read at the fragments, this is the discipline the grade was supposed to
deliver: a `static` term has at most as many consultations in flight as it has
consultations written (`peak_le_writtenSites_of_static`), and a `bounded n`
term at most `n` times that (`peak_le_of_bounded`).

**Sharing, and a discovery.** `peak` counts *occurrences* in flight, so
`peak (sharedPair l q) = 2` exactly as `peak (dupPair q) = 2` — and yet the run
of the shared pair touches the single key `Key.rel l []`
(`muExt_sharedPair_one_key`) while the duplicated pair touches two
(`muExt_dupPair_two_keys`). By the reading of §6a that "share costs one", the
shared pair's semantic width is one, not two, and `peak` over-counts it by
exactly the number of extra reads — the same over-charge `muS` makes, arrived
at from the other side. The count is left at occurrences deliberately: merging
sites means comparing labels, and `L` is not required to have decidable
equality anywhere in this package (`muExt_shareT`), so a distinct-key count
needs either a `DecidableEq L` hypothesis or a set-valued fold. That is
recorded as discovered work rather than smuggled in, because it changes what
`peak` means and not merely how it is computed.
-/

namespace Frag

/-- A width claim, read in Mathlib's `ℕ∞`: silence is `⊤`.

`Frag.width`'s `none` is "no a-priori width", and `⊤` in `WithTop ℕ` is the
element that says exactly that while still being comparable to every numeral —
which is what the bound below needs and what `Option Nat`'s own order (where
`none` is `⊥`) would get backwards. -/
def ofWidth : Option Nat → ℕ∞
  | none => ⊤
  | some n => (n : ℕ∞)

/-- **The copies a grade admits**: `max 1` of the claim.

The `max 1` is not a fudge; it is `Frag.wScale`'s own arithmetic (acat-l59)
read one level up. A grade's width counts *data-dependent* copies of a written
shell, and the shell always counts as one copy of itself, so a `static` term
admits one copy and not zero. This is the factor the bound below multiplies the
written sites by. -/
noncomputable def copies (w : Option Nat) : ℕ∞ := max 1 (ofWidth w)

/-- Every grade admits at least one copy. -/
theorem one_le_copies (w : Option Nat) : 1 ≤ copies w := le_max_left _ _

/-- Hence no grade admits zero copies — which is what keeps the bound's
right-hand side from collapsing at `⊤`. -/
theorem copies_ne_zero (w : Option Nat) : copies w ≠ 0 := by
  intro h
  have h1 := one_le_copies w
  rw [h] at h1
  exact absurd h1 (by simp)

/-- Copies at a finite claim, with the `max` moved inside the cast: the form
every arithmetic step below uses. -/
theorem copies_some (m : Nat) : copies (some m) = ((max 1 m : Nat) : ℕ∞) := by
  show max 1 ((m : Nat) : ℕ∞) = _
  exact_mod_cast rfl

/-- Copies at silence: unboundedly many. -/
theorem copies_none : copies none = ⊤ := by
  show max 1 (⊤ : ℕ∞) = ⊤
  simp

/-- Copies is monotone in the claim. -/
theorem copies_mono {w₁ w₂ : Option Nat} (h : ofWidth w₁ ≤ ofWidth w₂) :
    copies w₁ ≤ copies w₂ := max_le_max le_rfl h

/-- The width of a join dominates its left claim. -/
theorem ofWidth_le_wMax_left (w₁ w₂ : Option Nat) :
    ofWidth w₁ ≤ ofWidth (wMax w₁ w₂) := by
  cases w₁ with
  | none => exact le_of_eq rfl
  | some a =>
    cases w₂ with
    | none => exact le_top
    | some b =>
      show ((a : Nat) : ℕ∞) ≤ ((max a b : Nat) : ℕ∞)
      exact_mod_cast le_max_left a b

/-- The width of a join dominates its right claim. -/
theorem ofWidth_le_wMax_right (w₁ w₂ : Option Nat) :
    ofWidth w₂ ≤ ofWidth (wMax w₁ w₂) := by
  cases w₁ with
  | none => exact le_top
  | some a =>
    cases w₂ with
    | none => exact le_of_eq rfl
    | some b =>
      show ((b : Nat) : ℕ∞) ≤ ((max a b : Nat) : ℕ∞)
      exact_mod_cast le_max_right a b

/-- The width of a tensor dominates its left branch's claim. -/
theorem ofWidth_le_wAdd_left (w₁ w₂ : Option Nat) :
    ofWidth w₁ ≤ ofWidth (wAdd w₁ w₂) := by
  cases w₁ with
  | none => exact le_of_eq rfl
  | some a =>
    cases w₂ with
    | none => exact le_top
    | some b =>
      show ((a : Nat) : ℕ∞) ≤ ((a + b : Nat) : ℕ∞)
      exact_mod_cast Nat.le_add_right a b

/-- The width of a tensor dominates its right branch's claim. -/
theorem ofWidth_le_wAdd_right (w₁ w₂ : Option Nat) :
    ofWidth w₂ ≤ ofWidth (wAdd w₁ w₂) := by
  cases w₁ with
  | none => exact le_top
  | some a =>
    cases w₂ with
    | none => exact le_of_eq rfl
    | some b =>
      show ((b : Nat) : ℕ∞) ≤ ((a + b : Nat) : ℕ∞)
      exact_mod_cast Nat.le_add_left b a

/-- **A fan multiplies the copies**, provided it has at least one: this is the
one arithmetic identity the fan case of the bound turns on, and it is where
`wScale`'s `max 1` pays for itself — `n` copies of a shell that already counts
once is `n * max 1 m`, which is `≥ 1`, so the outer `max 1` is absorbed. -/
theorem copies_wScale_some {n : Nat} (hn : 0 < n) (m : Nat) :
    copies (wScale n (some m)) = (n : ℕ∞) * copies (some m) := by
  show copies (some (n * max 1 m)) = _
  rw [copies_some, copies_some]
  have h1 : max 1 (n * max 1 m) = n * max 1 m :=
    max_eq_right (Nat.one_le_iff_ne_zero.mpr
      (Nat.mul_ne_zero (by omega) (by omega)))
  rw [h1]
  exact_mod_cast rfl

end Frag

namespace Term

variable {Op : Type → Type → Type} {G L : Type}

/-- **The semantic width**: how many consultation sites a run of this workflow
can have in flight at once.

This is the fold acat-vbl asked for, and the one thing it must not do is re-run
the grade's arithmetic. It counts *consultations*, so only a path that reaches
a `prim` contributes:

| clause | peak | why |
|---|---|---|
| `prim op` | `1` | one consultation |
| `pureT fn` | `0` | a Transform consults nothing |
| `seqT t u` | `max` | the stages are not in flight together |
| `parT t u` | `+` | both branches are |
| `sumT`, `choiceT` | `max` | one alternative runs |
| `gateT false t` | `0` | nothing under a shut gate runs |
| `gateT true t` | `peak t` | an open gate is no gate |
| `scopeT`, `shareT` | `peak t` | annotations move no consultation |
| `retryT n t` | `peak t` | the max over trips; the trips are sequential |
| `fanT n t` | `n * peak t` | the copies are in flight together |
| `bindT t k` | `⊤` | an opaque continuation forfeits the count |

Two clauses deserve their reasons written down. `fanT` multiplies by `n` with
no `max 1`: `fanT 0 t` runs nothing, and a fan of a body that consults nothing
consults nothing however wide it is — the `max 1` of `Frag.wScale` is about
copies of a *shell*, and a shell is not a consultation. `retryT` takes the max
over trips rather than the sum because a fueled loop's trips happen one after
another; that they are *distinct sites* (`Step.retry trip`) is the keying
decision of `Step`, and distinct sites visited in sequence are not sites in
flight together.

`noncomputable` because Mathlib's `max` at `ℕ∞` comes from its complete
lattice. That is honest for what this is: a specification of a count, not a
meter to run. -/
noncomputable def peak {Op : Type → Type → Type} {G L : Type} :
    ∀ {f : Frag} {i o : Type}, Term Op G L f i o → ℕ∞
  | _, _, _, .prim _ => 1
  | _, _, _, .pureT _ => 0
  | _, _, _, .seqT t u => max (peak t) (peak u)
  | _, _, _, .parT t u => peak t + peak u
  | _, _, _, .sumT t u => max (peak t) (peak u)
  | _, _, _, .choiceT t u => max (peak t) (peak u)
  | _, _, _, .gateT b t => if b then peak t else 0
  | _, _, _, .scopeT _ t => peak t
  | _, _, _, .shareT _ t => peak t
  | _, _, _, .retryT _ t => peak t
  | _, _, _, .fanT n t => (n : ℕ∞) * peak t
  | _, _, _, .bindT _ _ => ⊤

/-- **The consultations a workflow has written in it**: `prim` occurrences,
counted once each, with a fan's body counted once because it is *written*
once.

This is the static factor of the bound below — the part the grade says nothing
about and the term says everything about. It over-counts on purpose in two
places: a shut gate's body is still written, and both arms of a `choiceT` are,
so `writtenSites` is an upper bound on what any single run could reach and
`peak` is free to be smaller. `bindT` is `⊤`: an opaque continuation may be
any term, so no finite number of written sites can be claimed. -/
def writtenSites {Op : Type → Type → Type} {G L : Type} :
    ∀ {f : Frag} {i o : Type}, Term Op G L f i o → ℕ∞
  | _, _, _, .prim _ => 1
  | _, _, _, .pureT _ => 0
  | _, _, _, .seqT t u => writtenSites t + writtenSites u
  | _, _, _, .parT t u => writtenSites t + writtenSites u
  | _, _, _, .sumT t u => writtenSites t + writtenSites u
  | _, _, _, .choiceT t u => writtenSites t + writtenSites u
  | _, _, _, .gateT _ t => writtenSites t
  | _, _, _, .scopeT _ t => writtenSites t
  | _, _, _, .shareT _ t => writtenSites t
  | _, _, _, .retryT _ t => writtenSites t
  | _, _, _, .fanT _ t => writtenSites t
  | _, _, _, .bindT _ _ => ⊤

/-- The grade's width claim about a term, read in `ℕ∞`: `widthT` with `none`
sent to `⊤`. This is the form in which the claim can be compared with `peak`
at all, and the comparison is the discovery recorded above. -/
def widthE {f : Frag} {i o : Type} (t : Term Op G L f i o) : ℕ∞ :=
  Frag.ofWidth (widthT t)

/-- The number of copies of its written shell a term's grade admits. -/
noncomputable def copiesT {f : Frag} {i o : Type} (t : Term Op G L f i o) : ℕ∞ :=
  Frag.copies (widthT t)

/-- **The grade bounds the data-dependent factor of the semantic width.**

At most `writtenSites t` consultations are written, at most `copiesT t` copies
of the written shell can be in flight, and the peak is at most their product.
This is the honest replacement for the bound acat-vbl asked for (`peak t ≤
widthT t`), which is false (`peak_not_le_widthE`) because grade width counts
copies and `peak` counts consultations.

Both factors are load-bearing and the bound is tight at the two witnesses that
kill the naive statement: at `fanT 7 (pureT id)` the copies are seven and the
written sites are zero (`0 = 0 * 7`), at `dupPair` the written sites are two
and the copies are one (`2 = 2 * 1`, `peak_dupPair_eq_bound`). It is an
inequality and not an equation because sequencing writes two sites and puts one
in flight (`peak_lt_bound_seqT`).

The proof is the twelve-constructor induction, with the arithmetic done in
`ℕ∞`: `max` and `+` need only monotonicity of `Frag.copies` in the claim, and
`fanT` needs `Frag.copies_wScale_some` plus the two degenerate cases — a fan of
no copies (`0 ≤ anything`) and a fan over a monadic body, where the body's own
bound forces `peak = 0` if nothing is written and `⊤` absorbs otherwise. -/
theorem peak_le_writtenSites_mul_copiesT :
    ∀ {f : Frag} {i o : Type} (t : Term Op G L f i o),
      peak t ≤ writtenSites t * copiesT t := by
  intro f i o t
  induction t with
  | prim op =>
    show (1 : ℕ∞) ≤ 1 * Frag.copies (some 0)
    rw [Frag.copies_some, one_mul]
    have h1 : max 1 0 = 1 := by decide
    rw [h1]
    simp
  | pureT fn => exact zero_le
  | seqT t u ih₁ ih₂ =>
    show max (peak t) (peak u)
        ≤ (writtenSites t + writtenSites u) * Frag.copies (Frag.wMax (widthT t) (widthT u))
    refine max_le (ih₁.trans ?_) (ih₂.trans ?_)
    · gcongr
      · exact le_self_add
      · exact Frag.copies_mono (Frag.ofWidth_le_wMax_left _ _)
    · gcongr
      · exact le_add_self
      · exact Frag.copies_mono (Frag.ofWidth_le_wMax_right _ _)
  | parT t u ih₁ ih₂ =>
    show peak t + peak u
        ≤ (writtenSites t + writtenSites u) * Frag.copies (Frag.wAdd (widthT t) (widthT u))
    rw [add_mul]
    refine add_le_add (ih₁.trans ?_) (ih₂.trans ?_)
    · gcongr
      exact Frag.copies_mono (Frag.ofWidth_le_wAdd_left _ _)
    · gcongr
      exact Frag.copies_mono (Frag.ofWidth_le_wAdd_right _ _)
  | sumT t u ih₁ ih₂ =>
    show max (peak t) (peak u)
        ≤ (writtenSites t + writtenSites u) * Frag.copies (Frag.wMax (widthT t) (widthT u))
    refine max_le (ih₁.trans ?_) (ih₂.trans ?_)
    · gcongr
      · exact le_self_add
      · exact Frag.copies_mono (Frag.ofWidth_le_wMax_left _ _)
    · gcongr
      · exact le_add_self
      · exact Frag.copies_mono (Frag.ofWidth_le_wMax_right _ _)
  | choiceT t u ih₁ ih₂ =>
    show max (peak t) (peak u)
        ≤ (writtenSites t + writtenSites u) * Frag.copies (Frag.wMax (widthT t) (widthT u))
    refine max_le (ih₁.trans ?_) (ih₂.trans ?_)
    · gcongr
      · exact le_self_add
      · exact Frag.copies_mono (Frag.ofWidth_le_wMax_left _ _)
    · gcongr
      · exact le_add_self
      · exact Frag.copies_mono (Frag.ofWidth_le_wMax_right _ _)
  | gateT b t ih =>
    cases b with
    | false => exact zero_le
    | true => exact ih
  | scopeT h t ih => exact ih
  | shareT l t ih => exact ih
  | retryT n t ih => exact ih
  | fanT n t ih =>
    show (n : ℕ∞) * peak t ≤ writtenSites t * Frag.copies (Frag.wScale n (widthT t))
    rcases Nat.eq_zero_or_pos n with hn | hn
    · subst hn
      rw [Nat.cast_zero, zero_mul]
      exact zero_le
    · have ih' : peak t ≤ writtenSites t * Frag.copies (widthT t) := ih
      cases hw : widthT t with
      | none =>
        rw [hw] at ih'
        rcases eq_or_ne (writtenSites t) 0 with hN | hN
        · rw [hN, Frag.copies_none, zero_mul] at ih'
          have hp : peak t = 0 := le_antisymm ih' zero_le
          rw [hp, mul_zero]
          exact zero_le
        · rw [show Frag.wScale n none = none from rfl, Frag.copies_none,
            ENat.mul_top hN]
          exact le_top
      | some m =>
        rw [hw] at ih'
        rw [Frag.copies_wScale_some hn]
        calc (n : ℕ∞) * peak t
            ≤ (n : ℕ∞) * (writtenSites t * Frag.copies (some m)) :=
              mul_le_mul_right ih' _
          _ = writtenSites t * ((n : ℕ∞) * Frag.copies (some m)) :=
              mul_left_comm _ _ _
  | bindT t kf ih₁ ih₂ =>
    show (⊤ : ℕ∞) ≤ ⊤ * Frag.copies (widthT (Term.bindT t kf))
    rw [ENat.top_mul (Frag.copies_ne_zero _)]

/-- **A static workflow has at most as many consultations in flight as it has
consultations written.** The grade admits one copy, so the bound loses its
second factor — and this is the first statement in the package that makes
`static` mean something about a run rather than about a shape. -/
theorem peak_le_writtenSites_of_static {i o : Type} (t : Term Op G L .static i o) :
    peak t ≤ writtenSites t := by
  have h := peak_le_writtenSites_mul_copiesT t
  have hc : copiesT t = 1 := by
    show Frag.copies (widthT t) = 1
    rw [widthT_static t, Frag.copies_some]
    have h1 : max 1 0 = 1 := by decide
    rw [h1]
    exact Nat.cast_one
  rwa [hc, mul_one] at h

/-- **A `bounded n` workflow has at most `n` times its written consultations in
flight** (with `max 1 n`, so `bounded 0` still admits the one shell it wrote).
This is the `.bounded 3` index finally saying something about what a run does.
-/
theorem peak_le_of_bounded {n : Nat} {i o : Type} (t : Term Op G L (.bounded n) i o) :
    peak t ≤ writtenSites t * ((max 1 n : Nat) : ℕ∞) := by
  have h := peak_le_writtenSites_mul_copiesT t
  have hc : copiesT t = ((max 1 n : Nat) : ℕ∞) := by
    show Frag.copies (widthT t) = _
    rw [widthT_bounded t, Frag.copies_some]
  rwa [hc] at h

/-! ### The witnesses: the two folds are incomparable

Neither `peak ≤ widthE` nor `widthE ≤ peak` holds, and one witness for each
direction is all it takes. Both are terms the package already cares about. -/

/-- **A fan of seven Transforms consults nothing.** This is the term the review
finding named, and the fold now says the true thing about it. -/
theorem peak_fanT_pureT :
    peak (Op := Op) (G := G) (L := L)
      (.fanT 7 (.pureT (fun s : String => s))) = 0 := by
  show ((7 : Nat) : ℕ∞) * 0 = 0
  exact mul_zero _

/-- …and the grade weighs it at seven. -/
theorem widthE_fanT_pureT :
    widthE (Op := Op) (G := G) (L := L)
      (.fanT 7 (.pureT (fun s : String => s))) = ((7 : Nat) : ℕ∞) := rfl

/-- **The strictness witness.** `peak` is *strictly* below the grade's claim at
`fanT 7 (pureT id)`: zero consultations against a width of seven. The gap is
not slack in a bound — it is the grade measuring copies of a shell that
contains no consultation. -/
theorem peak_lt_widthE_fanT_pureT :
    peak (Op := Op) (G := G) (L := L) (.fanT 7 (.pureT (fun s : String => s)))
      < widthE (Op := Op) (G := G) (L := L)
        (.fanT 7 (.pureT (fun s : String => s))) := by
  rw [peak_fanT_pureT, widthE_fanT_pureT]
  exact_mod_cast Nat.succ_pos 6

/-- **Duplication peaks at two.** The corollary acat-vbl asked for: two `prim`
occurrences side by side are two consultations in flight, which is what
`Env.share_ne_dup` said and what no previous fold in this package counted. -/
theorem peak_dupPair (q : Op String Nat) :
    peak (dupPair (G := G) (L := L) q) = 2 := by
  show (1 : ℕ∞) + 1 = 2
  exact one_add_one_eq_two

/-- …and the grade weighs the same term at zero, because two branches of a
tensor whose widths are both `0` add to `0`. -/
theorem widthE_dupPair (q : Op String Nat) :
    widthE (dupPair (G := G) (L := L) q) = 0 := rfl

/-- **The bound acat-vbl asked for is false.** `peak t ≤ widthT t` cannot hold
for every term, and `dupPair` is the counterexample: two consultations in
flight, a grade width of zero.

The finding is not that a fold is wrong. It is that `Frag.width` measures
*data-dependent* width — copies of a written shell — and a count of
consultations is not below it, in either direction
(`peak_lt_widthE_fanT_pureT` goes the other way). What the grade does bound is
one factor of the count, which is `peak_le_writtenSites_mul_copiesT`. -/
theorem peak_not_le_widthE (q : Op String Nat) :
    ¬ ∀ {f : Frag} {i o : Type} (t : Term Op G L f i o), peak t ≤ widthE t := by
  intro h
  have h2 := h (dupPair (G := G) (L := L) q)
  rw [peak_dupPair, widthE_dupPair] at h2
  exact absurd h2 (by simp)

/-- The true bound is tight at `dupPair`: two written sites, one copy, two in
flight. -/
theorem peak_dupPair_eq_bound (q : Op String Nat) :
    peak (dupPair (G := G) (L := L) q)
      = writtenSites (dupPair (G := G) (L := L) q)
        * copiesT (dupPair (G := G) (L := L) q) := by
  show (1 : ℕ∞) + 1 = (1 + 1) * Frag.copies (Frag.wAdd (some 0) (some 0))
  rw [show Frag.wAdd (some 0) (some 0) = some 0 from rfl, Frag.copies_some]
  have h1 : max 1 0 = 1 := by decide
  rw [h1, Nat.cast_one, mul_one]

/-- …and strict at a sequence: two consultations written, one in flight at a
time. This is why the bound is an inequality and why `writtenSites` alone is
not the semantic width. -/
theorem peak_lt_bound_seqT (q : Op String String) :
    peak (Op := Op) (G := G) (L := L) (.seqT (.prim q) (.prim q))
      < writtenSites (Op := Op) (G := G) (L := L) (.seqT (.prim q) (.prim q))
        * copiesT (Op := Op) (G := G) (L := L) (.seqT (.prim q) (.prim q)) := by
  show max (1 : ℕ∞) 1 < (1 + 1) * Frag.copies (Frag.wMax (some 0) (some 0))
  rw [show Frag.wMax (some 0) (some 0) = some 0 from rfl, Frag.copies_some]
  have h1 : max 1 0 = 1 := by decide
  rw [h1, Nat.cast_one, mul_one, max_self]
  exact_mod_cast Nat.one_lt_two

/-- **Sharing does not change the count, and that is a decision.** The labelled
pair peaks at two just as the duplicated one does, because `peak` counts
occurrences in flight and both occurrences are in flight.

The run, however, touches one key (`muExt_sharedPair_one_key` against
`muExt_dupPair_two_keys`), so on the reading of §6a where "share costs one"
this number is an over-count by exactly the number of extra reads — the same
over-charge `muS` makes at `shareT`, reached from the other side. Merging the
count means comparing labels, and nothing in this package requires
`DecidableEq L`; a distinct-key width is a different fold with a different
hypothesis, and it is recorded as discovered work rather than assumed here. -/
theorem peak_sharedPair (l : L) (q : Op String Nat) :
    peak (sharedPair (G := G) l q) = 2 := by
  show (1 : ℕ∞) + 1 = 2
  exact one_add_one_eq_two

/-! ### The anchor: `peak` is about meaning, and `widthT` is not

A fold on syntax is only a *semantic* width if some property of `⟦·⟧_ext`
depends on it. Here is that property, at the one value where it can be stated
without a theory of schedules: a term of peak zero consults nothing, and
therefore means the same thing in every world. -/

/-- **Zero peak is runner-blindness.** If a workflow's semantic width is `0`
then no runner can move its meaning: every world gives it the same partial
function, at every scope and from every key.

This is what makes `peak` a statement about `⟦·⟧_ext` rather than a second
piece of syntax arithmetic. The induction is the module's usual twelve cases,
and each one is the reason the corresponding clause of `peak` was written the
way it was: `prim` is excluded because it counts `1`; `gateT false` is
runner-blind because it is `none`; `fanT 0` is runner-blind because it denotes
the constant `[]` (`muExt_fanT_zero`) — which is precisely why that clause
multiplies by `n` with no `max 1`; `retryT` and `fanT` propagate through
`retryLoop_congr` and `fanRun_congr`; and `bindT` is excluded because `⊤ ≠ 0`.

The converse is *not* claimed and is not provable in this generality: to show
that a positive peak is observable one must build two runners that differ, and
a runner must produce values in an arbitrary `Op`'s answer type, which nothing
here supplies. At a concrete leaf signature it is easy, and
`widthE_zero_not_indep` does exactly that. -/
theorem muExt_indep_of_peak_eq_zero [PMonoid G] (run run' : Runner Op G L) :
    ∀ {f : Frag} {i o : Type} (t : Term Op G L f i o), peak t = 0 →
      ∀ (g : G) (k : Key L), muExt run t g k = muExt run' t g k := by
  intro f i o t
  induction t with
  | prim op =>
    intro h
    exact absurd (h : (1 : ℕ∞) = 0) one_ne_zero
  | pureT fn => intro _ _ _; rfl
  | seqT t u ih₁ ih₂ =>
    intro h g k
    have hm : max (peak t) (peak u) = 0 := h
    have ht : peak t = 0 := le_antisymm (hm ▸ le_max_left _ _) zero_le
    have hu : peak u = 0 := le_antisymm (hm ▸ le_max_right _ _) zero_le
    funext a
    rw [muExt_seqT, muExt_seqT, congrFun (ih₁ ht g (k.push .seqL)) a]
    cases muExt run' t g (k.push .seqL) a with
    | none => rfl
    | some b => exact congrFun (ih₂ hu g (k.push .seqR)) b
  | parT t u ih₁ ih₂ =>
    intro h g k
    have hm : peak t + peak u = 0 := h
    have ht : peak t = 0 := (add_eq_zero.mp hm).1
    have hu : peak u = 0 := (add_eq_zero.mp hm).2
    funext p
    rw [muExt_parT, muExt_parT, congrFun (ih₁ ht g (k.push .parL)) p.1,
      congrFun (ih₂ hu g (k.push .parR)) p.2]
  | sumT t u ih₁ ih₂ =>
    intro h g k
    have hm : max (peak t) (peak u) = 0 := h
    have ht : peak t = 0 := le_antisymm (hm ▸ le_max_left _ _) zero_le
    have hu : peak u = 0 := le_antisymm (hm ▸ le_max_right _ _) zero_le
    funext a
    rw [muExt_sumT, muExt_sumT, congrFun (ih₁ ht g (k.push .sumL)) a,
      congrFun (ih₂ hu g (k.push .sumR)) a]
  | choiceT t u ih₁ ih₂ =>
    intro h g k
    have hm : max (peak t) (peak u) = 0 := h
    have ht : peak t = 0 := le_antisymm (hm ▸ le_max_left _ _) zero_le
    have hu : peak u = 0 := le_antisymm (hm ▸ le_max_right _ _) zero_le
    funext x
    cases x with
    | inl a => exact congrFun (ih₁ ht g (k.push .choiceL)) a
    | inr b => exact congrFun (ih₂ hu g (k.push .choiceR)) b
  | gateT b t ih =>
    intro h g k
    cases b with
    | false => rfl
    | true => exact ih h g (k.push .gate)
  | scopeT hs t ih => intro h g k; exact ih h (g ⋄ hs) (k.push .scope)
  | shareT l t ih => intro h g _; exact ih h g (Key.rebase l)
  | retryT n t ih =>
    intro h g k
    funext a
    exact retryLoop_congr
      (fun trip a' => congrFun (ih h g (k.push (.retry trip))) a') n 0 a
  | fanT n t ih =>
    intro h g k
    have hm : (n : ℕ∞) * peak t = 0 := h
    rcases mul_eq_zero.mp hm with hn | hp
    · have hn0 : n = 0 := by exact_mod_cast hn
      subst hn0
      funext as
      rw [muExt_fanT_zero, muExt_fanT_zero]
    · funext as
      exact fanRun_congr
        (fun ix a => congrFun (ih hp g (k.push (.fan ix))) a) 0 (as.take n)
  | bindT t kf ih₁ ih₂ =>
    intro h
    exact absurd (h : (⊤ : ℕ∞) = 0) WithTop.top_ne_zero

end Term

/-- **The pure fan means one thing in every world.** The corollary of the
anchor at the strictness witness: the term the grade weighs at seven is proved
here to be entirely independent of what the world answers, because its
semantic width is zero. Read the two together — `peak_lt_widthE_fanT_pureT`
and this — and the review finding is discharged in the strongest available
form: the number the grade reports is not a number about this run. -/
theorem muExt_fanT_pureT_indep {Op : Type → Type → Type} {G L : Type} [PMonoid G]
    (run run' : Runner Op G L) (g : G) (k : Key L) :
    Term.muExt run (.fanT 7 (.pureT (fun s : String => s))) g k
      = Term.muExt run' (.fanT 7 (.pureT (fun s : String => s))) g k :=
  Term.muExt_indep_of_peak_eq_zero run run' _ Term.peak_fanT_pureT g k

/-- **A grade width of zero is not runner-blindness.** The leaf `prim ask` has
`widthE = 0` and two worlds that disagree about it, so no theorem of the shape
`muExt_indep_of_peak_eq_zero` can hold for `widthT`.

This is the sharp form of the review finding: `peak = 0` has a semantic
consequence and `widthT = 0` has none, so the two folds are not two spellings
of one measurement. -/
theorem widthE_zero_not_indep :
    Term.widthE (Term.prim (Op := AskOp) (G := LastOpt Unit) (L := Nat) AskOp.ask) = 0
      ∧ Term.muExt (askRunner (G := LastOpt Unit) (L := Nat) (fun _ => 0))
            (Term.prim AskOp.ask) LastOpt.unset Key.root ""
          ≠ Term.muExt (askRunner (G := LastOpt Unit) (L := Nat) (fun _ => 1))
            (Term.prim AskOp.ask) LastOpt.unset Key.root "" :=
  ⟨rfl, by decide⟩

/-- **The shared pair consults one key.** Both branches rebase to `Key.rel 0 []`,
so the answer sheet is read at one site and the two components of the answer
are literally the same value. Against `muExt_dupPair_two_keys` this is the
evidence for the over-count recorded at `peak_sharedPair`: the *occurrences* in
flight are two and the *sites* consulted are one. -/
theorem muExt_sharedPair_one_key (ε : Env (Key Nat) Nat) (a b : String) :
    Term.muExt (askRunner ε) (Term.sharedPair (G := LastOpt Unit) (0 : Nat) AskOp.ask)
        LastOpt.unset Key.root (a, b)
      = some (ε (.rel 0 []), ε (.rel 0 [])) := rfl

/-- **The duplicated pair consults two keys**, one per position, which is what
makes `peak (dupPair q) = 2` the right count for it and an over-count for the
shared pair. -/
theorem muExt_dupPair_two_keys (ε : Env (Key Nat) Nat) (a b : String) :
    Term.muExt (askRunner ε) (Term.dupPair (G := LastOpt Unit) (L := Nat) AskOp.ask)
        LastOpt.unset Key.root (a, b)
      = some (ε (.abs [Step.parL]), ε (.abs [Step.parR])) := rfl

/-! ### What semantic width still owes (discovered work, acat-vbl)

Three things, all of them recorded rather than papered over.

1. **"In flight" is still a fold, not a schedule.** `peak` is defined by
   structural recursion and its clauses encode a *reading* of concurrency —
   `parT` concurrent, `seqT` sequential, `retryT` sequential across trips. A
   width proved against an interleaving semantics would derive those clauses
   instead of postulating them, and would let `peak` be stated as a supremum
   over runs rather than a fold. Nothing in this package has a notion of run
   yet; `muExt` is a partial function, not a trace.

2. **The consultation multiset is not built.** The anchor here is the `peak = 0`
   case, which is the one case a fold can discharge without a trace. A
   `consults : Term → G → Key L → i → List (Key L)` mirroring `muExt`'s own
   control flow would give the *total* count semantically (and the distinct-key
   count, and the quantitative charge for sharing that `muS` still owes,
   acat-qtv). It is a second fold with a second congruence for `retryLoop` and
   `fanRun`, and it was not attempted here.

3. **Sharing's over-count.** `peak_sharedPair` counts occurrences, and
   `muExt_sharedPair_one_key` shows the run touches one site. A distinct-key
   width needs `DecidableEq L` or a set-valued fold; deciding which is a design
   question with the same shape as acat-bmc's (what a label *is*), so it is
   left to that decision rather than pre-empted.
-/
/-! ## Stage 3 — workflow equality is the quotient by meaning

Design §3: *semantic equality is equality of `⟦·⟧_ext`* — "the audit rejected
weakening equality to protect a caching story" — and §8's Lean argument is that
this is a definable type rather than a convention: `Quotient (Setoid.ker
denote)`, with `Quot.lift` turning respect-for-meaning into a proof obligation
the compiler checks.

That is what this section builds, in two equalities rather than one.

`WEq` is extensional equality quantified over all runners, all scopes and all
keys. It is the fine one, and it is *too* fine to be the equality of a
category: every structural rearrangement moves consultation keys, so under
`WEq` the two bracketings of a pipeline are different workflows and deleting an
open gate is a semantic change.

`WEqR` is the same comparison **up to a relabelling of sites**: a term may be
read as another if some finite, decidable rewrite of paths carries the one's
consultations onto the other's, with labelled (`shareT`) keys held fixed. Under
it — and proved, not postulated —

* `gateT true t ≈ t`, `scopeT 1 t ≈ t`, `seqT (pureT id) t ≈ t`,
  `seqT t (pureT id) ≈ t` and `seqT (seqT a b) c ≈ seqT a (seqT b c)`;
* `seqT`, `parT`, `sumT`, `choiceT`, `gateT` and `scopeT` are congruences, so
  they descend to the quotient;
* `Workflow` is the quotient, `Workflow.seq` is composition, the laws hold on
  it, and the static fragment is a `CategoryTheory.Category`;
* `dupPair` is still not `sharedPair`, and `WEq` is *strictly* finer.

The technical core is one lemma, `muExt_transport`: a term read from one base
is the same term read from another, provided the world is transported along the
relabelling connecting the bases. Every law is that lemma at a different
three-line path rewrite.
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
identifies terms that consult nothing (Transform fusion, a duplicated
alternative) and terms whose consultations are keyed alike, and it does not
identify a term with a re-plumbed copy of itself. That is *too* fine to be the
equality of a category: no rearrangement of a pipeline preserves keys, so
associativity, the units, and the absorption of an open gate all fail for it.

`WEq` therefore survives as the fine equality and as a *source* of coarse
equalities (`WEq.toWEqR`), and the quotient is taken by `WEqR` — this same
comparison up to a relabelling of absolute sites. The inclusion is strict
(`WEqR_strictly_coarser`). -/
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

/-- Workflow equality is an equivalence, so it is one: the `Setoid` of the
*fine* equality.

It is a `def` and no longer the instance. The quotient below is taken by
`wSetoidR`, the coarsening this module's Stage 3 exists to build, and two
`Setoid` instances on one type would make `Quotient.mk` ambiguous; the name is
kept resolving because it is the honest statement of what `WEq` is, and because
`WEq.toWEqR` is stated against it. -/
def wSetoid {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f : Frag}
    {i o : Type} : Setoid (Term Op G L f i o) where
  r := WEq
  iseqv := ⟨WEq.refl, WEq.symm, WEq.trans⟩

/-! ### The coarsening: equality up to a relabelling of sites

`WEq` compares two terms *at the same key*, and every structural rearrangement
moves keys, so `WEq` sees the move. The repair is not to stop looking at keys —
that would erase sharing, which is the one thing the design refuses
(`Env.share_ne_dup`) — but to compare the two terms **up to a relabelling of
absolute sites**, holding labelled sites fixed.

`WLe t u` says: at each absolute base, there is a relabelling `σ` of keys such
that reading `t` in the world is reading `u` in the world *renamed by* `σ`. The
order of quantifiers is the whole design:

* `σ` comes **after** the base and **before** the runner. After the base,
  because the rewrite that carries one shape's sites onto the other's depends
  on where the node sits — a `seq`-reassociation at depth three is a different
  finite rewrite from the same reassociation at the root. Before the runner,
  because a `σ` chosen per runner would let the relation cheat: symmetry and
  transitivity both need to feed a *modified* runner back into the hypothesis,
  which is impossible if `σ` may depend on it. (This is why the naive "quantify
  keys outside the comparison" repair fails: it offers no `σ` at all, and the
  two `seq` groupings genuinely assign different site sets.)
* `σ` must be a `Relabels` — it fixes every `rel` key. A labelled site is a
  name, not a position, so no rearrangement may move it, and this single side
  condition is what keeps `dupPair` and `sharedPair` apart
  (`WEqR_dupPair_ne_sharedPair`) while everything positional is freely
  renameable.

`WEqR` is the symmetrization: `t ≈ u` when each reads as the other. Both
relations are stated across *grades* (`f` and `f'` may differ), because
associativity of `seqT` changes the grade index by `Frag.join_assoc` and a
homogeneous relation could not even state it. -/

/-- **One-way site-relabelling refinement**: at every absolute base there is a
relabelling of sites carrying `t`'s consultations onto `u`'s. See the section
header for why the quantifiers sit exactly here. -/
def WLe {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f f' : Frag}
    {i o : Type} (t : Term Op G L f i o) (u : Term Op G L f' i o) : Prop :=
  ∀ s : Site, ∃ σ : Key L → Key L, Relabels σ ∧
    ∀ (run : Runner Op G L) (g : G),
      muExt run t g (.abs s) = muExt (run.rename σ) u g (.abs s)

namespace WLe

variable {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f f' f'' : Frag}
  {i o : Type}

/-- Every term reads as itself, by the identity relabelling. -/
theorem refl (t : Term Op G L f i o) : WLe t t :=
  fun _ => ⟨fun k => k, Relabels.id, fun _ _ => rfl⟩

/-- Refinements compose, by composing their relabellings. -/
theorem trans {t : Term Op G L f i o} {u : Term Op G L f' i o}
    {v : Term Op G L f'' i o} (h₁ : WLe t u) (h₂ : WLe u v) : WLe t v := by
  intro s
  obtain ⟨σ₁, hσ₁, e₁⟩ := h₁ s
  obtain ⟨σ₂, hσ₂, e₂⟩ := h₂ s
  refine ⟨fun k => σ₁ (σ₂ k), Relabels.comp hσ₁ hσ₂, ?_⟩
  intro run g
  rw [e₁ run g, e₂ (run.rename σ₁) g, Runner.rename_rename]

end WLe

/-- **Workflow equality up to site relabelling**: the coarsening of `WEq` that
makes the quotient a category. Two terms are equal when each reads as the other
under a relabelling of absolute sites.

This is the *antisymmetrization* of the preorder `WLe`, and at a single grade
it is literally `AntisymmRel WLe` — Mathlib's own construction, whose `Setoid`
(`AntisymmRel.setoid`) would supply the equivalence for free. What Mathlib
lacks is the heterogeneous case: `AntisymmRel` relates two elements of *one*
type, while `seqT`'s grade index makes the two sides of associativity live in
`Term … ((f₁.join f₂).join f₃) …` and `Term … (f₁.join (f₂.join f₃)) …`, which
are two types. Spelling the conjunction out is what lets the law be *stated*;
the equivalence proofs below are the three lines Mathlib's would have been. -/
def WEqR {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f f' : Frag}
    {i o : Type} (t : Term Op G L f i o) (u : Term Op G L f' i o) : Prop :=
  WLe t u ∧ WLe u t

namespace WEqR

variable {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f f' f'' : Frag}
  {i o : Type}

/-- Every workflow means what it means. -/
theorem refl (t : Term Op G L f i o) : WEqR t t := ⟨WLe.refl t, WLe.refl t⟩

/-- Site-relabelling equality is symmetric — by construction, since it is the
symmetrization of `WLe`. -/
theorem symm {t : Term Op G L f i o} {u : Term Op G L f' i o} (h : WEqR t u) :
    WEqR u t := ⟨h.2, h.1⟩

/-- Site-relabelling equality is transitive, because `WLe` is. -/
theorem trans {t : Term Op G L f i o} {u : Term Op G L f' i o}
    {v : Term Op G L f'' i o} (h₁ : WEqR t u) (h₂ : WEqR u v) : WEqR t v :=
  ⟨h₁.1.trans h₂.1, h₂.2.trans h₁.2⟩

/-- Transporting one side along an equation of grades. The two sides of
associativity have grade indices that agree only propositionally
(`Frag.join_assoc`), so the quotient's laws need this and nothing more: a cast
in the index is invisible to the meaning. -/
theorem cast {e : f = f'} (t : Term Op G L f i o) {u : Term Op G L f'' i o}
    (h : WEqR t u) : WEqR (e ▸ t) u := by
  cases e; exact h

end WEqR

/-- **The fine equality refines the coarse one**: `WEq ⊆ WEqR`, by taking the
identity relabelling. The inclusion is *strict* — `WEq_ne_WEqR` exhibits the
witness — which is the content of the coarsening. -/
theorem WEq.toWEqR {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f : Frag}
    {i o : Type} {t u : Term Op G L f i o} (h : WEq t u) : WEqR t u :=
  ⟨fun _ => ⟨fun k => k, Relabels.id, fun run g => h run g _⟩,
   fun _ => ⟨fun k => k, Relabels.id, fun run g => (h run g _).symm⟩⟩

section Shift

variable {Op : Type → Type → Type} {G L : Type} [PMonoid G]

/-- **A node that only shifts its body's sites is invisible to `WEqR`.**

If `u`'s meaning at any key is exactly `t`'s meaning one step below that key,
then `u` and `t` are equal up to relabelling: the relabelling is *insert that
step* one way and *drop it* the other, and both are `Key.relocate` of a
one-line path rewrite.

This one lemma discharges four of the laws the fine equality could not have —
an open gate, an empty scope, and either unit of sequencing — because all four
are the same phenomenon: a no-op node that renames every site beneath it. -/
theorem WEqR.of_shift {f f' : Frag} {i o : Type} {u : Term Op G L f' i o}
    {t : Term Op G L f i o} (st : Step)
    (h : ∀ (run : Runner Op G L) (g : G) (k : Key L),
      muExt run u g k = muExt run t g (k.push st)) :
    WEqR u t := by
  constructor
  · intro s
    refine ⟨Key.relocate s (fun p => st :: p), Relabels.relocate _ _, ?_⟩
    intro run g
    rw [h run g (.abs s)]
    refine (muExt_rename (Relabels.relocate _ _) t s (s ++ [st]) ?_ g).symm
    intro p
    rw [Key.relocate_abs]
    simp
  · intro s
    refine ⟨Key.relocate s (fun p => p.tail), Relabels.relocate _ _, ?_⟩
    intro run g
    rw [h (run.rename (Key.relocate s (fun p => p.tail))) g (.abs s)]
    refine (muExt_rename (Relabels.relocate _ _) t (s ++ [st]) s ?_ g).symm
    intro p
    have e : (s ++ [st]) ++ p = s ++ (st :: p) := by simp
    rw [e, Key.relocate_abs]
    simp

/-- **An open gate is no gate at all** — now an equality of workflows, not just
of matrices. `muS` absorbed `gateT true` from the start (`muS_gateT_true`); the
extensional side could not, because the `gate` step shifted every consultation
beneath it, and shifting sites is exactly what the coarsening forgives. -/
theorem WEqR_gateT_true {f : Frag} {i o : Type} (t : Term Op G L f i o) :
    WEqR (.gateT true t) t :=
  WEqR.of_shift .gate (fun _ _ _ => rfl)

/-- **The empty scope changes no workflow.** The quantitative half was
`muS_scopeT_unit`, an instance of the monoid action's unit law; the extensional
half needed the same unit law *and* the relabelling that erases the `scope`
step. -/
theorem WEqR_scopeT_unit {f : Frag} {i o : Type} (t : Term Op G L f i o) :
    WEqR (.scopeT (1 : G) t) t := by
  refine WEqR.of_shift .scope (fun run g k => ?_)
  show muExt run t (g * 1) (k.push .scope) = _
  rw [mul_one]

/-- **Left unit of sequencing**: a `Transform` that does nothing, run first,
does nothing. -/
theorem WEqR_seqT_pureT_id_left {f : Frag} {i o : Type} (t : Term Op G L f i o) :
    WEqR (.seqT (.pureT (fun a : i => a)) t) t := by
  refine WEqR.of_shift .seqR (fun run g k => ?_)
  funext a
  rfl

/-- **Right unit of sequencing**: the same `Transform` run last. -/
theorem WEqR_seqT_pureT_id_right {f : Frag} {i o : Type} (t : Term Op G L f i o) :
    WEqR (.seqT t (.pureT (fun a : o => a))) t := by
  refine WEqR.of_shift .seqL (fun run g k => ?_)
  funext a
  show (muExt run t g (k.push .seqL) a).bind (fun b => some b) = _
  cases muExt run t g (k.push .seqL) a <;> rfl

end Shift

section Assoc

variable {Op : Type → Type → Type} {G L : Type} [PMonoid G]

/-- **The path rewrite that reassociates a pipeline.** A right-nested
`seqT a (seqT b c)` keys its three stages at `[seqL]`, `[seqR, seqL]` and
`[seqR, seqR]`; the left-nested `seqT (seqT a b) c` keys them at `[seqL, seqL]`,
`[seqL, seqR]` and `[seqR]`. This function is that correspondence, read as a
rewrite of the first one or two steps of a path and the identity everywhere
else — three lines, finite, decidable, and the reason associativity is a
theorem below rather than an axiom. -/
def seqAssocPath : Site → Site
  | .seqL :: p => .seqL :: .seqL :: p
  | .seqR :: .seqL :: p => .seqL :: .seqR :: p
  | .seqR :: .seqR :: p => .seqR :: p
  | p => p

/-- The inverse rewrite, carrying left-nested sites onto right-nested ones. The
two are mutually inverse on the paths that occur, which is all the two
directions of `WEqR` need; they are not asked to be inverse on paths no term
reads at. -/
def seqAssocPathInv : Site → Site
  | .seqL :: .seqL :: p => .seqL :: p
  | .seqL :: .seqR :: p => .seqR :: .seqL :: p
  | .seqR :: p => .seqR :: .seqR :: p
  | p => p

/-- **Sequencing is associative up to relabelling** — the law the fine equality
could not have, and the one that makes the quotient a category.

Note the grades: the two sides are `Term … ((f₁.join f₂).join f₃) …` and
`Term … (f₁.join (f₂.join f₃)) …`, *different types*, which is why `WEqR` was
stated across grades. On the quotient the index is reconciled by
`Frag.join_assoc` and the law reappears as `Workflow.seq_assoc`. -/
theorem WEqR_seqT_assoc {f₁ f₂ f₃ : Frag} {i j k' o : Type}
    (a : Term Op G L f₁ i j) (b : Term Op G L f₂ j k') (c : Term Op G L f₃ k' o) :
    WEqR (.seqT (.seqT a b) c) (.seqT a (.seqT b c)) := by
  constructor
  · intro s
    refine ⟨Key.relocate s seqAssocPath, Relabels.relocate _ _, ?_⟩
    intro run g
    have ha : muExt (run.rename (Key.relocate s seqAssocPath)) a g
          ((Key.abs s).push .seqL)
        = muExt run a g (((Key.abs s).push .seqL).push .seqL) := by
      refine muExt_rename (Relabels.relocate _ _) a (s ++ [Step.seqL])
        ((s ++ [Step.seqL]) ++ [Step.seqL]) ?_ g
      intro p
      have e : (s ++ [Step.seqL]) ++ p = s ++ (Step.seqL :: p) := by simp
      rw [e, Key.relocate_abs]
      simp [seqAssocPath]
    have hb : muExt (run.rename (Key.relocate s seqAssocPath)) b g
          (((Key.abs s).push .seqR).push .seqL)
        = muExt run b g (((Key.abs s).push .seqL).push .seqR) := by
      refine muExt_rename (Relabels.relocate _ _) b ((s ++ [Step.seqR]) ++ [Step.seqL])
        ((s ++ [Step.seqL]) ++ [Step.seqR]) ?_ g
      intro p
      have e : ((s ++ [Step.seqR]) ++ [Step.seqL]) ++ p
          = s ++ (Step.seqR :: Step.seqL :: p) := by simp
      rw [e, Key.relocate_abs]
      simp [seqAssocPath]
    have hc : muExt (run.rename (Key.relocate s seqAssocPath)) c g
          (((Key.abs s).push .seqR).push .seqR)
        = muExt run c g ((Key.abs s).push .seqR) := by
      refine muExt_rename (Relabels.relocate _ _) c ((s ++ [Step.seqR]) ++ [Step.seqR])
        (s ++ [Step.seqR]) ?_ g
      intro p
      have e : ((s ++ [Step.seqR]) ++ [Step.seqR]) ++ p
          = s ++ (Step.seqR :: Step.seqR :: p) := by simp
      rw [e, Key.relocate_abs]
      simp [seqAssocPath]
    have hbc : muExt (run.rename (Key.relocate s seqAssocPath)) (.seqT b c) g
          ((Key.abs s).push .seqR)
        = fun y => (muExt (run.rename (Key.relocate s seqAssocPath)) b g
            (((Key.abs s).push .seqR).push .seqL) y).bind
              (muExt (run.rename (Key.relocate s seqAssocPath)) c g
                (((Key.abs s).push .seqR).push .seqR)) := by
      funext y; rw [muExt_seqT]
    funext x
    rw [muExt_seqT, muExt_seqT, muExt_seqT, hbc]
    simp only [ha, hb, hc]
    exact Option.bind_assoc _ _ _
  · intro s
    refine ⟨Key.relocate s seqAssocPathInv, Relabels.relocate _ _, ?_⟩
    intro run g
    have ha : muExt (run.rename (Key.relocate s seqAssocPathInv)) a g
          (((Key.abs s).push .seqL).push .seqL)
        = muExt run a g ((Key.abs s).push .seqL) := by
      refine muExt_rename (Relabels.relocate _ _) a ((s ++ [Step.seqL]) ++ [Step.seqL])
        (s ++ [Step.seqL]) ?_ g
      intro p
      have e : ((s ++ [Step.seqL]) ++ [Step.seqL]) ++ p
          = s ++ (Step.seqL :: Step.seqL :: p) := by simp
      rw [e, Key.relocate_abs]
      simp [seqAssocPathInv]
    have hb : muExt (run.rename (Key.relocate s seqAssocPathInv)) b g
          (((Key.abs s).push .seqL).push .seqR)
        = muExt run b g (((Key.abs s).push .seqR).push .seqL) := by
      refine muExt_rename (Relabels.relocate _ _) b ((s ++ [Step.seqL]) ++ [Step.seqR])
        ((s ++ [Step.seqR]) ++ [Step.seqL]) ?_ g
      intro p
      have e : ((s ++ [Step.seqL]) ++ [Step.seqR]) ++ p
          = s ++ (Step.seqL :: Step.seqR :: p) := by simp
      rw [e, Key.relocate_abs]
      simp [seqAssocPathInv]
    have hc : muExt (run.rename (Key.relocate s seqAssocPathInv)) c g
          ((Key.abs s).push .seqR)
        = muExt run c g (((Key.abs s).push .seqR).push .seqR) := by
      refine muExt_rename (Relabels.relocate _ _) c (s ++ [Step.seqR])
        ((s ++ [Step.seqR]) ++ [Step.seqR]) ?_ g
      intro p
      have e : (s ++ [Step.seqR]) ++ p = s ++ (Step.seqR :: p) := by simp
      rw [e, Key.relocate_abs]
      simp [seqAssocPathInv]
    have hbc : muExt run (.seqT b c) g ((Key.abs s).push .seqR)
        = fun y => (muExt run b g (((Key.abs s).push .seqR).push .seqL) y).bind
              (muExt run c g (((Key.abs s).push .seqR).push .seqR)) := by
      funext y; rw [muExt_seqT]
    funext x
    rw [muExt_seqT, muExt_seqT, muExt_seqT, hbc]
    simp only [ha, hb, hc]
    exact (Option.bind_assoc _ _ _).symm

end Assoc

section Congruence

/-! ### The coarsened equality is a congruence

A quotient with an operation on it needs the operation to respect the
equivalence. For `WEqR` that obligation has a new shape: each child comes with
*its own* relabelling, at *its own* base, and the node must produce one. The
answer is `Key.splice` — run the left child's relabelling below the left
branch, the right child's below the right, and nothing anywhere else — and the
two lemmas below say that splicing does not disturb what either child reads.

The binary constructors that descend are `seqT`, `parT`, `sumT` and `choiceT`;
`gateT` and `scopeT` descend with the child's own relabelling and no splice at
all. What does **not** descend here is `retryT`, `fanT`, `shareT` and `bindT` —
see the remainder note at `Workflow.seq_of`. -/

variable {Op : Type → Type → Type} {G L : Type} [PMonoid G]

/-- Below the left branch, a splice reads as the left child's relabelling. -/
theorem muExt_splice_left {run : Runner Op G L} {σ₁ σ₂ : Key L → Key L}
    (hσ₁ : Relabels σ₁) (s : Site) (st₁ st₂ : Step)
    {f : Frag} {i o : Type} (t : Term Op G L f i o) (g : G) :
    muExt (run.rename (Key.splice s st₁ st₂ σ₁ σ₂)) t g (.abs (s ++ [st₁]))
      = muExt (run.rename σ₁) t g (.abs (s ++ [st₁])) := by
  refine muExt_rename_congr (Relabels.splice _ _ _ _ _) hσ₁ t (s ++ [st₁]) ?_ g
  intro p
  have e : (s ++ [st₁]) ++ p = s ++ st₁ :: p := by simp
  rw [e, Key.splice_left]

/-- Below the right branch — a *different* branch — a splice reads as the right
child's relabelling. -/
theorem muExt_splice_right {run : Runner Op G L} {σ₁ σ₂ : Key L → Key L}
    (hσ₂ : Relabels σ₂) (s : Site) {st₁ st₂ : Step} (hst : st₁ ≠ st₂)
    {f : Frag} {i o : Type} (t : Term Op G L f i o) (g : G) :
    muExt (run.rename (Key.splice s st₁ st₂ σ₁ σ₂)) t g (.abs (s ++ [st₂]))
      = muExt (run.rename σ₂) t g (.abs (s ++ [st₂])) := by
  refine muExt_rename_congr (Relabels.splice _ _ _ _ _) hσ₂ t (s ++ [st₂]) ?_ g
  intro p
  have e : (s ++ [st₂]) ++ p = s ++ st₂ :: p := by simp
  rw [e, Key.splice_right s hst]

variable {f₁ f₁' f₂ f₂' : Frag}

/-- **Sequencing respects the coarsened equality**, so it descends to the
quotient. -/
theorem WLe.seqT_congr {i j o : Type} {t : Term Op G L f₁ i j}
    {t' : Term Op G L f₁' i j} {u : Term Op G L f₂ j o}
    {u' : Term Op G L f₂' j o} (ht : WLe t t') (hu : WLe u u') :
    WLe (.seqT t u) (.seqT t' u') := by
  intro s
  obtain ⟨σ₁, hσ₁, e₁⟩ := ht (s ++ [Step.seqL])
  obtain ⟨σ₂, hσ₂, e₂⟩ := hu (s ++ [Step.seqR])
  refine ⟨Key.splice s .seqL .seqR σ₁ σ₂, Relabels.splice _ _ _ _ _, ?_⟩
  intro run g
  funext x
  rw [muExt_seqT, muExt_seqT]
  simp only [Key.push_abs, muExt_splice_left hσ₁ s .seqL .seqR,
    muExt_splice_right hσ₂ s (by decide : Step.seqL ≠ Step.seqR), e₁ run g, e₂ run g]

/-- A tensor respects the coarsened equality. -/
theorem WLe.parT_congr {i j k' o : Type} {t : Term Op G L f₁ i j}
    {t' : Term Op G L f₁' i j} {u : Term Op G L f₂ k' o}
    {u' : Term Op G L f₂' k' o} (ht : WLe t t') (hu : WLe u u') :
    WLe (.parT t u) (.parT t' u') := by
  intro s
  obtain ⟨σ₁, hσ₁, e₁⟩ := ht (s ++ [Step.parL])
  obtain ⟨σ₂, hσ₂, e₂⟩ := hu (s ++ [Step.parR])
  refine ⟨Key.splice s .parL .parR σ₁ σ₂, Relabels.splice _ _ _ _ _, ?_⟩
  intro run g
  funext x
  rw [muExt_parT, muExt_parT]
  simp only [Key.push_abs, muExt_splice_left hσ₁ s .parL .parR,
    muExt_splice_right hσ₂ s (by decide : Step.parL ≠ Step.parR), e₁ run g, e₂ run g]

/-- Alternation respects the coarsened equality — bias and all: the leftmost
branch is still the one that answers, and both branches are still compared. -/
theorem WLe.sumT_congr {i o : Type} {t : Term Op G L f₁ i o}
    {t' : Term Op G L f₁' i o} {u : Term Op G L f₂ i o}
    {u' : Term Op G L f₂' i o} (ht : WLe t t') (hu : WLe u u') :
    WLe (.sumT t u) (.sumT t' u') := by
  intro s
  obtain ⟨σ₁, hσ₁, e₁⟩ := ht (s ++ [Step.sumL])
  obtain ⟨σ₂, hσ₂, e₂⟩ := hu (s ++ [Step.sumR])
  refine ⟨Key.splice s .sumL .sumR σ₁ σ₂, Relabels.splice _ _ _ _ _, ?_⟩
  intro run g
  funext x
  rw [muExt_sumT, muExt_sumT]
  simp only [Key.push_abs, muExt_splice_left hσ₁ s .sumL .sumR,
    muExt_splice_right hσ₂ s (by decide : Step.sumL ≠ Step.sumR), e₁ run g, e₂ run g]

/-- Branching on a decoded coproduct respects the coarsened equality. -/
theorem WLe.choiceT_congr {i j o : Type} {t : Term Op G L f₁ i o}
    {t' : Term Op G L f₁' i o} {u : Term Op G L f₂ j o}
    {u' : Term Op G L f₂' j o} (ht : WLe t t') (hu : WLe u u') :
    WLe (.choiceT t u) (.choiceT t' u') := by
  intro s
  obtain ⟨σ₁, hσ₁, e₁⟩ := ht (s ++ [Step.choiceL])
  obtain ⟨σ₂, hσ₂, e₂⟩ := hu (s ++ [Step.choiceR])
  refine ⟨Key.splice s .choiceL .choiceR σ₁ σ₂, Relabels.splice _ _ _ _ _, ?_⟩
  intro run g
  funext x
  cases x with
  | inl a =>
    show muExt run t g ((Key.abs s).push .choiceL) a
        = muExt (run.rename (Key.splice s .choiceL .choiceR σ₁ σ₂)) t' g
            ((Key.abs s).push .choiceL) a
    simp only [Key.push_abs, muExt_splice_left hσ₁ s .choiceL .choiceR, e₁ run g]
  | inr b =>
    show muExt run u g ((Key.abs s).push .choiceR) b
        = muExt (run.rename (Key.splice s .choiceL .choiceR σ₁ σ₂)) u' g
            ((Key.abs s).push .choiceR) b
    simp only [Key.push_abs,
      muExt_splice_right hσ₂ s (by decide : Step.choiceL ≠ Step.choiceR), e₂ run g]

/-- A gate respects the coarsened equality: the child's own relabelling serves,
since a gate has one child and shifts every site below it alike. -/
theorem WLe.gateT_congr {i o : Type} (b : Bool) {t : Term Op G L f₁ i o}
    {t' : Term Op G L f₁' i o} (ht : WLe t t') :
    WLe (.gateT b t) (.gateT b t') := by
  intro s
  obtain ⟨σ, hσ, e⟩ := ht (s ++ [Step.gate])
  refine ⟨σ, hσ, ?_⟩
  intro run g
  cases b with
  | false => rfl
  | true => exact e run g

/-- A scope respects the coarsened equality, at every ambient scope. -/
theorem WLe.scopeT_congr {i o : Type} (h : G) {t : Term Op G L f₁ i o}
    {t' : Term Op G L f₁' i o} (ht : WLe t t') :
    WLe (.scopeT h t) (.scopeT h t') := by
  intro s
  obtain ⟨σ, hσ, e⟩ := ht (s ++ [Step.scope])
  exact ⟨σ, hσ, fun run g => e run (g ⋄ h)⟩

/-- Sequencing descends: the two-sided form of `WLe.seqT_congr`, and the
obligation `Workflow.seq` discharges. -/
theorem WEqR.seqT_congr {i j o : Type} {t : Term Op G L f₁ i j}
    {t' : Term Op G L f₁' i j} {u : Term Op G L f₂ j o}
    {u' : Term Op G L f₂' j o} (ht : WEqR t t') (hu : WEqR u u') :
    WEqR (.seqT t u) (.seqT t' u') :=
  ⟨ht.1.seqT_congr hu.1, ht.2.seqT_congr hu.2⟩

/-- A tensor descends. -/
theorem WEqR.parT_congr {i j k' o : Type} {t : Term Op G L f₁ i j}
    {t' : Term Op G L f₁' i j} {u : Term Op G L f₂ k' o}
    {u' : Term Op G L f₂' k' o} (ht : WEqR t t') (hu : WEqR u u') :
    WEqR (.parT t u) (.parT t' u') :=
  ⟨ht.1.parT_congr hu.1, ht.2.parT_congr hu.2⟩

/-- Alternation descends. -/
theorem WEqR.sumT_congr {i o : Type} {t : Term Op G L f₁ i o}
    {t' : Term Op G L f₁' i o} {u : Term Op G L f₂ i o}
    {u' : Term Op G L f₂' i o} (ht : WEqR t t') (hu : WEqR u u') :
    WEqR (.sumT t u) (.sumT t' u') :=
  ⟨ht.1.sumT_congr hu.1, ht.2.sumT_congr hu.2⟩

/-- Branching descends. -/
theorem WEqR.choiceT_congr {i j o : Type} {t : Term Op G L f₁ i o}
    {t' : Term Op G L f₁' i o} {u : Term Op G L f₂ j o}
    {u' : Term Op G L f₂' j o} (ht : WEqR t t') (hu : WEqR u u') :
    WEqR (.choiceT t u) (.choiceT t' u') :=
  ⟨ht.1.choiceT_congr hu.1, ht.2.choiceT_congr hu.2⟩

/-- Gating descends. -/
theorem WEqR.gateT_congr {i o : Type} (b : Bool) {t : Term Op G L f₁ i o}
    {t' : Term Op G L f₁' i o} (ht : WEqR t t') :
    WEqR (.gateT b t) (.gateT b t') :=
  ⟨ht.1.gateT_congr b, ht.2.gateT_congr b⟩

/-- Scoping descends. -/
theorem WEqR.scopeT_congr {i o : Type} (h : G) {t : Term Op G L f₁ i o}
    {t' : Term Op G L f₁' i o} (ht : WEqR t t') :
    WEqR (.scopeT h t) (.scopeT h t') :=
  ⟨ht.1.scopeT_congr h, ht.2.scopeT_congr h⟩

end Congruence

section Witnesses

/-! ### What the coarsening keeps, and what it adds

A coarsening is only as good as what it refuses to identify. Two theorems fix
this one from both sides: it still separates sharing from duplication — the
distinction the whole package exists to record — and it is *strictly* coarser
than `WEq`, so it is a coarsening and not a renaming. -/

/-- **Sharing survives the coarsening.** `dupPair` and `sharedPair` are still
different workflows, and the reason is exactly the side condition on
relabellings: a relabelling may move absolute sites anywhere, but it fixes
labelled keys, and — more fundamentally — it is a *function* on keys, so it can
never split the one site `sharedPair` reads twice into the two sites `dupPair`
reads once each. A coarsening that erased this would be the wrong coarsening,
however many laws it bought. -/
theorem WEqR_dupPair_ne_sharedPair :
    ¬ WEqR (dupPair (G := LastOpt Unit) (L := Nat) AskOp.ask)
        (sharedPair (G := LastOpt Unit) (0 : Nat) AskOp.ask) := by
  intro h
  obtain ⟨σ, hσ, e⟩ := h.1 []
  have h2 := congrFun (e (askRunner epsSplitKey) LastOpt.unset) ("", "")
  have hL : muExt (askRunner epsSplitKey)
      (dupPair (G := LastOpt Unit) (L := Nat) AskOp.ask) LastOpt.unset
      (Key.abs []) ("", "") = some (0, 1) := rfl
  have hR : muExt ((askRunner epsSplitKey).rename σ)
      (sharedPair (G := LastOpt Unit) (0 : Nat) AskOp.ask) LastOpt.unset
      (Key.abs []) ("", "")
      = some (epsSplitKey (σ (Key.rel 0 [])), epsSplitKey (σ (Key.rel 0 []))) := rfl
  rw [hL, hR, hσ 0 []] at h2
  exact absurd h2 (by decide)

/-- **The coarsening is strict**: an open gate over a consulting leaf is
`WEqR`-equal to the leaf and *not* `WEq`-equal to it, because a world that
answers differently under a `gate` step tells the two apart at a fixed key.
`WEq ⊂ WEqR`, with this pair in the difference. -/
theorem WEqR_strictly_coarser :
    WEqR (Op := AskOp) (G := LastOpt Unit) (L := Nat)
        (.gateT true (.prim AskOp.ask)) (.prim AskOp.ask)
      ∧ ¬ WEq (Op := AskOp) (G := LastOpt Unit) (L := Nat)
        (.gateT true (.prim AskOp.ask)) (.prim AskOp.ask) := by
  refine ⟨WEqR_gateT_true _, ?_⟩
  intro h
  have h2 := congrFun (h (askRunner epsGateKey) LastOpt.unset Key.root) ""
  have hL : muExt (askRunner epsGateKey)
      (Term.gateT (G := LastOpt Unit) (L := Nat) true (.prim AskOp.ask))
      LastOpt.unset Key.root "" = some 1 := rfl
  have hR : muExt (askRunner epsGateKey)
      (Term.prim (G := LastOpt Unit) (L := Nat) AskOp.ask)
      LastOpt.unset Key.root "" = some 0 := rfl
  rw [hL, hR] at h2
  exact absurd h2 (by decide)

end Witnesses

/-- Site-relabelling equality is an equivalence, so it is one: **the** `Setoid`
of this module, and the one the quotient below is taken by. -/
instance wSetoidR {Op : Type → Type → Type} {G L : Type} [PMonoid G] {f : Frag}
    {i o : Type} : Setoid (Term Op G L f i o) where
  r := WEqR
  iseqv := ⟨WEqR.refl, fun h => WEqR.symm h, fun h₁ h₂ => WEqR.trans h₁ h₂⟩

/-- **A `Workflow` is a written workflow up to meaning**: the quotient of the
term syntax by extensional equality *up to a relabelling of sites*. This is
design §3's "semantic equality is equality of `⟦·⟧_ext`" as a *type* — two
terms that mean the same thing are not merely provably interchangeable, they
are the same element — and §8's reason for choosing Lean: the obligation to
respect meaning is discharged at the definition of every operation, by the
elaborator, or the operation does not exist.

The quotient is by `WEqR`, not `WEq`, and that choice is the whole of acat-5b7.
Under `WEq` this type had one operation and no laws — deleting an open gate
counted as a semantic change, and the two bracketings of a three-stage pipeline
were different workflows. Under `WEqR` it has associativity, both units, gate
and scope absorption, and six congruences; the static fragment is a genuine
`CategoryTheory.Category` (`Workflow.staticCategory`). What it does *not* do is
identify sharing with duplication (`WEqR_dupPair_ne_sharedPair`): the
coarsening moves positions and leaves names alone. -/
def Workflow (Op : Type → Type → Type) (G L : Type) [PMonoid G] (f : Frag)
    (i o : Type) : Type 1 :=
  Quotient (wSetoidR (Op := Op) (G := G) (L := L) (f := f) (i := i) (o := o))

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
`WEqR.seqT_congr` exists; had sequencing failed to respect meaning, this
definition would not elaborate, which is exactly the discipline the design
asked a host language to enforce. -/
def Workflow.seq {Op : Type → Type → Type} {G L : Type} [PMonoid G]
    {f g' : Frag} {i j o : Type} :
    Workflow Op G L f i j → Workflow Op G L g' j o →
      Workflow Op G L (f.join g') i o :=
  Quotient.lift₂ (fun t u => Workflow.of (Term.seqT t u))
    (fun _ _ _ _ ht hu => Quotient.sound (WEqR.seqT_congr ht hu))

/-- Sequencing on the quotient computes: the lift of a pair of written terms is
the written composite.

**The §8 move, and now the laws too.** `Workflow`, `Workflow.seq` and this
equation are the *type-level* claim — "equality is equality of meaning" as a
type, with the respect obligation checked by the elaborator. Under `WEq` that
was all there was, and the laws were not merely unproved but false: `seqT
(seqT a b) c` keys its stages at `[seqL, seqL]`, `[seqL, seqR]`, `[seqR]` while
`seqT a (seqT b c)` keys them at `[seqL]`, `[seqR, seqL]`, `[seqR, seqR]`, and a
key-sensitive runner over consulting stages separated the two groupings; `seqT
(pureT id) t` pushed a `seqR` onto every consultation of `t`; `gateT true` and
`scopeT unit` inserted their own steps.

Under `WEqR` all of those hold (`Workflow.seq_assoc`, `Workflow.seq_id_left`,
`Workflow.seq_id_right`, `Workflow.of_gateT_true`, `Workflow.of_scopeT_unit`)
and the static fragment is a `CategoryTheory.Category`.

**The honest remainder.** What is *not* proved here:

* **Three congruences are missing.** `retryT` and `fanT` would need a single
  relabelling spliced out of one per trip and one per copy — a countable
  splice, where `Key.splice` handles two; `bindT`'s continuation is an opaque
  function, so its relabelling would have to be chosen uniformly in the
  intermediate value. `shareT` is different in kind: its body is read from a
  `rel` base, and relabellings fix `rel` keys, so a congruence for it needs the
  relation extended to labelled bases — which is also where the gate law can
  genuinely fail, when a label's sites collide with the ambient base
  (acat-bmc's collision, seen from the quotient).
* **The comparison is at absolute bases only.** `WLe` quantifies over `Site`,
  i.e. over `Key.abs` bases. That is the right domain — a term is entered at
  the root or at a rebase, never at a fictitious labelled base — but it means
  the relation says nothing directly about terms read from inside a `shareT`.
* **The laws are for `seqT`.** `parT`, `sumT` and `choiceT` descend
  (their congruences are proved) but their own algebra — the tensor's
  functoriality, alternation's associativity — is not stated.
* **The `π` to matrices is still absent.** The coarsening removes one of the
  two obstructions recorded below: `gateT true` and `scopeT unit` now agree on
  both sides. The other obstruction stands unchanged
  (`one_add_one_of_muS_respects_WEq`), and `WEq ⊆ WEqR` means it applies a
  fortiori — `WEqR` identifies *more*, so a quantitative meaning respecting it
  still forces `1 + 1 = 1`. -/
theorem Workflow.seq_of {Op : Type → Type → Type} {G L : Type} [PMonoid G]
    {f g' : Frag} {i j o : Type} (t : Term Op G L f i j)
    (u : Term Op G L g' j o) :
    Workflow.seq (Workflow.of t) (Workflow.of u) = Workflow.of (Term.seqT t u) :=
  rfl

/-! ### The laws, on the quotient

Two of the four are stated with a cast in the grade index, and the cast is not
bureaucracy: `seqT`'s index is `Frag.join`, whose associativity and right unit
hold only propositionally (`Frag.join_assoc`, `Frag.join_static`), so the two
sides of the law inhabit two types that are equal but not definitionally so.
`Workflow.of_cast` moves the cast through the quotient map and `WEqR.cast`
absorbs it into the relation, after which the law is exactly the term-level
theorem. -/

section QuotientLaws

variable {Op : Type → Type → Type} {G L : Type} [PMonoid G]

/-- A cast in the grade index passes through the quotient map. -/
theorem Workflow.of_cast {f f' : Frag} {i o : Type} (e : f = f')
    (t : Term Op G L f i o) : e ▸ Workflow.of t = Workflow.of (e ▸ t) := by
  cases e; rfl

/-- **Sequencing on the quotient is associative** — modulo the grade index,
which the two sides compute differently and `Frag.join_assoc` reconciles. This
is the law acat-5b7 exists to obtain. -/
theorem Workflow.seq_assoc {f₁ f₂ f₃ : Frag} {i j k' o : Type}
    (a : Workflow Op G L f₁ i j) (b : Workflow Op G L f₂ j k')
    (c : Workflow Op G L f₃ k' o) :
    Frag.join_assoc f₁ f₂ f₃ ▸ ((a.seq b).seq c) = a.seq (b.seq c) := by
  refine Quotient.inductionOn₃ a b c (fun ta tb tc => ?_)
  show Frag.join_assoc f₁ f₂ f₃ ▸ Workflow.of (Term.seqT (Term.seqT ta tb) tc)
      = Workflow.of (Term.seqT ta (Term.seqT tb tc))
  rw [Workflow.of_cast]
  exact Quotient.sound (WEqR.cast _ (WEqR_seqT_assoc ta tb tc))

/-- **The identity `Transform` is a left unit for sequencing.** No cast: a
static stage in front costs the grade nothing, definitionally
(`Frag.static_join` is `rfl`). -/
theorem Workflow.seq_id_left {f : Frag} {i o : Type} (w : Workflow Op G L f i o) :
    Workflow.seq (Workflow.of (.pureT (fun a : i => a))) w = w :=
  Quotient.inductionOn w (fun t => Quotient.sound (WEqR_seqT_pureT_id_left t))

/-- **And a right unit**, modulo the grade index: `Frag.join_static` needs the
cases that `Frag.static_join` did not. -/
theorem Workflow.seq_id_right {f : Frag} {i o : Type}
    (w : Workflow Op G L f i o) :
    Frag.join_static f ▸ (w.seq (Workflow.of (.pureT (fun a : o => a)))) = w := by
  refine Quotient.inductionOn w (fun t => ?_)
  show Frag.join_static f ▸ Workflow.of (Term.seqT t (Term.pureT (fun a : o => a)))
      = Workflow.of t
  rw [Workflow.of_cast]
  exact Quotient.sound (WEqR.cast _ (WEqR_seqT_pureT_id_right t))

/-- **An open gate is not a workflow at all**: it is the workflow it guards. -/
theorem Workflow.of_gateT_true {f : Frag} {i o : Type} (t : Term Op G L f i o) :
    Workflow.of (.gateT true t) = Workflow.of t :=
  Quotient.sound (WEqR_gateT_true t)

/-- **An empty scope is not a workflow either.** -/
theorem Workflow.of_scopeT_unit {f : Frag} {i o : Type} (t : Term Op G L f i o) :
    Workflow.of (.scopeT (1 : G) t) = Workflow.of t :=
  Quotient.sound (WEqR_scopeT_unit t)

end QuotientLaws

section QuotientSmoke

/-! ### The laws at a written term

The theorems above are general; these two run them on syntax, which is where a
law either erases the node the designer wrote or does not. -/

/-- **A no-op wrapper is erased, twice over.** A consultation under an empty
scope, behind an identity `Transform`, behind an open gate is the consultation.
Under `WEq` not one of these three steps could be deleted. -/
example :
    Workflow.of (Op := AskOp) (G := LastOpt Unit) (L := Nat)
        (.gateT true (.seqT (.pureT (fun s : String => s))
          (.scopeT 1 (.prim AskOp.ask))))
      = Workflow.of (.prim AskOp.ask) := by
  rw [Workflow.of_gateT_true]
  show Workflow.seq (Workflow.of (Term.pureT (fun s : String => s)))
      (Workflow.of (Term.scopeT 1 (Term.prim AskOp.ask))) = _
  rw [Workflow.seq_id_left, Workflow.of_scopeT_unit]

/-- **Associativity, cast-free, on the fragment where it is cast-free.** At
`static` the grade index is a fixed point of `Frag.join`, so the law is a plain
equation between morphisms — which is exactly why the category instance below
can exist. -/
example (a b c : Term AskOp (LastOpt Unit) Nat .static String String) :
    Workflow.seq (Workflow.seq (Workflow.of a) (Workflow.of b)) (Workflow.of c)
      = Workflow.seq (Workflow.of a) (Workflow.seq (Workflow.of b) (Workflow.of c)) :=
  Quotient.sound (WEqR_seqT_assoc a b c)

end QuotientSmoke

/-! ### The static fragment is a category

Not "satisfies the category laws" — *is a category*, as Mathlib's
`CategoryTheory.Category`, so that every construction in that library applies
to workflows without translation.

The restriction to the `static` grade is what makes the instance possible
rather than a decoration: a `Category` has one `Hom` type per pair of objects
and composition must land in it, while `Workflow.seq` moves the grade index by
`Frag.join`. On `static` the index is a fixed point — `join static static` is
`static` by `rfl` — so composition closes and no cast enters the laws. The
graded whole is not a category but a *graded* one (a category enriched in the
`Frag` monoid's fibres); stating that is the successor, and the two casts in
`Workflow.seq_assoc`/`seq_id_right` are exactly what it would systematize.

The objects are wrapped in `StaticObj` rather than being `Type` itself, because
`Type` already carries Mathlib's own category instance and two instances on one
type is not a category, it is an ambiguity. -/

set_option linter.unusedVariables false in
/-- The objects of the static workflow category: types, wrapped so the instance
below cannot collide with Mathlib's category of types.

`Op` and `L` are phantom — the objects do not depend on them — and they are
carried anyway because the morphisms do: without them on the object type,
`staticCategory` would leave the leaf signature and the label type
undetermined at instance resolution, and there would be no way to say *which*
category of workflows is meant. -/
def StaticObj (Op : Type → Type → Type) (G L : Type) [PMonoid G] : Type 1 := Type

/-- **`Workflow` on the static fragment is a category**: objects are types,
morphisms are static workflows up to site relabelling, the identity is the
identity `Transform`, and composition is `Workflow.seq`. Every law is one of
the theorems above, and none of them was available before the coarsening. -/
instance staticCategory {Op : Type → Type → Type} {G L : Type} [PMonoid G] :
    CategoryTheory.Category (StaticObj Op G L) where
  Hom i o := Workflow Op G L .static i o
  id i := Workflow.of (.pureT (fun a : i => a))
  comp f g := Workflow.seq f g
  id_comp f := Workflow.seq_id_left f
  comp_id f :=
    Quotient.inductionOn f (fun t => Quotient.sound (WEqR_seqT_pureT_id_right t))
  assoc f g h :=
    Quotient.inductionOn₃ f g h
      (fun ta tb tc => Quotient.sound (WEqR_seqT_assoc ta tb tc))

/-! ### The two meanings are still incomparable, for a better reason

Neither equality respects the other, and the coarsening changes *which*
witnesses say so — not the conclusion.

`WEqR` does **not** imply equality of quantitative meanings, and since
`WEq ⊆ WEqR` (`WEq.toWEqR`) the old witness applies a fortiori: extensionally
`w ⊕ w` is `w` — the leftmost-defined alternative is the only one anyone sees —
while quantitatively `⟦w ⊕ w⟧ = ⟦w⟧ + ⟦w⟧`, which is `⟦w⟧` only in a carrier
whose alternation is idempotent. A carrier that *counts* separates two terms
that both extensional equalities identify; that is
`one_add_one_of_muS_respects_WEq` below, which is stated for `WEq` and so holds
for the coarser relation too.

The other direction had a *bad* witness and now has a good one. It used to be
`gateT true` and `scopeT unit`: same matrix, different `WEq` class. That was an
artefact of the fine keying and the coarsening has dissolved it — both pairs are
now equal on both sides (`WEqR_gateT_true`, `Workflow.of_gateT_true`). What
remains is not an artefact at all: `dupPair` and `sharedPair` have *literally
the same matrix* (`muS_dupPair_eq_sharedPair`, true by `rfl` because `muS` is
transparent to `shareT`) and are still different workflows
(`WEqR_dupPair_ne_sharedPair`). Equality of quantitative meanings therefore
does not imply `WEqR`, and the reason is the design's own §6a: a matrix has no
room to record a consultation site, so it cannot see sharing.

So the two equalities remain **incomparable**, and this is the honest statement
in place of the fibration story: no projection in either direction. One
direction is impossible outright — `one_add_one_of_muS_respects_WEq` shows a
`π` from the quotient to matrices would collapse any carrier that counts. The
other now waits on the quantitative side rather than the extensional one: a
site-aware carrier (the free semimodule on `Key`, or a consultation-multiset
fold) is what would let matrices see what `WEqR` sees, and that is acat-qtv's
question, no longer blocked on this one.
-/

/-- **Sharing and duplication have the same matrix.** True by `rfl`: `muS` is
transparent to `shareT` (`muS_shareT`), so the labelled tensor and the
duplicated one denote the same Kronecker product, at every carrier and every
interpretation.

Read with `WEqR_dupPair_ne_sharedPair`, this is the sharp form of "the
quantitative meaning does not refine the extensional one": here are two terms
one meaning cannot tell apart and the other must. -/
theorem muS_dupPair_eq_sharedPair {Op : Type → Type → Type} {G S : Type}
    [CompleteCSemiring S] [PMonoid G] (interp : Interp Op G S) (l : Nat)
    (q : Op String Nat) :
    muS (L := Nat) interp (Term.dupPair q) = muS interp (Term.sharedPair l q) := rfl

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
would need: no `π` sends a `Workflow` to a matrix — and since `WEq ⊆ WEqR`
(`WEq.toWEqR`), the obstruction survives the coarsening unchanged, because a
`muS` respecting the coarser relation would a fortiori respect this one. The
other projection is missing too, for the reason recorded above: matrices cannot
see sharing (`muS_dupPair_eq_sharedPair` against
`WEqR_dupPair_ne_sharedPair`). The quantitative meaning lives beside the
quotient, not over it, until a site-aware carrier is built (acat-qtv). -/
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
