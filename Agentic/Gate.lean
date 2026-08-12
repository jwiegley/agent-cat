import Agentic.Matrix

/-!
# Gating as a scalar action

Design §2's Grant/Consent row and §4's `LeftSemimodule` equation. A guard, a
refusal, a policy veto, a permission check: all of them
are one thing in this semantics, the action of a scalar on a matrix. The
scalar is `1` when the condition holds and `0` when it does not, and the whole
behaviour of refusal follows from the semiring laws already proved:

* **Refusal denotes `0`.** A gate that is shut is not a matrix with special
  entries; it is the zero matrix, which is to say the transition that assigns
  every outcome the impossible weight. That matrix is `Mat.matZero`, the
  additive unit of the matrix semiring, and it is defined in `Agentic.Matrix`
  beside the operations it annihilates — refusal is one of the things that
  produces the zero, not what the zero is *for*. `zeroMat` remains its name
  here.

* **`0` annihilates everything downstream.** Composing anything before or
  after a shut gate yields the zero matrix again, by `zero_mul`/`mul_zero`
  under the aggregation. There is therefore **no `Halt` constructor, no
  exception, no early-return bias to stipulate** — one scalar replaces three
  mechanisms, and the propagation of refusal is a theorem rather than an
  interpreter rule.

* **Nesting intersects.** A gate inside a gate is the gate on the conjunction,
  because the indicator scalars multiply. Policy composition is `∧`, and it is
  associative and commutative for the same reason `*` is.

`Mat.gate` is *defined* as that scalar action, so the three points above are
not readings of a guard that happen to agree with each other; they are one
definition and its arithmetic. Every law below is proved from `smul_smul`,
`indicator_and` and the semiring laws, with a case analysis on the guard
appearing only where a guard's two-valuedness is genuinely the point
(`gate_idem`).

The condition is taken as a bare `Prop`, with no `Decidable` instance at all:
the meaning of a guard is a proposition about the world, and deciding it is an
implementation's job, not a precondition for the guard to *mean* something. The
indicator is therefore classical and `noncomputable`, and a policy may be
gated on any condition whatever — that a reviewer would have approved, that a
budget will not be exceeded, that no rule is violated — whether or not anyone
can check it. Nothing below is weakened by this; the guard's two-valuedness
still enters only through `indicator_pos`, `indicator_neg` and the case
analysis inside `indicator_and`.
-/

namespace Agentic

open Classical

namespace Mat

variable {S : Type} {ι κ ν : Type}

/-- The indicator scalar of a condition: the free step `1` if the condition
holds, the impossible alternative `0` if it does not. Every guard in the
design is this scalar and nothing else. -/
noncomputable def indicator [CommSemiring S] (b : Prop) : S :=
  if b then 1 else 0

/-- Scaling a transition by a resource: every weight is multiplied by `s`.
This is the action of the semiring on matrices over it — the only mechanism
gating needs. -/
def smul [CommSemiring S] (s : S) (M : Mat S ι κ) : Mat S ι κ :=
  fun a c => s * M a c

/-- Gating a transition on a condition: **the scalar action of the condition's
indicator**, and nothing else. A guard does not choose between `M` and refusal;
it multiplies by `1` or by `0`, and the choice is what that multiplication
already does. Every law below is therefore semiring arithmetic carried
entrywise, and the guard's two-valuedness enters only through the indicator
(`indicator_pos`, `indicator_neg`, `indicator_and`). -/
noncomputable def gate [CommSemiring S] (b : Prop) (M : Mat S ι κ) : Mat S ι κ :=
  smul (indicator b) M

section Basic

variable [CommSemiring S]

/-- The action is an action: scaling twice is scaling by the product. This is
associativity of `*`, entrywise, and it is what makes nesting of guards
arithmetic rather than case analysis. -/
theorem smul_smul (s t : S) (M : Mat S ι κ) :
    smul s (smul t M) = smul (s * t) M := by
  funext a c
  exact (mul_assoc s t (M a c)).symm

/-- The indicator of a satisfied condition is the free step. -/
theorem indicator_pos {b : Prop} (hb : b) : (indicator b : S) = 1 :=
  if_pos hb

/-- The indicator of a violated condition is the impossible alternative. -/
theorem indicator_neg {b : Prop} (hb : ¬ b) : (indicator b : S) = 0 :=
  if_neg hb

/-- An open gate is no gate at all: scaling by the free step. -/
theorem gate_true {b : Prop} (hb : b) (M : Mat S ι κ) :
    gate b M = M := by
  funext a c
  show (indicator b : S) * M a c = M a c
  rw [indicator_pos hb, one_mul]

/-- A shut gate is refusal — not a diminished transition, the zero one:
scaling by the impossible alternative. -/
theorem gate_false {b : Prop} (hb : ¬ b) (M : Mat S ι κ) :
    gate b M = zeroMat := by
  funext a c
  show (indicator b : S) * M a c = 0
  rw [indicator_neg hb, zero_mul]

/-- Indicators multiply to the indicator of the conjunction: the arithmetic
behind policy composition. -/
theorem indicator_and (b₁ b₂ : Prop) :
    (indicator (b₁ ∧ b₂) : S) = indicator b₁ * indicator b₂ := by
  by_cases h₁ : b₁
  · by_cases h₂ : b₂
    · rw [indicator_pos (S := S) ⟨h₁, h₂⟩, indicator_pos (S := S) h₁,
        indicator_pos (S := S) h₂, one_mul]
    · rw [indicator_neg (S := S) fun h => h₂ h.2, indicator_pos (S := S) h₁,
        indicator_neg (S := S) h₂, mul_zero]
  · rw [indicator_neg (S := S) fun h => h₁ h.1, indicator_neg (S := S) h₁, zero_mul]

/-- **Nesting intersects.** A gate inside a gate is the gate on the
conjunction: policies compose by `∧`, and no order of checking is privileged,
because `∧` is commutative up to the same equality. -/
theorem gate_gate (b₁ b₂ : Prop) (M : Mat S ι κ) :
    gate b₁ (gate b₂ M) = gate (b₁ ∧ b₂) M := by
  show smul (indicator b₁) (smul (indicator b₂) M) = smul (indicator (b₁ ∧ b₂)) M
  rw [smul_smul, indicator_and]

/-- Gating is idempotent: checking the same condition twice checks it once.
What the proof needs is that the indicator is its own square, and that holds
because it is `1` or `0`: `1 * 1 = 1` and `0 * 0 = 0`. -/
theorem gate_idem (b : Prop) (M : Mat S ι κ) :
    gate b (gate b M) = gate b M := by
  show smul (indicator b) (smul (indicator b) M) = smul (indicator b) M
  rw [smul_smul]
  by_cases hb : b
  · rw [indicator_pos hb, one_mul]
  · rw [indicator_neg hb, zero_mul]

/-- Refusal refuses: gating the zero matrix changes nothing, because there is
nothing left to scale. -/
theorem gate_zeroMat (b : Prop) :
    gate b (zeroMat : Mat S ι κ) = zeroMat := by
  funext a c
  exact mul_zero (indicator b)

end Basic

section Annihilation

variable [CommSemiring S] [CompleteCSemiring S]

/-- Nothing follows refusal: composing after the zero matrix is refusal again.
This is `zero_mul` carried through the aggregation, and it is the reason the
design needs no `Halt`. It is the annihilation law of the matrix semiring
(`Mat.zero_comp`), read here where refusal is what produced the zero. -/
theorem zeroMat_comp (N : Mat S κ ν) : comp (zeroMat : Mat S ι κ) N = zeroMat :=
  zero_comp N

/-- Nothing reaches past refusal: composing before the zero matrix is refusal
again. The two annihilation laws together say that a shut gate anywhere in a
pipeline shuts the pipeline. -/
theorem comp_zeroMat (M : Mat S ι κ) : comp M (zeroMat : Mat S κ ν) = zeroMat :=
  comp_zero M

/-- The scalar passes through composition on the left: a guard imposed on the
first step of a pipeline is a guard on the pipeline. -/
theorem smul_comp (s : S) (M : Mat S ι κ) (N : Mat S κ ν) :
    comp (smul s M) N = smul s (comp M N) := by
  funext a c
  show (csum fun b => s * M a b * N b c) = s * csum fun b => M a b * N b c
  rw [csum_mul_left]
  exact csum_congr fun b => mul_assoc s (M a b) (N b c)

/-- The scalar passes through composition on the right as well, so a guard may
be hoisted out of any position in a pipeline: gating is an action on the whole
composite, not a property of one step. -/
theorem comp_smul (s : S) (M : Mat S ι κ) (N : Mat S κ ν) :
    comp M (smul s N) = smul s (comp M N) := by
  funext a c
  show (csum fun b => M a b * (s * N b c)) = s * csum fun b => M a b * N b c
  rw [csum_mul_left]
  refine csum_congr fun b => ?_
  rw [← mul_assoc, mul_comm (M a b) s, mul_assoc]

/-- Hoisting a gate out of a pipeline: guarding the first step guards the
whole composite. Together with `gate_gate` this is the entire calculus of
permissions — no separate propagation rule exists or is needed. -/
theorem gate_comp (b : Prop) (M : Mat S ι κ) (N : Mat S κ ν) :
    comp (gate b M) N = gate b (comp M N) :=
  smul_comp (indicator b) M N

/-- Guarding a later step likewise guards the whole composite. -/
theorem comp_gate (b : Prop) (M : Mat S ι κ) (N : Mat S κ ν) :
    comp M (gate b N) = gate b (comp M N) :=
  comp_smul (indicator b) M N

end Annihilation

end Mat

end Agentic
