import Agentic.Monoid

/-!
# The resource algebra: semirings, commutative, complete, and starred

This module fixes the algebraic vocabulary in which every later meaning is
written. There is no dependency on Mathlib, so the classes are defined here;
they are small, and the complete-with-a-star semiring the design needs is not
in Mathlib in this shape anyway.

The one import is `Agentic.Monoid`, and it is not decoration: the order this
module needs — `x ≤+ y` iff `x + y = y` — is the order an idempotent join
induces, which is developed there once for the whole package. `IdemAdd` below
is the statement that a semiring's `+` is such a join, and `addLe_eq_le` is the
proof that the two orders are the same relation and not two definitions that
resemble each other.

The base is `NSemiring`: a semiring whose `*` is **n**ot assumed commutative.
`CSemiring` adds `mul_comm` on top of it, and the prefix therefore means the
same thing it means for `PMonoid`/`CMonoid` — commutativity is a separate
licence, charged separately. (`SemiringBase` was the alternative name; `N`
against `C` was chosen because the two classes are then read off each other,
and because a bare `Semiring` would invite confusion with Mathlib's during any
future migration.)

Why the split is not bookkeeping: `Mat S ι ι` — the meaning space itself — and
the monoid semiring `S⟨K⟩` of `Agentic.Panel` are semirings whose `*` (matrix
composition, convolution) is *not* commutative, so with only `CSemiring` in the
package the two central constructions could not be said to be semirings at all,
and their laws stayed loose theorems. They are instances now
(`Agentic.Mat.instNSemiring`, `Agentic.MSemiring.instNSemiring`).

In the base the right-handed laws — `mul_one`, `right_distrib`, `mul_zero` —
are fields, because without commutativity nothing derives them; every public
lemma name is unchanged, and a commutative carrier still proves them in a line
from its own `mul_comm`.

The `Add`/`Mul`/`Zero`/`One` instances exist only so that `+ * 0 1` denote
the semiring operations; they carry no laws of their own.
-/

namespace Agentic

/-- An `NSemiring S` is a representation of a *resource semiring*: `⊕` (written
`+`) combines alternatives — two ways of getting the same result — and `⊗`
(written `*`) sequences — one step after another. `0` is the impossible
alternative and `1` the free step.

The `N` is for *not necessarily commutative*: `*` here is a monoid operation
and no more. Alternatives are still unordered (`add_comm` is a field), because
a `+` that cared about the order of two alternatives would not be an
alternation; it is sequencing whose order-sensitivity is left open, and
sequencing is exactly what matrix composition and panel convolution do. -/
class NSemiring (S : Type) where
  /-- Combination of alternatives, written `+`. -/
  add : S → S → S
  /-- Sequencing of steps, written `*`. -/
  mul : S → S → S
  /-- The impossible alternative, written `0`. -/
  zero : S
  /-- The free step, written `1`. -/
  one : S
  /-- Alternatives are unordered. -/
  add_comm : ∀ a b : S, add a b = add b a
  /-- Alternatives are unbracketed. -/
  add_assoc : ∀ a b c : S, add (add a b) c = add a (add b c)
  /-- The impossible alternative contributes nothing. -/
  zero_add : ∀ a : S, add zero a = a
  /-- Sequencing is unbracketed. -/
  mul_assoc : ∀ a b c : S, mul (mul a b) c = mul a (mul b c)
  /-- The free step costs nothing, before. -/
  one_mul : ∀ a : S, mul one a = a
  /-- The free step costs nothing, after. -/
  mul_one : ∀ a : S, mul a one = a
  /-- Sequencing distributes over alternatives offered downstream. -/
  left_distrib : ∀ a b c : S, mul a (add b c) = add (mul a b) (mul a c)
  /-- Sequencing distributes over alternatives offered upstream. -/
  right_distrib : ∀ a b c : S, mul (add a b) c = add (mul a c) (mul b c)
  /-- Sequencing after the impossible is impossible. -/
  zero_mul : ∀ a : S, mul zero a = zero
  /-- Sequencing before the impossible is impossible. -/
  mul_zero : ∀ a : S, mul a zero = zero

/-- `+` denotes `NSemiring.add`: the combination of alternatives. -/
instance instAddOfNSemiring {S : Type} [NSemiring S] : Add S := ⟨NSemiring.add⟩

/-- `*` denotes `NSemiring.mul`: the sequencing of steps. -/
instance instMulOfNSemiring {S : Type} [NSemiring S] : Mul S := ⟨NSemiring.mul⟩

/-- `0` denotes `NSemiring.zero`: the impossible alternative. -/
instance instZeroOfNSemiring {S : Type} [NSemiring S] : Zero S := ⟨NSemiring.zero⟩

/-- `1` denotes `NSemiring.one`: the free step. -/
instance instOneOfNSemiring {S : Type} [NSemiring S] : One S := ⟨NSemiring.one⟩

section NSemiringLaws

variable {S : Type} [NSemiring S]

/-- Alternatives are unordered (the class field, in notation). -/
theorem add_comm (a b : S) : a + b = b + a := NSemiring.add_comm a b

/-- Alternatives are unbracketed (the class field, in notation). -/
theorem add_assoc (a b c : S) : a + b + c = a + (b + c) := NSemiring.add_assoc a b c

/-- `0` is a left unit for `+` (the class field, in notation). -/
theorem zero_add (a : S) : (0 : S) + a = a := NSemiring.zero_add a

/-- Sequencing is unbracketed (the class field, in notation). -/
theorem mul_assoc (a b c : S) : a * b * c = a * (b * c) := NSemiring.mul_assoc a b c

/-- `1` is a left unit for `*` (the class field, in notation). -/
theorem one_mul (a : S) : (1 : S) * a = a := NSemiring.one_mul a

/-- `1` is a right unit for `*` (the class field, in notation). Over a
commutative carrier this is one rewrite from `one_mul`; over a
non-commutative one it is a genuine second law, which is why it is a field. -/
theorem mul_one (a : S) : a * 1 = a := NSemiring.mul_one a

/-- Sequencing distributes over alternatives on the left (the class field). -/
theorem left_distrib (a b c : S) : a * (b + c) = a * b + a * c :=
  NSemiring.left_distrib a b c

/-- Sequencing distributes over alternatives on the right (the class field). -/
theorem right_distrib (a b c : S) : (a + b) * c = a * c + b * c :=
  NSemiring.right_distrib a b c

/-- `0` annihilates on the left (the class field, in notation). -/
theorem zero_mul (a : S) : (0 : S) * a = 0 := NSemiring.zero_mul a

/-- `0` annihilates on the right too: refusal downstream is still refusal
(the class field, in notation). -/
theorem mul_zero (a : S) : a * (0 : S) = 0 := NSemiring.mul_zero a

/-- `0` is also a right unit for `+`: the symmetric variant, from
commutativity of `+`, which every semiring here has. -/
theorem add_zero (a : S) : a + 0 = a := by
  rw [add_comm, zero_add]

end NSemiringLaws

/-- A `CSemiring S` is a representation of a resource semiring whose sequencing
is *order-insensitive*: the resource cost of a sequence does not depend on the
order of its steps.

Commutativity of `*` is a real assumption and a real restriction. Every
*carrier* the design uses (possibility, worst-case cost, expectation) has it,
and the theorems that need it need it badly — the Kronecker mixed product above
all. What does *not* have it is the algebra built over those carriers: matrix
composition and panel convolution are non-commutative, and that is why they are
`NSemiring`s and this class is a strict strengthening rather than the base.
Order-sensitivity in the design lives in the world-threading and in those
constructions, never in the resource. -/
class CSemiring (S : Type) extends NSemiring S where
  /-- Resource cost is insensitive to the order of steps. -/
  mul_comm : ∀ a b : S, mul a b = mul b a

section CSemiringLaws

variable {S : Type} [CSemiring S]

/-- Sequencing is order-insensitive (the class field, in notation). -/
theorem mul_comm (a b : S) : a * b = b * a := CSemiring.mul_comm a b

/-- The middle-four interchange: two independent pairs of steps may be
regrouped. This is the sole reason the Kronecker mixed product holds, and the
sole place commutativity of `*` is doing real work. -/
theorem mul_mul_mul_comm (a b c d : S) : a * b * (c * d) = a * c * (b * d) := by
  rw [mul_assoc, ← mul_assoc b c d, mul_comm b c, mul_assoc c b d, ← mul_assoc]

end CSemiringLaws

/-- A `CompleteCSemiring S` is a representation of a resource semiring in which
*aggregation over an index* makes sense: `csum f` is the ⊕-sum of the whole
family `f`. Over `Prop` it is `∃`; over `Cost` it is the supremum; over an
expectation semiring it is the total measure.

**The index type is arbitrary** (`ι : Type`), and deliberately so, although the
design document hypothesises *countable* consultation indices (§2). Every
instance the design needs supplies a sum over any index at all: over `Prop` it
is `∃ i, f i`, over `Cost` a supremum in a complete linear order. Nothing in
the semantics — matrix composition, Chapman–Kolmogorov, the Kronecker mixed
product — appeals to an enumeration of the index, so a `Countable ι`
hypothesis would add a proof obligation at every use site and buy no theorem.
Countability remains true of the *intended* indices (conversations, tool calls,
panel members are all countable) and is what makes these sums
finite-approximable in an implementation; but it is a fact about the models,
not a premise of the meanings, and it is legitimate — and usual — for a meaning
to quantify over more than an implementation can enumerate. Should a later
stratum need genuine enumeration (a truncated sum, or transport along
`ι ≃ Nat`), the way to add it is a `Countable` class with `csum` unchanged:
an interface change, not a theorem change. -/
class CompleteCSemiring (S : Type) extends CSemiring S where
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
  `+`, and without it the two operations are only accidentally related: the
  remaining axioms speak of point-supported families, of reindexing and of
  multiplication, and never once say that `csum` *is* an iterated `+`. A
  complete semiring is normally defined so that this holds by construction, and
  the axiom is stated here because the class had omitted it.

  It is not a consequence of the other fields. Take `(Nat ∪ {⊤}, +, ×)` —
  ordinary arithmetic, `⊕ = +` and `⊗ = ×` — and let `csum` be the supremum.
  Every axiom above holds and this one fails, since `csum {2, 3} = 3` while
  `2 + 3 = 5`. That model is *not* this package's `Cost`, whose `⊕` already is
  `max`, and where aggregation by supremum therefore agrees with `+`. -/
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
outer `Bool`-aggregation back as a `+`. Nothing about the carrier is used, so
the law that `Matrix` once carried as a hypothesis on every theorem that
distributes composition over matrix addition is available to all of them for
free. -/
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

/-- A `StarSemiring S` is a representation of *iteration* in a resource
semiring: `star x` is the resource of doing `x` any number of times, including
none. The single equation says exactly that unrolling the loop once from the
front changes nothing, and it is the law that makes the retry combinator
(`Agentic.Star`) meaningful.

The base is `NSemiring`, **not** `CSemiring`, and that is the point of the
class as it now stands. The design's headline retry solve is
`(M_A · d)* · M_B` at *matrices* (§5.2), and matrix composition does not
commute; a star that demanded a commutative carrier could not be asked of
`Mat S ι ι` at all, so the design's own statement was unstatable in the very
place it is meant to be read. Nothing in the retry theorems used commutativity
— they are left-handed throughout — so the licence was being charged and not
spent.

What this class assumes is **one unrolling law and nothing else**. It is not a
Conway semiring: the Conway identities proper — `(x + y)* = x* · (y · x*)*`
and `(x · y)* = 1 + x · (y · x)* · y` — are not assumed here or anywhere in
this package. Neither is the least-fixed-point property that pins `star` down:
that is the separate strengthening `KleeneStar`, at the end of this module, and
what it costs is an idempotent `+`. Two different `star`s may satisfy this
field on the same carrier — at `Cost` the loop equation of `Agentic.Star` has
three solutions where the star has one (`retry_cost_ambiguous`) — so a theorem
proved from this class alone is a theorem about *any* solution of the unrolling
equation. That is as much as the unrolling law can say; the theorems that need
the solution to be *the* solution take `[KleeneStar S]` and say so.

Unrolling from the back, `x* = 1 + x* · x`, is *not* a field: over a
commutative carrier it is the theorem `star_eq_right`, and over a
non-commutative one it is a genuinely different law that no construction here
requires. -/
class StarSemiring (S : Type) [NSemiring S] where
  /-- Any number of repetitions of `x`, including none. -/
  star : S → S
  /-- Unrolling from the front: `x* = 1 + x · x*`. -/
  star_eq_left : ∀ x : S, star x = 1 + x * star x

export StarSemiring (star)

/-- `ConwayStar` is `StarSemiring`: the former name, kept resolving.

The rename is a correction of an overclaim, not a change of content. The class
never had the Conway identities — its docstring said so — and it now also
carries the weaker base (`NSemiring`), so the name had nothing left to point
at. Existing `[CSemiring S] [ConwayStar S]` hypotheses still elaborate, since
a commutative carrier is a carrier. -/
abbrev ConwayStar (S : Type) [CSemiring S] : Type := StarSemiring S

/-- `ConwayStar.star_eq_left` is `StarSemiring.star_eq_left`: the old
projection name, kept resolving for callers that spelled the field out. -/
theorem ConwayStar.star_eq_left {S : Type} [NSemiring S] [StarSemiring S]
    (x : S) : star x = 1 + x * star x :=
  StarSemiring.star_eq_left x

/-- Unrolling from the back: `x* = 1 + x* · x`. Not an assumption — with a
commutative `*` the two unrollings are one law, so no instance is asked to
prove it twice. Over a non-commutative carrier (matrices, panels) this is
unavailable, and deliberately: the retry solve is left-handed, so nothing
needs it. -/
theorem star_eq_right {S : Type} [CSemiring S] [StarSemiring S] (x : S) :
    star x = 1 + star x * x :=
  (StarSemiring.star_eq_left x).trans (congrArg (fun y => 1 + y) (mul_comm x (star x)))

/-! ## The canonical additive order

An equation cannot select a solution; only an order can. The order used here is
the canonical one a semiring already carries: `x ≤+ y` iff `x + y = y` — *`y`
is an alternative that already includes `x`*. Nothing has to be added to the
signature to write it down, and at every carrier in this package it means what
the carrier's own order means: implication at `Prop`, the max-order at `Cost`,
entrywise implication at `Prop`-matrices.

It is a *partial* order exactly when `+` is idempotent, which is `IdemAdd`
below; without idempotence `x ≤+ x` need not hold and the relation is not even
reflexive. That is a real fence and it is worth naming what falls outside it:
the expectation semiring `SqZero P M` of `Agentic.Instances`, whose `+`
accumulates moments rather than joining them, is **not** idempotent at the
moment module it is meant for, so this order is not its order and the Kleene
induction stated with it is not available there — its star answers the
unrolling law and is not claimed to be least. (The Viterbi carrier `Prob` is a
different matter: its `⊕` is `max`, so it is idempotent and it *is* a
`KleeneStar`; "probability" alone does not decide the question, the choice of
`⊕` does.) What a non-idempotent carrier needs is an order supplied separately
(a `[LE S]` with monotonicity laws, `acat-jmm`), and the honest reading of
`KleeneStar` is: leastness for the idempotent carriers, which is every carrier
here except expectation. -/

/-- `x ≤+ y` — *`y` already includes `x`* — is the canonical additive preorder
of a semiring: `x + y = y`, the order induced by `+` read as a join.

Defining the order by an equation rather than by cases is what makes the lemmas
below equational consequences of the semiring laws, and it is what lets
`retry_least` be proved by rewriting rather than by an argument about the
carrier. -/
def addLe {S : Type} [NSemiring S] (x y : S) : Prop := x + y = y

@[inherit_doc addLe]
infix:50 " ≤+ " => addLe

/-- An `IdemAdd S` is the statement that a resource semiring's alternation is a
*join*: offering the same alternative twice offers it once.

This is the duplication licence of `IdemCMonoid` (`Agentic.Monoid`) written at
the additive half of a semiring, and it is exactly the hypothesis under which
`≤+` is a partial order. Possibility, worst-case cost and matrices over them
have it; a counting or probabilistic carrier does not, and is thereby excluded
from every theorem below — deliberately, and with the consequence recorded in
the section docstring above. -/
class IdemAdd (S : Type) [NSemiring S] : Prop where
  /-- Offering the same alternative twice offers it once. -/
  add_idem : ∀ x : S, x + x = x

section AddOrder

variable {S : Type} [NSemiring S]

/-- The order is the equation, by definition — stated so that proofs may hand
an equation to a `≤+` goal without unfolding a `def` by hand. -/
theorem addLe_iff {x y : S} : x ≤+ y ↔ x + y = y := Iff.rfl

/-- The impossible alternative is below everything: `0` is the least element,
and this needs no idempotence. -/
theorem zero_addLe (x : S) : (0 : S) ≤+ x := zero_add x

/-- The order is transitive. Idempotence is not used: transitivity is
associativity of `+`. -/
theorem addLe_trans {x y z : S} (hxy : x ≤+ y) (hyz : y ≤+ z) : x ≤+ z := by
  show x + z = z
  rw [← hyz, ← add_assoc, hxy]

/-- The order is antisymmetric, so it is a genuine partial order wherever it is
reflexive: two mutually-including alternatives are one alternative. -/
theorem addLe_antisymm {x y : S} (hxy : x ≤+ y) (hyx : y ≤+ x) : x = y := by
  rw [← hxy, add_comm, hyx]

/-- Sequencing is monotone in its right operand: a step before a weaker
alternative is weaker. Distributivity, and nothing else. -/
theorem mul_addLe_mul_left (a : S) {x y : S} (h : x ≤+ y) : a * x ≤+ a * y := by
  show a * x + a * y = a * y
  rw [← left_distrib, h]

/-- Sequencing is monotone in its left operand. -/
theorem mul_addLe_mul_right (a : S) {x y : S} (h : x ≤+ y) : x * a ≤+ y * a := by
  show x * a + y * a = y * a
  rw [← right_distrib, h]

/-- A choice between two alternatives already included in `z` is included in
`z`: `+` is the *least* upper bound of `≤+`, not merely an upper bound. -/
theorem add_addLe {x y z : S} (hx : x ≤+ z) (hy : y ≤+ z) : x + y ≤+ z := by
  show x + y + z = z
  rw [add_assoc, hy, hx]

end AddOrder

section AddOrderIdem

variable {S : Type} [NSemiring S] [IdemAdd S]

/-- Alternation is idempotent (the class field, in notation). -/
theorem add_idem (x : S) : x + x = x := IdemAdd.add_idem x

/-- The order is reflexive: idempotence, in the order's notation. This is the
one law that fails without `IdemAdd`, and it is the one every leastness proof
starts from. -/
theorem addLe_refl (x : S) : x ≤+ x := add_idem x

/-- Equals are below equals: the bridge from a solved equation to the order in
which the solution is compared. `retry_least` is `retry_le_of_step` composed
with this. -/
theorem addLe_of_eq {x y : S} (h : x = y) : x ≤+ y := h ▸ addLe_refl x

/-- An alternative is below any choice that offers it, on the left: the join is
an upper bound of its left operand. -/
theorem addLe_add_left (x y : S) : x ≤+ x + y := by
  show x + (x + y) = x + y
  rw [← add_assoc, add_idem]

/-- An alternative is below any choice that offers it, on the right. -/
theorem addLe_add_right (x y : S) : y ≤+ x + y := by
  show y + (x + y) = x + y
  rw [← add_assoc, add_comm y x, add_assoc, add_idem]

/-- **The additive order is the package's join order.** A semiring with an
idempotent `+` is an `IdemCMonoid` on its additive half, and `≤+` is that
monoid's `IdemCMonoid.le` — the same relation, not a parallel definition. The
order lemmas above could therefore have been imported from `Agentic.Monoid`;
they are re-proved in the semiring's notation because every consumer here
writes `+` rather than `⋄`, and this pair of declarations is what keeps the two
developments one development rather than the fourth and fifth copy of an
order. -/
@[reducible] def addIdemCMonoid (S : Type) [NSemiring S] [IdemAdd S] : IdemCMonoid S where
  op x y := x + y
  unit := 0
  op_assoc := add_assoc
  unit_op := zero_add
  op_unit := add_zero
  op_comm := add_comm
  op_idem := add_idem

/-- The additive order *is* the induced join order of `Agentic.Monoid`, by
`rfl`: both sides are the equation `x + y = y`. -/
theorem addLe_eq_le (x y : S) :
    (x ≤+ y) = @IdemCMonoid.le S (addIdemCMonoid S) x y := rfl

end AddOrderIdem

/-- A `KleeneStar S` is a representation of iteration that is *characterised*
rather than merely constrained: the star is the **least** solution of the loop
equation, in the canonical additive order.

`StarSemiring` says `x* = 1 + x · x*`, which every fixed point of the same
equation also says; the class therefore admits several stars on one carrier and
several answers to one loop. At `Cost` this is not hypothetical — with
`a = 1` and `b = fin 3` the retry equation is solved by `fin 3`, by `fin 5` and
by `inf` alike, each by `rfl` (`Agentic.retry_cost_ambiguous`). This class adds
the missing half: `star_le_left` says the star's answer is below every other,
so the loop's meaning is pinned.

**Why idempotence is a field.** Leastness needs an order, and the order chosen
is `≤+`, which is reflexive only when `+` is a join. Rather than carry a
`[IdemAdd S]` hypothesis on every theorem that uses leastness, the class
extends `IdemAdd`: an instance of `KleeneStar` is a promise that the carrier's
alternation is idempotent *and* that its star is least in the resulting order.
Four of the five carriers that have a star here are idempotent (`Prop`, `Cost`,
`Prob`, `Mat Prop ι ι`) and are instances; the fifth, the expectation semiring
`SqZero P M`, is not, so it carries `StarSemiring` alone. It needs a different
order and a different class (acat-jmm), and is honestly outside this one.

**Why the induction is left-handed.** `star_le_left` is stated with the
multiplication on the same side as `star_eq_left` and as the retry solve
`(M_A · d)* · M_B`, so that `retry_least` follows by two rewrites over the
*non-commutative* base. The right-handed principle
(`b + x · a ≤+ x → b · star a ≤+ x`) is a genuinely different law over a
non-commutative carrier; nothing here needs it, so nothing here assumes it. -/
class KleeneStar (S : Type) [NSemiring S] extends StarSemiring S, IdemAdd S where
  /-- **Kleene induction**, left-handed: anything closed under the loop step is
  above the loop's solve. Read `b + a * x ≤+ x` as "`x` absorbs the exit and
  one more trip", and the conclusion as "then `x` absorbs the whole loop". -/
  star_le_left : ∀ a b x : S, b + a * x ≤+ x → star a * b ≤+ x

/-- **Kleene induction** (the class field, in notation): if `x` absorbs the
exit `b` and one more trip round `a`, it absorbs `a* · b`. -/
theorem star_le_left {S : Type} [NSemiring S] [KleeneStar S] (a b x : S)
    (h : b + a * x ≤+ x) : star a * b ≤+ x :=
  KleeneStar.star_le_left a b x h

/-- **The star is the least solution of its own unrolling law**: any `x` with
`1 + a · x ≤+ x` — in particular any `x` with `x = 1 + a · x` — is above `a*`.
With `star_eq_left`, which says `a*` *is* such an `x`, this characterises the
star: it is the least prefixed point of `y ↦ 1 + a · y`. -/
theorem star_le {S : Type} [NSemiring S] [KleeneStar S] (a x : S)
    (h : 1 + a * x ≤+ x) : star a ≤+ x := by
  have hx := star_le_left a 1 x h
  rwa [mul_one] at hx

/-- The star of a solved equation, in the form the read-outs use: if
`x = 1 + a · x` then `a* ≤+ x`. This is `star_le` with the equation turned into
the order by `addLe_of_eq`, and it is what makes "all three of `fin 3`, `fin 5`
and `inf` solve the loop, and the star picks the first" a theorem. -/
theorem star_le_of_eq {S : Type} [NSemiring S] [KleeneStar S] {a x : S}
    (h : x = 1 + a * x) : star a ≤+ x :=
  star_le a x (addLe_of_eq h.symm)

end Agentic
