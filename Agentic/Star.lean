import Agentic.Semiring
import Agentic.Instances
import Agentic.Matrix

/-!
# Retry as a star: the loop solved, not unrolled

A retry loop — attempt `A`, and on the decision `d` go round again, otherwise
finish with `B` — has a meaning that is not "some number of unrollings". It is
the least solution of a linear fixed-point equation in the resource semiring,
and the star is the operator that produces it (design §5.2).

Two strengths of hypothesis appear below and the difference between them is the
subject of this module. Under `[StarSemiring S]` — the single unrolling law,
the Conway identities never assumed — the retry solve *answers* the loop
equation, and nothing more can be said: at `Cost` the same equation is answered
by `fin 3`, by `fin 5` and by `inf`, each by `rfl` (`retry_cost_ambiguous`).
Under `[KleeneAlgebra S]` — that law, an idempotent `+`, and Kleene induction —
the retry solve is the *least* answer (`retry_least`), so the loop equation
characterises it and the theorems may say "solves". Every lattice carrier of
this package is a `KleeneAlgebra`, and so are its matrices: possibility,
worst-case cost, consensus weight, and square transitions over any of the
three, all by the one construction of `Agentic.Semiring`
(`KleeneAlgebra.ofSupDistrib`). One carrier is not — the expectation semiring,
whose `+` is not idempotent at the moment module it is meant for — and the
read-outs there are stated at the weaker strength, deliberately (acat-zms,
acat-jmm).

Everything in the retry section is stated over Mathlib's `Semiring` — a
*non*-commutative carrier — because the design's headline solve is at matrices and matrix
composition does not commute. The proofs are left-handed throughout, matching
the design's own `L = M_A · (d · L) + M_B`; commutativity was never used by
them and is no longer required of them. The consequence is the section
`Retry, at matrices` below, where the solve is finally stated at the meaning
space it was written for.

The fixed-point law below is a *theorem*, so the loop's meaning is pinned by
the algebra rather than by an operational story about how many times the body
runs — and with `retry_least` it is pinned completely, since the algebra now
says which of the equation's solutions the loop denotes.
-/

namespace Agentic

open Computability KStar

-- The possibility carrier (`Prop` as a resource semiring) is a scoped
-- instance set, so that importing this package does not install arithmetic on
-- every proposition; the read-outs below are *at* possibility and ask for it.
open scoped Agentic.Possibility

section Retry

variable {S : Type} [Semiring S] [KStar S] [StarSemiring S]

/-- `retry mA mB d` is the meaning of *do `A`; while the decision `d` says so,
do `A` again; then do `B`*: the star of the loop body `mA * d`, followed by the
exit `mB`. The star is not an abbreviation for an infinite sum here — it is a
solution of the loop equation (`retry_fixed`), and over a carrier with Kleene
induction it is the least one (`retry_least`). -/
def retry (mA mB d : S) : S := (mA * d)∗ * mB

/-- The retry loop satisfies its own equation: `retry = A · (d · retry) + B`.
One unrolling of the star, one distribution, one reassociation — and the loop
is seen to be a fixed point, not a limit.

This is half the content of "solve the loop instead of unrolling it": a
workflow with a retry node denotes this element, and the element answers the
design's equation `L = M_A · (d · L) + M_B`. Under the hypothesis in force
here — `StarSemiring`, one unrolling law — it does *not* say the element is the
only such answer, and at `Cost` it is not (`retry_cost_ambiguous`). The other
half is `retry_least`, which needs the stronger `KleeneAlgebra` and is charged
for there; the wording of this theorem is deliberately the weaker one, because its
hypothesis is the weaker one.

The proof is left-handed and uses no commutativity, which is why the whole
section lives over Mathlib's `Semiring`: the same three steps run at matrices, where
`*` is composition. -/
theorem retry_fixed (mA mB d : S) :
    retry mA mB d = mA * (d * retry mA mB d) + mB := by
  show (mA * d)∗ * mB = mA * (d * ((mA * d)∗ * mB)) + mB
  calc (mA * d)∗ * mB
      = (1 + mA * d * (mA * d)∗) * mB := by rw [← StarSemiring.star_eq_left]
    _ = 1 * mB + mA * d * (mA * d)∗ * mB := right_distrib _ _ _
    _ = mB + mA * (d * ((mA * d)∗ * mB)) := by
          rw [one_mul, mul_assoc (mA * d) ((mA * d)∗) mB,
            mul_assoc mA d ((mA * d)∗ * mB)]
    _ = mA * (d * ((mA * d)∗ * mB)) + mB := add_comm _ _

/-- Iterating the impossible step is free: `0* = 1`. A loop that cannot even
begin has exactly one run, the empty one. -/
theorem star_zero : (0 : S)∗ = 1 := by
  calc (0 : S)∗ = 1 + 0 * (0 : S)∗ := StarSemiring.star_eq_left 0
    _ = 1 + 0 := by rw [zero_mul]
    _ = 1 := add_zero 1

/-- A loop whose body cannot happen costs only its exit: `retry 0 mB d = mB`.
The impossible attempt contributes no iterations. -/
theorem retry_zero_body (mB d : S) : retry (0 : S) mB d = mB := by
  show ((0 : S) * d)∗ * mB = mB
  rw [zero_mul, star_zero, one_mul]

/-- A loop that never re-enters is its exit: if the decision is impossible,
`retry mA mB 0 = mB`. -/
theorem retry_zero_decision (mA mB : S) : retry mA mB (0 : S) = mB := by
  show (mA * (0 : S))∗ * mB = mB
  rw [mul_zero, star_zero, one_mul]

omit [StarSemiring S] in
/-- **A loop whose exit is free is the star of its body**: `retry mA 1 d` is
`(M_A · d)*`. One rewrite, and it earns a name because it is the form the
per-carrier read-outs are stated in — the exit contributes nothing, so whatever
the star says about the body is what the loop says. -/
theorem retry_one (mA d : S) : retry mA (1 : S) d = (mA * d)∗ := mul_one _

end Retry

/-! ### The loop's meaning, pinned: retry is the *least* solution

`retry_fixed` says the retry solve answers `L = M_A · (d · L) + M_B`. It does
not say which answer it is, and at `Cost` the question is not idle: the same
equation is answered by `fin 3`, by `fin 5` and by `inf`
(`retry_cost_ambiguous`, below). An equation cannot choose; an order can, and
the order is Mathlib's `≤` — `x ≤ y` iff `x + y = y`, the canonical additive order of
`Agentic.Semiring`.

Under `[KleeneAlgebra S]` — one unrolling law, an idempotent `+`, and Kleene
induction — the retry solve is the *least* answer, and "the loop denotes this
element" becomes a characterisation rather than a coincidence. Everything in
this section is two rewrites away from `star_le_left`; the content is in
`KleeneAlgebra.ofSupDistrib`, where leastness is proved once, of the aggregate
of the powers, for every carrier at once.

The hypothesis is charged honestly. Theorems above this line assume only
`[StarSemiring S]` and claim only that the solve *answers* the equation;
theorems below assume `[KleeneAlgebra S]` and claim that it *solves* it. -/

section RetryLeast

variable {S : Type} [KleeneAlgebra S]

/-- **The retry solve absorbs into any invariant of the loop step.** If `x`
absorbs the exit and one more trip — `M_A · (d · x) + M_B ≤ x`, the loop
equation weakened to an inequation — then `retry ≤ x`.

This is Kleene induction with `a := M_A · d` and `b := M_B`; the two rewrites
are the reassociation `M_A · (d · x) = (M_A · d) · x` and the exchange of the
two alternatives. Prefixed points rather than fixed points is the right
generality: it is what makes the theorem usable as an over-approximation
principle (any bound closed under the loop step bounds the loop), and the
fixed-point version is one line below. -/
theorem retry_le_of_step (mA mB d x : S) (h : mA * (d * x) + mB ≤ x) :
    retry mA mB d ≤ x := by
  show (mA * d)∗ * mB ≤ x
  refine star_le_left (mA * d) mB x ?_
  show mB + mA * d * x ≤ x
  rw [mul_assoc mA d x, add_comm mB (mA * (d * x))]
  exact h

/-- **`retry` is the least solution of the design's loop equation.** Every `x`
with `x = M_A · (d · x) + M_B` satisfies `retry M_A M_B d ≤ x`.

With `retry_fixed` — which says `retry` is itself such an `x` — this is the
characterisation the design means by "solve the loop instead of unrolling it":
not *an* answer to §5.2's equation but *the* answer, the least one, the one a
bound checker and a possibility read-out can both be asked for. It is the
statement that the review's under-determination finding is repaired, and it
holds at every carrier that has a `KleeneAlgebra` instance: possibility,
worst-case cost, consensus weight, and the matrices over each. -/
theorem retry_least (mA mB d x : S) (h : x = mA * (d * x) + mB) :
    retry mA mB d ≤ x :=
  retry_le_of_step mA mB d x (le_of_eq h.symm)

/-- **Leastness identifies the solve among the solutions that are below it.**
Two-sided: a solution of the loop equation that is itself below `retry` *is*
`retry`. Antisymmetry of `≤` is what turns "least" into "unique in its
lower set", and it is the form in which a later carrier-specific argument —
"this candidate is a solution and is no worse" — concludes an equality. -/
theorem retry_eq_of_least (mA mB d x : S) (h : x = mA * (d * x) + mB)
    (hle : x ≤ retry mA mB d) : x = retry mA mB d :=
  le_antisymm hle (retry_least mA mB d x h)

end RetryLeast

/-! ### Retry, at matrices: the design's headline solve, and its answer pinned

§5.2 writes the retry solve as `L = (M_A · d)* · M_B`, and the `·` there is
composition of resource-weighted transitions — the solve lives at *matrices*,
which is where a workflow's meaning lives. `retry` and `retry_fixed` are
already stated over an arbitrary `Semiring` carrying a star, and square
matrices are a `Semiring` (`Mat.instNSemiring`); what this section supplies is
the reading, with `*` spelled `Mat.comp` and `+` spelled `Mat.matAdd`, so that
the design's equation and the package's theorem can be compared without an act
of faith.

**The star is no longer a hypothesis.** These sections used to carry
`[KStar (Mat S ι ι)]` and, for leastness, a `ind` argument standing in for
Kleene induction, because the package constructed a matrix star at exactly one
carrier. `Mat.instKleeneAlgebra` constructs it at every carrier whose
aggregation is a supremum, so the hypotheses below are hypotheses *about the
entries* — `[CsumIsSup S]` — and the matrix algebra is built, not assumed. -/

section RetryMat

variable {S : Type} [CommSemiring S] [CompleteCSemiring S] [CompleteLattice S] [CsumIsSup S]
  {ι : Type}

/-- **The retry solve at matrices**, in the design's own notation:
`L = (M_A · d)* · M_B`. This is `retry` with the matrix semiring's operations
written out, and it is true by `rfl` — the general definition already *is* the
design's formula. -/
theorem retry_mat (mA mB d : Mat S ι ι) :
    retry mA mB d = Mat.comp ((Mat.comp mA d)∗) mB := rfl

/-- **The design's loop equation, at matrices**: `L = M_A · (d · L) + M_B`
(§5.2), with composition for `·` and alternation of transitions for `+`.

The scalar proof transfers verbatim because it never used commutativity of
`*`; this theorem is `retry_fixed` at `Mat S ι ι`, not a re-proof. -/
theorem retry_mat_fixed (mA mB d : Mat S ι ι) :
    retry mA mB d = Mat.matAdd (Mat.comp mA (Mat.comp d (retry mA mB d))) mB :=
  retry_fixed mA mB d

/-- **The design's loop equation, at matrices, with its answer pinned**: every
transition `L` satisfying `L = M_A · (d · L) + M_B` is above the retry solve.
This is `retry_least` at `Mat S ι ι`, so §5.2's `(M_A · d)* · M_B` is *the*
meaning of a retry node and not one of several transitions that happen to
satisfy its equation.

**Written in the design's own spelling.** Composition is `Mat.comp`,
alternation is `Mat.matAdd`, and `≤` is the entrywise order of
`Mat.instCompleteLattice` — the package's own matrix semiring throughout.

Left-handed Kleene induction used to be a *hypothesis* of this theorem, on the
ground that no matrix star existed at an arbitrary complete carrier and so
there was no `KleeneAlgebra (Mat S ι ι)` to quantify over. There is one now, so
the theorem constructs its algebra instead of assuming it, and the fence comes
down. -/
theorem retry_mat_least (mA mB d L : Mat S ι ι)
    (h : L = Mat.matAdd (Mat.comp mA (Mat.comp d L)) mB) :
    retry mA mB d ≤ L :=
  retry_least mA mB d L h

end RetryMat

/-! ### Reachability: the general matrix star, read at possibility

Reachability *was* the package's only matrix star — a hand-built aggregate of
powers with its own induction principle, its own unrolling law and its own
leastness argument, some two hundred lines of it. `Mat.instKleeneAlgebra`
supplies all of that generically, so what is left here is the reading: at the
possibility carrier the aggregate over path lengths is an existential, so the
star of a transition relation is "some finite path", and the reflexive–
transitive closure facts are *read out* of the Kleene laws rather than proved
by induction on a path.

Every theorem below is one Kleene law at one carrier. That is the point: the
facts a reader knows about reachability are the facts a Kleene algebra has, and
recognising them as such is what made three other matrix stars appear at the
same time. -/

namespace Mat

variable {ι : Type}

/-- `reach M` is a representation of *reachability* under the transition `M`:
the entry `reach M a b` is the aggregate, over every number of steps `n`, of
getting from `a` to `b` in exactly `n` steps.

It is now *defined* as the general matrix star `M∗`, and the name is kept
because `reach` is what this element is called at this carrier: at possibility
the aggregate is `∃`, so the entry says "some finite path leads from `a` to
`b`". -/
noncomputable def reach (M : Mat Prop ι ι) : Mat Prop ι ι := M∗

/-- Reachability *is* the star: the definition, named so that a reader who
recognises one spelling recognises the other. -/
theorem reach_eq_kstar (M : Mat Prop ι ι) : reach M = M∗ := rfl

/-- Reachability unfolded: at possibility the aggregate over path lengths is an
existential, so `reach` is "some finite path". This is `Mat.kstar_apply` — the
general entrywise reading of the star — with `csum` at `Prop` read as `∃`. -/
theorem reach_iff (M : Mat Prop ι ι) (a b : ι) :
    reach M a b ↔ ∃ n : Nat, (M ^ n) a b :=
  iff_of_eq (kstar_apply M a b)

/-- **The additive order at `Prop`-matrices is entrywise implication.** With
the entrywise complete lattice of `Mat.instCompleteLattice` this is `Iff.rfl`:
`≤` on matrices is `≤` at every entry, and `≤` on `Prop` is `→`. The order in
which leastness is stated is therefore the order a reader of a transition
relation already has in mind: `N` allows every transition `M` allows. -/
theorem le_iff_entrywise {M N : Mat Prop ι ι} :
    M ≤ N ↔ ∀ a b, M a b → N a b := Iff.rfl

/-- Every state reaches itself, by the empty path. This is `one_le_kstar` —
the star is above the identity — read at one diagonal entry. -/
theorem reach_refl (M : Mat Prop ι ι) (a : ι) : reach M a a :=
  le_iff_entrywise.mp one_le_kstar a a (cast (idMat_self a).symm trivial)

/-- An edge is a path: one possible transition makes its target reachable.
This is Mathlib's `le_kstar`, `M ≤ M∗`, read at one entry. -/
theorem reach_of_edge (M : Mat Prop ι ι) {a b : ι} (h : M a b) : reach M a b :=
  le_iff_entrywise.mp le_kstar a b h

/-- Reachability is transitive, by concatenation of paths. This is Mathlib's
`kstar_mul_kstar` — `M∗ · M∗ = M∗`, the star is idempotent under composition —
read at one entry, where composition at possibility is "via some intermediate
state". -/
theorem reach_trans (M : Mat Prop ι ι) {a b c : ι}
    (hab : reach M a b) (hbc : reach M b c) : reach M a c := by
  have h : (M∗ * M∗) a c := ⟨b, hab, hbc⟩
  rwa [kstar_mul_kstar] at h

/-- **Reachability is the *least* reflexive–transitive relation containing
`M`**: whatever is reflexive, transitive and holds of every edge holds wherever
`reach M` does. With `reach_refl`, `reach_of_edge` and `reach_trans` this makes
"`reach M` is the reflexive–transitive closure of `M`" a theorem rather than a
gloss on the name.

The proof is Mathlib's `kstar_le_of_mul_le_left`: a relation above the identity
that absorbs one more edge on the right absorbs the whole star. Reflexivity is
`1 ≤ R`; absorption is transitivity composed with "every edge is in `R`". No
induction on the length of a path appears anywhere, because the induction lives
once, in `KleeneAlgebra.ofSupDistrib`. -/
theorem reach_least (M : Mat Prop ι ι) (R : ι → ι → Prop)
    (hrefl : ∀ a, R a a) (hedge : ∀ a b, M a b → R a b)
    (htrans : ∀ a b c, R a b → R b c → R a c) {a b : ι}
    (h : reach M a b) : R a b := by
  refine le_iff_entrywise.mp (kstar_le_of_mul_le_left ?_ ?_) a b h
  · refine le_iff_entrywise.mpr fun x y hxy => ?_
    by_cases hx : x = y
    · exact hx ▸ hrefl x
    · exact False.elim (cast (idMat_ne hx) hxy)
  · exact le_iff_entrywise.mpr fun x y hxy =>
      match hxy with
      | ⟨c, hxc, hcy⟩ => htrans x c y hxc (hedge c y hcy)

/-- **The retry solve, at matrices over possibility, read out.** A retry loop
can end at `b` from `a` exactly when attempt-and-retry reaches some state `c`
from which the exit reaches `b`. This is the design's `(M_A · d)* · M_B`
evaluated, not paraphrased — and `retry_mat_fixed` and `retry_mat_least` apply
to it. -/
theorem retry_reach_iff (mA mB d : Mat Prop ι ι) (a b : ι) :
    retry mA mB d a b ↔ ∃ c, reach (comp mA d) a c ∧ mB c b := Iff.rfl

end Mat

/-- **The retry solve is least at `Prop`-matrices**, where the star is
reachability. A special case of `retry_mat_least` now that the matrix Kleene
algebra exists at every carrier; kept because possibility is the factor the
design's reachability read-out is stated in. -/
theorem retry_mat_least_prop {ι : Type} (mA mB d L : Mat Prop ι ι)
    (h : L = Mat.matAdd (Mat.comp mA (Mat.comp d L)) mB) :
    retry mA mB d ≤ L :=
  retry_mat_least mA mB d L h

/-! ### The witness the matrix star was wanted for: consensus weight

The point of a matrix star that is not tied to possibility is that a workflow's
meaning at *another* factor also has one. `Mat Prob ι ι` is the case the design
asks for by name — best-path absorption of a Markov chain, §5.2 — and it was
out of reach while the only matrix star was reachability. The two theorems
below are that carrier's star, existing and least. -/

/-- **Consensus weight has a matrix star.** The Viterbi semiring is a complete
lattice whose aggregation is its supremum, so `Mat Prob ι ι` is a Kleene
algebra: the best-weighted run from `a` to `b` over *any* number of steps is an
element of the meaning space. -/
noncomputable example {ι : Type} : KleeneAlgebra (Mat Prob ι ι) := inferInstance

/-- **The retry solve is least at `Prob`-matrices too.** The design's loop
equation at the consensus-weight factor has the retry solve for its least
answer, exactly as at possibility — the statement `acat-ew8` wanted and could
not have. Nothing is proved here beyond naming the instance: the content is
`Mat.instKleeneAlgebra`, and that this line typechecks *is* the payoff. -/
theorem retry_mat_least_prob {ι : Type} (mA mB d L : Mat Prob ι ι)
    (h : L = Mat.matAdd (Mat.comp mA (Mat.comp d L)) mB) :
    retry mA mB d ≤ L :=
  retry_mat_least mA mB d L h

/-- **And at worst-case cost.** The third lattice carrier, for completeness:
a retry loop between states has a least worst-case bound. `Mat Cost ι ι` was
the carrier `acat-9ml` was opened for. -/
theorem retry_mat_least_cost {ι : Type} (mA mB d L : Mat Cost ι ι)
    (h : L = Mat.matAdd (Mat.comp mA (Mat.comp d L)) mB) :
    retry mA mB d ≤ L :=
  retry_mat_least mA mB d L h

/-- **A one-point transition is a scalar, and its powers are the scalar's.**
A `1 × 1` composition aggregates over a one-point intermediate index, which is
`csum_unit`; so the `n`-th power of a `1 × 1` transition is the `n`-th power of
its single entry. -/
theorem Mat.pow_unit {S : Type} [CommSemiring S] [CompleteCSemiring S] (M : Mat S Unit Unit) :
    ∀ n : Nat, (M ^ n) () () = (M () ()) ^ n
  | 0 => by
    rw [pow_zero, pow_zero]
    exact Mat.idMat_self ()
  | n + 1 => by
    have h : (M * M ^ n) () () = csum (fun b : Unit => M () b * (M ^ n) b ()) := rfl
    rw [pow_succ' M n, h, csum_unit, Mat.pow_unit M n, ← pow_succ' (M () ()) n]

/-- **A `Prob`-matrix star, computed.** At the one-point index a transition
*is* a consensus weight, and the matrix star is the scalar star of its single
entry — so the matrix construction really does aggregate the powers, and at
this carrier it aggregates the powers of a probability. With `Prob.kstar_eq`
this is a number: `1` for a sub-unit body, `⊤` for a body that amplifies. -/
theorem Mat.kstar_unit_prob (M : Mat Prob Unit Unit) : (M∗) () () = (M () ())∗ := by
  rw [Mat.kstar_apply M () (), csum_congr (Mat.pow_unit M)]
  rfl

/-- **The Viterbi read-out of the matrix star**: the weight of getting from `a`
to `b` at all is the *best* weight over all path lengths — best-path absorption
of a Markov chain, which is what §5.2 asks the probability factor for. This is
`Mat.kstar_apply` with `csum` at this carrier read as `⨆`. -/
theorem Mat.kstar_prob_apply {ι : Type} (M : Mat Prob ι ι) (a b : ι) :
    (M∗) a b = ⨆ n : Nat, (M ^ n) a b :=
  Mat.kstar_apply M a b

/-! ### Fuel: the star truncated

A retry node with a fuel does not denote the star; it denotes the star
*truncated* at the fuel (design §5.2, and `Mat.powSum` for the matrix form).
The truncation is the same Horner recursion as the star's own unfolding law,
with the recursive occurrence replaced by one less fuel — so the fueled loop
is a finite fold, which is exactly why a fueled retry keeps a static grade. -/

section Trunc

variable {S : Type} [Semiring S]

/-- `starTrunc n x` is the resource of doing `x` at most `n` times: the scalar
truncated star, `1 + x · (1 + x · (⋯))` to depth `n`. Where `star` answers the
loop equation, this one unrolls it a bounded number of times and stops — which
is all a fuel promises. -/
def starTrunc : Nat → S → S
  | 0, _ => 1
  | n + 1, x => 1 + x * starTrunc n x

/-- No fuel is the free step: a loop allowed no trips is the empty run. -/
theorem starTrunc_zero (x : S) : starTrunc 0 x = 1 := rfl

/-- The truncated unrolling: fuel `n+1` is *do nothing, or do `x` and continue
with fuel `n`*. This is `StarSemiring.star_eq_left` with the star replaced by one
less fuel, and unlike that law it is true by `rfl` — the fuel makes the
fixed-point equation into a recursion. -/
theorem starTrunc_succ (n : Nat) (x : S) :
    starTrunc (n + 1) x = 1 + x * starTrunc n x := rfl

/-- Fuel that has stopped mattering never starts again: if truncating at `n`
already agrees with the star, so does truncating at `n+1`. This is the exact
sense in which the truncation approximates the solution — the star is a fixed
point of the very step the truncation iterates. -/
theorem starTrunc_succ_of_eq [KStar S] [StarSemiring S] {n : Nat} {x : S}
    (h : starTrunc n x = x∗) : starTrunc (n + 1) x = x∗ := by
  rw [starTrunc_succ, h, ← StarSemiring.star_eq_left]

end Trunc

section TruncMatrix

variable {S : Type} [CommSemiring S] [CompleteCSemiring S]

/-- **The scalar truncated star is the matrix one, at one state.** A `1 × 1`
transition is a scalar, and `Mat.powSum` at the one-point index is
`starTrunc` — so the fueled retry of `Matrix` and the fueled loop of this
module are the same construction seen at two widths, not two constructions
that happen to be named alike. -/
theorem powSum_unit_eq_starTrunc (x : S) :
    ∀ n : Nat, Mat.powSum n (fun _ _ : Unit => x) () () = starTrunc n x
  | 0 => by
    show (Mat.idMat : Mat S Unit Unit) () () = 1
    exact Mat.idMat_self ()
  | n + 1 => by
    show (Mat.idMat : Mat S Unit Unit) () ()
        + csum (fun _ : Unit => x * Mat.powSum n (fun _ _ : Unit => x) () ())
      = 1 + x * starTrunc n x
    rw [Mat.idMat_self, csum_unit, powSum_unit_eq_starTrunc x n]

end TruncMatrix

/-! ### Read-outs at `Prop`: retry is the possibility of the exit

The design reads the retry solve "per factor, changing only the semiring: at
Bool, termination possibility" (§5.2). That read-out was unavailable while the
star lived only at `Cost`; with `Prop`'s Kleene algebra it can be stated, and
what it says is worth stating. -/

/-- Iteration is always possible: `p* = True`. A loop may be run no times, and
running it no times is possible whatever the body — which is Mathlib's
`kstar_eq_one` at a carrier where everything is below `1`. -/
theorem star_prop (p : Prop) : p∗ = True := kstar_eq_one.mpr fun _ => trivial

/-- **Termination possibility.** At the possibility carrier a retry loop can
happen exactly when its *exit* can: the attempt and the retry decision drop
out, because a loop that may be taken zero times imposes no condition.

This is the honest content of "at Bool, termination possibility" — the loop
does not obstruct termination; the exit is what decides it. The scalar reading
is degenerate by design (a `1 × 1` matrix cannot say where the loop went); the
same read-out with the state kept is `Mat.retry_reach_iff`, where the exit's
possibility is required *from a reachable state*. -/
theorem retry_possible (mA mB d : Prop) : retry mA mB d ↔ mB := by
  show ((mA * d)∗ * mB) ↔ mB
  rw [star_prop]
  exact Iff.intro And.right fun h => ⟨trivial, h⟩

/-- **At possibility the loop equation has only one solution.** Every `x` with
`x = 1 + p · x` is `True`, so the under-determination that afflicts `Cost` does
not arise here: the equation already pins the answer, and leastness merely
agrees with it.

The proof is leastness all the same — `star_le_of_eq` gives `p* ≤ x`, which at
this carrier reads `True → x` — and that is the honest way to state the
collapse: not "the star happens to be `True`" but "`True` is below every
solution, and `True` is the top, so every solution is `True`". -/
theorem star_prop_solution (p x : Prop) (h : x = 1 + p * x) : x = True :=
  propext ⟨fun _ => trivial,
    fun _ => le_prop_iff.mp (star_le_of_eq h) (cast (star_prop p).symm trivial)⟩

/-! ### Read-outs at `Cost`: `checkBounds` is the existence of the star

Instantiating the star at worst-case cost turns the static question "does this
retry loop have a bound?" into an equation. The bound exists exactly when the
loop body is free; a body of positive cost, repeated without limit, diverges.
That equivalence — not a syntactic side condition — is what a bound checker
checks. -/

/-- A free loop body iterates for free: `(fin 0)* = fin 0`. This is the one
case in which an unbounded retry still admits a bound. -/
theorem star_fin_zero : (Cost.fin 0)∗ = Cost.fin 0 := by
  rw [Cost.kstar_eq, if_pos (le_refl (Cost.fin 0))]

/-- A loop body of positive cost, iterated without limit, diverges:
`(fin (n+1))* = inf`. There is no finite bound to quote, and the honest
worst case says so. -/
theorem star_pos (n : Nat) : (Cost.fin (n + 1))∗ = Cost.inf := by
  rw [Cost.kstar_eq, if_neg (fun h => absurd (Cost.fin_le_fin.mp h) (by omega))]

/-- An impossible loop body iterates for free: `bot* = fin 0`, since the only
run of the loop is the empty one. -/
theorem star_bot : Cost.bot∗ = Cost.fin 0 := by
  rw [Cost.kstar_eq]
  exact if_pos (bot_le : Cost.bot ≤ Cost.fin 0)

/-- A divergent body stays divergent under iteration. -/
theorem star_inf : Cost.inf∗ = Cost.inf := by
  rw [Cost.kstar_eq, if_neg Cost.not_inf_le_fin]

/-! #### Which solution is it? The two cases of the unrolling equation

At `Cost` the unrolling equation `x = 1 + a · x` does not determine `x`, and
the two theorems below say precisely how much it does determine. Over a costly
body there is only one solution, `inf`, and the star's answer is forced. Over a
free body every `x` at or above `fin 0` is a solution — an infinite family —
and the star's answer is the least of them. Both are read off the class rather
than off any closed form for the star, which is the point of having the
class. -/

/-- **A costly body admits only divergence.** If `a = fin (n+1)` then the
unrolling equation forces `x = inf`: there is nothing to choose between, and
`checkBounds` reporting `inf` is not a conservative approximation but the
answer.

`star_le_of_eq` gives `a* ≤ x`, and `a*` is `inf`, which is the top of the
cost order — so `x` is `inf`. -/
theorem star_pos_solution (n : Nat) {x : Cost} (h : x = 1 + Cost.fin (n + 1) * x) :
    x = Cost.inf :=
  Cost.eq_inf_of_inf_le (star_pos n ▸ star_le_of_eq h)

/-- **A free body admits a whole up-set of bounds.** The solutions of
`x = 1 + fin 0 · x` are exactly the costs at or above `fin 0` — `fin 0`,
`fin 1`, …, and `inf` — because the equation reduces to `fin 0 ⊕ x = x`.

This is the under-determination in its clearest form: an equation with a whole
up-set of answers. `star (fin 0) = fin 0` is the bottom of that up-set, and
`star_le_of_eq` is the theorem that says so, so a free loop is quoted the bound
it deserves rather than one of the infinitely many bounds it satisfies. -/
theorem star_fin_zero_solutions (x : Cost) :
    x = 1 + Cost.fin 0 * x ↔ Cost.fin 0 ≤ x := by
  constructor
  · intro h
    exact star_fin_zero ▸ star_le_of_eq h
  · intro hx
    have h1 : ((Cost.fin 0) * x) = x := one_mul x
    show x = ((Cost.fin 0) + (((Cost.fin 0) * x)))
    rw [h1]
    exact (sup_eq_right.mpr hx).symm

/-- **`checkBounds` is the existence of the star.** A retry loop at worst-case
cost has a finite bound precisely when its body is free; otherwise the star is
`inf`. The static analysis the design calls `checkBounds` is therefore not an
extra judgement layered on top of the semantics — it is the question of which
of the star's two values obtains. -/
theorem star_eq_one_iff (x : Cost) : x∗ = (1 : Cost) ↔ x ≤ Cost.fin 0 :=
  kstar_eq_one

/-- The complementary read-out: an unfree body has no bound at all. -/
theorem star_eq_inf_of_not_le (x : Cost) (hx : ¬ x ≤ Cost.fin 0) :
    x∗ = Cost.inf := by
  rw [Cost.kstar_eq, if_neg hx]

/-- The retry loop at worst-case cost, read out: the loop is bounded exactly
when attempt-and-decide is free, and then the bound is the exit's. Combining
`retry` with the two star values leaves nothing to check by hand. -/
theorem retry_cost_bounded (mA mB d : Cost) (h : (mA * d) ≤ Cost.fin 0) :
    retry mA mB d = mB := by
  show ((mA * d)∗ * mB) = mB
  rw [Cost.kstar_eq, if_pos h]
  exact one_mul mB

/-! ### The finding, memorialized: one equation, three answers, one meaning

The review's machine-checked objection to `retry_fixed` was a counterexample,
and a counterexample deserves to be kept rather than paraphrased. Take the free
attempt and the free decision, `M_A = d = fin 0`, and the exit `M_B = fin 3`.
The design's loop equation `L = M_A · (d · L) + M_B` is then solved by `fin 3`,
by `fin 5` and by `inf` alike — each by `rfl`, so no cleverness is hiding in
the proofs — and `retry_fixed`, which assumes only `StarSemiring`, cannot
distinguish them. Read as a bound checker, the equation would license quoting
`inf` for a loop that costs `3`.

`retry_least` distinguishes them. Under `[KleeneAlgebra Cost]` the retry solve is
below all three, and it *is* `fin 3`: the loop's meaning is the tightest bound
the equation admits, and the other two answers are exposed as the
over-approximations they are. The three theorems below are the finding, its
repair, and the check that the repair bites at the very numbers that produced
it. -/

/-- **The equation under-determines.** All three of `fin 3`, `fin 5` and `inf`
solve `L = M_A · (d · L) + M_B` at `M_A = d = fin 0`, `M_B = fin 3`. Each by
`rfl`: `fin 0` is the unit of `⊗`, so the right-hand side is `L ⊕ fin 3`, and
every `L` at or above `fin 3` is fixed by it.

This is the review finding as a theorem. `retry_fixed` holds of all three
and cannot prefer one, which is exactly why `retry_fixed`'s docstring says the
solve *answers* the equation. -/
theorem retry_cost_ambiguous :
    (Cost.fin 3 = Cost.fin 0 * (Cost.fin 0 * Cost.fin 3) + Cost.fin 3)
      ∧ (Cost.fin 5 = Cost.fin 0 * (Cost.fin 0 * Cost.fin 5) + Cost.fin 3)
      ∧ (Cost.inf = Cost.fin 0 * (Cost.fin 0 * Cost.inf) + Cost.fin 3) :=
  ⟨rfl, rfl, rfl⟩

/-- The retry solve at those numbers is `fin 3`: a free attempt iterated freely,
then an exit costing three. -/
theorem retry_cost_value :
    retry (Cost.fin 0) (Cost.fin 3) (Cost.fin 0) = Cost.fin 3 :=
  retry_cost_bounded _ _ _ (le_of_eq (Cost.fin_mul_fin 0 0))

/-- **And leastness selects it.** The retry solve is below each of the three
solutions, so among the answers the equation admits it is the smallest — and by
`retry_cost_value` that smallest answer is `fin 3`, the true worst case, not
`fin 5` and not `inf`.

Satisfaction has become characterisation at the exact instance where the
distinction was found. -/
theorem retry_cost_selects_least :
    (retry (Cost.fin 0) (Cost.fin 3) (Cost.fin 0) ≤ Cost.fin 3)
      ∧ (retry (Cost.fin 0) (Cost.fin 3) (Cost.fin 0) ≤ Cost.fin 5)
      ∧ (retry (Cost.fin 0) (Cost.fin 3) (Cost.fin 0) ≤ Cost.inf) :=
  ⟨retry_least _ _ _ _ retry_cost_ambiguous.1,
   retry_least _ _ _ _ retry_cost_ambiguous.2.1,
   retry_least _ _ _ _ retry_cost_ambiguous.2.2⟩

/-! ### The payoff: a fueled loop always has a finite worst case

The untruncated star diverges as soon as the body costs anything
(`star_pos`). The *fueled* loop does not: whatever the body's finite cost and
whatever the fuel, the truncated star is a finite bound. That is the whole
argument for fuel — not that it makes the loop terminate, which is an
operational claim, but that it makes the worst case quotable, which is a
denotational one.

The four scalar theorems in this subsection are the **`Unit` shadow** of the
matrix statements that follow: a scalar is a `1 × 1` transition, `starTrunc` is
`Mat.powSum` at the one-point index (`powSum_unit_eq_starTrunc`), and a fueled
retry in the design is a fueled retry *between states*. They are kept because
they are what the `Cost` read-outs above are phrased in, and because the
scalar bound is the one a reader checks by hand; the statement that carries the
design's weight is `Mat.retryTrunc_cost_finite`, and `starTrunc_fin_le` derives
the scalar bound from the matrix one rather than leaving the two related by
resemblance. -/

/-- A loop whose body cannot happen costs nothing, at any fuel. -/
theorem starTrunc_bot (n : Nat) : starTrunc n Cost.bot = Cost.fin 0 := by
  cases n <;> rfl

/-- A free body stays free, at any fuel: the fixed point is reached at once. -/
theorem starTrunc_fin_zero : ∀ n : Nat, starTrunc n (Cost.fin 0) = Cost.fin 0
  | 0 => rfl
  | n + 1 => by
    rw [starTrunc_succ, starTrunc_fin_zero n]
    rfl

/-- **A fueled loop over a finite body has a finite worst case**, and a bound
is exhibited rather than merely asserted: the induction on the fuel produces
the number, one trip's cost at a time. -/
theorem starTrunc_fin : ∀ (n k : Nat), ∃ m, starTrunc n (Cost.fin k) = Cost.fin m
  | 0, _ => ⟨0, rfl⟩
  | n + 1, k =>
    match starTrunc_fin n k with
    | ⟨m, hm⟩ => ⟨k + m, by
        rw [starTrunc_succ, hm]
        show Cost.fin (max 0 (k + m)) = Cost.fin (k + m)
        exact congrArg Cost.fin (Nat.max_eq_right (Nat.zero_le (k + m)))⟩

/-- **The fueled loop never diverges.** Where `star_pos` says an unbounded
retry over a costly body has no bound at all, this says the fuel buys one
back: `checkBounds` on a fueled retry never has to answer `inf`. -/
theorem starTrunc_cost_finite (n k : Nat) : starTrunc n (Cost.fin k) ≠ Cost.inf := by
  match starTrunc_fin n k with
  | ⟨m, hm⟩ =>
    rw [hm]
    exact fun h => Cost.not_inf_le_fin (le_of_eq h.symm)

/-- The truncation is sound for the solution: however much fuel is spent, the
fueled loop is no worse than the star, so a bound proved of the star is a
bound of every truncation of it. -/
theorem starTrunc_le_star (n : Nat) (x : Cost) : starTrunc n x ≤ x∗ := by
  rcases Cost.cost_cases x with hb | ⟨k, hk⟩ | hi
  · subst hb; rw [starTrunc_bot, star_bot]
  · subst hk
    cases k with
    | zero => rw [starTrunc_fin_zero, star_fin_zero]
    | succ _ => rw [star_pos]; exact le_top
  · subst hi; rw [star_inf]; exact le_top

/-! ### Fuel at its honest home: the fueled retry *matrix* has a finite bound

A workflow's meaning is a matrix, so the design's claim about fuel — that a
fueled retry always has a quotable worst case — is a claim about
`Mat.retryTrunc`, not about a scalar. It needs one hypothesis the scalar
statement hides: a `1 × 1` body is bounded by its own single entry, but a body
between states is bounded only if its entries are *uniformly* bounded. Over an
infinite state space that is a real assumption — the worst case is a supremum,
and a supremum of unboundedly growing finite costs is `inf`. `Mat.CostBounded`
names it, and every theorem below charges for it.

With that hypothesis the bound is exhibited, not merely asserted: fuel `n` over
a body bounded by `k` costs at most `n · k + k` — `n` trips round the loop and
one exit. -/

namespace Mat

variable {ι κ ν : Type}

/-- `CostBounded k M` is the property that every transition in `M` costs at
most `k`: a uniform bound on the entries.

Uniformity is the whole content. Entrywise finiteness is not enough for a
matrix bound, because composition aggregates over the intermediate state and
the aggregate of a family of finite costs with no common bound is `inf`. -/
def CostBounded (k : Nat) (M : Mat Cost ι κ) : Prop :=
  ∀ a b, M a b ≤ Cost.fin k

/-- A bound may always be weakened. -/
theorem costBounded_mono {k j : Nat} {M : Mat Cost ι κ} (h : k ≤ j)
    (hM : CostBounded k M) : CostBounded j M :=
  fun a b => le_trans (hM a b) (Cost.fin_le_fin.mpr h)

/-- Doing nothing costs nothing: the identity transition is bounded by every
bound, its entries being `1 = fin 0` and `0 = bot`. -/
theorem idMat_costBounded (k : Nat) : CostBounded k (idMat : Mat Cost ι ι) := by
  intro a b
  by_cases h : a = b
  · cases h
    rw [idMat_self]
    exact Cost.fin_le_fin.mpr (Nat.zero_le k)
  · rw [idMat_ne h]
    exact bot_le

/-- A choice between two bounded transitions is bounded: the worst case of two
alternatives is the worse of them. -/
theorem matAdd_costBounded {k : Nat} {M N : Mat Cost ι κ}
    (hM : CostBounded k M) (hN : CostBounded k N) : CostBounded k (matAdd M N) :=
  fun a b => sup_le (hM a b) (hN a b)

/-- **Bounds add along composition**: a step of at most `j` followed by a step
of at most `k` costs at most `j + k`. The aggregation over the intermediate
state is where uniformity is spent — the bound must hold of every intermediate
state at once for the supremum to respect it. -/
theorem comp_costBounded {j k : Nat} {M : Mat Cost ι κ} {N : Mat Cost κ ν}
    (hM : CostBounded j M) (hN : CostBounded k N) :
    CostBounded (j + k) (comp M N) := by
  intro a c
  refine Cost.csum_le (fun b => ?_)
  have h1 : ((M a b) * (N b c)) ≤ ((M a b) * (Cost.fin k)) :=
    Cost.mul_mono_right _ (hN b c)
  have h2 : ((M a b) * (Cost.fin k)) ≤ ((Cost.fin j) * (Cost.fin k)) := by
    rw [mul_comm (M a b) (Cost.fin k), mul_comm (Cost.fin j) (Cost.fin k)]
    exact Cost.mul_mono_right _ (hM a b)
  exact le_trans h1 h2

/-- **The fueled star of a bounded transition is bounded**: `n` trips over a
body of at most `k` cost at most `n · k`. The induction is on the fuel, and it
is the matrix form of `starTrunc_fin` — with the bound named rather than
existentially quantified. -/
theorem powSum_costBounded {k : Nat} {M : Mat Cost ι ι} (hM : CostBounded k M) :
    ∀ n : Nat, CostBounded (n * k) (powSum n M)
  | 0 => idMat_costBounded _
  | n + 1 => by
    have hcomp : CostBounded (k + n * k) (comp M (powSum n M)) :=
      comp_costBounded hM (powSum_costBounded hM n)
    have harith : k + n * k ≤ (n + 1) * k :=
      Nat.le_of_eq (by rw [Nat.succ_mul, Nat.add_comm])
    exact matAdd_costBounded (idMat_costBounded _) (costBounded_mono harith hcomp)

/-- A retry body's exit block inherits the body's bound. -/
theorem exitBlock_costBounded {k : Nat} {M : Mat Cost ι (Sum κ ν)}
    (hM : CostBounded k M) : CostBounded k (exitBlock M) :=
  fun a c => hM a (Sum.inl c)

/-- A retry body's loop block inherits the body's bound. -/
theorem loopBlock_costBounded {k : Nat} {M : Mat Cost ι (Sum κ ν)}
    (hM : CostBounded k M) : CostBounded k (loopBlock M) :=
  fun a c => hM a (Sum.inr c)

/-- **The fueled retry matrix is bounded, and by an exhibited number**: fuel
`n` over a body bounded by `k` costs at most `n · k + k` — at most `n` trips
round the loop block, then one exit. -/
theorem retryTrunc_costBounded {k : Nat} {M : Mat Cost ι (Sum κ ι)}
    (hM : CostBounded k M) (n : Nat) :
    CostBounded (n * k + k) (retryTrunc n M) :=
  comp_costBounded (powSum_costBounded (loopBlock_costBounded hM) n)
    (exitBlock_costBounded hM)

/-- **The fueled retry never diverges** — the design's payoff for fuel, at the
matrices where a workflow's meaning lives. Where the unbounded star answers
`inf` for any body that costs anything (`star_pos`), no entry of a fueled
retry over a uniformly bounded body is `inf`: `checkBounds` on a fueled retry
node never has to report an unbounded cost.

This is `starTrunc_cost_finite` at full width, and it is the statement the
design's §5.2 actually makes; the scalar one is its `Unit` shadow. -/
theorem retryTrunc_cost_finite {k : Nat} {M : Mat Cost ι (Sum κ ι)}
    (hM : CostBounded k M) (n : Nat) (a : ι) (b : κ) :
    retryTrunc n M a b ≠ Cost.inf := by
  intro h
  exact Cost.not_inf_le_fin (h ▸ retryTrunc_costBounded hM n a b)

end Mat

/-- **The scalar fuel bound, derived at the one-point index.** `starTrunc n`
over a body of cost `k` is at most `n · k`, and the proof is not a second
induction: it is `Mat.powSum_costBounded` at `Unit`, transported by
`powSum_unit_eq_starTrunc`. The scalar payoff theorems above are thereby the
matrix ones seen at one state, not a parallel development — and this version
quotes the bound, where `starTrunc_fin` only promises that one exists. -/
theorem starTrunc_fin_le (n k : Nat) :
    starTrunc n (Cost.fin k) ≤ Cost.fin (n * k) := by
  have hM : Mat.CostBounded k (fun _ _ : Unit => Cost.fin k) :=
    fun _ _ => le_refl _
  have h := Mat.powSum_costBounded hM n () ()
  rw [powSum_unit_eq_starTrunc] at h
  exact h

/-! ### Read-outs at consensus weight: the best run leaves at once

The design reads the retry solve per factor, and at the probability factor it
reads "absorption of a Markov chain" (§5.2). Which probability factor is meant
matters. Sum-product absorption — the total probability of leaving, summed over
path lengths — lives in `(ℝ≥0∞, +, ×)`, a different semiring on the same
numbers, whose star is a geometric series rather than a maximum. The factor §2
actually names is Viterbi, `([0,1], max, ×)`, and that is the one `Prob` reads
off `ℝ≥0∞`: `⊕` is `max`, `⊗` is `×`, and `[0,1]` appears as the hypothesis
`≤ 1` on the theorems that need it.

At Viterbi the read-out is best-path absorption, and it has a sharp closed
form: the most probable run of a retry loop is the one that goes round it no
times. That is not a degeneracy of the formalisation; it is what max-times
says. Each trip multiplies by a probability, probabilities are at most one, and
`⊕` keeps the best alternative — so the best run through a loop is the shortest
one, and the loop's weight is its exit's weight. -/

/-- Iteration at a sub-unit consensus weight is certain: `p* = 1`, the Viterbi
twin of `star_prop`.

The hypothesis `p ≤ 1` is the design's `[0,1]`, and it is a hypothesis rather
than a fact about the type because the carrier is now `ℝ≥0∞` and not a
constructor-restricted stand-in for it. Above `1` the star answers `⊤`, which
is the honest reading of a step that amplifies: iterated without limit it has
no finite weight. -/
theorem star_prob {p : Prob} (hp : p ≤ 1) : p∗ = 1 := kstar_eq_one.mpr hp

/-- **Viterbi absorption.** At consensus weight a retry loop weighs exactly what
its exit weighs: the attempt and the retry decision drop out, because taking the
loop again cannot raise a probability and `max` keeps the best alternative.

This is §5.2's absorption read-out at the Viterbi factor — the best absorbing
run is the immediate exit. The hypothesis is that attempt-and-decide is at most
certain, which is exactly what makes "taking the loop again cannot raise a
probability" true; at `ℝ≥0∞` it has to be said, and saying it is a repair
rather than a restriction. The sum-product reading, where the loop contributes
a geometric series rather than a maximum, is a different semiring on the same
carrier and is not built here. -/
theorem retry_prob (mA mB d : Prob) (h : mA * d ≤ 1) : retry mA mB d = mB := by
  show (mA * d)∗ * mB = mB
  rw [star_prob h, one_mul]

/-! ### Read-outs at expectation: `p* m p*`, and the projection that survives it

§5.2's last read-out is "at the expectation semiring, the expected cost of a
retry loop is `p* m p*`, in three lines". Every ingredient of that sentence now
exists: the expectation semiring is complete (`instCompleteCSemiringSqZero`), so
a meaning may be written over it; it carries a star
(`SqZero.instStarSemiringSqZero`), so a loop has a solve; and the solve's two
components are the two read-outs below — the weight is the loop of the weights,
and the moment is the design's `p* m p*`.

What is *not* claimed is leastness. The additive order needs an idempotent `+`,
and `SqZero P M`'s `+` is idempotent only when `M`'s accumulation is, which the
intended `M` — an expectation of costs, which genuinely adds — is not
(acat-zms). So these are theorems about the solve the design writes down, in
the strength `StarSemiring` licenses: it *answers* the loop equation. Pinning it
needs an order supplied separately, which is acat-jmm. -/

section RetryExpectation

variable {P M : Type} [CommSemiring P] [AddCommMonoid M] [Module P M] [KStar P] [StarSemiring P]

omit [StarSemiring P] in
/-- **The projection commutes with the retry solve.** Forgetting the moment
turns a loop at expectation into the same loop at the weights: the probability
factor of a retry loop is the retry loop of the probability factors.

This is design §3's projection with the star included — `SqZero.pi` is a
homomorphism of semirings (`pi_add`, `pi_mul`) and of stars (`pi_star`), hence
of everything built from them — and it is what makes the expectation carrier a
refinement of the probability carrier rather than a separate story. -/
theorem pi_retry (mA mB d : SqZero P M) :
    SqZero.pi (retry mA mB d) = retry (SqZero.pi mA) (SqZero.pi mB) (SqZero.pi d) :=
  rfl

omit [StarSemiring P] in
/-- **The expected cost of a retry loop.** The moment of the solve is the
exit's moment weighted by the loop's star, plus the body's moment weighted by
the exit and by the star *twice* — `p* m p*`, with the exit's weight carried
along.

The proof is one application of Mathlib's `mul_smul`: the definition already has the
two weightings nested, and the theorem is the statement that they compose into
the single weight `M_B · p* · p*`. -/
theorem retry_moment (mA mB d : SqZero P M) :
    (retry mA mB d).moment
      = ((((mA * d)∗.base) • mB.moment) + ((mB.base * ((mA * d)∗.base * (mA * d)∗.base)) • (mA * d).moment)) := by
  show ((((mA * d)∗.base) • mB.moment)
      + (mB.base • (((mA * d)∗.base * (mA * d)∗.base) • (mA * d).moment))) = _
  exact congrArg (fun m => (((mA * d)∗.base) • mB.moment) + m)
    (mul_smul mB.base ((mA * d)∗.base * (mA * d)∗.base) (mA * d).moment).symm

omit [StarSemiring P] in
/-- **The retry solve at expectation, both components at once**: a pair whose
weight is the retry solve of the weights and whose moment is the expected cost.
This is the read-out the design asks for — "read it per factor, changing only
the semiring" — with the two factors of the expectation semiring read off
separately and no factor left implicit. -/
theorem retry_expectation (mA mB d : SqZero P M) :
    retry mA mB d
      = ⟨retry mA.base mB.base d.base,
         ((((mA * d)∗.base) • mB.moment) + ((mB.base * ((mA * d)∗.base * (mA * d)∗.base)) • (mA * d).moment))⟩ :=
  SqZero.eq_of_parts (pi_retry mA mB d) (retry_moment mA mB d)

omit [StarSemiring P] in
/-- **`p* m p*`, with the exit removed.** A loop whose exit is free has for its
expected cost exactly the design's formula: the body's moment weighted by the
star on both sides. `retry_one` reduces the loop to the star of its body, and
`SqZero.star_moment` reads the star's moment off. -/
theorem retry_one_moment (mA d : SqZero P M) :
    (retry mA (1 : SqZero P M) d).moment
      = ((mA * d)∗.base * (mA * d)∗.base) • (mA * d).moment := by
  rw [retry_one]
  exact SqZero.star_moment (mA * d)

omit [StarSemiring P] in
/-- **The design's three lines, at the dual numbers.** With the moment module
the carrier itself, the weighting is multiplication and the expected cost of a
free-exit retry loop is literally `p* · m · p*` — §5.2's formula, in §5.2's
order, as a theorem. -/
theorem retry_one_moment_dual (mA d : SqZero P P) :
    (retry mA (1 : SqZero P P) d).moment
      = (mA * d)∗.base * (mA * d).moment * (mA * d)∗.base := by
  rw [retry_one]
  exact SqZero.star_moment_dual (mA * d)

end RetryExpectation

/-- **The expectation semiring carries a meaning.** Composition of transitions
elaborates over `SqZero Prop Prop` and computes what Chapman–Kolmogorov says it
should: the aggregate, over the intermediate state, of the two weighted steps.

This one-line `rfl` is the review's failing probe, repaired. Before
`instCompleteCSemiringSqZero` the term `Mat.comp M N` did not elaborate at this
carrier — there was no `csum` — so the design's fibration had a fibre with no
matrices in it. -/
theorem comp_sqZero_prop (M N : Mat (SqZero Prop Prop) Bool Bool) (a b : Bool) :
    Mat.comp M N a b = csum (fun c => M a c * N c b) := rfl

/-- The same at the probability carrier: expectation over consensus weight
composes too, so the expected-cost meaning exists at the factor §3's projection
projects onto and not only at possibility. -/
theorem comp_sqZero_prob (M N : Mat (SqZero Prob Prob) Bool Bool) (a b : Bool) :
    Mat.comp M N a b = csum (fun c => M a c * N c b) := rfl

/-! ### Every carrier aggregates additively

`Mat.powSum` is a truncated star for any complete resource semiring, and its
reading as `I + M + M² + ⋯` needs aggregation to split over binary
alternatives. That split used to be a hypothesis carried by every theorem that
wanted it; since two-point agreement (`CompleteCSemiring.csum_pair`) joined the
class it is a theorem about every carrier, `csumAdditive`.

The four statements below are what remain of the carrier-specific proofs: not
work, but a check that the general derivation lands where the design says it
lands — at possibility, where the law is `∃` distributing over `∨`; at
worst-case cost, where it is the supremum of pointwise maxima being the maximum
of the suprema; at consensus weight, where it is the same for the probability
order; and at expectation, where it holds componentwise and where, before the
completion of that carrier, it could not be stated at all. Each is now the
general theorem instantiated. -/

/-- Possibility aggregates additively: `∃` distributes over `∨`. -/
theorem csumAdditive_Prop : CsumAdditive Prop := csumAdditive

/-- Worst-case cost aggregates additively: the supremum of pointwise maxima is
the maximum of the suprema. -/
theorem csumAdditive_Cost : CsumAdditive Cost := csumAdditive

/-- Consensus weight aggregates additively: the best of two pointwise bests is
the best of the two aggregates. -/
theorem csumAdditive_Prob : CsumAdditive Prob := csumAdditive

/-- Expectation aggregates additively — the law holds of the completed
square-zero extension, weights and moments together. -/
theorem csumAdditive_SqZero : CsumAdditive (SqZero Prob Prob) := csumAdditive

end Agentic
