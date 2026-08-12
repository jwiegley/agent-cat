import Agentic.Semiring

/-!
# Resource-weighted transitions as matrices

The meaning space of the design is a category of matrices over a complete
resource semiring. Everything in this module is stated for *bare* matrices;
the world-threading that makes the design's tensor merely premonoidal is
introduced later and lives there, not here.
-/

namespace Agentic

open Computability KStar

/-- A `Mat S ι κ` is a representation of a resource-weighted transition: the
entry `M a b` is the weight of `a` becoming `b`. A model IS such a matrix — the
weight of a prompt becoming a completion; so is a workflow, so is a tool call,
so is a whole session. Nothing at this layer distinguishes them, and no kind of
thing is missing from the list.

There *is* a written syntax — `Agentic.Term`, the graded term language of §4 —
so "the design has no separate notion of program" is no longer the whole story.
It remains true that the syntax is not a second kind of *meaning*: a term is a
tree a designer writes, and the quantitative meaning function that reads it,
`Agentic.Term.muS`, lands in exactly these matrices — every clause of it is one
of the operations below. The two strata now touch, and they touch here.

**SURVIVOR — what Mathlib lacks.** Mathlib has `Matrix m n α := m → n → α`
(`Mathlib/LinearAlgebra/Matrix/Defs.lean`, line 53), which is this type on the
nose, and it is *not* the type that is missing. What is missing is the
multiplication. Mathlib's matrix product is

```
@[default_instance 100]
instance [Fintype m] [Mul α] [AddCommMonoid α] :
    HMul (Matrix l m α) (Matrix m n α) (Matrix l n α)
```

(`Mathlib/Data/Matrix/Mul.lean`, line 294), summing with `Finset.sum` over
`Finset.univ`; its own docstring says "This is currently only defined when `m`
is finite". Every index in this package is an arbitrary `Type`: prompts,
completions, patches, findings, sessions, the environment's answer space. None
of them is a `Fintype`, and none of them may be assumed one — "the table of all
replies" is the whole idea of §1, and there are infinitely many replies. The
intermediate index of a Chapman–Kolmogorov composition is therefore summed with
`csum` (`Agentic.CompleteCSemiring`, itself a survivor for the same reason),
not with `Finset.sum`, and a distinct type is what keeps the two products from
being confused: `Mat` is a `def`, so `Matrix`'s `HMul` — a `default_instance`,
which fires eagerly — cannot reach it and silently demand a `Fintype`.

Everything else in this module is downstream of that one choice. `comp` is not
`Matrix.mul`; `kron` is not `Matrix.kroneckerMap`
(`Mathlib/LinearAlgebra/Matrix/Kronecker.lean`, line 55); the
`Semiring (Mat S ι ι)` instance is not `Matrix.semiring`
(`Mathlib/Data/Matrix/Mul.lean`, line 496, `[Fintype n] [DecidableEq n]`).
Should Mathlib ever acquire an arbitrary-index matrix product over a complete
semiring, this module becomes a transport. -/
def Mat (S : Type) (ι κ : Type) : Type := ι → κ → S

/-- `CsumAdditive S` is the property that aggregation splits over binary
alternatives: `⊕ᵢ (xᵢ + yᵢ) = (⊕ᵢ xᵢ) + (⊕ᵢ yᵢ)`.

It used to be a hypothesis — a fence carried by every theorem that distributes
composition over matrix addition — on the ground that `CompleteCSemiring` did
not imply it. That ground has given way: what the class was missing was not
this law but the law relating `csum` to `+` at all, `CompleteCSemiring.csum_pair`,
and with that axiom in place `CsumAdditive S` holds of *every* complete
resource semiring (`csumAdditive`, below). The name survives as a statement,
not as an obligation. -/
def CsumAdditive (S : Type) [CommSemiring S] [CompleteCSemiring S] : Prop :=
  ∀ {ι : Type} (x y : ι → S), csum (fun i => x i + y i) = csum x + csum y

/-- **Every complete resource semiring aggregates additively.** The derivation
is `csum_add`, proved with the other aggregation laws in `Agentic.Semiring`
because `Panel` needs it too: rewrite each binary `+` as an aggregation over `Bool`
(two-point agreement, read backwards), exchange the two aggregations (Fubini),
and read the outer one back as a `+`. No hypothesis on the carrier is left,
so the theorems below state the distributive laws they mean. -/
theorem csumAdditive {S : Type} [CommSemiring S] [CompleteCSemiring S] : CsumAdditive S :=
  fun x y => csum_add x y

namespace Mat

variable {S : Type} {ι κ ν ρ ι' κ' ν' : Type}

open Classical in
/-- The identity transition: `a` becomes `a` for free and becomes nothing
else. Caching, replay and "do nothing" all denote this matrix.

The equality test is classical, so the identity exists at **every** index
type and not merely at the decidable ones. Deciding whether two states are
equal is an implementation's problem; a meaning is entitled to say that `a`
becomes `a` whether or not anyone can check it, and the price — this
definition, and everything downstream of it, is `noncomputable` — is exactly
the price of letting the meaning be uncomputable. -/
noncomputable def idMat [CommSemiring S] : Mat S ι ι :=
  fun a b => if a = b then 1 else 0

/-- Staying put is free: the diagonal entry of the identity is `1`. Stated as
a lemma so that no later proof has to name the classical decision procedure
that `idMat` was defined with. -/
theorem idMat_self [CommSemiring S] (a : ι) : (idMat : Mat S ι ι) a a = 1 :=
  if_pos rfl

/-- Becoming something else is impossible: the off-diagonal entries of the
identity are `0`. -/
theorem idMat_ne [CommSemiring S] {a b : ι} (h : a ≠ b) : (idMat : Mat S ι ι) a b = 0 :=
  if_neg h

/-- Composition of transitions: the weight of `a` becoming `c` is the
aggregate, over every intermediate `b`, of doing the first step and then the
second. This is Chapman–Kolmogorov, and it is the only sequencing operator the
design needs. -/
def comp [CommSemiring S] [CompleteCSemiring S] (M : Mat S ι κ) (N : Mat S κ ν) : Mat S ι ν :=
  fun a c => csum fun b => M a b * N b c

/-- The Kronecker product: two transitions run side by side on a pair of
indices, their weights multiplied. -/
def kron [CommSemiring S] (A : Mat S ι κ) (B : Mat S ι' κ') :
    Mat S (ι × ι') (κ × κ') :=
  fun p q => A p.1 q.1 * B p.2 q.2

/-- Composition is associative: the intermediate index may be summed over in
either order, so a pipeline has one meaning, not a bracketing of meanings. -/
theorem comp_assoc [CommSemiring S] [CompleteCSemiring S]
    (M : Mat S ι κ) (N : Mat S κ ν) (P : Mat S ν ρ) :
    comp (comp M N) P = comp M (comp N P) := by
  funext a d
  show csum (fun c => (csum fun b => M a b * N b c) * P c d)
      = csum fun b => M a b * (csum fun c => N b c * P c d)
  calc csum (fun c => (csum fun b => M a b * N b c) * P c d)
      = csum (fun c => csum fun b => M a b * N b c * P c d) :=
        csum_congr fun c => csum_mul_right (P c d) fun b => M a b * N b c
    _ = csum (fun b => csum fun c => M a b * N b c * P c d) :=
        csum_swap fun c b => M a b * N b c * P c d
    _ = csum (fun b => csum fun c => M a b * (N b c * P c d)) :=
        csum_congr fun b => csum_congr fun c => mul_assoc _ _ _
    _ = csum (fun b => M a b * csum fun c => N b c * P c d) :=
        csum_congr fun b => (csum_mul_left (M a b) fun c => N b c * P c d).symm

/-- The identity transition is a left unit: prefixing "do nothing" changes no
meaning. The point-mass axiom for aggregation is exactly what makes this
work. -/
theorem id_comp [CommSemiring S] [CompleteCSemiring S] (M : Mat S ι κ) :
    comp idMat M = M := by
  funext a c
  show csum (fun b => (idMat : Mat S ι ι) a b * M b c) = M a c
  have h : ∀ b, b ≠ a → (idMat : Mat S ι ι) a b * M b c = 0 := by
    intro b hb
    rw [idMat_ne fun he => hb he.symm, zero_mul]
  rw [csum_point a (fun b => (idMat : Mat S ι ι) a b * M b c) h, idMat_self, one_mul]

/-- The identity transition is a right unit: appending "do nothing" changes no
meaning. -/
theorem comp_id [CommSemiring S] [CompleteCSemiring S] (M : Mat S ι κ) :
    comp M idMat = M := by
  funext a c
  show csum (fun b => M a b * (idMat : Mat S κ κ) b c) = M a c
  have h : ∀ b, b ≠ c → M a b * (idMat : Mat S κ κ) b c = 0 := by
    intro b hb
    rw [idMat_ne hb, mul_zero]
  rw [csum_point c (fun b => M a b * (idMat : Mat S κ κ) b c) h, idMat_self, mul_one]

/-- The mixed product law: running `A` then `C` beside `B` then `D` is the
same as running `A` beside `B` and then `C` beside `D`. Everything is used
here — `csum_prod` to split the product index, `csum_swap` and the infinitary
distributive laws to separate the two aggregations, and commutativity of `*`
to interchange the middle pair.

This equality holds for **bare** matrices, unconditionally. The design's
premonoidal degradation — the failure of `(f ⊗ id) ∘ (id ⊗ g)` to equal
`(id ⊗ g) ∘ (f ⊗ id)` — comes from world-threading, from effects on a shared
environment; it does not come from the resource algebra, and so it cannot be
seen at this level. -/
theorem kron_mixed_product [CommSemiring S] [CompleteCSemiring S]
    (A : Mat S ι κ) (B : Mat S ι' κ') (C : Mat S κ ν) (D : Mat S κ' ν') :
    comp (kron A B) (kron C D) = kron (comp A C) (comp B D) := by
  funext p q
  show csum (fun r : κ × κ' => A p.1 r.1 * B p.2 r.2 * (C r.1 q.1 * D r.2 q.2))
      = (csum fun b => A p.1 b * C b q.1) * (csum fun b' => B p.2 b' * D b' q.2)
  calc csum (fun r : κ × κ' => A p.1 r.1 * B p.2 r.2 * (C r.1 q.1 * D r.2 q.2))
      = csum (fun b => csum fun b' => A p.1 b * B p.2 b' * (C b q.1 * D b' q.2)) :=
        csum_prod fun b b' => A p.1 b * B p.2 b' * (C b q.1 * D b' q.2)
    _ = csum (fun b => csum fun b' => A p.1 b * C b q.1 * (B p.2 b' * D b' q.2)) :=
        csum_congr fun b => csum_congr fun b' => mul_mul_mul_comm _ _ _ _
    _ = csum (fun b => A p.1 b * C b q.1 * csum fun b' => B p.2 b' * D b' q.2) :=
        csum_congr fun b =>
          (csum_mul_left (A p.1 b * C b q.1) fun b' => B p.2 b' * D b' q.2).symm
    _ = (csum fun b => A p.1 b * C b q.1) * (csum fun b' => B p.2 b' * D b' q.2) :=
        (csum_mul_right _ fun b => A p.1 b * C b q.1).symm

/-! ### Functions and coproducts as matrices

Two combinators the meaning fold of `Agentic.Meaning` reads its `pureT` and
`choiceT` rows off. Neither is about resources: a plain function weighs one
outcome `1` and every other `0`, and a branch on a coproduct weighs by
whichever side arrived. They live here because they are matrix constructions
and because their laws are the composition laws proved above. -/

open Classical in
/-- **A plain function as a transition**: `pointMat f` sends `a` to `f a` for
free and to nothing else. This is the design's `Transform` row — a `Transform`
is a plain function, central by construction, and what it denotes is a 0-1
matrix, not a diminished or weighted one.

The equality test is classical, exactly as `idMat`'s is and for the same
reason: a meaning is entitled to say that `a` becomes `f a` whether or not
anyone can decide the outcome type's equality. Indeed `idMat` *is* `pointMat
id` (`pointMat_id`). -/
noncomputable def pointMat [CommSemiring S] (f : ι → κ) : Mat S ι κ :=
  fun a b => if f a = b then 1 else 0

/-- A function reaches its own value for free. Stated as a lemma so that no
proof below has to name the classical decision procedure `pointMat` was
defined with, exactly as `idMat_self` does for the identity. -/
theorem pointMat_apply_self [CommSemiring S] (f : ι → κ) (a : ι) :
    (pointMat f : Mat S ι κ) a (f a) = 1 :=
  if_pos rfl

/-- A function reaches nothing else: every outcome other than the function's
value has the impossible weight. -/
theorem pointMat_apply_ne [CommSemiring S] {f : ι → κ} {a : ι} {b : κ}
    (h : f a ≠ b) : (pointMat f : Mat S ι κ) a b = 0 :=
  if_neg h

/-- Doing nothing is the identity function's transition: the two definitions
agree on the nose, so the `Transform` row subsumes the `Category` row's unit
rather than sitting beside it. -/
theorem pointMat_id [CommSemiring S] :
    (pointMat (fun a : ι => a) : Mat S ι ι) = idMat := rfl

/-- **A function composes by substitution**: prefixing a pipeline with the
transition of `f` is evaluating the pipeline at `f a`. The aggregate collapses
to its one nonzero term, which is what makes a `Transform` cost nothing and
sum over nothing. -/
theorem pointMat_comp [CommSemiring S] [CompleteCSemiring S] (f : ι → κ) (M : Mat S κ ν) :
    comp (pointMat f) M = fun a c => M (f a) c := by
  funext a c
  show csum (fun b => (pointMat f : Mat S ι κ) a b * M b c) = M (f a) c
  have h : ∀ b, b ≠ f a → (pointMat f : Mat S ι κ) a b * M b c = 0 := by
    intro b hb
    rw [pointMat_apply_ne fun he => hb he.symm, zero_mul]
  rw [csum_point (f a) (fun b => (pointMat f : Mat S ι κ) a b * M b c) h,
    pointMat_apply_self, one_mul]

/-- **Transforms fuse.** Two plain functions in sequence denote the composite
function's transition: the `Transform` row is a functor, so a decoding step
followed by a projection is one step and costs what one step costs. -/
theorem pointMat_pointMat [CommSemiring S] [CompleteCSemiring S] (f : ι → κ) (g : κ → ν) :
    comp (pointMat f : Mat S ι κ) (pointMat g) = pointMat (fun a => g (f a)) := by
  rw [pointMat_comp]
  funext a c
  rfl

/-- **Branching on a coproduct**: the input has already been decoded onto
`ι ⊕ κ`, and each side is handled by its own transition. This is the matrix
the design's `Choice` row denotes — the finite coproduct of verdicts through
which the static fragment buys value-dependence. -/
def caseMat (M : Mat S ι ν) (N : Mat S κ ν) : Mat S (Sum ι κ) ν :=
  fun x c =>
    match x with
    | Sum.inl a => M a c
    | Sum.inr b => N b c

/-- A branch followed by a common continuation is the branch of the two
continued arms: whatever both sides do next may be pushed into either side.
This is the first composition law of the coproduct. -/
theorem caseMat_comp [CommSemiring S] [CompleteCSemiring S]
    (M : Mat S ι ν) (N : Mat S κ ν) (P : Mat S ν ρ) :
    comp (caseMat M N) P = caseMat (comp M P) (comp N P) := by
  funext x c
  cases x <;> rfl

/-- Injecting on the left and then branching is the left arm — the coproduct's
computation rule, and the second composition law. Together with `caseMat_inr`
this says the branch really is defined by what it does on the two injections,
so nothing about `caseMat` depends on the encoding of `Sum`. -/
theorem caseMat_inl [CommSemiring S] [CompleteCSemiring S] (M : Mat S ι ν) (N : Mat S κ ν) :
    comp (pointMat Sum.inl) (caseMat M N) = M := by
  rw [pointMat_comp]
  funext a c
  rfl

/-- Injecting on the right and then branching is the right arm. -/
theorem caseMat_inr [CommSemiring S] [CompleteCSemiring S] (M : Mat S ι ν) (N : Mat S κ ν) :
    comp (pointMat Sum.inr) (caseMat M N) = N := by
  rw [pointMat_comp]
  funext a c
  rfl

/-! ### The truncating fan: bounded data-dependent width

`Agentic.Term`'s `fanT n` maps a sub-workflow across a list whose length only
the values decide, promising at most `n` of them, and the promise was recorded
there as a commitment on the *meaning*: the fold truncates its input at `n`.
This section is where that commitment is paid.

The weight of a list `as` becoming a list `bs` is the product of the entrywise
weights, provided the lengths agree once `as` has been cut to `n`, and `0`
otherwise — so no output longer than `n` has any weight at all
(`fanMat_eq_zero_of_length_gt`) and a `0`-fan denotes the constant `[]`
(`fanMat_zero`). Nothing here aggregates: the fan is a *product* over the
list's positions, because the copies run together rather than as
alternatives. -/

/-! The weight of running several things all of which must happen is the
product of a list of resources — `List.prod`, with `List.prod_nil` for the
empty fan, which costs nothing. This is the fan's arithmetic, as distinct from
`csum`'s, which is the arithmetic of alternatives. -/

/-- **The truncating fan.** `fanMat n M` runs `M` on each of the *first `n`*
elements of its input, weighing an output list by the product of the entrywise
weights when the lengths match and by `0` when they do not.

Truncation is the whole content of the `bounded n` grade's honesty: the
promise "at most `n` copies" is not enforced by a length-indexed input type,
it is *made true* by the meaning, which simply cannot see past the `n`-th
element (`fanMat_take`). -/
def fanMat [CommSemiring S] (n : Nat) (M : Mat S ι κ) : Mat S (List ι) (List κ) :=
  fun as bs =>
    if (as.take n).length = bs.length then
      (List.zipWith (fun a b => M a b) (as.take n) bs).prod
    else 0

/-- Cutting the input at `n` before the fan changes nothing, because the fan
cuts it anyway: two inputs agreeing on their first `n` entries have the same
meaning under `fanT n`. -/
theorem fanMat_take [CommSemiring S] (n : Nat) (M : Mat S ι κ) (as : List ι) :
    fanMat n M (as.take n) = fanMat n M as := by
  funext bs
  show (if ((as.take n).take n).length = bs.length then
          (List.zipWith (fun a b => M a b) ((as.take n).take n) bs).prod else 0)
      = if (as.take n).length = bs.length then
          (List.zipWith (fun a b => M a b) (as.take n) bs).prod else 0
  rw [List.take_take, Nat.min_self]

/-- **The truncation is observable**: no output longer than the fan's bound has
any weight. This is the consequence `Agentic.Term.fanT` promised would be
stated at the fold — the `bounded n` grade is not a decoration on a meaning
that could exceed it. -/
theorem fanMat_eq_zero_of_length_gt [CommSemiring S] (n : Nat) (M : Mat S ι κ)
    (as : List ι) (bs : List κ) (h : n < bs.length) : fanMat n M as bs = 0 := by
  have hlen : (as.take n).length ≤ n := by
    rw [List.length_take]; exact Nat.min_le_left n as.length
  show (if (as.take n).length = bs.length then
          (List.zipWith (fun a b => M a b) (as.take n) bs).prod else 0) = 0
  exact if_neg fun he => by omega

/-- **A fan of no copies denotes the constant `[]`**: `fanT 0` is the point
matrix of the function that answers with the empty list, whatever it was
given. This is the observable consequence `Agentic.Term.fanT`'s docstring
promised, in the form it promised it, and it is a corollary of truncation
rather than a special case in the definition. -/
theorem fanMat_zero [CommSemiring S] (M : Mat S ι κ) :
    fanMat 0 M = pointMat (fun _ : List ι => ([] : List κ)) := by
  funext as bs
  cases bs with
  | nil =>
    have h1 : pointMat (fun _ : List ι => ([] : List κ)) as [] = (1 : S) :=
      pointMat_apply_self _ as
    rw [h1]
    rfl
  | cons b bs =>
    have h1 : pointMat (fun _ : List ι => ([] : List κ)) as (b :: bs) = (0 : S) :=
      pointMat_apply_ne (by simp)
    rw [h1]
    exact fanMat_eq_zero_of_length_gt 0 M as (b :: bs) (by simp)

/-! ### The truncated star: fuel as a finite unrolling

A retry node carries a fuel, and the design reads fuel as *truncation of the
star* (§5.2). The truncated star is a finite object, and this section builds
it: powers of a square matrix, the Horner sum of those powers, and the block
split that turns a body returning `o ⊕ i` — *answer* or *go round again* —
into the fueled retry matrix.

The *untruncated* matrix star is built too, at the end of this module
(`Mat.instKleeneAlgebra`), for **every** carrier whose aggregation is a
supremum. It used to be absent, on the ground that the aggregate-of-powers
construction needed a reindexing law for `csum` that `CompleteCSemiring` does
not have; that ground was mistaken. What the construction needs is not
reindexing but *order* — that the aggregate be a least upper bound — and
`CsumIsSup` supplies exactly that. So `powSum` is no longer the only iteration
this module offers, and the fueled constructions below are what a *fuel* is,
not what a missing star made do.

One algebraic fact governs the shape of everything below: whether aggregation
splits over binary alternatives, `⊕ᵢ (xᵢ + yᵢ) = (⊕ᵢ xᵢ) + (⊕ᵢ yᵢ)`. It does,
in every complete resource semiring — `csumAdditive` above — but only because
`CompleteCSemiring` now says how `csum` and `+` are related in the first place.
The axiom that says so is two-point agreement, `csum_pair`, and it is a real
assumption rather than a bookkeeping one: take the semiring `(Nat ∪ {⊤}, +, ×)`
— ordinary arithmetic, `⊕ = +` and `⊗ = ×` — and aggregate by supremum. It
satisfies every *other* axiom of the class and refutes agreement, since
`csum {2, 3} = sup {2, 3} = 3` while `2 + 3 = 5`. Such a carrier is not a
complete semiring at all; it is a semiring with an unrelated aggregation
bolted on, and the class used to admit it by silence.

That counter-model is **not** this package's `Cost`, and must not be mistaken
for it: in `Cost` the semiring's `⊕` *is* `max`, so aggregating by supremum
agrees with it. The counterexample needs a carrier whose `⊕` and whose
aggregation are pulled apart — arithmetic addition against supremum — which is
exactly what `(Nat ∪ {⊤}, +, ×)` with `csum = sup` supplies.

`powSum` is nonetheless *defined* by the Horner recursion `Σ⁰ = I`,
`Σⁿ⁺¹ = I + M · Σⁿ`, for the separate reason that this makes the unfolding law
`powSum_succ` hold by `rfl`: the fueled loop is a recursion the fold can walk,
not a sum it must first be shown to be. The Σ-of-powers *reading* — that this
is `I + M + M² + ⋯ + Mⁿ` — is the theorem `powSum_eq_sumPow`, and it now holds
unconditionally. -/

/-- Alternatives of transitions, entrywise: `matAdd M N` is the weight of
getting there by `M` *or* by `N`. Fan-in of two whole transitions, as opposed
to the fan-in over intermediate states that composition performs. -/
def matAdd [CommSemiring S] (M N : Mat S ι κ) : Mat S ι κ :=
  fun a b => M a b + N a b

/-- Alternatives of transitions are unbracketed, because alternatives of
weights are. -/
theorem matAdd_assoc [CommSemiring S] (M N P : Mat S ι κ) :
    matAdd (matAdd M N) P = matAdd M (matAdd N P) := by
  funext a b
  exact add_assoc (M a b) (N a b) (P a b)

/-- Alternatives of transitions are unordered. -/
theorem matAdd_comm [CommSemiring S] (M N : Mat S ι κ) :
    matAdd M N = matAdd N M := by
  funext a b
  exact add_comm (M a b) (N a b)

/-- **The refused transition**: every outcome has the impossible weight. This
is the `0` of the meaning space — what a shut gate denotes, and, by the
annihilation laws below, what every pipeline containing one denotes.

It is defined here, beside the identity and the two compositions it interacts
with, rather than in `Agentic.Gate` where it first appeared: the zero matrix is
not about gating, it is the additive unit of the matrix semiring, and gating is
one of the things that produces it. -/
def matZero [CommSemiring S] : Mat S ι κ := fun _ _ => 0

/-- `zeroMat` is `matZero`: the spelling `Agentic.Gate` introduced, kept so
that the refusal theorems there read as they did. -/
abbrev zeroMat [CommSemiring S] : Mat S ι κ := matZero

/-- Refusal is no alternative at all: offering a transition beside the refused
one is offering the transition. -/
theorem matAdd_zero [CommSemiring S] (M : Mat S ι κ) : matAdd M matZero = M := by
  funext a b
  exact add_zero (M a b)

/-- The same on the other side: the refused transition is the unit of
alternation. -/
theorem zero_matAdd [CommSemiring S] (M : Mat S ι κ) : matAdd matZero M = M := by
  funext a b
  exact zero_add (M a b)

/-- Composition distributes over alternatives on the left. The proof is one
application of the semiring's distributive law under the aggregation sign, and
then the split of one aggregation into two that `csumAdditive` licenses. -/
theorem comp_matAdd_left [CommSemiring S] [CompleteCSemiring S]
    (M : Mat S ι κ) (N P : Mat S κ ν) :
    comp M (matAdd N P) = matAdd (comp M N) (comp M P) := by
  funext a c
  show csum (fun b => M a b * (N b c + P b c))
      = csum (fun b => M a b * N b c) + csum (fun b => M a b * P b c)
  rw [← csumAdditive (fun b => M a b * N b c) (fun b => M a b * P b c)]
  exact csum_congr fun b => left_distrib (M a b) (N b c) (P b c)

/-- Composition distributes over alternatives on the right. -/
theorem comp_matAdd_right [CommSemiring S] [CompleteCSemiring S]
    (M N : Mat S ι κ) (P : Mat S κ ν) :
    comp (matAdd M N) P = matAdd (comp M P) (comp N P) := by
  funext a c
  show csum (fun b => (M a b + N a b) * P b c)
      = csum (fun b => M a b * P b c) + csum (fun b => N a b * P b c)
  rw [← csumAdditive (fun b => M a b * P b c) (fun b => N a b * P b c)]
  exact csum_congr fun b => right_distrib (M a b) (N a b) (P b c)

/-- Nothing follows refusal: composing after the refused transition is refusal
again. This is `zero_mul` carried through the aggregation, and it is the reason
the design needs no `Halt`. -/
theorem zero_comp [CommSemiring S] [CompleteCSemiring S] (N : Mat S κ ν) :
    comp (matZero : Mat S ι κ) N = matZero := by
  funext a c
  show (csum fun b => (0 : S) * N b c) = 0
  rw [csum_congr fun b => zero_mul (N b c), csum_zero]

/-- Nothing reaches past refusal: composing before the refused transition is
refusal again. The two annihilation laws together say that a shut gate anywhere
in a pipeline shuts the pipeline. -/
theorem comp_zero [CommSemiring S] [CompleteCSemiring S] (M : Mat S ι κ) :
    comp M (matZero : Mat S κ ν) = matZero := by
  funext a c
  show (csum fun b => M a b * (0 : S)) = 0
  rw [csum_congr fun b => mul_zero (M a b), csum_zero]

/-- **The meaning space is a semiring.** Square matrices over a complete
resource semiring carry Mathlib's `Semiring`: alternation of transitions is `+` with the
refused transition as `0`, composition is `*` with the identity as `1`, and the
fourteen laws are the theorems above — associativity of composition, the two
unit laws, the two distributivities, the two annihilations.

It is a `Semiring` and not a `CommSemiring`, and that is the whole reason the
base class is Mathlib's non-commutative one: `comp M N` is not `comp N M`, so
the meaning space could not be called a semiring at all while the package's
only semiring class demanded a commutative `*`. The category laws of §3–4 and the semiring laws are now the
same statement, made once.

Noncomputable, because `idMat` is: the identity tests equality of states
classically, which is what lets it exist at every index type. -/
noncomputable instance instAddCommMonoid [CommSemiring S] [CompleteCSemiring S] :
    AddCommMonoid (Mat S ι ι) where
  add := matAdd
  zero := matZero
  nsmul n M := Nat.rec matZero (fun _ ih => matAdd ih M) n
  add_comm := matAdd_comm
  add_assoc := matAdd_assoc
  zero_add := zero_matAdd
  add_zero := matAdd_zero

/-- **The meaning space is a semiring.** Composition is `*` with the identity
as `1`, over the entrywise alternation above; the laws are the theorems of this
section. It is a `Semiring` and not a `CommSemiring`, and that is the point:
`comp M N` is not `comp N M`, so the category laws of §3–4 and the semiring
laws are the same statement only because Mathlib's base does not demand a
commutative `*`. -/
noncomputable instance instNSemiring [CommSemiring S] [CompleteCSemiring S] : Semiring (Mat S ι ι) where
  __ := instAddCommMonoid
  mul := comp
  one := idMat
  mul_assoc := comp_assoc
  one_mul := id_comp
  mul_one := comp_id
  left_distrib := comp_matAdd_left
  right_distrib := comp_matAdd_right
  zero_mul := zero_comp
  mul_zero := comp_zero

/-! ### The matrix star, at every carrier whose aggregation is a supremum

This is the payoff of `CsumIsSup`, and it closes the gap the module's opening
paragraphs used to apologise for. `Mat S ι ι` is a `Semiring`; give the entries
a complete lattice and matrices inherit one entrywise; then the three
hypotheses of `KleeneAlgebra.ofSupDistrib` are entrywise readings of the three
facts about `S`, and the matrix star `M∗ = ⨆ₙ Mⁿ` — *some number of steps* —
exists, is a least solution, and satisfies **both** Kleene inductions.

Both matters. `Mat S ι ι` is not commutative, so `kstar_mul_le_self` and
`mul_kstar_le_self` are genuinely different statements; the general
construction proves each by its own induction on the exponent, which is why
this instance costs nothing beyond the two distributive laws below.
-/

/-- **Matrices inherit the entries' complete lattice, entrywise.** Nothing is
new here — it is Mathlib's `Pi` instance twice over — but it has to be said
once, because `Mat` is a type synonym and instance search does not see through
it. The join is alternation of transitions (`matAdd`, by `matAdd_eq_sup`), so
this order is the canonical additive order and not a second one. -/
noncomputable instance instCompleteLattice [CompleteLattice S] :
    CompleteLattice (Mat S ι κ) :=
  inferInstanceAs (CompleteLattice (ι → κ → S))

section IsSup

variable [CommSemiring S] [CompleteCSemiring S] [CompleteLattice S] [CsumIsSup S]

omit [CommSemiring S] [CompleteCSemiring S] [CsumIsSup S] in
/-- An aggregate of transitions is read entrywise: `(⨆ᵢ Fᵢ) a b = ⨆ᵢ Fᵢ a b`.
Mathlib's `iSup_apply`, applied twice, through the `Mat` synonym. -/
theorem apply_iSup {J : Type} (F : J → Mat S ι κ) (a : ι) (b : κ) :
    (⨆ i, F i) a b = ⨆ i, F i a b :=
  calc (⨆ i, F i) a b = (⨆ i, F i a) b := congrFun (iSup_apply (f := F) (a := a)) b
    _ = ⨆ i, F i a b := iSup_apply

/-- **Alternation of transitions is the lattice join.** Offering `M` or `N` is
the entrywise better of the two, which is `csum_add_eq_sup` at every entry. It
replaces `Mat.instIdemAdd`, which used to induce a *second* order on matrices
from `+` rather than reading off the one the entries already carried. -/
theorem matAdd_eq_sup (M N : Mat S ι κ) : matAdd M N = M ⊔ N :=
  funext fun a => funext fun b => csum_add_eq_sup (M a b) (N a b)

/-- **Composition distributes over an arbitrary alternation on the right**:
`M · (⨆ᵢ Fᵢ) = ⨆ᵢ (M · Fᵢ)`. Two aggregations are exchanged — over the
intermediate state and over the family — which is Fubini for `csum`. -/
theorem comp_iSup {J : Type} (M : Mat S ι κ) (F : J → Mat S κ ν) :
    comp M (⨆ i, F i) = ⨆ i, comp M (F i) := by
  funext a c
  rw [apply_iSup]
  calc csum (fun b => M a b * (⨆ i, F i) b c)
      = csum (fun b => csum fun i => M a b * F i b c) :=
        csum_congr fun b => by rw [apply_iSup, csum_mul_iSup, csum_eq_iSup]
    _ = csum (fun i => csum fun b => M a b * F i b c) := csum_swap _
    _ = ⨆ i, csum fun b => M a b * F i b c := csum_eq_iSup _

/-- **Composition distributes over an arbitrary alternation on the left**:
`(⨆ᵢ Fᵢ) · M = ⨆ᵢ (Fᵢ · M)`. The right-handed twin, and it is a separate
theorem because matrix composition is not commutative. -/
theorem iSup_comp {J : Type} (M : Mat S κ ν) (F : J → Mat S ι κ) :
    comp (⨆ i, F i) M = ⨆ i, comp (F i) M := by
  funext a c
  rw [apply_iSup]
  calc csum (fun b => (⨆ i, F i) a b * M b c)
      = csum (fun b => csum fun i => F i a b * M b c) :=
        csum_congr fun b => by rw [apply_iSup, csum_iSup_mul, csum_eq_iSup]
    _ = csum (fun i => csum fun b => F i a b * M b c) := csum_swap _
    _ = ⨆ i, csum fun b => F i a b * M b c := csum_eq_iSup _

/-- **The matrix star, for every idempotent complete carrier.** Square
transitions over a carrier whose aggregation is a supremum form a Kleene
algebra, with `M∗ = ⨆ₙ Mⁿ` — the transition of running `M` some number of
times, the untruncated limit of `powSum`.

This is what the package used to have exactly one instance of, built by hand at
possibility and called reachability. It now holds at possibility, at worst-case
cost and at consensus weight alike, so §5.2's `(M_A · d)* · M_B` is an element
of the meaning space at *every* factor the design reads a workflow in, and
`retry_least` applies there. Reachability survives as the read-out of this
instance at `Prop` (`Mat.reach`, in `Agentic.Star`), not as its only witness.

Idempotence of `+` comes with the instance, so `Mat.instIdemAdd` — which
induced its own order from `+` — is gone; `add_idem` at matrices is now
Mathlib's, about this order. -/
noncomputable instance instKleeneAlgebra : KleeneAlgebra (Mat S ι ι) :=
  KleeneAlgebra.ofSupDistrib matAdd_eq_sup (fun M F => comp_iSup M F) (fun M F => iSup_comp M F)

/-- **The matrix star is the aggregate of the powers, entrywise**: the weight
of getting from `a` to `b` at all is the aggregate, over the number of steps,
of getting there in exactly that many. At possibility this reads "some finite
path"; at worst-case cost, "the worst of all path lengths". -/
theorem kstar_apply (M : Mat S ι ι) (a b : ι) :
    (M∗) a b = csum fun n : Nat => (M ^ n) a b := by
  show (⨆ n : Nat, M ^ n) a b = _
  rw [apply_iSup, csum_eq_iSup]

end IsSup

/-! Iterated composition is `M ^ n`, the `Monoid` power of the semiring
instance above: `M` run exactly `n` times, with `M ^ 0 = 1 = idMat` — doing
nothing is running the transition no times. -/

/-- **The truncated star.** `powSum n M` is the transition of running `M` at
most `n` times, built by the Horner recursion `Σ⁰ = I`, `Σⁿ⁺¹ = I + M · Σⁿ`.
This is the fueled analogue of `star`, and it is what a `.static` `retryT`
denotes: a finite fold over the term, which is why the fuel leaves the grade
alone and why the grade is honest.

The recursion, not the sum of powers, is the definition; `powSum_eq_sumPow`
recovers the sum on the one extra hypothesis that recovering it needs. -/
noncomputable def powSum [CommSemiring S] [CompleteCSemiring S] : Nat → Mat S ι ι → Mat S ι ι
  | 0, _ => idMat
  | n + 1, M => matAdd idMat (comp M (powSum n M))

/-- No fuel is the identity: a retry allowed zero trips through the body still
does nothing, for free. -/
theorem powSum_zero [CommSemiring S] [CompleteCSemiring S] (M : Mat S ι ι) :
    powSum 0 M = idMat := rfl

/-- **The truncated-star unfolding**, the fueled analogue of `star_eq_left`:
running `M` at most `n+1` times is doing nothing, or running `M` once and then
running it at most `n` more times. Unconditional, and true by `rfl` — which is
the whole reason `powSum` is defined by the Horner recursion rather than as a
sum of powers. -/
theorem powSum_succ [CommSemiring S] [CompleteCSemiring S] (n : Nat) (M : Mat S ι ι) :
    powSum (n + 1) M = matAdd idMat (comp M (powSum n M)) := rfl

/-- The sum of powers, written directly: `I + M + M² + ⋯ + Mⁿ`. This is the
reading one *wants* of the truncated star, and it is kept separate from
`powSum` because only the Horner recursion makes `powSum_succ` hold by `rfl`;
that the two agree is `powSum_eq_sumPow`. -/
noncomputable def sumPow [CommSemiring S] [CompleteCSemiring S] : Nat → Mat S ι ι → Mat S ι ι
  | 0, _ => idMat
  | n + 1, M => matAdd (sumPow n M) (M ^ (n + 1))

/-- The sum of powers satisfies the Horner unfolding. This is the whole
content of the equivalence; the induction is on the fuel, and the only step
that needs additivity of aggregation is pushing `M` across the final `+`. -/
theorem sumPow_horner [CommSemiring S] [CompleteCSemiring S]
    (M : Mat S ι ι) : ∀ n : Nat, matAdd idMat (comp M (sumPow n M)) = sumPow (n + 1) M
  | 0 => by
    show matAdd idMat (comp M idMat) = matAdd idMat (M ^ 1)
    rw [comp_id, pow_one]
  | n + 1 => by
    show matAdd idMat (comp M (matAdd (sumPow n M) (M ^ (n + 1))))
        = matAdd (sumPow (n + 1) M) (M ^ (n + 1 + 1))
    rw [comp_matAdd_left, ← matAdd_assoc, sumPow_horner M n,
      show M ^ (n + 1 + 1) = comp M (M ^ (n + 1)) from pow_succ' M (n + 1)]

/-- **The Σ-reading of the truncated star.** The Horner recursion really is
`I + M + M² + ⋯ + Mⁿ`, so "run the body at most `n` times" and "run it exactly
`k` times, for some `k ≤ n`" are the same transition — in every complete
resource semiring, with no side condition on the carrier. -/
theorem powSum_eq_sumPow [CommSemiring S] [CompleteCSemiring S]
    (M : Mat S ι ι) : ∀ n : Nat, powSum n M = sumPow n M
  | 0 => rfl
  | n + 1 => by
    rw [powSum_succ, powSum_eq_sumPow M n, sumPow_horner M n]

/-! ### The retry block split

A retry body answers into `o ⊕ i`: `Sum.inl` is *done, here is the answer* and
`Sum.inr` is *not yet, go round again with this*. Restricting the body along
the two injections splits it into the exit block and the loop block, and the
fueled retry is the truncated star of the loop followed by the exit. -/

/-- The exit block: the part of a retry body that answers, read off along
`Sum.inl`. -/
def exitBlock (M : Mat S ι (Sum κ ν)) : Mat S ι κ :=
  fun a c => M a (Sum.inl c)

/-- The loop block: the part of a retry body that goes round again, read off
along `Sum.inr`. -/
def loopBlock (M : Mat S ι (Sum κ ν)) : Mat S ι ν :=
  fun a c => M a (Sum.inr c)

/-- **The fueled retry.** `retryTrunc n M` is the design's §5.2 star truncated
at the fuel: go round the loop block at most `n` times, then leave by the exit
block. This is what a `.static` `retryT` denotes, and why its grade is honest —
the meaning is a finite fold over the term, with no appeal to a fixed point
that the term does not exhibit. -/
noncomputable def retryTrunc [CommSemiring S] [CompleteCSemiring S]
    (n : Nat) (M : Mat S ι (Sum κ ι)) : Mat S ι κ :=
  comp (powSum n (loopBlock M)) (exitBlock M)

/-- A retry with no fuel is its body's exit block: one attempt, no trips round
the loop. Unconditional. -/
theorem retryTrunc_zero [CommSemiring S] [CompleteCSemiring S]
    (M : Mat S ι (Sum κ ι)) : retryTrunc 0 M = exitBlock M :=
  id_comp (exitBlock M)

/-- **One iteration of the fueled retry**, unrolled: with fuel `n+1` the
workflow either leaves at once by the exit block, or goes once round the loop
block and retries with fuel `n`. This is `powSum_succ` transported across the
block split; distributing the exit across the two alternatives is where
additivity of aggregation is consumed. -/
theorem retryTrunc_succ [CommSemiring S] [CompleteCSemiring S]
    (n : Nat) (M : Mat S ι (Sum κ ι)) :
    retryTrunc (n + 1) M
      = matAdd (exitBlock M) (comp (loopBlock M) (retryTrunc n M)) := by
  show comp (matAdd idMat (comp (loopBlock M) (powSum n (loopBlock M)))) (exitBlock M)
      = matAdd (exitBlock M)
        (comp (loopBlock M) (comp (powSum n (loopBlock M)) (exitBlock M)))
  rw [comp_matAdd_right, id_comp, comp_assoc]

/-- Value-dependent sequencing: the second transition may depend on the value
the first produced. `k b` is the transition chosen once `b` is known, read as a
matrix out of the one-point index because its source is that value itself. -/
def dependentSeq [CommSemiring S] [CompleteCSemiring S] (M : Mat S ι κ) (k : κ → Mat S Unit ν) :
    Mat S ι ν :=
  fun a c => csum fun b => M a b * k b () c

/-- Value-dependent sequencing IS matrix composition — Chapman–Kolmogorov is
bind, and the meaning space is therefore monadic (design §4, stratification).
The intermediate value is summed over; nothing new is needed, and in
particular the design does not acquire a second sequencing operator when
workflows start branching on what they read. -/
theorem dependentSeq_eq_comp [CommSemiring S] [CompleteCSemiring S]
    (M : Mat S ι κ) (k : κ → Mat S Unit ν) :
    dependentSeq M k = comp M (fun b c => k b () c) := rfl

end Mat

end Agentic
