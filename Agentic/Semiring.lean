import Agentic.Monoid
import Mathlib.Algebra.Order.Kleene
import Mathlib.Algebra.Module.Defs
import Mathlib.Algebra.Module.Prod

/-!
# The resource algebra: Mathlib's semirings, and the one thing Mathlib lacks

This module used to define the whole algebraic vocabulary of the package:
`NSemiring` (fourteen fields), `CSemiring`, the canonical additive order `≤+`
with its own eight lemmas, `IdemAdd`, `StarSemiring`, `KleeneStar`. All but one
of those is now Mathlib's, and the migration is not a renaming exercise — the
Mathlib versions come with an order, a lattice, monotonicity instances and a
Kleene-induction library that the hand-rolled classes did not have.

| ours | Mathlib |
| --- | --- |
| `NSemiring` | `Semiring` |
| `CSemiring` | `CommSemiring` |
| `IdemAdd` | `IdemSemiring` (idempotent `+`, *with* the induced lattice) |
| `≤+`, `addLe` | `≤` (`IdemSemiring`'s `SemilatticeSup`) |
| `KleeneStar` | `KleeneAlgebra` (`kstar`, `∗`, and both inductions) |
| `star` | `KStar.kstar` |

Two things survive, and each says here exactly what Mathlib lacks.

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

open Computability

/-- `NSemiring S` is Mathlib's `Semiring S`: `+` combines alternatives, `*`
sequences, `0` is the impossible alternative and `1` the free step, and `*` is
**n**ot assumed commutative — which is what lets `Mat S ι ι` and the monoid
semiring `S⟨K⟩` be semirings at all. -/
abbrev NSemiring (S : Type) := Semiring S

/-- `CSemiring S` is Mathlib's `CommSemiring S`: a resource semiring whose
sequencing is order-insensitive. Every *carrier* (possibility, worst-case cost,
consensus weight, expectation) has it; the algebra built over them (matrices,
panels) does not, which is why the base is `Semiring`. -/
abbrev CSemiring (S : Type) := CommSemiring S

/-- `IdemAdd S` is Mathlib's `IdemSemiring S`: a semiring whose alternation is
a join. Mathlib's version carries the induced `SemilatticeSup` and `OrderBot`
as part of the class, so the canonical additive order — the eight lemmas this
module used to prove — arrives with it. -/
abbrev IdemAdd (S : Type) := IdemSemiring S

namespace NSemiring

variable {S : Type} [Semiring S]

/-- Alternatives are unordered (Mathlib's `add_comm`, under the old name). -/
theorem add_comm (a b : S) : a + b = b + a := _root_.add_comm a b

/-- Alternatives are unbracketed (Mathlib's `add_assoc`). -/
theorem add_assoc (a b c : S) : a + b + c = a + (b + c) := _root_.add_assoc a b c

/-- `0` is a left unit for `+` (Mathlib's `zero_add`). -/
theorem zero_add (a : S) : (0 : S) + a = a := _root_.zero_add a

/-- Sequencing is unbracketed (Mathlib's `mul_assoc`). -/
theorem mul_assoc (a b c : S) : a * b * c = a * (b * c) := _root_.mul_assoc a b c

/-- `1` is a left unit for `*` (Mathlib's `one_mul`). -/
theorem one_mul (a : S) : (1 : S) * a = a := _root_.one_mul a

/-- `1` is a right unit for `*` (Mathlib's `mul_one`). -/
theorem mul_one (a : S) : a * 1 = a := _root_.mul_one a

/-- Sequencing distributes over alternatives on the left (Mathlib's
`left_distrib`). -/
theorem left_distrib (a b c : S) : a * (b + c) = a * b + a * c :=
  _root_.left_distrib a b c

/-- Sequencing distributes over alternatives on the right (Mathlib's
`right_distrib`). -/
theorem right_distrib (a b c : S) : (a + b) * c = a * c + b * c :=
  _root_.right_distrib a b c

/-- `0` annihilates on the left (Mathlib's `zero_mul`). -/
theorem zero_mul (a : S) : (0 : S) * a = 0 := MulZeroClass.zero_mul a

/-- `0` annihilates on the right (Mathlib's `mul_zero`). -/
theorem mul_zero (a : S) : a * (0 : S) = 0 := MulZeroClass.mul_zero a

end NSemiring

namespace CSemiring

/-- Sequencing is order-insensitive (Mathlib's `mul_comm`, under the old
name). -/
theorem mul_comm {S : Type} [CommSemiring S] (a b : S) : a * b = b * a :=
  _root_.mul_comm a b

end CSemiring

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
would add a proof obligation at every use site and buy no theorem. -/
class CompleteCSemiring (S : Type) extends CommSemiring S where
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

variable {S : Type} [CompleteCSemiring S]

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

/-! ## Iteration

`star` is Mathlib's `KStar.kstar`, written `x∗` in the `Computability` scope.
-/

/-- `star x` is `KStar.kstar x`: any number of repetitions of `x`, including
none. The package's spelling, kept resolving over Mathlib's notation class. -/
abbrev star {S : Type} [KStar S] (x : S) : S := KStar.kstar x

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
  star_eq_left : ∀ x : S, star x = 1 + x * star x

/-- Every Kleene algebra unrolls from the front: Mathlib's
`one_add_mul_kstar`, read as the survivor class's single field. This is what
lets `Agentic.Star`'s retry theorems be stated once, at the weak hypothesis,
and still apply to `Prop`, `Cost`, `Prob` and `Mat Prop ι ι`. -/
instance (priority := 100) instStarSemiringOfKleene {S : Type} [KleeneAlgebra S] :
    StarSemiring S where
  star_eq_left _ := one_add_mul_kstar.symm

/-- `ConwayStar` is `StarSemiring`: the former name, kept resolving.

The rename was a correction of an overclaim — the class never had the Conway
identities — and the name is kept for callers that spelled it out. -/
abbrev ConwayStar (S : Type) [CommSemiring S] [KStar S] : Prop := StarSemiring S

/-- `ConwayStar.star_eq_left` is `StarSemiring.star_eq_left`: the old
projection name, kept resolving for callers that spelled the field out. -/
theorem ConwayStar.star_eq_left {S : Type} [Semiring S] [KStar S] [StarSemiring S]
    (x : S) : star x = 1 + x * star x :=
  StarSemiring.star_eq_left x

/-- Unrolling from the back: `x∗ = 1 + x∗ · x`. Not an assumption — with a
commutative `*` the two unrollings are one law. Over a non-commutative carrier
(matrices, panels) this is unavailable, and deliberately: the retry solve is
left-handed, so nothing needs it. -/
theorem star_eq_right {S : Type} [CommSemiring S] [KStar S] [StarSemiring S] (x : S) :
    star x = 1 + star x * x :=
  (StarSemiring.star_eq_left x).trans (congrArg (fun y => 1 + y) (mul_comm x (star x)))

/-! ## The canonical additive order

An equation cannot select a solution; only an order can. The order used here is
the canonical one a semiring already carries: `x ≤+ y` iff `x + y = y` — *`y`
is an alternative that already includes `x`*.

That order is now **Mathlib's `≤`**. `IdemSemiring` is defined so that
`a ≤ b ↔ a + b = b` (`add_eq_right_iff_le`), with the `SemilatticeSup` and
`OrderBot` structure that follows, and every lemma this module used to prove —
reflexivity, transitivity, antisymmetry, `0` least, both monotonicities of `*`,
the least-upper-bound property of `+` — is Mathlib's. `≤+` survives as notation
so that existing statements keep reading as they did.

It is a *partial* order exactly when `+` is idempotent, and that fence is worth
naming: the expectation semiring `SqZero P M` of `Agentic.Instances`, whose `+`
accumulates moments rather than joining them, is **not** an `IdemSemiring`, so
this order is not its order and the Kleene induction stated with it is not
available there. (The Viterbi carrier `Prob` is a different matter: its `⊕` is
`max`, so it is idempotent and it *is* a `KleeneAlgebra`; "probability" alone
does not decide the question, the choice of `⊕` does.) -/

/-- `x ≤+ y` — *`y` already includes `x`* — is Mathlib's `≤`. At an
`IdemSemiring` that relation *is* `x + y = y` (`add_eq_right_iff_le`), so this
is the same order the package always meant, with Mathlib's library attached. -/
abbrev addLe {S : Type} [LE S] (x y : S) : Prop := x ≤ y

@[inherit_doc addLe]
infix:50 " ≤+ " => addLe

section AddOrder

variable {S : Type} [IdemSemiring S]

/-- The order is the equation (Mathlib's `add_eq_right_iff_le`, reversed). -/
theorem addLe_iff {x y : S} : x ≤+ y ↔ x + y = y := add_eq_right_iff_le.symm

/-- The impossible alternative is below everything: `0` is `⊥`. -/
theorem zero_addLe (x : S) : (0 : S) ≤+ x := by
  simp

/-- The order is transitive (Mathlib's `le_trans`). -/
theorem addLe_trans {x y z : S} (hxy : x ≤+ y) (hyz : y ≤+ z) : x ≤+ z :=
  le_trans hxy hyz

/-- The order is antisymmetric (Mathlib's `le_antisymm`). -/
theorem addLe_antisymm {x y : S} (hxy : x ≤+ y) (hyx : y ≤+ x) : x = y :=
  le_antisymm hxy hyx

/-- Sequencing is monotone in its right operand (Mathlib's `mul_left_mono`). -/
theorem mul_addLe_mul_left (a : S) {x y : S} (h : x ≤+ y) : a * x ≤+ a * y :=
  mul_right_mono h

/-- Sequencing is monotone in its left operand (Mathlib's `mul_right_mono`). -/
theorem mul_addLe_mul_right (a : S) {x y : S} (h : x ≤+ y) : x * a ≤+ y * a :=
  mul_left_mono h

/-- `+` is the *least* upper bound of `≤+` (Mathlib's `add_le`). -/
theorem add_addLe {x y z : S} (hx : x ≤+ z) (hy : y ≤+ z) : x + y ≤+ z :=
  add_le hx hy

/-- Alternation is idempotent (Mathlib's `add_idem`). -/
theorem add_idem (x : S) : x + x = x := _root_.add_idem x

/-- The order is reflexive (Mathlib's `le_refl`). -/
theorem addLe_refl (x : S) : x ≤+ x := le_refl x

/-- Equals are below equals: the bridge from a solved equation to the order in
which the solution is compared. -/
theorem addLe_of_eq {x y : S} (h : x = y) : x ≤+ y := le_of_eq h

/-- An alternative is below any choice that offers it, on the left (Mathlib's
`le_self_add`). -/
theorem addLe_add_left (x y : S) : x ≤+ x + y := le_self_add

/-- An alternative is below any choice that offers it, on the right (Mathlib's
`le_add_self`). -/
theorem addLe_add_right (x y : S) : y ≤+ x + y := le_add_self

end AddOrder

/-- Every idempotent semiring's `+` is an idempotent operation, in Mathlib's
unbundled form. The bundled `IdemSemiring` carries its own `Semiring` structure,
so a construction that is generic in *another* semiring structure on the same
carrier — `Mat S ι ι` over `[CompleteCSemiring S]`, say — cannot consume
`IdemSemiring S` without a diamond. The unbundled mixin has no structure to
clash, so it is what such constructions ask for. -/
instance (priority := 100) instIdempotentAddOfIdemSemiring {S : Type} [IdemSemiring S] :
    Std.IdempotentOp (α := S) (· + ·) :=
  ⟨add_idem⟩

/-- `KleeneStar S` is Mathlib's `KleeneAlgebra S`: iteration that is
*characterised* rather than merely constrained, the star being the least
solution of the loop equation in the canonical additive order.

Mathlib's class asks for five laws where ours asked for one (`star_le_left`)
plus idempotence, and the extra four are the right-handed twins that a
non-commutative carrier genuinely needs. In exchange it brings `le_kstar`,
`kstar_mono`, `kstar_idem`, `kstar_eq_one`, `one_add_mul_kstar`, the two
`kstar_mul_le`/`mul_kstar_le` families, and the `IdemSemiring` order. -/
abbrev KleeneStar (S : Type) := KleeneAlgebra S

/-- **Kleene induction**, left-handed: anything closed under the loop step is
above the loop's solve. Read `b + a * x ≤+ x` as "`x` absorbs the exit and one
more trip", and the conclusion as "then `x` absorbs the whole loop".

This was a class field; it is now Mathlib's `kstar_mul_le`, which is the same
statement with the hypothesis split into its two halves. -/
theorem star_le_left {S : Type} [KleeneAlgebra S] (a b x : S)
    (h : b + a * x ≤+ x) : star a * b ≤+ x :=
  kstar_mul_le (le_trans le_self_add h) (le_trans le_add_self h)

/-- **The star is the least solution of its own unrolling law**: any `x` with
`1 + a · x ≤+ x` — in particular any `x` with `x = 1 + a · x` — is above `a∗`.
With the unrolling law, which says `a∗` *is* such an `x`, this characterises
the star: it is the least prefixed point of `y ↦ 1 + a · y`. -/
theorem star_le {S : Type} [KleeneAlgebra S] (a x : S)
    (h : 1 + a * x ≤+ x) : star a ≤+ x := by
  have hx := star_le_left a 1 x h
  rwa [mul_one] at hx

/-- The star of a solved equation, in the form the read-outs use: if
`x = 1 + a · x` then `a∗ ≤+ x`. -/
theorem star_le_of_eq {S : Type} [KleeneAlgebra S] {a x : S}
    (h : x = 1 + a * x) : star a ≤+ x :=
  star_le a x (addLe_of_eq h.symm)

/-- `IdemAdd.add_idem` — the old class field, kept resolving as Mathlib's
`add_idem`. -/
theorem IdemAdd.add_idem {S : Type} [IdemSemiring S] (x : S) : x + x = x := _root_.add_idem x

/-- `KleeneStar.star_le_left` — the old class field, kept resolving as the
theorem `star_le_left` (Mathlib's `kstar_mul_le`). -/
theorem KleeneStar.star_le_left {S : Type} [KleeneAlgebra S] (a b x : S)
    (h : b + a * x ≤+ x) : star a * b ≤+ x := _root_.Agentic.star_le_left a b x h

/-- `addIdemCMonoid S` is the join-semilattice on the additive half of an
idempotent semiring.

It used to build an `IdemCMonoid` by hand — the fourth copy of the package's
order — and that copy is what the migration deleted: `IdemSemiring` *is* a
`SemilatticeSup` whose `⊔` is `+`, so the bridge is `inferInstance`. -/
abbrev addIdemCMonoid (S : Type) [IdemSemiring S] : SemilatticeSup S := inferInstance

/-- **The additive order is the package's join order**, by `rfl`: `≤+` is
Mathlib's `≤`, and at an `IdemSemiring` that is the join order of `+`. The two
developments the package used to keep in step are now one development, in
Mathlib. -/
theorem addLe_eq_le {S : Type} [IdemSemiring S] (x y : S) : (x ≤+ y) = (x ≤ y) := rfl

/-- Build a Kleene algebra on a **commutative** idempotent semiring out of the
two facts the package's carriers actually prove: the unrolling law and
left-handed Kleene induction.

Mathlib's `KleeneAlgebra` asks for five fields, two of which are the
right-handed twins of the other two. Over a commutative `*` the twins are the
same law, so the carriers `Cost` and `Prob` — which had exactly `star_eq_left`
and `star_le_left` — become instances with no new mathematics. -/
abbrev KleeneAlgebra.ofCommStarLe {S : Type} [IdemCommSemiring S] (kst : S → S)
    (unroll : ∀ x : S, kst x = 1 + x * kst x)
    (least : ∀ a b x : S, b + a * x ≤ x → kst a * b ≤ x) : KleeneAlgebra S where
  kstar := kst
  one_le_kstar a := by rw [unroll a]; exact le_self_add
  mul_kstar_le_kstar a := by conv_rhs => rw [unroll a]
                             exact le_add_self
  kstar_mul_le_kstar a := by
    rw [mul_comm]
    conv_rhs => rw [unroll a]
    exact le_add_self
  kstar_mul_le_self a b h := least a b b (add_le le_rfl h)
  mul_kstar_le_self a b h := by
    rw [mul_comm]
    exact least a b b (add_le le_rfl (by rwa [mul_comm]))

end Agentic
