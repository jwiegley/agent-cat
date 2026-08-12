import Agentic.Monoid
import Mathlib.Algebra.Order.Kleene
import Mathlib.Algebra.Module.Defs
import Mathlib.Algebra.Module.Prod
import Mathlib.Order.CompleteLattice.Lemmas

/-!
# The resource algebra: Mathlib's semirings, and the one thing Mathlib lacks

This module used to define the whole algebraic vocabulary of the package:
`NSemiring` (fourteen fields), `CSemiring`, the canonical additive order `≤+`
with its own eight lemmas, `IdemAdd`, `StarSemiring`, `KleeneStar`. All but two
of those are Mathlib's, and as of this arc the package no longer keeps a second
name for any of them: the binders below and in every consumer say
`Semiring`/`CommSemiring`/`IdemSemiring`/`KleeneAlgebra`, the canonical
additive order is written `≤`, and iteration is written `x∗` (Mathlib's
`KStar.kstar`, notation from the `Computability` scope). The old names survive
for one `@[deprecated]` line each, with no consumers, because
`doc/walkthrough.html` still spells them.

| was | is |
| --- | --- |
| `NSemiring` | `Semiring` |
| `CSemiring` | `CommSemiring` |
| `IdemAdd` | `IdemSemiring` (idempotent `+`, *with* the induced lattice) |
| `≤+`, `addLe` | `≤` (`IdemSemiring`'s `SemilatticeSup`) |
| `KleeneStar` | `KleeneAlgebra` (`kstar`, `∗`, and both inductions) |
| `star x` | `x∗` |

Two things survive as *interfaces*, and each says here exactly what Mathlib
lacks. Beside them this module now carries the arc's one piece of mathematics:
`CsumIsSup`, the mixin that says a carrier's aggregation is its supremum, and
`KleeneAlgebra.ofSupDistrib`, which turns that into a star. Four hand-built
Kleene algebras — possibility, worst-case cost, consensus weight, and the
reachability star at `Prop`-matrices — and the `ofCommStarLe` builder they
shared are gone, replaced by one construction and four one-line instances.

* **`StarSemiring`** — a star satisfying the unrolling law `x∗ = 1 + x · x∗`
  and *nothing else*. Mathlib's weakest star-with-laws is `KleeneAlgebra`,
  which bundles an idempotent `+` and the two induction principles; the
  expectation semiring `SqZero P M` (`Agentic.Instances`) has a star and does
  not have an idempotent `+`, so it is outside `KleeneAlgebra` and would lose
  its star entirely. The class is now a `Prop` mixin over Mathlib's `KStar`, so
  a `KleeneAlgebra` carrier satisfies it for free (`instStarSemiringOfKleene`)
  and no diamond can form.
* **`CompleteCSemiring`** — aggregation over an *arbitrary* index type.
  Mathlib has no complete-semiring class: `tsum` is topological, `iSup` needs a
  `CompleteLattice` and therefore an idempotent `+`, and `Order.Quantale`'s
  `IsQuantale` is a `Semigroup` distributing over a `CompleteLattice` — again
  idempotent, and with no `csum_point`/`csum_prod` interface. The package needs
  one aggregation that covers **both** the idempotent carriers (`Prop`, `Cost`,
  `Prob`, where `csum` is a supremum) **and** the non-idempotent expectation
  semiring (`SqZero P M`, where it is componentwise and is not a supremum), so
  no lattice-based unification is available. The class now extends Mathlib's
  `CommSemiring` and adds `csum` alone.
-/

namespace Agentic

open Computability KStar

/-- `NSemiring S` is Mathlib's `Semiring S`. Deprecated compatibility alias,
kept only because `doc/walkthrough.html` still spells it. -/
@[deprecated Semiring (since := "2026-08-12")]
abbrev NSemiring (S : Type) := Semiring S

/-- `CSemiring S` is Mathlib's `CommSemiring S`. Deprecated compatibility
alias, kept only because `doc/walkthrough.html` still spells it. -/
@[deprecated CommSemiring (since := "2026-08-12")]
abbrev CSemiring (S : Type) := CommSemiring S

/-- `IdemAdd S` is Mathlib's `IdemSemiring S`. Deprecated compatibility alias,
kept only because `doc/walkthrough.html` still spells it. -/
@[deprecated IdemSemiring (since := "2026-08-12")]
abbrev IdemAdd (S : Type) := IdemSemiring S

/-- `KleeneStar S` is Mathlib's `KleeneAlgebra S`. Deprecated compatibility
alias, kept only because `doc/walkthrough.html` still spells it. -/
@[deprecated KleeneAlgebra (since := "2026-08-12")]
abbrev KleeneStar (S : Type) := KleeneAlgebra S

/-- A `CompleteCSemiring S` is a representation of a resource semiring in which
*aggregation over an index* makes sense: `csum f` is the ⊕-sum of the whole
family `f`. Over `Prop` it is `∃`; over `Cost` it is the supremum; over an
expectation semiring it is the total measure.

**SURVIVOR — what Mathlib lacks.** Mathlib has no class for a semiring with an
arbitrary-index sum. The three candidates and why each fails here:

* `tsum` (`Mathlib.Topology.Algebra.InfiniteSum`) is a *topological* limit of
  finite partial sums. It needs `TopologicalSpace` and `T2Space`, it is only
  meaningful when the family is summable, and the design's `csum` at `Prop` and
  `Cost` is not a limit of anything.
* `iSup` needs a `CompleteLattice`, and a semiring whose `csum` is `iSup` has
  an idempotent `+` (two-point agreement, `csum_pair`, forces `x + y = x ⊔ y`).
* `Mathlib.Algebra.Order.Quantale`'s `IsQuantale` is exactly a semigroup
  distributing over a complete lattice — the honest Mathlib name for a complete
  *idempotent* semiring — and it carries no `csum_point`, no `csum_prod` and no
  unit.

All three exclude the expectation semiring `SqZero P M`, whose aggregation is
componentwise and whose `+` accumulates rather than joins, and that carrier is
half of what `Agentic.Matrix` is asked to compose over. One interface must
cover both families, so the interface stays — but it now extends Mathlib's
`CommSemiring` and adds nothing except `csum` and its laws.

**The index type is arbitrary** (`ι : Type`), deliberately: nothing in the
semantics appeals to an enumeration of the index, so a `Countable ι` hypothesis
would add a proof obligation at every use site and buy no theorem.

**It is a mixin, not an extension.** `[CommSemiring S]` is an instance
*parameter*: the class adds `csum` to a carrier that already has its
arithmetic, and carries no `Semiring` structure of its own. Extending would
create a second `Semiring S` beside every other one — beside `IdemSemiring S`
in particular — so a construction generic in *both* (`Mat S ι ι`'s idempotent
alternation, the panel's duplication licence, matrix leastness) could not
consume the two together without proving the two arithmetics defeq. As a mixin
there is nothing to reconcile, and `[IdemCommSemiring S] [CompleteCSemiring S]`
is an ordinary pair of hypotheses. -/
class CompleteCSemiring (S : Type) [CommSemiring S] where
  /-- The ⊕-aggregate of a whole family: `csum f = ⊕ᵢ f i`. -/
  csum : {ι : Type} → (ι → S) → S
  /-- Aggregating nothing but impossibilities is impossible. -/
  csum_zero : ∀ {ι : Type}, csum (fun _ : ι => (0 : S)) = 0
  /-- A family supported at one index aggregates to its one value. The index
  type carries no `DecidableEq`: *which* index bears the mass is a fact about
  the family, not a computation the meaning is entitled to perform, and both
  carriers discharge the axiom classically. -/
  csum_point : ∀ {ι : Type} (i₀ : ι) (f : ι → S),
    (∀ i, i ≠ i₀ → f i = 0) → csum f = f i₀
  /-- Sequencing distributes over aggregation: the infinitary left distributive law. -/
  csum_mul_left : ∀ {ι : Type} (x : S) (f : ι → S),
    x * csum f = csum (fun i => x * f i)
  /-- Fubini: a doubly-indexed family may be aggregated in either order. -/
  csum_swap : ∀ {ι κ : Type} (f : ι → κ → S),
    csum (fun i => csum (fun j => f i j)) = csum (fun j => csum (fun i => f i j))
  /-- Aggregating over a product index is aggregating twice. -/
  csum_prod : ∀ {ι κ : Type} (f : ι → κ → S),
    csum (fun p : ι × κ => f p.1 p.2) = csum (fun i => csum (fun j => f i j))
  /-- **Two-point agreement**: aggregating a family of two agrees with binary
  alternation. This is the glue between the infinitary `csum` and the finitary
  `+`, and without it the two operations are only accidentally related.

  It is not a consequence of the other fields. Take `(Nat ∪ {⊤}, +, ×)` —
  ordinary arithmetic, `⊕ = +` and `⊗ = ×` — and let `csum` be the supremum.
  Every axiom above holds and this one fails, since `csum {2, 3} = 3` while
  `2 + 3 = 5`. -/
  csum_pair : ∀ x y : S, csum (fun b : Bool => cond b x y) = x + y

export CompleteCSemiring (csum)

section CompleteLaws

variable {S : Type} [CommSemiring S] [CompleteCSemiring S]

/-- Aggregating nothing but impossibilities is impossible (the field, exported). -/
theorem csum_zero {ι : Type} : csum (fun _ : ι => (0 : S)) = 0 :=
  CompleteCSemiring.csum_zero

/-- A family supported at one index aggregates to its one value (the field). -/
theorem csum_point {ι : Type} (i₀ : ι) (f : ι → S)
    (h : ∀ i, i ≠ i₀ → f i = 0) : csum f = f i₀ :=
  CompleteCSemiring.csum_point i₀ f h

/-- Sequencing distributes over aggregation on the left (the field). -/
theorem csum_mul_left {ι : Type} (x : S) (f : ι → S) :
    x * csum f = csum (fun i => x * f i) :=
  CompleteCSemiring.csum_mul_left x f

/-- Fubini for doubly-indexed families (the field). -/
theorem csum_swap {ι κ : Type} (f : ι → κ → S) :
    csum (fun i => csum (fun j => f i j)) = csum (fun j => csum (fun i => f i j)) :=
  CompleteCSemiring.csum_swap f

/-- Aggregation over a product index is iterated aggregation (the field). -/
theorem csum_prod {ι κ : Type} (f : ι → κ → S) :
    csum (fun p : ι × κ => f p.1 p.2) = csum (fun i => csum (fun j => f i j)) :=
  CompleteCSemiring.csum_prod f

/-- Aggregation of a two-point family is binary alternation (the field). -/
theorem csum_pair (x y : S) : csum (fun b : Bool => cond b x y) = x + y :=
  CompleteCSemiring.csum_pair x y

/-- Aggregating over the one-point index is reading off the one value. The
bookkeeping lemma that identifies a `1 × 1` matrix with a scalar. -/
theorem csum_unit (f : Unit → S) : csum f = f () :=
  csum_point () f fun _ hi => absurd rfl hi

/-- Sequencing distributes over aggregation on the right: the symmetric
variant, from commutativity of `*`. -/
theorem csum_mul_right {ι : Type} (x : S) (f : ι → S) :
    csum f * x = csum (fun i => f i * x) := by
  rw [mul_comm, csum_mul_left]
  exact congrArg csum (funext fun i => mul_comm x (f i))

/-- Aggregation respects pointwise equality of families: the `funext`
congruence, stated so proofs need not rebuild it. -/
theorem csum_congr {ι : Type} {f g : ι → S} (h : ∀ i, f i = g i) :
    csum f = csum g :=
  congrArg csum (funext h)

/-- Any family indexed by `Bool` aggregates to the alternative of its two
values: `csum_pair` with the `cond` presentation stripped away. -/
theorem csum_bool (g : Bool → S) : csum g = g true + g false := by
  rw [← csum_pair (g true) (g false)]
  exact csum_congr fun b => by cases b <;> rfl

/-- **Aggregation is additive**: an aggregate of alternatives is the
alternative of the aggregates, `⊕ᵢ (xᵢ + yᵢ) = (⊕ᵢ xᵢ) + (⊕ᵢ yᵢ)`. Two-point
agreement is exactly the missing ingredient — replace each binary `+` by an
aggregation over `Bool`, exchange the two aggregations by Fubini, and read the
outer `Bool`-aggregation back as a `+`. -/
theorem csum_add {ι : Type} (x y : ι → S) :
    csum (fun i => x i + y i) = csum x + csum y :=
  calc csum (fun i => x i + y i)
      = csum (fun i => csum fun b : Bool => cond b (x i) (y i)) :=
        csum_congr fun i => (csum_pair (x i) (y i)).symm
    _ = csum (fun b : Bool => csum fun i => cond b (x i) (y i)) :=
        csum_swap fun i (b : Bool) => cond b (x i) (y i)
    _ = (csum fun i => cond true (x i) (y i)) + (csum fun i => cond false (x i) (y i)) :=
        csum_bool fun b : Bool => csum fun i => cond b (x i) (y i)
    _ = csum x + csum y := rfl

end CompleteLaws

/-! ## Aggregation as a supremum

`CompleteCSemiring` says what an aggregate *is* — a `⊕`-sum over an arbitrary
index — and its six laws say how it behaves under the semiring operations. What
they do not say is anything about *order*: from them one can derive `f i ≤ csum
f` at an idempotent carrier, but never the converse, `csum f ≤ y` from `∀ i, f
i ≤ y`. Leastness of an aggregate is exactly the fact the six fields lack, and
without it the aggregate of a family is only an upper bound of it, not the
least one.

The mixin below supplies precisely that, and supplies it by identifying `csum`
with an operator that already has the property: Mathlib's `iSup`. It is not a
new axiom about `csum` so much as the statement that on a *lattice* carrier the
package's aggregation and Mathlib's are the same function — after which the
whole `iSup` API (`le_iSup`, `iSup_le`, `iSup_le_iff`, `iSup_comm`, …) applies
to `csum` with no translation. -/

/-- `CsumIsSup S` says that the aggregation of `CompleteCSemiring S` is the
supremum of the carrier's complete lattice: `⊕ᵢ fᵢ = ⨆ᵢ fᵢ`.

**Why this is a separate mixin and not a field of `CompleteCSemiring`.** The
expectation semiring `SqZero P M` is a `CompleteCSemiring` whose aggregation is
componentwise and is *not* a supremum — its `+` accumulates moments rather than
joining them — so the law cannot be asked of every complete carrier. It holds
at exactly the three lattice carriers (`Prop`, `Cost`, `Prob`), and at those it
holds by `rfl` or by one Mathlib lemma, because their `csum` was *defined* as
`iSup`.

**What it buys.** Everything an order buys over an equation. With it, `csum f ≤
y` follows from `∀ i, f i ≤ y` (`csum_le`), the finitary `+` is the lattice
join (`csum_add_eq_sup`), the infinitary distributive laws become
`iSup`-distributivity (`csum_mul_iSup`, `csum_iSup_mul`), and those three facts
are exactly the hypotheses of `KleeneAlgebra.ofSupDistrib` — so every carrier
satisfying this mixin has a Kleene star, `x∗ = ⨆ₙ xⁿ`, with no per-carrier
construction at all. -/
class CsumIsSup (S : Type) [CommSemiring S] [CompleteCSemiring S] [CompleteLattice S] : Prop where
  /-- Aggregation is the lattice supremum. -/
  csum_eq_iSup : ∀ {ι : Type} (f : ι → S), csum f = ⨆ i, f i

section IsSupLaws

variable {S : Type} [CommSemiring S] [CompleteCSemiring S] [CompleteLattice S] [CsumIsSup S]

/-- Aggregation is the lattice supremum (the field, exported). -/
theorem csum_eq_iSup {ι : Type} (f : ι → S) : csum f = ⨆ i, f i :=
  CsumIsSup.csum_eq_iSup f

/-- Every member of a family is below its aggregate: Mathlib's `le_iSup`. -/
theorem le_csum {ι : Type} (f : ι → S) (i : ι) : f i ≤ csum f :=
  (csum_eq_iSup f).ge.trans' (le_iSup f i)

/-- **The aggregate is the *least* upper bound**: Mathlib's `iSup_le`. This is
the fact `CompleteCSemiring`'s six fields cannot deliver, and the reason this
mixin exists. -/
theorem csum_le {ι : Type} {f : ι → S} {y : S} (h : ∀ i, f i ≤ y) : csum f ≤ y :=
  (csum_eq_iSup f).le.trans (iSup_le h)

/-- **Binary alternation is the lattice join**: `x + y = x ⊔ y`. Two-point
agreement (`csum_pair`) says the `+` of the semiring is the aggregate of a
two-point family; this mixin says that aggregate is a supremum; and
`iSup_bool_eq` reads a two-point supremum as a join. So the semiring's `⊕` and
the carrier's `⊔` are one operation, which is what an `IdemSemiring` demands. -/
theorem csum_add_eq_sup (x y : S) : x + y = x ⊔ y := by
  rw [← csum_pair x y, csum_eq_iSup, iSup_bool_eq]
  rfl

/-- **Sequencing distributes over arbitrary suprema on the left**, the
infinitary distributive law of `CompleteCSemiring` restated in Mathlib's
vocabulary. -/
theorem csum_mul_iSup {ι : Type} (x : S) (f : ι → S) : x * (⨆ i, f i) = ⨆ i, x * f i := by
  rw [← csum_eq_iSup, csum_mul_left, csum_eq_iSup]

/-- **Sequencing distributes over arbitrary suprema on the right**, from
commutativity of `*`. -/
theorem csum_iSup_mul {ι : Type} (x : S) (f : ι → S) : (⨆ i, f i) * x = ⨆ i, f i * x := by
  rw [mul_comm, csum_mul_iSup]
  exact iSup_congr fun i => mul_comm x (f i)

end IsSupLaws

/-! ## Iteration

Iteration is Mathlib's `KStar.kstar`, written `x∗` in the `Computability`
scope. The package's own `star` abbreviation is gone; the survivor below is the
*law*, not the operation.
-/

/-- A `StarSemiring S` is a representation of *iteration* in a resource
semiring: the single equation says that unrolling the loop once from the front
changes nothing.

**SURVIVOR — what Mathlib lacks.** Mathlib's only star-with-laws on a semiring
is `KleeneAlgebra`, which asks for an idempotent `+` (through `IdemSemiring`)
and for both Kleene inductions. The expectation semiring `SqZero P M` has a
star — `⟨p∗, p∗ m p∗⟩`, design §5.2 — and does *not* have an idempotent `+`, so
it is not a `KleeneAlgebra` and under Mathlib alone it could carry no star at
all. This class is that gap and nothing more: one unrolling law, stated as a
`Prop` mixin over Mathlib's `KStar` so that every `KleeneAlgebra` carrier
satisfies it for free (`instStarSemiringOfKleene`) with no diamond.

What this class assumes is **one unrolling law and nothing else**. It is not a
Conway semiring, and it does not pin the star down: two different stars may
satisfy it on one carrier (at `Cost` the loop equation of `Agentic.Star` has
three solutions where the star has one, `retry_cost_ambiguous`). Theorems that
need the solution to be *the* solution take `[KleeneAlgebra S]`.

Unrolling from the back, `x∗ = 1 + x∗ · x`, is not a field: over a commutative
carrier it is `star_eq_right`, and over a non-commutative one it is a
genuinely different law that no construction here requires of this class. -/
class StarSemiring (S : Type) [Semiring S] [KStar S] : Prop where
  /-- Unrolling from the front: `x∗ = 1 + x · x∗`. -/
  star_eq_left : ∀ x : S, x∗ = 1 + x * x∗

/-- Every Kleene algebra unrolls from the front: Mathlib's
`one_add_mul_kstar`, read as the survivor class's single field. This is what
lets `Agentic.Star`'s retry theorems be stated once, at the weak hypothesis,
and still apply to `Prop`, `Cost`, `Prob` and `Mat Prop ι ι`. -/
instance (priority := 100) instStarSemiringOfKleene {S : Type} [KleeneAlgebra S] :
    StarSemiring S where
  star_eq_left _ := one_add_mul_kstar.symm

/-- Unrolling from the back: `x∗ = 1 + x∗ · x`. Not an assumption — with a
commutative `*` the two unrollings are one law. Over a non-commutative carrier
(matrices, panels) this is unavailable, and deliberately: the retry solve is
left-handed, so nothing needs it. -/
theorem star_eq_right {S : Type} [CommSemiring S] [KStar S] [StarSemiring S] (x : S) :
    x∗ = 1 + x∗ * x :=
  (StarSemiring.star_eq_left x).trans (congrArg (fun y => 1 + y) (mul_comm x (x∗)))

/-! ## The canonical additive order

An equation cannot select a solution; only an order can. The order used here is
the canonical one a semiring already carries: `x ≤ y` iff `x + y = y` — *`y` is
an alternative that already includes `x`*.

That order is **Mathlib's `≤`**, and it is now also Mathlib's *spelling*.
`IdemSemiring` is defined so that `a ≤ b ↔ a + b = b`
(`add_eq_right_iff_le`), with the `SemilatticeSup` and `OrderBot` structure
that follows, and every lemma this module used to prove — reflexivity,
transitivity, antisymmetry, `0` least, both monotonicities of `*`, the
least-upper-bound property of `+` — is Mathlib's, under Mathlib's names. The
`≤+` notation and its twelve wrappers are retired.

It is a *partial* order exactly when `+` is idempotent, and that fence is worth
naming: the expectation semiring `SqZero P M` of `Agentic.Instances`, whose `+`
accumulates moments rather than joining them, is **not** an `IdemSemiring`, so
this order is not its order and the Kleene induction stated with it is not
available there. (The Viterbi carrier `Prob` is a different matter: its `⊕` is
`max`, so it is idempotent and it *is* a `KleeneAlgebra`; "probability" alone
does not decide the question, the choice of `⊕` does.) -/

/-- `addLe` is Mathlib's `≤`. Deprecated compatibility alias, kept only
because `doc/walkthrough.html` still spells it; the `≤+` notation it carried is
retired and every statement in the package is written with `≤`. -/
@[deprecated LE.le (since := "2026-08-12")]
abbrev addLe {S : Type} [LE S] (x y : S) : Prop := x ≤ y

/-- **Kleene induction**, left-handed: anything closed under the loop step is
above the loop's solve. Read `b + a * x ≤ x` as "`x` absorbs the exit and one
more trip", and the conclusion as "then `x` absorbs the whole loop".

This was a class field; it is now Mathlib's `kstar_mul_le`, which is the same
statement with the hypothesis split into its two halves. -/
theorem star_le_left {S : Type} [KleeneAlgebra S] (a b x : S)
    (h : b + a * x ≤ x) : a∗ * b ≤ x :=
  kstar_mul_le (le_trans le_self_add h) (le_trans le_add_self h)

/-- **The star is the least solution of its own unrolling law**: any `x` with
`1 + a · x ≤ x` — in particular any `x` with `x = 1 + a · x` — is above `a∗`.
With the unrolling law, which says `a∗` *is* such an `x`, this characterises
the star: it is the least prefixed point of `y ↦ 1 + a · y`. -/
theorem star_le {S : Type} [KleeneAlgebra S] (a x : S)
    (h : 1 + a * x ≤ x) : a∗ ≤ x := by
  have hx := star_le_left a 1 x h
  rwa [mul_one] at hx

/-- The star of a solved equation, in the form the read-outs use: if
`x = 1 + a · x` then `a∗ ≤ x`. -/
theorem star_le_of_eq {S : Type} [KleeneAlgebra S] {a x : S}
    (h : x = 1 + a * x) : a∗ ≤ x :=
  star_le a x (le_of_eq h.symm)

/-! ## The one star: iteration as the aggregate of the powers

Every star in this package is the same element — `x∗ = ⨆ₙ xⁿ`, the aggregate
over how many times the loop is run — and until this arc every one of them was
built by hand: a closed-form `if` at `Cost`, the identical closed form again at
`Prob`, `True` at possibility, reachability at `Prop`-matrices, each with its
own unrolling law and its own leastness proof. The construction below replaces
all four. It asks for the three facts a *complete idempotent* semiring has —
the join is the sum, and multiplication distributes over arbitrary joins on
each side — and produces the star, both unrolling laws and both Kleene
inductions.

Nothing here is commutative, deliberately: the payoff is
`Mat.instKleeneAlgebra`, where `*` is composition and the right-handed
induction is a genuinely different statement from the left-handed one. Both are
proved, by the same induction on the exponent read on the other side.
-/

/-- **The Kleene star of a complete idempotent semiring**: `x∗ = ⨆ₙ xⁿ`.

The hypotheses are exactly what the proofs use, and each is the honest name of
a property of the carrier:

* `hadd` — the semiring's `⊕` is the lattice's `⊔`. This is what makes the
  carrier an `IdemSemiring` at *the lattice's own order*, so that `≤` in the
  conclusion is the order the carrier came with and not a second one induced by
  `+`. (`0 = ⊥` is not assumed: `0 + a = a` and `hadd` already make `0` a
  bottom.)
* `hmul_iSup`, `hiSup_mul` — sequencing distributes over an *arbitrary*
  aggregate of alternatives, on each side. Finite distributivity is a semiring
  law; these are its infinitary strengthening, and they are the whole reason a
  supremum of powers behaves like a loop.

All five `KleeneAlgebra` fields fall out of `le_iSup`/`iSup_le`. Unrolling is
the reindexing `n ↦ n+1` of the powers; the two inductions are the two ways of
proving `aⁿ · b ≤ b` from `a · b ≤ b`, by induction on `n` peeling the exponent
from the near or the far end. The right-handed induction is *not* obtained from
the left by commutativity — it is proved — which is what lets the same
construction serve matrices. -/
@[reducible] noncomputable def KleeneAlgebra.ofSupDistrib {S : Type} [Semiring S]
    [CompleteLattice S]
    (hadd : ∀ x y : S, x + y = x ⊔ y)
    (hmul_iSup : ∀ {ι : Type} (x : S) (f : ι → S), x * (⨆ i, f i) = ⨆ i, x * f i)
    (hiSup_mul : ∀ {ι : Type} (x : S) (f : ι → S), (⨆ i, f i) * x = ⨆ i, f i * x) :
    KleeneAlgebra S :=
  have hml : ∀ (x : S) {y z : S}, y ≤ z → x * y ≤ x * z := by
    intro x y z h
    calc x * y ≤ x * y ⊔ x * z := le_sup_left
      _ = x * (y ⊔ z) := by rw [← hadd y z, mul_add, hadd]
      _ = x * z := by rw [sup_eq_right.mpr h]
  have hmr : ∀ (x : S) {y z : S}, y ≤ z → y * x ≤ z * x := by
    intro x y z h
    calc y * x ≤ y * x ⊔ z * x := le_sup_left
      _ = (y ⊔ z) * x := by rw [← hadd y z, add_mul, hadd]
      _ = z * x := by rw [sup_eq_right.mpr h]
  { __ := (inferInstance : Semiring S)
    __ := (inferInstance : CompleteLattice S)
    add_eq_sup := hadd
    kstar := fun x => ⨆ n : Nat, x ^ n
    one_le_kstar := fun a => le_iSup_of_le 0 (le_of_eq (pow_zero a).symm)
    mul_kstar_le_kstar := fun a => by
      show a * (⨆ n : Nat, a ^ n) ≤ ⨆ n : Nat, a ^ n
      rw [hmul_iSup]
      exact iSup_le fun n => le_iSup_of_le (n + 1) (le_of_eq (pow_succ' a n).symm)
    kstar_mul_le_kstar := fun a => by
      show (⨆ n : Nat, a ^ n) * a ≤ ⨆ n : Nat, a ^ n
      rw [hiSup_mul]
      exact iSup_le fun n => le_iSup_of_le (n + 1) (le_of_eq (pow_succ a n).symm)
    kstar_mul_le_self := fun a b h => by
      show (⨆ n : Nat, a ^ n) * b ≤ b
      rw [hiSup_mul]
      refine iSup_le fun n => ?_
      induction n with
      | zero => exact le_of_eq (by rw [pow_zero, one_mul])
      | succ n ih =>
        calc a ^ (n + 1) * b = a ^ n * (a * b) := by rw [pow_succ, mul_assoc]
          _ ≤ a ^ n * b := hml _ h
          _ ≤ b := ih
    mul_kstar_le_self := fun a b h => by
      show b * (⨆ n : Nat, a ^ n) ≤ b
      rw [hmul_iSup]
      refine iSup_le fun n => ?_
      induction n with
      | zero => exact le_of_eq (by rw [pow_zero, mul_one])
      | succ n ih =>
        calc b * a ^ (n + 1) = (b * a) * a ^ n := by rw [pow_succ', ← mul_assoc]
          _ ≤ b * a ^ n := hmr _ h
          _ ≤ b := ih }

/-- **The star of every lattice carrier of this package**, in one line: a
commutative complete resource semiring whose aggregation is its supremum is a
Kleene algebra, with `x∗ = ⊕ₙ xⁿ`.

This is `ofSupDistrib` with its three hypotheses discharged by `CsumIsSup`
(`csum_add_eq_sup`, `csum_mul_iSup`, `csum_iSup_mul`). Possibility, worst-case
cost and consensus weight are its three instances, and each of the three
carriers now contributes *no* star mathematics of its own — only the one line
that says its `csum` is an `iSup`. -/
@[reducible] noncomputable def KleeneAlgebra.ofCsumIsSup (S : Type) [CommSemiring S]
    [CompleteCSemiring S] [CompleteLattice S] [CsumIsSup S] : KleeneAlgebra S :=
  KleeneAlgebra.ofSupDistrib csum_add_eq_sup csum_mul_iSup csum_iSup_mul

end Agentic
