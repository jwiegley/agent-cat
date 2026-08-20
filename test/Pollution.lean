import Agentic

/-!
# The pollution probe, as a build-gated test

An instance is a claim about a type, not about a file. `instance : CommMonoid
Bool` does not mean "in this package `*` on `Bool` is `or`"; it means "for
everyone who transitively imports this package, `*` on `Bool` is `or`, `1` is
`false`, and `(37 : Bool)` elaborates". The review's probe P7 found three such
claims being made by this package about types it does not own — `Bool` (the type
of every `decide` and of the retired `Term.gateT`'s condition), `Prop` (the sort
of every proposition in Lean), and `ℕ`.

They were removed in two different ways, because the two carriers wanted
different remedies: the join reducers became a type synonym, and the possibility
semiring became a `scoped` namespace. Both of those carriers have since gone
altogether — they lived in the pre-re-derivation stratum, which the `acat-q1i`
excision removed on 2026-08-20 (`doc/research/term-algebra-results.md`) — so the
negations below are no longer *repairs* of anything. They are a **standing
guard**: this file is in `defaultTargets`, so `lake build` fails the moment a
future module installs arithmetic on a type this package does not own. That is
the property worth pinning, and it does not depend on who once broke it.

**How the assertions work.** `fail_if_success have : C := inferInstance` succeeds
exactly when the instance `C` cannot be synthesized, so each `example` below is a
machine-checked *absence*. The file deliberately does **not** `open Agentic`: it
is a faithful stand-in for a downstream user who writes `import Agentic` and then
gets on with their own algebra.

The positive controls at the end matter as much as the negations: an absence
proved by breaking the thing is worthless, so the same file checks that the
carriers the package *does* own still have the algebra they are supposed to have.
Those carriers are now the scope monoid (`Agentic.LastOpt`, `Agentic.Scope`) and
the verdict monoid (`Agentic.Core.Verdict`), which is the whole of the algebra
the surviving package installs.
-/

namespace Agentic.Test

/-! ## `Bool` is nobody's monoid

`Bool` is the result of every `decide`, the tag `Plan.caseB` branches on, and the
second component of what a bounded revision returns. A `CommMonoid Bool` reaches
all of those, and `(1 : Bool)` — which under a race reducer would mean `false` —
is the collision that made the probe alarming rather than theoretical. -/

/-- No multiplication is installed on `Bool`. -/
example : True := by
  fail_if_success have : Mul Bool := inferInstance
  trivial

/-- No `1` is installed on `Bool`; in particular `(1 : Bool)` does not
elaborate, and cannot silently mean `false`. -/
example : True := by
  fail_if_success have : One Bool := inferInstance
  trivial

/-- No monoid, commutative or otherwise, is installed on `Bool`. -/
example : True := by
  fail_if_success have : Monoid Bool := inferInstance
  trivial

/-- And no numerals: `(37 : Bool)` does not elaborate either. -/
example : True := by
  fail_if_success have : NatCast Bool := inferInstance
  trivial

/-! ## `Prop` carries no arithmetic

A reader who has not asked to read propositions as resources is not given
`0 = False`, `1 = True`, `2 = True` and a `NatCast`. -/

/-- No addition on propositions. -/
example : True := by
  fail_if_success have : AddCommMonoid Prop := inferInstance
  trivial

/-- No multiplication on propositions. -/
example : True := by
  fail_if_success have : Mul Prop := inferInstance
  trivial

/-- No numerals on propositions: `(37 : Prop)` does not elaborate. -/
example : True := by
  fail_if_success have : NatCast Prop := inferInstance
  trivial

/-- No semiring on propositions. -/
example : True := by
  fail_if_success have : Semiring Prop := inferInstance
  trivial

/-! ## `ℕ` keeps its own arithmetic

This is the assertion in the *other* direction: whatever the package does with
counting, `ℕ`'s multiplication is still multiplication and its `1` is still
one. -/

/-- `1 * 2 = 2` on `ℕ` means what it has always meant. -/
example : (1 : Nat) * 2 = 2 := by decide

/-- And `ℕ`'s `1` is `1`, not some fold's unit `0`. -/
example : (1 : Nat) ≠ 0 := by decide

/-! ## The positive controls

The two carriers the package owns, reached exactly as a downstream user would
reach them. -/

/-- The scope axis is a monoid — on `Agentic.LastOpt`, which is a type this
package owns, and not on `Option`. -/
example : Monoid (Agentic.LastOpt Nat) := inferInstance

/-- …and it is **not** commutative, which is not an omission: the failure of
commutativity *is* innermost-wins (`Agentic.LastOpt.set_overrides`). This
negation is the one absence in this file that the package asserts on purpose
about a type it does own. -/
example : True := by
  fail_if_success have : CommMonoid (Agentic.LastOpt Nat) := inferInstance
  trivial

/-- Combining two settings of one axis keeps the right one: the inner scope has
the last word. -/
example :
    Agentic.LastOpt.set 2 * Agentic.LastOpt.set 5 = (Agentic.LastOpt.set 5 : Agentic.LastOpt Nat) :=
  rfl

/-- The unit of a scope axis is saying nothing. -/
example : (1 : Agentic.LastOpt Nat) = Agentic.LastOpt.unset := rfl

/-- Several axes are the product monoid, which is Mathlib's and not this
package's. -/
example : Monoid (Agentic.Scope Nat Bool) := inferInstance

/-- The verdict monoid is a `MonoidWithZero`, with refusal as the zero: the
algebra a panel folds with, and Mathlib's rather than a private structure. -/
example : MonoidWithZero Agentic.Core.Verdict := inferInstance

/-- Approval is the right unit — `v * approve = v`, here at `v = declined`.
(Annihilation, `declined * v = declined` for arbitrary `v`, is the
`MonoidWithZero` fact above; this example witnesses only the unit law.) -/
example :
    Agentic.Core.Verdict.declined * Agentic.Core.Verdict.approve
      = Agentic.Core.Verdict.declined :=
  Agentic.Core.Verdict.mul_approve _

end Agentic.Test
