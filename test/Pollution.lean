import Agentic

/-!
# The pollution probe, as a build-gated test

An instance is a claim about a type, not about a file. `instance : CommMonoid
Bool` does not mean "in this package `*` on `Bool` is `or`"; it means "for
everyone who transitively imports this package, `*` on `Bool` is `or`, `1` is
`false`, and `(37 : Bool)` elaborates". The review's probe P7 found three such
claims being made by this package about types it does not own — `Bool` (which
is the type of `Term.gateT`'s condition and of every `decide`) and `Prop`
(which is the sort of every proposition in Lean).

They were removed in two different ways, because the two carriers wanted
different remedies (`Agentic.Keys.Race` is a synonym; the possibility semiring
is a scope — each is argued where it is declared). This file is the check that
they *stay* removed, and it is in `defaultTargets`, so `lake build` fails if a
later instance re-pollutes either type.

**How the assertions work.** `fail_if_success have : C := inferInstance` succeeds
exactly when the instance `C` cannot be synthesized, so each `example` below is a
machine-checked *absence*. The file deliberately does **not** `open Agentic`
and deliberately does **not** `open scoped Agentic.Possibility`: it is a
faithful stand-in for a downstream user who writes `import Agentic` and then
gets on with their own algebra.

The positive controls at the end matter as much as the negations: an absence
proved by breaking the thing is worthless, so the same file checks that the
package's own carriers still have the instances they are supposed to have.
-/

namespace Agentic.Test

/-! ## `Bool` is nobody's monoid

`Bool` is the condition of `Term.gateT`, the result of every `decide`, and the
index of every two-point matrix in the package. A `CommMonoid Bool` reaches all
of those, and `(1 : Bool)` — which under the race reducer means `false` — is
the collision that made the probe alarming rather than theoretical. -/

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

The possibility semiring is real and is used throughout `Agentic.Star`, but it
is `scoped` in `Agentic.Possibility`, so a reader who has not asked to read
propositions as resources is not given `0 = False`, `1 = True`, `2 = True` and
a `NatCast`. -/

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

/-- Not even the aggregation class, which is this package's own: the whole
possibility carrier is behind the scope, not merely its arithmetic. -/
example : True := by
  fail_if_success have : CompleteCSemiring Prop := inferInstance
  trivial

/-! ## `ℕ` keeps its own arithmetic

The tally and width reducers are both natural-number folds, and neither is
allowed to decide what `*` on `ℕ` means. This is the assertion that the
wrappers did their job in the *other* direction: `ℕ`'s multiplication is still
multiplication. -/

/-- `1 * 2 = 2` on `ℕ` means what it has always meant. -/
example : (1 : Nat) * 2 = 2 := by decide

/-- And `ℕ`'s `1` is `1`, not the width fold's unit `0`. -/
example : (1 : Nat) ≠ 0 := by decide

/-! ## The positive controls

Each carrier the package *does* own still has its algebra, reached through the
synonym or the scope that now guards it. -/

/-- The race reducer is a commutative monoid — on `Race`, which is a type this
package owns. -/
example : CommMonoid Race := inferInstance

/-- Racing is `or`, with `false` as the unit, exactly as before the synonym:
`Race.of true * Race.of false` is a yes. -/
example : Race.of true * Race.of false = Race.of true := rfl

/-- The unit of the race is "nobody answered". -/
example : (1 : Race) = Race.of false := rfl

/-- The width fold is a commutative monoid on `Width`. -/
example : CommMonoid Width := inferInstance

/-- The width fold is still `max` with `0` for the unit. -/
example : Width.mk 2 * Width.mk 5 = Width.mk 5 := rfl

/-- Both are idempotent, so the speculate/race licence is still available. -/
example : Std.IdempotentOp (α := Race) (· * ·) := inferInstance

/-- The free key monoid is untouched: concatenation on `List` is the one bare
instance the package keeps, and it is argued for in `Agentic.Keys`. -/
example : (1 : List Nat) = [] := rfl

/-- And the possibility semiring is one `open scoped` away, with nothing else
changed. -/
example : True := by
  open scoped Agentic.Possibility in
  exact (fun (_ : CompleteCSemiring Prop) => trivial) inferInstance

end Agentic.Test
